[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\codex-worktree-trust-bridge.json'),
    [string]$InstanceName,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$NewBeginMarker = '# BEGIN CODEX WORKTREE TRUST BRIDGE'
$NewEndMarker = '# END CODEX WORKTREE TRUST BRIDGE'
$LegacyBeginMarker = '# BEGIN CODEX AUTO WORKTREE TRUST'
$LegacyEndMarker = '# END CODEX AUTO WORKTREE TRUST'

function Get-CanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd('\', '/')
    }
    return $full.ToLowerInvariant()
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $childKey = Get-CanonicalPath $Child
    $parentKey = Get-CanonicalPath $Parent
    return $childKey -eq $parentKey -or
        $childKey.StartsWith($parentKey + '\', [StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Bridge configuration does not exist: $ConfigPath"
}

$BridgeConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($BridgeConfig.schema -ne 'codex-worktree-trust-bridge.config' -or [int]$BridgeConfig.version -ne 1) {
    throw "Unsupported bridge configuration: $ConfigPath"
}

$AllowedRoots = @($BridgeConfig.allowedRoots | ForEach-Object { Get-CanonicalPath ([string]$_) } | Sort-Object -Unique)
if (-not $AllowedRoots.Count) {
    throw 'At least one allowed root is required.'
}

$UiPollIntervalMs = [Math]::Max(250, [Math]::Min(10000, [int]$BridgeConfig.uiPollIntervalMs))
$ReconcileIntervalSeconds = [Math]::Max(5, [Math]::Min(3600, [int]$BridgeConfig.reconcileIntervalSeconds))
$DiscoveryDepth = [Math]::Max(1, [Math]::Min(8, [int]$BridgeConfig.discoveryDepth))
$EnableConfigTrust = [bool]$BridgeConfig.enableConfigTrust
$EnableUiAutoApprove = [bool]$BridgeConfig.enableUiAutoApprove
$PruneMissingManagedEntries = [bool]$BridgeConfig.pruneMissingManagedEntries

$trustModeProperty = $BridgeConfig.PSObject.Properties['trustMode']
$TrustMode = if ($null -ne $trustModeProperty) {
    ([string]$trustModeProperty.Value).Trim().ToLowerInvariant()
}
else {
    'git-only'
}
if ($TrustMode -notin @('git-only', 'all-directories')) {
    throw "Unsupported trustMode '$TrustMode'. Expected git-only or all-directories."
}

$deniedActionProperty = $BridgeConfig.PSObject.Properties['deniedDialogAction']
$DeniedDialogAction = if ($null -ne $deniedActionProperty) {
    ([string]$deniedActionProperty.Value).Trim().ToLowerInvariant()
}
else {
    'leave-open'
}
if ($DeniedDialogAction -notin @('leave-open', 'cancel')) {
    throw "Unsupported deniedDialogAction '$DeniedDialogAction'. Expected leave-open or cancel."
}

$deniedGraceProperty = $BridgeConfig.PSObject.Properties['deniedDialogGraceSeconds']
$DeniedDialogGraceSeconds = if ($null -ne $deniedGraceProperty) {
    [Math]::Max(0, [Math]::Min(60, [int]$deniedGraceProperty.Value))
}
else {
    3
}

$CodexHome = Join-Path $env:USERPROFILE '.codex'
$CodexConfigPath = Join-Path $CodexHome 'config.toml'
$StateDirectory = Join-Path $CodexHome 'state'
$StatePath = Join-Path $StateDirectory 'codex-worktree-trust-bridge.json'
$LogDirectory = Join-Path $CodexHome 'log'
$LogPath = Join-Path $LogDirectory 'codex-worktree-trust-bridge.log'
$BackupDirectory = Join-Path $CodexHome 'backups\codex-worktree-trust-bridge'
$GitExecutable = (Get-Command git.exe -ErrorAction Stop).Source
$LauncherProcessId = if ($env:CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID) {
    [int]$env:CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID
}
else { $null }

foreach ($directory in @($StateDirectory, $LogDirectory, $BackupDirectory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$userToken = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -replace '[^A-Za-z0-9_.-]', '_')
$instanceToken = if ([string]::IsNullOrWhiteSpace($InstanceName)) {
    $userToken
}
else {
    ($InstanceName -replace '[^A-Za-z0-9_.-]', '_')
}
$InstanceMutex = [Threading.Mutex]::new($false, "Local\CodexWorktreeTrustBridge-$instanceToken")
$ConfigMutex = [Threading.Mutex]::new($false, "Local\CodexWorktreeTrustBridgeConfig-$userToken")
$HasInstanceMutex = $false

function Write-BridgeLog {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data = @{}
    )
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $Event
        data = $Data
    }
    Add-Content -LiteralPath $LogPath -Value ($record | ConvertTo-Json -Compress -Depth 10) -Encoding utf8
}

function Invoke-GitLines {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitExecutable
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add('-C')
    [void]$startInfo.ArgumentList.Add($WorkingDirectory)
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'git.exe did not start.'
        }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputText = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult().Trim()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($errorText)) { '' } else { ": $errorText" }
        throw "git -C '$WorkingDirectory' $($Arguments -join ' ') failed with exit $exitCode$detail"
    }
    if ([string]::IsNullOrEmpty($outputText)) { return @() }
    return @($outputText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
}

function Test-AllowedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($allowedRoot in $AllowedRoots) {
        if (Test-PathInside -Child $Path -Parent $allowedRoot) { return $true }
    }
    return $false
}

function Get-AllowedRootForPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($allowedRoot in $AllowedRoots) {
        if (Test-PathInside -Child $Path -Parent $allowedRoot) { return $allowedRoot }
    }
    return $null
}

function Test-AllowlistedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'path is not absolute' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'directory does not exist' }
    }

    $canonical = Get-CanonicalPath $Path
    $allowedRoot = Get-AllowedRootForPath $canonical
    if (-not $allowedRoot) {
        return [pscustomobject]@{ Ok = $false; Reason = 'path is outside the allowlist' }
    }

    try {
        $filesystemRoot = Get-CanonicalPath ([IO.Path]::GetPathRoot($canonical))
        $cursor = $canonical
        while ($true) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return [pscustomobject]@{ Ok = $false; Reason = "reparse point is not allowed: $cursor" }
            }
            if ($cursor -eq $filesystemRoot) { break }
            $parent = [IO.Directory]::GetParent($cursor)
            if (-not $parent) {
                return [pscustomobject]@{ Ok = $false; Reason = 'path ancestry could not be validated' }
            }
            $cursor = Get-CanonicalPath $parent.FullName
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = "path validation failed: $($_.Exception.Message)" }
    }

    return [pscustomobject]@{ Ok = $true; Path = $canonical; AllowedRoot = $allowedRoot }
}

function Test-RegisteredGitWorktree {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directoryValidation = Test-AllowlistedDirectory $Path
    if (-not $directoryValidation.Ok) { return $false }
    try {
        $canonical = $directoryValidation.Path
        $top = (Invoke-GitLines -WorkingDirectory $canonical -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1)
        if (-not $top -or (Get-CanonicalPath $top) -ne $canonical) { return $false }
        $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in Invoke-GitLines -WorkingDirectory $canonical -Arguments @('worktree', 'list', '--porcelain')) {
            if ($line -match '^worktree\s+(.+)$') {
                [void]$registered.Add((Get-CanonicalPath $Matches[1].Trim()))
            }
        }
        return $registered.Contains($canonical)
    }
    catch {
        return $false
    }
}

function Test-TrustEligiblePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directoryValidation = Test-AllowlistedDirectory $Path
    if (-not $directoryValidation.Ok) { return $directoryValidation }
    if ($TrustMode -eq 'git-only' -and -not (Test-RegisteredGitWorktree $directoryValidation.Path)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'path is not an allowlisted registered Git worktree' }
    }
    return [pscustomobject]@{
        Ok = $true
        Path = $directoryValidation.Path
        AllowedRoot = $directoryValidation.AllowedRoot
        TrustMode = $TrustMode
    }
}

function New-PathSet {
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    return ,$set
}

function Load-ManagedState {
    $set = New-PathSet
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            foreach ($path in @($state.managedPaths)) {
                if ($path) { [void]$set.Add((Get-CanonicalPath ([string]$path))) }
            }
        }
        catch {
            Write-BridgeLog -Event 'STATE_READ_ERROR' -Data @{ error = $_.Exception.Message }
        }
    }
    return ,$set
}

function Save-ManagedState {
    param([Parameter(Mandatory = $true)]$ManagedPaths)
    $payload = [ordered]@{
        schema = 'codex-worktree-trust-bridge.state'
        version = 1
        updatedAt = (Get-Date).ToString('o')
        trustMode = $TrustMode
        managedPaths = @($ManagedPaths | Sort-Object)
    }
    $temporary = "$StatePath.tmp-$PID"
    [IO.File]::WriteAllText($temporary, ($payload | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
}

function Get-ManagedPathsFromBlock {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$BeginMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker
    )
    $set = New-PathSet
    $pattern = '(?s)' + [regex]::Escape($BeginMarker) + '(.*?)' + [regex]::Escape($EndMarker)
    $block = [regex]::Match($Text, $pattern)
    if (-not $block.Success) { return ,$set }
    foreach ($match in [regex]::Matches($block.Groups[1].Value, "(?im)^\s*\[projects\.'([^']+)'\]\s*$")) {
        try { [void]$set.Add((Get-CanonicalPath $match.Groups[1].Value)) } catch {}
    }
    return ,$set
}

function Remove-ManagedBlocks {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $result = $Text
    foreach ($markers in @(
        @($LegacyBeginMarker, $LegacyEndMarker),
        @($NewBeginMarker, $NewEndMarker)
    )) {
        $pattern = '(?s)\r?\n?' + [regex]::Escape($markers[0]) + '.*?' + [regex]::Escape($markers[1]) + '\r?\n?'
        $result = [regex]::Replace($result, $pattern, '')
    }
    return $result.TrimEnd()
}

function ConvertFrom-TomlBasicString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $builder = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -ne '\') {
            [void]$builder.Append($character)
            continue
        }

        $index++
        if ($index -ge $Value.Length) {
            throw 'Invalid trailing escape in a TOML basic string.'
        }

        $escape = $Value[$index]
        switch -CaseSensitive ($escape) {
            '"' { [void]$builder.Append('"') }
            '\' { [void]$builder.Append('\') }
            'b' { [void]$builder.Append([char]8) }
            't' { [void]$builder.Append([char]9) }
            'n' { [void]$builder.Append([char]10) }
            'f' { [void]$builder.Append([char]12) }
            'r' { [void]$builder.Append([char]13) }
            'u' {
                if ($index + 4 -ge $Value.Length) {
                    throw 'Incomplete Unicode escape in a TOML basic string.'
                }
                $hex = $Value.Substring($index + 1, 4)
                if ($hex -notmatch '^[0-9A-Fa-f]{4}$') {
                    throw "Invalid Unicode escape in a TOML basic string: \u$hex"
                }
                $codePoint = [Convert]::ToInt32($hex, 16)
                if ($codePoint -ge 0xD800 -and $codePoint -le 0xDFFF) {
                    throw 'A TOML Unicode escape cannot encode an isolated surrogate.'
                }
                [void]$builder.Append([char]::ConvertFromUtf32($codePoint))
                $index += 4
            }
            'U' {
                if ($index + 8 -ge $Value.Length) {
                    throw 'Incomplete long Unicode escape in a TOML basic string.'
                }
                $hex = $Value.Substring($index + 1, 8)
                if ($hex -notmatch '^[0-9A-Fa-f]{8}$') {
                    throw "Invalid long Unicode escape in a TOML basic string: \U$hex"
                }
                $codePoint = [Convert]::ToInt64($hex, 16)
                if ($codePoint -gt 0x10FFFF -or ($codePoint -ge 0xD800 -and $codePoint -le 0xDFFF)) {
                    throw "Invalid Unicode code point in a TOML basic string: U+$hex"
                }
                [void]$builder.Append([char]::ConvertFromUtf32([int]$codePoint))
                $index += 8
            }
            default { throw "Unsupported TOML basic-string escape: \$escape" }
        }
    }
    return $builder.ToString()
}

function Get-ManualProjectSections {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $headers = New-PathSet
    $trusted = New-PathSet
    $pattern = @'
(?ms)^\s*\[projects\.(?:'([^']*)'|"((?:\\.|[^"\\])*)")\]\s*(?:#[^\r\n]*)?\r?\n(.*?)(?=^\s*\[|\z)
'@.Trim()
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $decodedPath = if ($match.Groups[1].Success) {
            $match.Groups[1].Value
        }
        else {
            ConvertFrom-TomlBasicString $match.Groups[2].Value
        }
        $path = Get-CanonicalPath $decodedPath
        if (-not $headers.Add($path)) {
            throw "Duplicate TOML project table resolves to the same path: $path"
        }
        if ($match.Groups[3].Value -match '(?im)^\s*trust_level\s*=\s*["'']trusted["'']\s*$') {
            [void]$trusted.Add($path)
        }
    }
    return [pscustomobject]@{ Headers = $headers; Trusted = $trusted }
}

function Backup-CodexConfig {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Copy-Item -LiteralPath $CodexConfigPath -Destination (Join-Path $BackupDirectory "config.$stamp.toml")
    $old = @(Get-ChildItem -LiteralPath $BackupDirectory -Filter 'config.*.toml' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20)
    foreach ($file in $old) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
}

function Update-CodexTrustConfig {
    param([Parameter(Mandatory = $true)]$ManagedPaths)
    if (-not $EnableConfigTrust) { return }
    if (-not $ConfigMutex.WaitOne(15000)) { throw 'Timed out waiting for the Codex config mutex.' }
    try {
        if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) {
            New-Item -ItemType File -Force -Path $CodexConfigPath | Out-Null
        }
        $original = [IO.File]::ReadAllText($CodexConfigPath)
        $base = Remove-ManagedBlocks $original
        $manual = Get-ManualProjectSections $base
        $builder = [Text.StringBuilder]::new($base)
        if ($builder.Length -gt 0) { [void]$builder.AppendLine(); [void]$builder.AppendLine() }
        [void]$builder.AppendLine($NewBeginMarker)
        foreach ($path in @($ManagedPaths | Sort-Object)) {
            if ($path.Contains("'")) {
                Write-BridgeLog -Event 'PATH_REFUSED' -Data @{ path = $path; reason = 'single quote is unsupported in TOML project key' }
                continue
            }
            if ($manual.Headers.Contains($path)) { continue }
            [void]$builder.AppendLine("[projects.'$path']")
            [void]$builder.AppendLine('trust_level = "trusted"')
            [void]$builder.AppendLine()
        }
        [void]$builder.AppendLine($NewEndMarker)
        $updated = $builder.ToString()
        if ($updated -eq $original) { return }
        Backup-CodexConfig
        $temporary = "$CodexConfigPath.tmp-$PID"
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $CodexConfigPath -Force
        Write-BridgeLog -Event 'CONFIG_SYNCED' -Data @{ managedCount = $ManagedPaths.Count }
    }
    finally {
        [void]$ConfigMutex.ReleaseMutex()
    }
}

function Test-ExactTrustedEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    $sections = Get-ManualProjectSections $text
    return $sections.Trusted.Contains((Get-CanonicalPath $Path))
}

function Find-GitRoots {
    $results = New-PathSet
    $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('.git', 'node_modules', '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache')) {
        [void]$excluded.Add($name)
    }
    foreach ($allowedRoot in $AllowedRoots) {
        if (-not (Test-Path -LiteralPath $allowedRoot -PathType Container)) { continue }
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{ Path = $allowedRoot; Depth = 0 })
        while ($queue.Count) {
            $item = $queue.Dequeue()
            $marker = Join-Path $item.Path '.git'
            if (Test-Path -LiteralPath $marker) {
                [void]$results.Add((Get-CanonicalPath $item.Path))
                continue
            }
            if ($item.Depth -ge $DiscoveryDepth) { continue }
            foreach ($directory in Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction SilentlyContinue) {
                if ($excluded.Contains($directory.Name)) { continue }
                if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $queue.Enqueue([pscustomobject]@{ Path = $directory.FullName; Depth = $item.Depth + 1 })
            }
        }
    }
    return ,$results
}

function Discover-RegisteredWorktrees {
    $result = New-PathSet
    $gitRoots = Find-GitRoots
    $seenCommonDirectories = New-PathSet
    foreach ($gitRoot in $gitRoots) {
        try {
            $commonDirectory = (Invoke-GitLines -WorkingDirectory $gitRoot -Arguments @('rev-parse', '--git-common-dir') | Select-Object -First 1)
            if (-not [IO.Path]::IsPathFullyQualified($commonDirectory)) {
                $commonDirectory = Join-Path $gitRoot $commonDirectory
            }
            $commonKey = Get-CanonicalPath $commonDirectory
            if (-not $seenCommonDirectories.Add($commonKey)) { continue }
            foreach ($line in Invoke-GitLines -WorkingDirectory $gitRoot -Arguments @('worktree', 'list', '--porcelain')) {
                if ($line -notmatch '^worktree\s+(.+)$') { continue }
                $path = Get-CanonicalPath $Matches[1].Trim()
                if (Test-RegisteredGitWorktree $path) {
                    [void]$result.Add($path)
                }
                else {
                    Write-BridgeLog -Event 'GIT_WORKTREE_SKIPPED' -Data @{
                        path = $path
                        reason = 'registered path failed exact Git root/worktree validation'
                    }
                }
            }
        }
        catch {
            Write-BridgeLog -Event 'GIT_DISCOVERY_ERROR' -Data @{ root = $gitRoot; error = $_.Exception.Message }
        }
    }
    return ,$result
}

$ManagedPaths = Load-ManagedState
$ApprovalCooldown = @{}
$RefusalCooldown = @{}
$CancelCooldown = @{}
$DialogErrorCooldown = @{}
$DenialFirstSeen = @{}

function Import-LegacyManagedPaths {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { return }
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    foreach ($set in @(
        (Get-ManagedPathsFromBlock -Text $text -BeginMarker $LegacyBeginMarker -EndMarker $LegacyEndMarker),
        (Get-ManagedPathsFromBlock -Text $text -BeginMarker $NewBeginMarker -EndMarker $NewEndMarker)
    )) {
        foreach ($path in $set) {
            $validation = Test-TrustEligiblePath $path
            if ($validation.Ok) {
                [void]$ManagedPaths.Add($validation.Path)
            }
        }
    }
}

function Invoke-Reconcile {
    $discovered = Discover-RegisteredWorktrees
    $nextManagedPaths = New-PathSet
    foreach ($path in $discovered) { [void]$nextManagedPaths.Add($path) }
    foreach ($path in @($ManagedPaths)) {
        $validation = Test-TrustEligiblePath $path
        if ($validation.Ok) {
            [void]$nextManagedPaths.Add($validation.Path)
            continue
        }
    }
    $ManagedPaths.Clear()
    foreach ($path in $nextManagedPaths) { [void]$ManagedPaths.Add($path) }
    Update-CodexTrustConfig $ManagedPaths
    Save-ManagedState $ManagedPaths
    Write-BridgeLog -Event 'RECONCILED' -Data @{
        pid = $PID
        launcherPid = $LauncherProcessId
        managedCount = $ManagedPaths.Count
        roots = $AllowedRoots
        trustMode = $TrustMode
    }
}

function Ensure-ManagedTrust {
    param([Parameter(Mandatory = $true)][string]$Path)
    $validation = Test-TrustEligiblePath $Path
    if (-not $validation.Ok) { return $validation }
    $canonical = $validation.Path
    [void]$ManagedPaths.Add($canonical)
    Update-CodexTrustConfig $ManagedPaths
    Save-ManagedState $ManagedPaths
    if (-not (Test-ExactTrustedEntry $canonical)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'exact trusted project entry is absent after config sync' }
    }
    return [pscustomobject]@{ Ok = $true; Path = $canonical }
}

function Get-CodexRootElements {
    $roots = @()
    foreach ($process in Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            if ($root) { $roots += $root }
        }
        catch {}
    }
    return $roots
}

function Get-DialogAncestor {
    param([Parameter(Mandatory = $true)]$Element)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $current = $Element
    while ($current) {
        if ($current.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and
            [string]$current.Current.ClassName -like '*codex-dialog*') {
            return $current
        }
        $current = $walker.GetParent($current)
    }
    return $null
}

function Get-AutomationElementIdentity {
    param([Parameter(Mandatory = $true)]$Element)
    try {
        $runtimeId = @($Element.GetRuntimeId())
        if ($runtimeId.Count) { return 'runtime:' + ($runtimeId -join '.') }
    }
    catch {}

    $rectangle = $Element.Current.BoundingRectangle
    return 'fallback:{0}|{1}|{2}|{3},{4},{5},{6}' -f @(
        [int64]$Element.Current.NativeWindowHandle,
        [string]$Element.Current.AutomationId,
        [string]$Element.Current.ClassName,
        [Math]::Round($rectangle.X, 2),
        [Math]::Round($rectangle.Y, 2),
        [Math]::Round($rectangle.Width, 2),
        [Math]::Round($rectangle.Height, 2)
    )
}

function Test-UiClassToken {
    param(
        [Parameter(Mandatory = $true)]$Element,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $tokens = @(([string]$Element.Current.ClassName) -split '\s+' | Where-Object { $_ })
    return $Token -in $tokens
}

function Select-UniqueDialogButton {
    param(
        [Parameter(Mandatory = $true)]$VisibleButtons,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$ClassToken,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $named = @($VisibleButtons | Where-Object { [string]$_.Current.Name -in $Names })
    if ($named.Count -gt 1) { throw "Trust dialog contains multiple $Role buttons by accessible name." }
    if ($named.Count -eq 1) { return $named[0] }

    $classMatched = @($VisibleButtons | Where-Object { Test-UiClassToken -Element $_ -Token $ClassToken })
    if ($classMatched.Count -ne 1) {
        throw "Trust dialog does not contain one unambiguous $Role button."
    }
    return $classMatched[0]
}

function Get-TrustDialogButtons {
    param(
        [Parameter(Mandatory = $true)]$Dialog
    )
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )
    $buttons = $Dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $visible = @()
    for ($index = 0; $index -lt $buttons.Count; $index++) {
        $button = $buttons.Item($index)
        if ($button.Current.IsEnabled -and -not $button.Current.IsOffscreen) { $visible += $button }
    }
    if ($visible.Count -lt 2) { throw 'Trust dialog does not contain the expected button set.' }

    $trustButton = Select-UniqueDialogButton -VisibleButtons $visible `
        -Names @('信任文件夹', 'Trust Folder', 'Trust this folder') `
        -ClassToken 'bg-primary-solid' -Role 'trust'
    $cancelButton = Select-UniqueDialogButton -VisibleButtons $visible `
        -Names @('取消', 'Cancel') `
        -ClassToken 'bg-transparent' -Role 'cancel'

    $trustIdentity = Get-AutomationElementIdentity $trustButton
    $cancelIdentity = Get-AutomationElementIdentity $cancelButton
    if ($trustIdentity -eq $cancelIdentity) {
        throw 'Trust and cancel resolved to the same UI Automation element.'
    }

    $trustInvokePattern = $null
    if (-not $trustButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$trustInvokePattern)) {
        throw 'Trust button does not support InvokePattern.'
    }
    $cancelInvokePattern = $null
    if (-not $cancelButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$cancelInvokePattern)) {
        throw 'Cancel button does not support InvokePattern.'
    }

    return [pscustomobject]@{
        Trust = $trustButton
        Cancel = $cancelButton
        TrustInvoke = $trustInvokePattern
        CancelInvoke = $cancelInvokePattern
    }
}

function Invoke-TrustDialogAction {
    param(
        [Parameter(Mandatory = $true)]$Buttons,
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][ValidateSet('approve', 'cancel')][string]$Action,
        [string]$Reason
    )
    $button = if ($Action -eq 'approve') { $Buttons.Trust } else { $Buttons.Cancel }
    $invokePattern = if ($Action -eq 'approve') { $Buttons.TrustInvoke } else { $Buttons.CancelInvoke }
    $buttonName = [string]$button.Current.Name
    $buttonClass = [string]$button.Current.ClassName
    $invokePattern.Invoke()
    $event = if ($Action -eq 'approve') { 'APPROVED' } else { 'CANCELLED' }
    Write-BridgeLog -Event $event -Data @{
        folder = $Folder
        reason = $Reason
        buttonName = $buttonName
        buttonClass = $buttonClass
    }
}

function Invoke-UiScan {
    if (-not $EnableUiAutoApprove) { return 0 }
    $candidates = [Collections.Generic.List[object]]::new()
    $seenDialogKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in Get-CodexRootElements) {
        $elements = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        for ($index = 0; $index -lt $elements.Count; $index++) {
            $element = $elements.Item($index)
            if ($element.Current.ControlType -ne [System.Windows.Automation.ControlType]::ListItem) { continue }
            $folder = [string]$element.Current.Name
            if (-not $folder -or -not [IO.Path]::IsPathFullyQualified($folder)) { continue }
            $folderKey = Get-CanonicalPath $folder
            $dialog = Get-DialogAncestor $element
            if (-not $dialog) { continue }
            $dialogIdentity = Get-AutomationElementIdentity $dialog
            $dialogKey = "$folderKey|$dialogIdentity"
            if (-not $seenDialogKeys.Add($dialogKey)) { continue }
            [void]$candidates.Add([pscustomobject]@{
                Folder = $folder
                FolderKey = $folderKey
                Dialog = $dialog
                DialogKey = $dialogKey
            })
        }
    }

    foreach ($dictionary in @($ApprovalCooldown, $CancelCooldown, $RefusalCooldown, $DialogErrorCooldown, $DenialFirstSeen)) {
        foreach ($key in @($dictionary.Keys)) {
            if (-not $seenDialogKeys.Contains([string]$key)) { [void]$dictionary.Remove($key) }
        }
    }

    foreach ($candidate in $candidates) {
        $now = [DateTimeOffset]::UtcNow
        $dialogKey = $candidate.DialogKey
        if ($ApprovalCooldown.ContainsKey($dialogKey) -and
            ($now - $ApprovalCooldown[$dialogKey]).TotalSeconds -lt 10) {
            continue
        }
        if ($CancelCooldown.ContainsKey($dialogKey) -and
            ($now - $CancelCooldown[$dialogKey]).TotalSeconds -lt 10) {
            continue
        }

        try {
            # Validate and resolve both actionable controls before persisting trust.
            # An ambiguous or changed dialog must not create a durable authorization.
            $buttons = Get-TrustDialogButtons $candidate.Dialog
            $validation = Ensure-ManagedTrust $candidate.Folder
            if (-not $validation.Ok) {
                $denialState = $DenialFirstSeen[$dialogKey]
                if ($null -eq $denialState -or [string]$denialState.Reason -ne [string]$validation.Reason) {
                    $denialState = [pscustomobject]@{ FirstSeen = $now; Reason = [string]$validation.Reason }
                    $DenialFirstSeen[$dialogKey] = $denialState
                }
                if (-not $RefusalCooldown.ContainsKey($dialogKey) -or
                    ($now - $RefusalCooldown[$dialogKey]).TotalSeconds -ge 30) {
                    Write-BridgeLog -Event 'REFUSED' -Data @{
                        folder = $candidate.Folder
                        reason = $validation.Reason
                        deniedDialogAction = $DeniedDialogAction
                        dialogIdentity = $dialogKey
                    }
                    $RefusalCooldown[$dialogKey] = $now
                }
                if ($DeniedDialogAction -eq 'cancel' -and
                    ($now - [DateTimeOffset]$denialState.FirstSeen).TotalSeconds -ge $DeniedDialogGraceSeconds) {
                    Invoke-TrustDialogAction -Buttons $buttons -Folder $candidate.FolderKey -Action cancel -Reason $validation.Reason
                    $CancelCooldown[$dialogKey] = $now
                    [void]$DenialFirstSeen.Remove($dialogKey)
                    Start-Sleep -Milliseconds 350
                    return 1
                }
                continue
            }

            Invoke-TrustDialogAction -Buttons $buttons -Folder $validation.Path -Action approve
            $ApprovalCooldown[$dialogKey] = $now
            [void]$RefusalCooldown.Remove($dialogKey)
            [void]$DialogErrorCooldown.Remove($dialogKey)
            [void]$DenialFirstSeen.Remove($dialogKey)
            [void]$CancelCooldown.Remove($dialogKey)
            Start-Sleep -Milliseconds 350
            return 1
        }
        catch {
            if (-not $DialogErrorCooldown.ContainsKey($dialogKey) -or
                ($now - $DialogErrorCooldown[$dialogKey]).TotalSeconds -ge 30) {
                Write-BridgeLog -Event 'DIALOG_HANDLER_ERROR' -Data @{
                    folder = $candidate.Folder
                    dialogIdentity = $dialogKey
                    error = $_.Exception.ToString()
                }
                $DialogErrorCooldown[$dialogKey] = $now
            }
            continue
        }
    }
    return 0
}

try {
    $HasInstanceMutex = $InstanceMutex.WaitOne(0)
    if (-not $HasInstanceMutex) { exit 0 }
    Write-BridgeLog -Event 'STARTED' -Data @{
        pid = $PID
        launcherPid = $LauncherProcessId
        configPath = $ConfigPath
        allowedRoots = $AllowedRoots
        once = [bool]$Once
        uiPollIntervalMs = $UiPollIntervalMs
        reconcileIntervalSeconds = $ReconcileIntervalSeconds
        trustMode = $TrustMode
        deniedDialogAction = $DeniedDialogAction
        deniedDialogGraceSeconds = $DeniedDialogGraceSeconds
    }

    Import-LegacyManagedPaths
    try { Invoke-Reconcile } catch { Write-BridgeLog -Event 'RECONCILE_ERROR' -Data @{ error = $_.Exception.ToString() } }
    $nextReconcile = [Diagnostics.Stopwatch]::StartNew()

    do {
        try { [void](Invoke-UiScan) } catch { Write-BridgeLog -Event 'UI_SCAN_ERROR' -Data @{ error = $_.Exception.ToString() } }
        if ($nextReconcile.Elapsed.TotalSeconds -ge $ReconcileIntervalSeconds) {
            try { Invoke-Reconcile } catch { Write-BridgeLog -Event 'RECONCILE_ERROR' -Data @{ error = $_.Exception.ToString() } }
            $nextReconcile.Restart()
        }
        if (-not $Once) { Start-Sleep -Milliseconds $UiPollIntervalMs }
    } while (-not $Once)
}
finally {
    if ($HasInstanceMutex) { [void]$InstanceMutex.ReleaseMutex() }
    $InstanceMutex.Dispose()
    $ConfigMutex.Dispose()
}
