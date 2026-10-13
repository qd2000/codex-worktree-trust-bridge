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
$script:LastReconcileDurationMs = 0L
$script:LastReconcileFailure = $null
$script:LastReconcileStartedUtc = $null
$script:ReconcileInProgress = $false
$script:ReconcileStopwatch = $null
$script:ReconcileHadCriticalGitFailure = $false
$script:ReconcileBudget = $null

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

function Get-BridgeBoundedInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Default,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum
    )
    $property = $BridgeConfig.PSObject.Properties[$Name]
    $value = if ($null -eq $property) { $Default } else { [int]$property.Value }
    if ($value -lt $Minimum -or $value -gt $Maximum) {
        throw "Configuration '$Name' must be between $Minimum and $Maximum."
    }
    return $value
}

$AllowedRoots = @($BridgeConfig.allowedRoots | ForEach-Object { Get-CanonicalPath ([string]$_) } | Sort-Object -Unique)
if (-not $AllowedRoots.Count) {
    throw 'At least one allowed root is required.'
}

$UiPollIntervalMs = [Math]::Max(250, [Math]::Min(10000, [int]$BridgeConfig.uiPollIntervalMs))
$ReconcileIntervalSeconds = [Math]::Max(5, [Math]::Min(3600, [int]$BridgeConfig.reconcileIntervalSeconds))
$DiscoveryDepth = [Math]::Max(1, [Math]::Min(8, [int]$BridgeConfig.discoveryDepth))
$GitCommandTimeoutMs = (Get-BridgeBoundedInteger -Name 'gitCommandTimeoutSeconds' -Default 10 -Minimum 1 -Maximum 60) * 1000
$GitCleanupTimeoutMs = (Get-BridgeBoundedInteger -Name 'gitCleanupTimeoutSeconds' -Default 5 -Minimum 1 -Maximum 15) * 1000
$GitMaximumStandardOutputBytes = Get-BridgeBoundedInteger -Name 'gitMaximumStandardOutputBytes' -Default 262144 -Minimum 4096 -Maximum 4194304
$GitMaximumStandardErrorBytes = Get-BridgeBoundedInteger -Name 'gitMaximumStandardErrorBytes' -Default 65536 -Minimum 1024 -Maximum 1048576
$GitJobMemoryMiB = Get-BridgeBoundedInteger -Name 'gitJobMemoryMiB' -Default 128 -Minimum 32 -Maximum 512
$GitProcessLimit = Get-BridgeBoundedInteger -Name 'gitProcessLimit' -Default 8 -Minimum 1 -Maximum 32
$ReconcileTimeoutSeconds = Get-BridgeBoundedInteger -Name 'reconcileTimeoutSeconds' -Default 120 -Minimum 5 -Maximum 300
$DiscoveryDirectoryLimit = Get-BridgeBoundedInteger -Name 'discoveryDirectoryLimit' -Default 5000 -Minimum 100 -Maximum 50000
$DiscoveryRepositoryLimit = Get-BridgeBoundedInteger -Name 'discoveryRepositoryLimit' -Default 256 -Minimum 1 -Maximum 4096
$DiscoveryWorktreeLimit = Get-BridgeBoundedInteger -Name 'discoveryWorktreeLimit' -Default 1024 -Minimum 1 -Maximum 16384
$GitCommandLimitPerReconcile = Get-BridgeBoundedInteger -Name 'gitCommandLimitPerReconcile' -Default 2048 -Minimum 8 -Maximum 32768
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
$NativeHelperPath = Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.Native.dll'
if (-not (Test-Path -LiteralPath $NativeHelperPath -PathType Leaf)) {
    $NativeHelperPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts\bin\CodexWorktreeTrustBridge.Native.dll'
}
if (-not (Test-Path -LiteralPath $NativeHelperPath -PathType Leaf)) {
    throw 'The bounded native process helper is missing.'
}
if (-not ('CodexTrustBridge.BoundedProcessRunner' -as [type])) { Add-Type -Path $NativeHelperPath }
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'
$env:GIT_OPTIONAL_LOCKS = '0'
$env:LC_ALL = 'C'
$env:LANG = 'C'
$script:GitMetrics = [ordered]@{
    commandCount = 0L; failureCount = 0L; timeoutCount = 0L; outputLimitCount = 0L
    invalidUtf8Count = 0L; cleanupFailureCount = 0L; activeCount = 0
    lastDurationMs = 0L; maximumDurationMs = 0L; lastExitCode = $null
    lastFailureKind = $null; lastFailure = $null; lastFailureUtc = $null
    lastCleanupVerified = $true; peakJobMemoryBytes = 0L; maximumActiveProcesses = 0
}
$LauncherProcessId = if ($env:CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID) {
    [int]$env:CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID
}
else { $null }

foreach ($directory in @($StateDirectory, $LogDirectory, $BackupDirectory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$userToken = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -replace '[^A-Za-z0-9_.-]', '_')
$instanceToken = if ([string]::IsNullOrWhiteSpace($InstanceName)) {
    # Match the launcher's per-user/per-config ownership boundary. A user may run
    # an isolated diagnostic or test configuration beside production without
    # either process being mistaken for a duplicate of the other.
    $identityBytes = [Text.Encoding]::UTF8.GetBytes($userToken + '|' + (Get-CanonicalPath $ConfigPath))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $identityHash = [BitConverter]::ToString($sha256.ComputeHash($identityBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
    $userToken + '-' + $identityHash.Substring(0, 20)
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Critical
    )
    if ($ReconcileInProgress) {
        Assert-ReconcileBudget
        if ($ReconcileBudget.gitCommands -ge $GitCommandLimitPerReconcile) {
            $script:ReconcileHadCriticalGitFailure = $true
            throw "Git command budget exceeded ($GitCommandLimitPerReconcile)."
        }
        $script:ReconcileBudget.gitCommands++
    }
    $script:GitMetrics.commandCount++
    $script:GitMetrics.activeCount++
    $result = $null
    try {
        $boundedArguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @('--no-optional-locks', '-c', 'core.pager=cat', '-c', 'color.ui=false', '-C', $WorkingDirectory)) {
            $boundedArguments.Add($argument)
        }
        foreach ($argument in $Arguments) { $boundedArguments.Add($argument) }
        $result = [CodexTrustBridge.BoundedProcessRunner]::Run(
            $GitExecutable,
            $boundedArguments.ToArray(),
            $WorkingDirectory,
            $GitCommandTimeoutMs,
            $GitCleanupTimeoutMs,
            $GitMaximumStandardOutputBytes,
            $GitMaximumStandardErrorBytes,
            [long]$GitJobMemoryMiB * 1MB,
            $GitProcessLimit)
        $script:GitMetrics.lastDurationMs = [long]$result.DurationMilliseconds
        $script:GitMetrics.maximumDurationMs = [Math]::Max([long]$GitMetrics.maximumDurationMs, [long]$result.DurationMilliseconds)
        $script:GitMetrics.lastExitCode = [int]$result.ExitCode
        $script:GitMetrics.lastCleanupVerified = [bool]$result.CleanupVerified
        $script:GitMetrics.peakJobMemoryBytes = [Math]::Max([long]$GitMetrics.peakJobMemoryBytes, [long]$result.PeakJobMemoryBytes)
        $script:GitMetrics.maximumActiveProcesses = [Math]::Max([int]$GitMetrics.maximumActiveProcesses, [int]$result.MaximumActiveProcesses)

        $kind = $null
        if (-not $result.CleanupVerified) { $kind = 'cleanup'; $script:GitMetrics.cleanupFailureCount++ }
        elseif ($result.TimedOut) { $kind = 'timeout'; $script:GitMetrics.timeoutCount++ }
        elseif ($result.StandardOutputLimitExceeded -or $result.StandardErrorLimitExceeded) { $kind = 'output-limit'; $script:GitMetrics.outputLimitCount++ }
        elseif ($result.InvalidUtf8) { $kind = 'invalid-utf8'; $script:GitMetrics.invalidUtf8Count++ }
        elseif ($result.ExitCode -ne 0) { $kind = 'exit' }
        if ($kind) {
            $detail = if ([string]::IsNullOrWhiteSpace([string]$result.StandardError)) { '' } else { ([string]$result.StandardError).Trim() }
            if ($detail.Length -gt 512) { $detail = $detail.Substring(0, 512) }
            $message = "Git command failed ($kind, exit=$($result.ExitCode), durationMs=$($result.DurationMilliseconds))"
            if ($detail) { $message += ": $detail" }
            $script:GitMetrics.failureCount++
            $script:GitMetrics.lastFailureKind = $kind
            $script:GitMetrics.lastFailure = $message
            $script:GitMetrics.lastFailureUtc = [DateTime]::UtcNow.ToString('o')
            if ($ReconcileInProgress -and ($Critical -or $kind -ne 'exit')) {
                $script:ReconcileHadCriticalGitFailure = $true
            }
            $exception = [InvalidOperationException]::new($message)
            $exception.Data['GitFailureKind'] = $kind
            $exception.Data['GitExitCode'] = [int]$result.ExitCode
            $exception.Data['GitStandardError'] = [string]$result.StandardError
            throw $exception
        }
        if ($ReconcileInProgress) { Assert-ReconcileBudget }
        if ([string]::IsNullOrEmpty([string]$result.StandardOutput)) { return @() }
        return @(([string]$result.StandardOutput -split '\r?\n') | Where-Object { $_.Length -gt 0 })
    }
    catch {
        if ($null -eq $result) {
            $script:GitMetrics.failureCount++
            $script:GitMetrics.lastFailureKind = 'start'
            $script:GitMetrics.lastFailure = $_.Exception.Message
            $script:GitMetrics.lastFailureUtc = [DateTime]::UtcNow.ToString('o')
            $script:GitMetrics.lastCleanupVerified = $false
            if ($ReconcileInProgress) { $script:ReconcileHadCriticalGitFailure = $true }
        }
        throw
    }
    finally {
        $script:GitMetrics.activeCount--
    }
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
        # A plain non-zero result here means this candidate is stale or not a
        # registered worktree and may be skipped. Invoke-GitLines still marks
        # timeout/output/UTF-8/cleanup/start failures as critical infrastructure
        # failures for the active reconcile.
        $topLines = @(Invoke-GitLines -WorkingDirectory $canonical -Arguments @('rev-parse', '--show-toplevel'))
        if ($topLines.Count -ne 1) { return $false }
        $top = $topLines[0]
        if (-not [IO.Path]::IsPathFullyQualified($top) -or (Get-CanonicalPath $top) -ne $canonical) { return $false }
        $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in Invoke-GitLines -WorkingDirectory $canonical -Arguments @('worktree', 'list', '--porcelain')) {
            if ($line -match '^worktree\s+(.+)$') {
                $candidate = $Matches[1].Trim()
                if (-not [IO.Path]::IsPathFullyQualified($candidate)) { return $false }
                [void]$registered.Add((Get-CanonicalPath $candidate))
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
            Assert-ReconcileBudget
            $item = $queue.Dequeue()
            $script:ReconcileBudget.directories++
            if ($ReconcileBudget.directories -gt $DiscoveryDirectoryLimit) {
                throw "Directory discovery budget exceeded ($DiscoveryDirectoryLimit)."
            }
            $marker = Join-Path $item.Path '.git'
            if (Test-Path -LiteralPath $marker) {
                $script:ReconcileBudget.repositories++
                if ($ReconcileBudget.repositories -gt $DiscoveryRepositoryLimit) {
                    throw "Repository discovery budget exceeded ($DiscoveryRepositoryLimit)."
                }
                [void]$results.Add((Get-CanonicalPath $item.Path))
                continue
            }
            if ($item.Depth -ge $DiscoveryDepth) { continue }
            try { $children = @(Get-ChildItem -LiteralPath $item.Path -Directory -Force -ErrorAction Stop) }
            catch { throw "Directory discovery failed at '$($item.Path)': $($_.Exception.Message)" }
            foreach ($directory in $children) {
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
        Assert-ReconcileBudget
        try {
            # Backups can contain a literal .git marker after the repository it
            # pointed to has been removed. Skip only Git's deterministic
            # "not a git repository" exit. Timeouts, output/protocol/cleanup
            # failures and every other non-zero result remain critical and keep
            # the previous managed state intact.
            $commonLines = @(Invoke-GitLines -WorkingDirectory $gitRoot -Arguments @('rev-parse', '--git-common-dir'))
        }
        catch {
            $kind = [string]$_.Exception.Data['GitFailureKind']
            $exitCode = [int]$_.Exception.Data['GitExitCode']
            $standardError = [string]$_.Exception.Data['GitStandardError']
            $staleMarker = $kind -eq 'exit' -and $exitCode -eq 128 -and
                $standardError -match '(?im)^fatal:\s+not a git repository(?:\s|:|\(|$)'
            if ($staleMarker) {
                Write-BridgeLog -Event 'GIT_ROOT_SKIPPED' -Data @{
                    path = $gitRoot
                    reason = 'stale or invalid .git marker is not a repository'
                }
                continue
            }
            $script:ReconcileHadCriticalGitFailure = $true
            throw
        }
        if ($commonLines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($commonLines[0])) {
            $script:ReconcileHadCriticalGitFailure = $true
            throw "Git common-directory output is malformed for '$gitRoot'."
        }
        $commonDirectory = $commonLines[0]
        if (-not [IO.Path]::IsPathFullyQualified($commonDirectory)) {
            $commonDirectory = Join-Path $gitRoot $commonDirectory
        }
        $commonKey = Get-CanonicalPath $commonDirectory
        if (-not $seenCommonDirectories.Add($commonKey)) { continue }
        foreach ($line in Invoke-GitLines -WorkingDirectory $gitRoot -Arguments @('worktree', 'list', '--porcelain') -Critical) {
            if ($line -notmatch '^worktree\s+(.+)$') { continue }
            $script:ReconcileBudget.worktrees++
            if ($ReconcileBudget.worktrees -gt $DiscoveryWorktreeLimit) {
                throw "Worktree discovery budget exceeded ($DiscoveryWorktreeLimit)."
            }
            $candidate = $Matches[1].Trim()
            if (-not [IO.Path]::IsPathFullyQualified($candidate)) {
                $script:ReconcileHadCriticalGitFailure = $true
                throw "Git returned a non-absolute worktree path for '$gitRoot'."
            }
            $path = Get-CanonicalPath $candidate
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
    if ($ReconcileHadCriticalGitFailure) { throw 'Git discovery was incomplete; previous managed state is preserved.' }
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
    if ($ReconcileInProgress) { throw 'A reconcile run is already active.' }
    $script:ReconcileInProgress = $true
    $script:LastReconcileSucceeded = $false
    $script:LastReconcileFailure = $null
    $script:LastReconcileStartedUtc = [DateTime]::UtcNow.ToString('o')
    $script:ReconcileStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $script:ReconcileHadCriticalGitFailure = $false
    $script:ReconcileBudget = [ordered]@{ directories = 0; repositories = 0; worktrees = 0; gitCommands = 0 }
    try {
        $discovered = Discover-RegisteredWorktrees
        $nextManagedPaths = New-PathSet
        foreach ($path in $discovered) { [void]$nextManagedPaths.Add($path) }
        foreach ($path in @($ManagedPaths)) {
            Assert-ReconcileBudget
            $validation = Test-TrustEligiblePath $path
            if ($validation.Ok) {
                [void]$nextManagedPaths.Add($validation.Path)
                continue
            }
        }
        Assert-ReconcileBudget
        if ($ReconcileHadCriticalGitFailure) { throw 'Git validation was incomplete; previous managed state is preserved.' }
        Update-CodexTrustConfig $nextManagedPaths
        Save-ManagedState $nextManagedPaths
        $ManagedPaths.Clear()
        foreach ($path in $nextManagedPaths) { [void]$ManagedPaths.Add($path) }
        $script:LastReconcileSucceeded = $true
        $script:ReconcileCount++
        Write-BridgeLog -Event 'RECONCILED' -Data @{
            pid = $PID
            launcherPid = $LauncherProcessId
            managedCount = $ManagedPaths.Count
            roots = $AllowedRoots
            trustMode = $TrustMode
            durationMs = $ReconcileStopwatch.ElapsedMilliseconds
            budget = $ReconcileBudget
        }
    }
    catch {
        $script:LastReconcileFailure = $_.Exception.Message
        Write-BridgeLog -Event 'RECONCILE_FAILED' -Data @{
            error = $_.Exception.Message
            durationMs = $ReconcileStopwatch.ElapsedMilliseconds
            budget = $ReconcileBudget
            previousManagedCount = $ManagedPaths.Count
        }
        throw
    }
    finally {
        $script:LastReconcileDurationMs = $ReconcileStopwatch.ElapsedMilliseconds
        $script:ReconcileInProgress = $false
    }
}

function Assert-ReconcileBudget {
    if (-not $ReconcileInProgress -or $null -eq $ReconcileStopwatch) { return }
    if ($ReconcileStopwatch.Elapsed.TotalSeconds -ge $ReconcileTimeoutSeconds) {
        $script:ReconcileHadCriticalGitFailure = $true
        throw "Reconcile deadline exceeded ($ReconcileTimeoutSeconds seconds)."
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
        reconcileTimeoutSeconds = $ReconcileTimeoutSeconds
        gitCommandTimeoutMs = $GitCommandTimeoutMs
        gitMaximumStandardOutputBytes = $GitMaximumStandardOutputBytes
        gitMaximumStandardErrorBytes = $GitMaximumStandardErrorBytes
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
