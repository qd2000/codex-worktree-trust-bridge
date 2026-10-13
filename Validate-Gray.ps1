[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallReceiptPath,
    [ValidateRange(120, 1440)][int]$DurationMinutes = 120,
    [ValidateRange(10, 30)][int]$SampleIntervalSeconds = 30,
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge',
    [string]$TaskPath = '\',
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\tools\codex-worktree-trust-bridge'),
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\codex-worktree-trust-bridge.json'),
    [string]$StatePath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.json'),
    [string]$ActionLedgerPath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.ui-actions.json'),
    [string]$CodexConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$LogPath = (Join-Path $env:USERPROFILE '.codex\log\codex-worktree-trust-bridge.log'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.codex\backups\codex-worktree-trust-bridge\maintenance'),
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.Maintenance.ps1'
if (-not (Test-Path -LiteralPath $module)) { $module = Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Maintenance.ps1' }
if (-not (Test-Path -LiteralPath $module)) { throw 'Maintenance implementation is missing.' }
. $module

function Get-GrayProcessResource {
    param([Parameter(Mandatory)]$Identity)
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid)
        [void]$process.Handle
        if ($process.HasExited -or $process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$Identity.creationFileTimeUtc -or
            (ConvertTo-BridgeCanonicalPath $process.MainModule.FileName) -ine [string]$Identity.executablePath) {
            throw "Process identity changed during gray observation: $($Identity.pid)"
        }
        $process.Refresh()
        return [pscustomobject]@{
            pid = $process.Id
            creationFileTimeUtc = [long]$Identity.creationFileTimeUtc
            privateBytes = $process.PrivateMemorySize64
            workingSetBytes = $process.WorkingSet64
            handles = $process.HandleCount
        }
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Get-GraySlope {
    param([Parameter(Mandatory)][object[]]$Rows, [Parameter(Mandatory)][string]$Property)
    $meanX = ($Rows | Measure-Object -Property elapsedSeconds -Average).Average
    $meanY = ($Rows | Measure-Object -Property $Property -Average).Average
    $variance = 0.0
    $covariance = 0.0
    foreach ($row in $Rows) {
        $x = [double]$row.elapsedSeconds - $meanX
        $variance += $x * $x
        $covariance += $x * ([double]$row.$Property - $meanY)
    }
    if ($variance -eq 0) { return 0.0 }
    return $covariance / $variance * 60.0
}

function Get-GrayMedian {
    param([Parameter(Mandatory)][double[]]$Values)
    if (-not $Values.Count) { throw 'Cannot compute a median from an empty window.' }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Invoke-GrayGit {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$WorkingDirectory)
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $git
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Gray Git command did not start.' }
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw 'Gray Git command exceeded 30 seconds.'
        }
        if ($process.ExitCode -ne 0) { throw "Gray Git command failed with exit $($process.ExitCode)." }
    }
    finally { $process.Dispose() }
}

$layout = New-BridgeMaintenanceLayout -TaskName $TaskName -TaskPath $TaskPath `
    -InstallRoot $InstallRoot -ConfigPath $ConfigPath -StatePath $StatePath `
    -ActionLedgerPath $ActionLedgerPath -CodexConfigPath $CodexConfigPath `
    -LogPath $LogPath -BackupRoot $BackupRoot
$installReceipt = Read-BridgeJson -Path $InstallReceiptPath -MaximumBytes 4194304
if ($installReceipt.schema -ne 'codex-worktree-trust-bridge.install' -or -not [bool]$installReceipt.passed -or
    [string]$installReceipt.artifact.deploymentMode -ne 'canary') {
    throw 'Gray validation requires a successful canary installation receipt.'
}
if ($env:COMPUTERNAME -ine 'QDSPC') { throw 'The first production gray run is restricted to QDSPC.' }
$artifact = Test-BridgeArtifactDirectory -ArtifactDirectory $layout.installRoot -CanaryDeployment
if ([string]$installReceipt.artifact.manifestSha256 -cne $artifact.ManifestSha256) {
    throw 'Installed canary manifest differs from the installation receipt.'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $BackupRoot ('gray-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
}
$OutputDirectory = ConvertTo-BridgeCanonicalPath $OutputDirectory
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$samplesPath = Join-Path $OutputDirectory 'samples.jsonl'
$activityPath = Join-Path $OutputDirectory 'activity.jsonl'
$receiptPath = Join-Path $OutputDirectory 'gray-authorization.json'

$configuration = Read-BridgeJson -Path $layout.configPath -MaximumBytes 1048576
$allowedRoot = @($configuration.allowedRoots | ForEach-Object { ConvertTo-BridgeCanonicalPath ([string]$_) } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1)
if (-not $allowedRoot.Count) { throw 'No existing allowed root is available for the gray Git workload.' }
$allowedRoot = [string]$allowedRoot[0]
if (((Get-Item -LiteralPath $allowedRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Gray workload refuses a reparse-point allowed root.'
}
$token = '.codex-trust-bridge-gray-v022-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
$repo = Join-Path $allowedRoot $token
$worktrees = [Collections.Generic.List[string]]::new()
$activity = [Collections.Generic.List[object]]::new()
$rows = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$durationSeconds = [double]$DurationMinutes * 60.0
$failure = $null

function Add-GrayWorktree([string]$Name) {
    $path = Join-Path $allowedRoot ($token + '-' + $Name)
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('worktree', 'add', '--detach', $path, 'HEAD')
    $worktrees.Add($path)
    $event = @{ elapsedSeconds = $clock.Elapsed.TotalSeconds; action = 'add-worktree'; path = $path; utc = [DateTime]::UtcNow.ToString('o') }
    $activity.Add($event)
    Add-Content -LiteralPath $activityPath -Value ($event | ConvertTo-Json -Compress) -Encoding utf8
}

function Remove-GrayWorktree([string]$Path) {
    if (-not $worktrees.Contains($Path)) { return }
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('worktree', 'remove', '--force', $Path)
    [void]$worktrees.Remove($Path)
    $event = @{ elapsedSeconds = $clock.Elapsed.TotalSeconds; action = 'remove-worktree'; path = $Path; utc = [DateTime]::UtcNow.ToString('o') }
    $activity.Add($event)
    Add-Content -LiteralPath $activityPath -Value ($event | ConvertTo-Json -Compress) -Encoding utf8
}

try {
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('init', '--initial-branch=main')
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('config', 'user.name', 'Trust Bridge Gray')
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('config', 'user.email', 'gray@example.invalid')
    [IO.File]::WriteAllText((Join-Path $repo 'README.txt'), 'representative gray workload', [Text.UTF8Encoding]::new($false))
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('add', 'README.txt')
    Invoke-GrayGit -WorkingDirectory $repo -Arguments @('commit', '-m', 'gray baseline')
    Add-GrayWorktree 'wt1'
    Add-GrayWorktree 'wt2'
    Add-GrayWorktree 'wt3'

    $initial = Get-BridgeInstalledStatus -Layout $layout
    if (-not $initial.Healthy) { throw "Canary is not healthy before gray sampling: $($initial.State): $($initial.Error)" }
    $initialReconcile = [long]$initial.Health.reconcileCount
    $initialGitCommands = [long]$initial.Health.git.commandCount
    $initialUiScans = [long]$initial.Health.ui.scanCount
    $initialUiFailures = [long]$initial.Health.ui.failureCount
    $initialGitTimeouts = [long]$initial.Health.git.timeoutCount
    $initialGitOutputLimits = [long]$initial.Health.git.outputLimitCount
    $initialGitCleanupFailures = [long]$initial.Health.git.cleanupFailureCount
    $nextSample = 0.0
    $topologyEvents = @(
        @{ at = $durationSeconds * 0.25; action = 'add'; name = 'wt4'; done = $false },
        @{ at = $durationSeconds * 0.50; action = 'remove'; name = 'wt1'; done = $false },
        @{ at = $durationSeconds * 0.75; action = 'add'; name = 'wt5'; done = $false },
        @{ at = $durationSeconds * 0.875; action = 'remove'; name = 'wt2'; done = $false }
    )
    while ($clock.Elapsed.TotalSeconds -lt $durationSeconds) {
        $elapsed = $clock.Elapsed.TotalSeconds
        foreach ($event in $topologyEvents) {
            if (-not $event.done -and $elapsed -ge [double]$event.at) {
                if ($event.action -eq 'add') { Add-GrayWorktree ([string]$event.name) }
                else {
                    $match = @($worktrees | Where-Object { $_ -like "*-$($event.name)" } | Select-Object -First 1)
                    if ($match.Count) { Remove-GrayWorktree ([string]$match[0]) }
                }
                $event.done = $true
            }
        }
        if ($elapsed -ge $nextSample) {
            $status = Get-BridgeInstalledStatus -Layout $layout
            if (-not $status.Healthy) { throw "Canary became unhealthy: $($status.State): $($status.Error)" }
            if ((Get-BridgeFileHash $layout.manifestPath) -cne $artifact.ManifestSha256) { throw 'Installed manifest changed during gray observation.' }
            $set = $status.ProcessSet
            $launcher = Get-GrayProcessResource $set.Launcher
            $runtime = Get-GrayProcessResource $set.Runtime
            $descendants = @($set.Descendants | ForEach-Object { Get-GrayProcessResource $_ })
            $descendantPrivate = [long](($descendants | Measure-Object -Property privateBytes -Sum).Sum)
            $descendantWorking = [long](($descendants | Measure-Object -Property workingSetBytes -Sum).Sum)
            $descendantHandles = [long](($descendants | Measure-Object -Property handles -Sum).Sum)
            $row = [pscustomobject]@{
                utc = [DateTime]::UtcNow.ToString('o'); elapsedSeconds = $elapsed
                manifestSha256 = $artifact.ManifestSha256
                launcherPid = $launcher.pid; runtimePid = $runtime.pid
                launcherPrivateBytes = $launcher.privateBytes; runtimePrivateBytes = $runtime.privateBytes
                descendantPrivateBytes = $descendantPrivate
                aggregatePrivateBytes = [long]$launcher.privateBytes + [long]$runtime.privateBytes + $descendantPrivate
                launcherWorkingSetBytes = $launcher.workingSetBytes; runtimeWorkingSetBytes = $runtime.workingSetBytes
                descendantWorkingSetBytes = $descendantWorking
                aggregateWorkingSetBytes = [long]$launcher.workingSetBytes + [long]$runtime.workingSetBytes + $descendantWorking
                launcherHandles = $launcher.handles; runtimeHandles = $runtime.handles; descendantHandles = $descendantHandles
                aggregateHandles = [long]$launcher.handles + [long]$runtime.handles + $descendantHandles
                descendantCount = $descendants.Count
                managedHeapBytes = [long]$status.Health.parent.managedHeapBytes
                reconcileCount = [long]$status.Health.reconcileCount
                gitCommandCount = [long]$status.Health.git.commandCount
                gitFailureCount = [long]$status.Health.git.failureCount
                gitTimeoutCount = [long]$status.Health.git.timeoutCount
                gitOutputLimitCount = [long]$status.Health.git.outputLimitCount
                gitCleanupFailureCount = [long]$status.Health.git.cleanupFailureCount
                gitActiveCount = [int]$status.Health.git.activeCount
                uiScanCount = [long]$status.Health.ui.scanCount
                uiFailureCount = [long]$status.Health.ui.failureCount
                uiWorkerGeneration = [long]$status.Health.ui.workerGeneration
                uiWorkerActive = [bool]$status.Health.ui.workerActive
                healthy = [bool]$status.Health.healthy
            }
            $rows.Add($row)
            Add-Content -LiteralPath $samplesPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
            $nextSample += $SampleIntervalSeconds
        }
        Start-Sleep -Milliseconds 250
    }

    $usable = @($rows | Where-Object { $_.elapsedSeconds -ge 600 })
    if ($usable.Count -lt 200) { throw "Only $($usable.Count) usable post-warm-up samples were recorded." }
    $privatePeak = [long](($usable | Measure-Object -Property aggregatePrivateBytes -Maximum).Maximum)
    $handlesPeak = [long](($usable | Measure-Object -Property aggregateHandles -Maximum).Maximum)
    $privateSlope = (Get-GraySlope $usable aggregatePrivateBytes) / 1MB
    $handleSlope = Get-GraySlope $usable aggregateHandles
    $runtimePrivateSlope = (Get-GraySlope $usable runtimePrivateBytes) / 1MB
    $launcherPrivateSlope = (Get-GraySlope $usable launcherPrivateBytes) / 1MB
    $descendantPrivateSlope = (Get-GraySlope $usable descendantPrivateBytes) / 1MB
    $lastWindow = @($usable | Where-Object { $_.elapsedSeconds -ge ($durationSeconds - 900) })
    $previousWindow = @($usable | Where-Object { $_.elapsedSeconds -ge ($durationSeconds - 1800) -and $_.elapsedSeconds -lt ($durationSeconds - 900) })
    $lastMedian = Get-GrayMedian ([double[]]@($lastWindow.aggregatePrivateBytes))
    $previousMedian = Get-GrayMedian ([double[]]@($previousWindow.aggregatePrivateBytes))
    $final = $rows[-1]
    $reconcileDelta = [long]$final.reconcileCount - $initialReconcile
    $gitCommandDelta = [long]$final.gitCommandCount - $initialGitCommands
    $uiScanDelta = [long]$final.uiScanCount - $initialUiScans
    $postWarmupGenerations = @($usable.uiWorkerGeneration | Sort-Object -Unique)
    $resourceGatePassed = $privatePeak -le 512MB -and $handlesPeak -le 2000 -and
        $privateSlope -le 0.25 -and $handleSlope -le 0.2 -and
        ($lastMedian - $previousMedian) -le 16MB
    $activityGatePassed = $reconcileDelta -ge 100 -and $gitCommandDelta -ge 200 -and $uiScanDelta -ge 100 -and
        $activity.Count -ge 7 -and $postWarmupGenerations.Count -eq 1
    $integrityGatePassed = [long]$final.gitTimeoutCount -eq $initialGitTimeouts -and
        [long]$final.gitOutputLimitCount -eq $initialGitOutputLimits -and
        [long]$final.gitCleanupFailureCount -eq $initialGitCleanupFailures -and
        [long]$final.uiFailureCount -eq $initialUiFailures -and
        @($rows | Where-Object { -not $_.healthy }).Count -eq 0
    if (-not $resourceGatePassed -or -not $activityGatePassed -or -not $integrityGatePassed) {
        throw "Gray gate failed: resource=$resourceGatePassed activity=$activityGatePassed integrity=$integrityGatePassed"
    }

    $receipt = [ordered]@{
        schema = 'codex-worktree-trust-bridge.gray-authorization'; version = 1
        createdAtUtc = $null; passed = $false
        hostName = $env:COMPUTERNAME
        qdspcCanaryPassed = $false; fleetDeploymentAllowed = $false
        candidateManifestSha256 = $artifact.ManifestSha256
        sourceCommit = [string]$artifact.Manifest.sourceCommit
        installReceiptPath = ConvertTo-BridgeCanonicalPath $InstallReceiptPath
        durationSeconds = $clock.Elapsed.TotalSeconds; sampleIntervalSeconds = $SampleIntervalSeconds
        totalSamples = $rows.Count; usableSamples = $usable.Count; warmupSeconds = 600
        resourceGatePassed = $resourceGatePassed; activityGatePassed = $activityGatePassed
        integrityGatePassed = $integrityGatePassed
        metrics = [ordered]@{
            aggregatePrivatePeakBytes = $privatePeak; aggregateHandlesPeak = $handlesPeak
            aggregatePrivateSlopeMiBPerMinute = $privateSlope; aggregateHandleSlopePerMinute = $handleSlope
            runtimePrivateSlopeMiBPerMinute = $runtimePrivateSlope
            launcherPrivateSlopeMiBPerMinute = $launcherPrivateSlope
            descendantPrivateSlopeMiBPerMinute = $descendantPrivateSlope
            previous15MinuteMedianPrivateBytes = $previousMedian; final15MinuteMedianPrivateBytes = $lastMedian
            reconcileDelta = $reconcileDelta; gitCommandDelta = $gitCommandDelta; uiScanDelta = $uiScanDelta
            postWarmupWorkerGenerations = $postWarmupGenerations
        }
        workload = [ordered]@{
            allowedRoot = $allowedRoot; temporaryRepository = $repo
            topologyEvents = $activity.ToArray(); limitation = 'Real Codex window scanning plus controlled Git/worktree topology; no synthetic production dialog invocation.'
        }
        samplesPath = $samplesPath; activityPath = $activityPath
        cleanupVerified = $false
        postCleanup = $null
    }
}
catch {
    $failure = $_
}
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($path in @($worktrees.ToArray())) {
        try {
            Invoke-GrayGit -WorkingDirectory $repo -Arguments @('worktree', 'remove', '--force', $path)
            [void]$worktrees.Remove($path)
        }
        catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    try {
        if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction Stop }
    }
    catch { $cleanupErrors.Add($_.Exception.Message) }

    if ($null -eq $failure -and $cleanupErrors.Count -eq 0) {
        $preCleanupReconcile = if ($rows.Count) { [long]$rows[-1].reconcileCount } else { 0L }
        $cleanupClock = [Diagnostics.Stopwatch]::StartNew()
        $cleanupDeadlineSeconds = [Math]::Max(240, ([int]$configuration.reconcileIntervalSeconds * 3) + 60)
        $cleanupVerified = $false
        $cleanupStatus = $null
        do {
            Start-Sleep -Seconds 2
            $cleanupStatus = Get-BridgeInstalledStatus -Layout $layout
            $stateContainsToken = $false
            if (Test-Path -LiteralPath $layout.statePath -PathType Leaf) {
                try {
                    $state = Read-BridgeJson -Path $layout.statePath -MaximumBytes 4194304
                    $stateContainsToken = @($state.managedPaths | Where-Object { ([string]$_).IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
                }
                catch { $stateContainsToken = $true }
            }
            $configContainsToken = $false
            if (Test-Path -LiteralPath $layout.codexConfigPath -PathType Leaf) {
                $configContainsToken = [IO.File]::ReadAllText($layout.codexConfigPath).IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
            $cleanupVerified = $cleanupStatus.Healthy -and
                [string]$cleanupStatus.ManifestSha256 -ceq $artifact.ManifestSha256 -and
                [long]$cleanupStatus.Health.reconcileCount -ge ($preCleanupReconcile + 2) -and
                -not (Test-Path -LiteralPath $repo) -and -not $worktrees.Count -and
                -not $stateContainsToken -and -not $configContainsToken
        } while (-not $cleanupVerified -and $cleanupClock.Elapsed.TotalSeconds -lt $cleanupDeadlineSeconds)

        if ($cleanupVerified) {
            $receipt.cleanupVerified = $true
            $receipt.postCleanup = [ordered]@{
                durationSeconds = $cleanupClock.Elapsed.TotalSeconds
                reconcileCount = [long]$cleanupStatus.Health.reconcileCount
                manifestSha256 = [string]$cleanupStatus.ManifestSha256
                temporaryRepositoryAbsent = -not (Test-Path -LiteralPath $repo)
                managedStateTokenAbsent = $true
                codexConfigTokenAbsent = $true
            }
        }
        else {
            $cleanupErrors.Add('Gray workload cleanup was not reconciled out of bridge state/config before the deadline.')
        }
    }
}

if ($cleanupErrors.Count -and $null -eq $failure) {
    $failure = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new(($cleanupErrors -join ' | ')),
        'GrayCleanupFailed',
        [Management.Automation.ErrorCategory]::InvalidResult,
        $repo)
}

if ($null -ne $failure) {
    $failedReceipt = [ordered]@{
        schema = 'codex-worktree-trust-bridge.gray-authorization'; version = 1
        createdAtUtc = [DateTime]::UtcNow.ToString('o'); passed = $false
        hostName = $env:COMPUTERNAME
        qdspcCanaryPassed = $false; fleetDeploymentAllowed = $false
        candidateManifestSha256 = $artifact.ManifestSha256
        sourceCommit = [string]$artifact.Manifest.sourceCommit
        durationSeconds = $clock.Elapsed.TotalSeconds; totalSamples = $rows.Count
        cleanupVerified = $false; cleanupErrors = $cleanupErrors.ToArray()
        error = $failure.Exception.ToString(); samplesPath = $samplesPath; activityPath = $activityPath
    }
    Write-BridgeAtomicJson -Path $receiptPath -Value $failedReceipt
    throw $failure
}

$receipt.createdAtUtc = [DateTime]::UtcNow.ToString('o')
$receipt.passed = $true
$receipt.qdspcCanaryPassed = $true
$receipt.fleetDeploymentAllowed = $true
Write-BridgeAtomicJson -Path $receiptPath -Value $receipt
$receipt | ConvertTo-Json -Depth 20
