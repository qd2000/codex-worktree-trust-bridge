[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\codex-worktree-trust-bridge.json'),
    [string]$InstanceName,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


$versionPath = Join-Path $PSScriptRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) { $versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION' }
$PackageVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$SourceManifestHash = if (Test-Path -LiteralPath $manifestPath) { (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash } else { $null }
$script:LastReconcileSucceeded = $false
$script:ReconcileCount = 0
$script:ConfigWriteUncertain = $false

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
    $Data['pid'] = $PID
    $Data['launcherPid'] = $LauncherProcessId
    $Data['packageVersion'] = $PackageVersion
    $Data['runId'] = $env:CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID
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
    $backupPath = Join-Path $BackupDirectory "config.$stamp-$([guid]::NewGuid().ToString('N')).toml"
    Copy-Item -LiteralPath $CodexConfigPath -Destination $backupPath
    $old = @(Get-ChildItem -LiteralPath $BackupDirectory -Filter 'config.*.toml' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20)
    foreach ($file in $old) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
    return $backupPath
}

function Update-CodexTrustConfig {
    param([Parameter(Mandatory = $true)]$ManagedPaths, [scriptblock]$BeforeCommit)
    if (-not $EnableConfigTrust) { return }
    if ($ConfigWriteUncertain) { throw 'A previous config replacement is uncertain; automatic writes remain disabled until reconciled.' }
    $acquired = $false
    $temporary = $null
    try { $acquired = $ConfigMutex.WaitOne(15000) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Timed out waiting for the Codex config mutex.' }
    try {
        if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) {
            # CreateNew never truncates a file that appeared after Test-Path.
            try { $created = [IO.File]::Open($CodexConfigPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read); $created.Dispose() }
            catch [IO.IOException] { if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { throw } }
        }
        if ((Get-Item -LiteralPath $CodexConfigPath).Length -gt 8MB) { throw 'Codex configuration exceeds the bounded parser budget.' }
        $preimageHash = (Get-FileHash -LiteralPath $CodexConfigPath -Algorithm SHA256).Hash
        $original = [IO.File]::ReadAllText($CodexConfigPath)
        if ((Get-FileHash -LiteralPath $CodexConfigPath -Algorithm SHA256).Hash -ne $preimageHash) { throw 'Codex configuration changed during the initial read.' }
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
        if ([Text.Encoding]::UTF8.GetByteCount($updated) -gt 8MB) { throw 'Updated configuration exceeds the bounded write budget.' }
        $backupPath = Backup-CodexConfig
        $temporary = "$CodexConfigPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        # Validate after acquiring the config mutex and preparing the update,
        # not before a potentially long mutex wait or discovery operation.
        if ($BeforeCommit) { & $BeforeCommit }
        if ((Get-FileHash -LiteralPath $CodexConfigPath -Algorithm SHA256).Hash -ne $preimageHash -or
            (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $preimageHash) {
            Write-BridgeLog -Event 'CONFIG_CONCURRENT_CHANGE' -Data @{ backupPath = $backupPath; expectedHash = $preimageHash }
            throw 'Codex configuration changed while preparing the update; the newer file was not replaced.'
        }
        try {
            # Cooperating writers share ConfigMutex. This preimage guard detects
            # non-cooperating edits before replacement; it is not a filesystem
            # compare-and-swap transaction against arbitrary external writers.
            [IO.File]::Replace($temporary, $CodexConfigPath, [NullString]::Value)
        }
        catch {
            # Do not blindly replay a possibly completed replacement or restore
            # an older snapshot over a third-party write after a failure.
            $script:ConfigWriteUncertain = $true
            Write-BridgeLog -Event 'CONFIG_WRITE_UNCERTAIN' -Data @{ backupPath = $backupPath; error = $_.Exception.Message }
            throw
        }
        Write-BridgeLog -Event 'CONFIG_SYNCED' -Data @{ managedCount = $ManagedPaths.Count; backupPath = $backupPath; previousHash = $preimageHash }
    }
    finally {
        try { if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force } }
        finally { [void]$ConfigMutex.ReleaseMutex() }
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
    $script:LastReconcileSucceeded = $false
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
    $script:LastReconcileSucceeded = $true
    $script:ReconcileCount++
    Write-BridgeLog -Event 'RECONCILED' -Data @{
        pid = $PID
        launcherPid = $LauncherProcessId
        managedCount = $ManagedPaths.Count
        roots = $AllowedRoots
        trustMode = $TrustMode
    }
}

function Ensure-ManagedTrust {
    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$BeforeWrite)
    $validation = Test-TrustEligiblePath $Path
    if (-not $validation.Ok) { return $validation }
    $canonical = $validation.Path
    # Do not enqueue an uncommitted UI intent in the shared reconciliation set.
    # A failed late dialog check must not be written by the next periodic sync.
    $proposed = New-PathSet
    foreach ($existingPath in $ManagedPaths) { [void]$proposed.Add($existingPath) }
    [void]$proposed.Add($canonical)
    Update-CodexTrustConfig -ManagedPaths $proposed -BeforeCommit $BeforeWrite
    if (-not (Test-ExactTrustedEntry $canonical)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'exact trusted project entry is absent after config sync' }
    }
    [void]$ManagedPaths.Add($canonical)
    Save-ManagedState $ManagedPaths
    return [pscustomobject]@{ Ok = $true; Path = $canonical }
}

. (Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.Supervision.ps1')

try {
    try { $HasInstanceMutex = $InstanceMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $HasInstanceMutex = $true }
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

    Initialize-UiSupervisor
    Import-LegacyManagedPaths
    try { Invoke-Reconcile } catch { Write-BridgeLog -Event 'RECONCILE_ERROR' -Data @{ error = $_.Exception.ToString() } }
    $nextReconcile = [Diagnostics.Stopwatch]::StartNew()

    do {
        try { [void](Invoke-UiScan) } catch { Write-BridgeLog -Event 'UI_SCAN_ERROR' -Data @{ error = $_.Exception.ToString() } }
        if ($nextReconcile.Elapsed.TotalSeconds -ge $ReconcileIntervalSeconds) {
            try { Invoke-Reconcile } catch { Write-BridgeLog -Event 'RECONCILE_ERROR' -Data @{ error = $_.Exception.ToString() } }
            $nextReconcile.Restart()
        }
        Write-BridgeHealth
        if (-not $Once) { Start-Sleep -Milliseconds $UiPollIntervalMs }
    } while (-not $Once)
}
finally {
    try {
        if ($HasInstanceMutex) {
            try {
                Stop-UiWorker
                $Ui.State = 'STOPPED'
                Write-BridgeHealth -Force
            }
            finally { [void]$InstanceMutex.ReleaseMutex() }
        }
    }
    finally {
        $InstanceMutex.Dispose()
        $ConfigMutex.Dispose()
    }
}
