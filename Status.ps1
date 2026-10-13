[CmdletBinding()]
param([string]$TaskName = 'Codex-Worktree-Trust-Bridge')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-SamePath {
    param([string]$Left, [string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        return [IO.Path]::GetFullPath($Left.Trim('"')).TrimEnd('\') -ieq
            [IO.Path]::GetFullPath($Right.Trim('"')).TrimEnd('\')
    }
    catch { return $false }
}

$codexHome = Join-Path $env:USERPROFILE '.codex'
$installRoot = Join-Path $codexHome 'tools\codex-worktree-trust-bridge'
$runtimePath = Join-Path $installRoot 'CodexWorktreeTrustBridge.ps1'
$launcherPath = Join-Path $installRoot 'CodexWorktreeTrustBridge.Launcher.exe'
$configPath = Join-Path $codexHome 'codex-worktree-trust-bridge.json'
$statePath = Join-Path $codexHome 'state\codex-worktree-trust-bridge.json'
$logPath = Join-Path $codexHome 'log\codex-worktree-trust-bridge.log'
$workerPath = Join-Path $installRoot 'CodexWorktreeTrustBridge.UiWorker.exe'
$healthPath = "$configPath.health.json"
$processReceiptPath = "$configPath.process.json"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $TaskName } else { $null }
$allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$launcherProcesses = @($allProcesses | Where-Object {
    $_.ExecutablePath -and (Test-SamePath $_.ExecutablePath $launcherPath)
})
$runtimeProcesses = @($allProcesses | Where-Object {
    $_.Name -ieq 'pwsh.exe' -and $_.CommandLine -and $_.CommandLine -like "*$runtimePath*"
})
$workerProcesses = @($allProcesses | Where-Object {
    $_.ExecutablePath -and (Test-SamePath $_.ExecutablePath $workerPath)
})

$config = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
    catch {}
}
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch {}
}

$logEntries = [Collections.Generic.List[object]]::new()
$recentLog = @()
if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    $recentLog = @(Get-Content -LiteralPath $logPath -Tail 12 -ErrorAction SilentlyContinue)
    foreach ($line in @(Get-Content -LiteralPath $logPath -Tail 1000 -ErrorAction SilentlyContinue)) {
        try {
            $entry = $line | ConvertFrom-Json
            $entry | Add-Member -NotePropertyName ParsedTimestamp -NotePropertyValue ([DateTimeOffset]::Parse([string]$entry.timestamp)) -Force
            [void]$logEntries.Add($entry)
        }
        catch {}
    }
}

$launcherProcess = if ($launcherProcesses.Count -eq 1) { $launcherProcesses[0] } else { $null }
$runtimeProcess = if ($runtimeProcesses.Count -eq 1) { $runtimeProcesses[0] } else { $null }
$latestStarted = $null
$latestReconciled = $null
if ($runtimeProcess) {
    $latestStarted = $logEntries |
        Where-Object { $_.event -eq 'STARTED' -and [int]$_.data.pid -eq [int]$runtimeProcess.ProcessId } |
        Sort-Object ParsedTimestamp -Descending |
        Select-Object -First 1
    $latestReconciled = $logEntries |
        Where-Object { $_.event -eq 'RECONCILED' -and [int]$_.data.pid -eq [int]$runtimeProcess.ProcessId } |
        Sort-Object ParsedTimestamp -Descending |
        Select-Object -First 1
}

$reconcileIntervalSeconds = if ($config -and $config.PSObject.Properties['reconcileIntervalSeconds']) {
    [int]$config.reconcileIntervalSeconds
}
else { 60 }
$freshnessLimitSeconds = [Math]::Max(120, ($reconcileIntervalSeconds * 2) + 30)
$reconcileFresh = [bool]($latestReconciled -and
    ([DateTimeOffset]::Now - $latestReconciled.ParsedTimestamp).TotalSeconds -le $freshnessLimitSeconds)

$taskActionIsLauncher = [bool]($task -and $task.Actions.Count -eq 1 -and
    (Test-SamePath ([string]$task.Actions[0].Execute) $launcherPath))
$processPairValid = [bool]($launcherProcess -and $runtimeProcess -and
    [int]$runtimeProcess.ParentProcessId -eq [int]$launcherProcess.ProcessId)
$reconcileMatchesLauncher = $false
if ($latestReconciled -and $launcherProcess -and $latestReconciled.data.PSObject.Properties['launcherPid']) {
    $reconcileMatchesLauncher = [int]$latestReconciled.data.launcherPid -eq [int]$launcherProcess.ProcessId
}

$liveHealth = $null
$identityVerified = $false
$identityError = $null
$artifactHash = $null
$resourcePrivateBytes = 0L
$resourceWorkingSetBytes = 0L
$resourceHandles = 0L
foreach ($row in @($launcherProcesses) + @($runtimeProcesses) + @($workerProcesses)) {
    $resourcePrivateBytes += [long]$row.PrivatePageCount
    $resourceWorkingSetBytes += [long]$row.WorkingSetSize
    $resourceHandles += [long]$row.HandleCount
}
try {
    if (-not $processPairValid) { throw 'No unique matching launcher/runtime pair.' }
    foreach ($file in @($healthPath, $processReceiptPath, (Join-Path $installRoot 'manifest.json'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -gt 256KB) {
            throw 'Live health, process receipt, or bounded artifact manifest is missing.'
        }
    }
    $liveHealth = Get-Content -LiteralPath $healthPath -Raw | ConvertFrom-Json
    $receipt = Get-Content -LiteralPath $processReceiptPath -Raw | ConvertFrom-Json
    $manifestPath = Join-Path $installRoot 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $artifactHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    if ($liveHealth.schema -ne 'codex-worktree-trust-bridge.health' -or $liveHealth.version -ne 1 -or
        $receipt.schema -ne 'codex-worktree-trust-bridge.process' -or $receipt.version -ne 1 -or
        $manifest.schema -ne 'codex-worktree-trust-bridge.build' -or $manifest.version -ne 1) { throw 'Unrecognized evidence schema.' }
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($liveHealth.updatedAtUtc)).TotalSeconds
    if ($age -lt 0 -or $age -gt 45 -or $receipt.phase -ne 'running' -or
        $liveHealth.pid -ne $runtimeProcess.ProcessId -or $receipt.runtimePid -ne $runtimeProcess.ProcessId -or
        $receipt.launcherPid -ne $launcherProcess.ProcessId -or $liveHealth.launcherPid -ne $launcherProcess.ProcessId -or
        $liveHealth.runId -cne $receipt.runId -or [string]::IsNullOrWhiteSpace($liveHealth.runId)) { throw 'Evidence is stale or does not identify the live pair.' }
    foreach ($identity in @(
        @{ Id = [int]$launcherProcess.ProcessId; Birth = [string]$receipt.launcherStartFileTimeUtc },
        @{ Id = [int]$runtimeProcess.ProcessId; Birth = [string]$receipt.runtimeStartFileTimeUtc }
    )) {
        $p = [Diagnostics.Process]::GetProcessById($identity.Id)
        try { if ($p.HasExited -or $p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $identity.Birth) { throw 'Process creation identity changed.' } }
        finally { $p.Dispose() }
    }
    if ($liveHealth.creationFileTimeUtc -ne $receipt.runtimeStartFileTimeUtc -or
        -not (Test-SamePath $receipt.configPath $configPath) -or -not (Test-SamePath $receipt.runtimePath $runtimePath) -or
        -not (Test-SamePath $receipt.launcherPath $launcherPath)) { throw 'Evidence paths or runtime birth do not agree.' }
    $artifacts = @($manifest.artifacts)
    if ($artifacts.Count -lt 6 -or $artifacts.Count -gt 32) { throw 'Manifest file count is invalid.' }
    foreach ($artifact in $artifacts) {
        if ($artifact.path -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $artifact.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Unsafe manifest entry.' }
        if ((Get-FileHash -LiteralPath (Join-Path $installRoot $artifact.path) -Algorithm SHA256).Hash -ne $artifact.sha256) { throw 'An installed artifact no longer matches its manifest.' }
    }
    if ($artifactHash -ne $liveHealth.sourceManifestSha256 -or
        $receipt.runtimeSha256 -ne (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash -or
        $receipt.launcherSha256 -ne (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash -or
        $liveHealth.packageVersion -ne $manifest.packageVersion) { throw 'The startup identities and current artifacts differ.' }
    if ($liveHealth.ui.workerActive) {
        if ($workerProcesses.Count -ne 1 -or $workerProcesses[0].ParentProcessId -ne $runtimeProcess.ProcessId -or
            $workerProcesses[0].ProcessId -ne $liveHealth.ui.worker.ProcessId) { throw 'UI worker ownership does not match live health.' }
        $p = [Diagnostics.Process]::GetProcessById([int]$workerProcesses[0].ProcessId)
        try { if ($p.HasExited -or $p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$liveHealth.ui.worker.CreationFileTimeUtc) { throw 'UI worker process identity changed.' } }
        finally { $p.Dispose() }
    }
    elseif ($workerProcesses.Count -ne 0) { throw 'An unexpected UI worker remains alive.' }
    $identityVerified = $true
}
catch { $identityError = $_.Exception.Message }

$healthState = if (-not $task) {
    'NOT_INSTALLED'
}
elseif ($launcherProcesses.Count -gt 1 -or $runtimeProcesses.Count -gt 1) {
    'DUPLICATE_PROCESS'
}
elseif ($task.State -ne 'Running') {
    'STOPPED'
}
elseif (-not $taskActionIsLauncher) {
    'TASK_MISCONFIGURED'
}
elseif (-not $processPairValid -or -not $reconcileMatchesLauncher) {
    'PROCESS_PAIR_INVALID'
}
elseif (-not $reconcileFresh) {
    'STALE_RECONCILE'
}
elseif (-not $identityVerified) {
    'UNVERIFIED_UI_AND_RESOURCES'
}
elseif (-not $liveHealth.healthy -or $liveHealth.ui.state -notin @('HEALTHY', 'IDLE', 'DISABLED')) {
    'DEGRADED'
}
elseif ($resourcePrivateBytes -gt 512MB -or $resourceHandles -gt 2000) {
    'RESOURCE_DEGRADED'
}
else {
    'HEALTHY'
}

$result = [pscustomobject]@{
    Healthy = $healthState -eq 'HEALTHY'
    HealthState = $healthState
    ProcessIdentityVerified = $identityVerified
    IdentityError = $identityError
    LiveHealth = $liveHealth
    ArtifactManifestSha256 = $artifactHash
    SustainedAcceptance = 'Not inferred from this instantaneous status check.'
    ResourceSample = @{ privateBytes = $resourcePrivateBytes; workingSetBytes = $resourceWorkingSetBytes; handles = $resourceHandles }
    WorkerProcesses = @($workerProcesses | Select-Object ProcessId, ParentProcessId, CreationDate, ExecutablePath)
    Task = if ($task) { [pscustomobject]@{
        Name = $task.TaskName
        State = [string]$task.State
        LastRunTime = $taskInfo.LastRunTime
        LastTaskResult = $taskInfo.LastTaskResult
        Action = @($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" })
        TriggerDelay = @($task.Triggers | ForEach-Object { $_.Delay })
    } } else { $null }
    LauncherProcesses = @($launcherProcesses | ForEach-Object { [pscustomobject]@{
        ProcessId = $_.ProcessId
        ParentProcessId = $_.ParentProcessId
        SessionId = $_.SessionId
        CreationDate = $_.CreationDate
        ExecutablePath = $_.ExecutablePath
        CommandLine = $_.CommandLine
    } })
    RuntimeProcesses = @($runtimeProcesses | ForEach-Object { [pscustomobject]@{
        ProcessId = $_.ProcessId
        ParentProcessId = $_.ParentProcessId
        SessionId = $_.SessionId
        CreationDate = $_.CreationDate
        ExecutablePath = $_.ExecutablePath
        CommandLine = $_.CommandLine
    } })
    LatestStarted = if ($latestStarted) { [pscustomobject]@{
        Timestamp = $latestStarted.timestamp
        ProcessId = $latestStarted.data.pid
        LauncherProcessId = if ($latestStarted.data.PSObject.Properties['launcherPid']) {
            $latestStarted.data.launcherPid
        } else { $null }
    } } else { $null }
    LatestReconciled = if ($latestReconciled) { [pscustomobject]@{
        Timestamp = $latestReconciled.timestamp
        ProcessId = $latestReconciled.data.pid
        LauncherProcessId = if ($latestReconciled.data.PSObject.Properties['launcherPid']) {
            $latestReconciled.data.launcherPid
        } else { $null }
        ManagedCount = $latestReconciled.data.managedCount
    } } else { $null }
    PackageVersion = if (Test-Path -LiteralPath (Join-Path $installRoot 'VERSION')) {
        (Get-Content (Join-Path $installRoot 'VERSION') -Raw).Trim()
    } else { $null }
    AllowedRoots = if ($config) { @($config.allowedRoots) } else { @() }
    TrustMode = if ($config -and $config.PSObject.Properties['trustMode']) { [string]$config.trustMode } else { 'git-only' }
    DeniedDialogAction = if ($config -and $config.PSObject.Properties['deniedDialogAction']) { [string]$config.deniedDialogAction } else { 'leave-open' }
    DeniedDialogGraceSeconds = if ($config -and $config.PSObject.Properties['deniedDialogGraceSeconds']) { [int]$config.deniedDialogGraceSeconds } else { 3 }
    ManagedPathCount = if ($state) { @($state.managedPaths).Count } else { 0 }
    RuntimeHash = if (Test-Path -LiteralPath $runtimePath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimePath).Hash } else { $null }
    LauncherHash = if (Test-Path -LiteralPath $launcherPath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $launcherPath).Hash } else { $null }
    RecentLog = $recentLog
}

$result | ConvertTo-Json -Depth 10
if (-not $result.Healthy) { exit 1 }
