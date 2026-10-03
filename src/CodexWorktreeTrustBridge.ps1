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

$CodexHome = Join-Path $env:USERPROFILE '.codex'
$CodexConfigPath = Join-Path $CodexHome 'config.toml'
$StateDirectory = Join-Path $CodexHome 'state'
$StatePath = Join-Path $StateDirectory 'codex-worktree-trust-bridge.json'
$LogDirectory = Join-Path $CodexHome 'log'
$LogPath = Join-Path $LogDirectory 'codex-worktree-trust-bridge.log'
$BackupDirectory = Join-Path $CodexHome 'backups\codex-worktree-trust-bridge'

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
$ConfigMutex = [Threading.Mutex]::new($false, "Local\CodexWorktreeTrustBridgeConfig-$instanceToken")
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
    $output = @(& git.exe -C $WorkingDirectory @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git -C '$WorkingDirectory' $($Arguments -join ' ') failed with exit $LASTEXITCODE"
    }
    return $output
}

function Test-AllowedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($allowedRoot in $AllowedRoots) {
        if (Test-PathInside -Child $Path -Parent $allowedRoot) { return $true }
    }
    return $false
}

function Test-RegisteredGitWorktree {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-AllowedPath $Path)) { return $false }
    try {
        $top = (Invoke-GitLines -WorkingDirectory $Path -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1)
        if (-not $top -or (Get-CanonicalPath $top) -ne (Get-CanonicalPath $Path)) { return $false }
        $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($line in Invoke-GitLines -WorkingDirectory $Path -Arguments @('worktree', 'list', '--porcelain')) {
            if ($line -match '^worktree\s+(.+)$') {
                [void]$registered.Add((Get-CanonicalPath $Matches[1].Trim()))
            }
        }
        return $registered.Contains((Get-CanonicalPath $Path))
    }
    catch {
        return $false
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

function Get-ManualProjectSections {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $headers = New-PathSet
    $trusted = New-PathSet
    $pattern = "(?ms)^\s*\[projects\.'([^']+)'\]\s*\r?\n(.*?)(?=^\s*\[|\z)"
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        try {
            $path = Get-CanonicalPath $match.Groups[1].Value
            [void]$headers.Add($path)
            if ($match.Groups[2].Value -match '(?im)^\s*trust_level\s*=\s*["'']trusted["'']\s*$') {
                [void]$trusted.Add($path)
            }
        }
        catch {}
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
    $key = Get-CanonicalPath $Path
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    $pattern = "(?ms)^\s*\[projects\.'" + [regex]::Escape($key) + "'\]\s*\r?\n(.*?)(?=^\s*\[|\z)"
    $section = [regex]::Match($text, $pattern)
    return $section.Success -and $section.Groups[1].Value -match '(?im)^\s*trust_level\s*=\s*["'']trusted["'']\s*$'
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
                if ((Test-AllowedPath $path) -and (Test-Path -LiteralPath $path -PathType Container)) {
                    [void]$result.Add($path)
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

function Import-LegacyManagedPaths {
    if (-not (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf)) { return }
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    foreach ($set in @(
        (Get-ManagedPathsFromBlock -Text $text -BeginMarker $LegacyBeginMarker -EndMarker $LegacyEndMarker),
        (Get-ManagedPathsFromBlock -Text $text -BeginMarker $NewBeginMarker -EndMarker $NewEndMarker)
    )) {
        foreach ($path in $set) {
            if ((Test-AllowedPath $path) -and (Test-RegisteredGitWorktree $path)) {
                [void]$ManagedPaths.Add($path)
            }
        }
    }
}

function Invoke-Reconcile {
    $discovered = Discover-RegisteredWorktrees
    if ($PruneMissingManagedEntries) {
        $ManagedPaths.Clear()
    }
    foreach ($path in $discovered) { [void]$ManagedPaths.Add($path) }
    if (-not $PruneMissingManagedEntries) {
        foreach ($path in @($ManagedPaths)) {
            if (-not (Test-RegisteredGitWorktree $path)) { [void]$ManagedPaths.Remove($path) }
        }
    }
    Update-CodexTrustConfig $ManagedPaths
    Save-ManagedState $ManagedPaths
    Write-BridgeLog -Event 'RECONCILED' -Data @{ managedCount = $ManagedPaths.Count; roots = $AllowedRoots }
}

function Ensure-ManagedTrust {
    param([Parameter(Mandatory = $true)][string]$Path)
    $canonical = Get-CanonicalPath $Path
    if (-not (Test-RegisteredGitWorktree $canonical)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'path is not an allowlisted registered Git worktree' }
    }
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

function Invoke-TrustButton {
    param(
        [Parameter(Mandatory = $true)]$Dialog,
        [Parameter(Mandatory = $true)][string]$Folder
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

    $trustButton = $visible | Where-Object {
        [string]$_.Current.Name -in @('信任文件夹', 'Trust Folder', 'Trust this folder')
    } | Select-Object -First 1

    if (-not $trustButton) {
        $trustButton = $visible | Where-Object { [string]$_.Current.ClassName -like '*bg-primary-solid*' } | Select-Object -First 1
        $cancel = $visible | Where-Object { [string]$_.Current.ClassName -like '*bg-transparent*' } | Select-Object -First 1
        if (-not $trustButton -or -not $cancel) {
            throw 'Dialog buttons do not match the Codex trust-dialog shape.'
        }
    }

    $invokePattern = $null
    if (-not $trustButton.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        throw 'Trust button does not support InvokePattern.'
    }
    $buttonName = [string]$trustButton.Current.Name
    $buttonClass = [string]$trustButton.Current.ClassName
    $invokePattern.Invoke()
    Write-BridgeLog -Event 'APPROVED' -Data @{ folder = $Folder; buttonName = $buttonName; buttonClass = $buttonClass }
}

function Invoke-UiScan {
    if (-not $EnableUiAutoApprove) { return 0 }
    $handled = 0
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
            if (-not $seen.Add($folder)) { continue }
            $folderKey = Get-CanonicalPath $folder
            $now = [DateTimeOffset]::UtcNow
            if ($ApprovalCooldown.ContainsKey($folderKey) -and
                ($now - $ApprovalCooldown[$folderKey]).TotalSeconds -lt 10) {
                continue
            }
            $dialog = Get-DialogAncestor $element
            if (-not $dialog) { continue }

            $validation = Ensure-ManagedTrust $folder
            if (-not $validation.Ok) {
                if (-not $RefusalCooldown.ContainsKey($folderKey) -or
                    ($now - $RefusalCooldown[$folderKey]).TotalSeconds -ge 30) {
                    Write-BridgeLog -Event 'REFUSED' -Data @{ folder = $folder; reason = $validation.Reason }
                    $RefusalCooldown[$folderKey] = $now
                }
                continue
            }
            Invoke-TrustButton -Dialog $dialog -Folder $validation.Path
            $ApprovalCooldown[$folderKey] = $now
            [void]$RefusalCooldown.Remove($folderKey)
            $handled++
            Start-Sleep -Milliseconds 350
            break
        }
    }
    return $handled
}

try {
    $HasInstanceMutex = $InstanceMutex.WaitOne(0)
    if (-not $HasInstanceMutex) { exit 0 }
    Write-BridgeLog -Event 'STARTED' -Data @{
        pid = $PID
        configPath = $ConfigPath
        allowedRoots = $AllowedRoots
        once = [bool]$Once
        uiPollIntervalMs = $UiPollIntervalMs
        reconcileIntervalSeconds = $ReconcileIntervalSeconds
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
