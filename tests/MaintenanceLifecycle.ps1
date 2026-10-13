[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The Windows .NET Framework compiler is required.' }

$testRoot = Join-Path $root ('.artifacts\maintenance-tests\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$evidence = Join-Path $testRoot 'evidence'
$machine = Join-Path $testRoot 'machine'
$artifact = Join-Path $testRoot 'candidate-artifact'
$corruptArtifact = Join-Path $testRoot 'corrupt-artifact'
$legacySource = Join-Path $testRoot 'legacy-source'
$decoyRoot = Join-Path $testRoot 'decoy'
$controlPath = Join-Path $testRoot 'control.json'
$readyPath = Join-Path $testRoot 'runtime-ready.json'
$childReadyPath = Join-Path $testRoot 'runtime-child-ready.json'
$productionBeforePath = Join-Path $evidence 'production-before.json'
$productionAfterPath = Join-Path $evidence 'production-after.json'
$taskName = 'Codex-Worktree-Trust-Bridge-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$freshTaskName = 'Codex-Worktree-Trust-Bridge-Test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
foreach ($directory in @($evidence, $machine, $artifact, $legacySource, $decoyRoot)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$layout = New-BridgeMaintenanceLayout -TaskName $taskName -TaskPath '\' `
    -InstallRoot (Join-Path $machine 'install') `
    -ConfigPath (Join-Path $machine 'bridge.json') `
    -StatePath (Join-Path $machine 'state\bridge-state.json') `
    -ActionLedgerPath (Join-Path $machine 'state\ui-actions.json') `
    -CodexConfigPath (Join-Path $machine 'codex\config.toml') `
    -LogPath (Join-Path $machine 'log\bridge.log') `
    -BackupRoot (Join-Path $machine 'backups')

$freshRoot = Join-Path $testRoot 'fresh-machine'
$freshLayout = New-BridgeMaintenanceLayout -TaskName $freshTaskName -TaskPath '\' `
    -InstallRoot (Join-Path $freshRoot 'install') `
    -ConfigPath (Join-Path $freshRoot 'bridge.json') `
    -StatePath (Join-Path $freshRoot 'state\bridge-state.json') `
    -ActionLedgerPath (Join-Path $freshRoot 'state\ui-actions.json') `
    -CodexConfigPath (Join-Path $freshRoot 'codex\config.toml') `
    -LogPath (Join-Path $freshRoot 'log\bridge.log') `
    -BackupRoot (Join-Path $freshRoot 'backups')

function Get-TextSha256 {
    param([string]$Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-ProductionFingerprint {
    $productionLayout = New-BridgeMaintenanceLayout
    $task = Get-BridgeTask $productionLayout
    if (-not $task) { return [ordered]@{ taskExisted = $false } }
    $set = Get-BridgeProcessSet -Layout $productionLayout -Task $task -AllowMissingPair
    $files = @($productionLayout.launcherPath, $productionLayout.runtimePath,
        (Join-Path $productionLayout.installRoot 'VERSION'), $productionLayout.configPath)
    return [ordered]@{
        taskExisted = $true
        taskState = [string]$task.State
        taskXmlSha256 = Get-TextSha256 (Export-ScheduledTask -TaskName $productionLayout.taskName -TaskPath $productionLayout.taskPath)
        launcher = $set.Launcher
        runtime = $set.Runtime
        hashes = @($files | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object {
            [ordered]@{ path = ConvertTo-BridgeCanonicalPath $_; sha256 = Get-BridgeFileHash $_ }
        })
    }
}

function Invoke-ToolProcess {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string[]]$Arguments,
        [bool]$ExpectSuccess = $true,
        [int]$TimeoutSeconds = 120
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($value in @('-NoLogo', '-NoProfile', '-File', $Script) + $Arguments) { [void]$info.ArgumentList.Add($value) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start tool: $Script" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "Tool timed out: $Script"
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; Error = $errorText }
        if ($ExpectSuccess -and $process.ExitCode -ne 0) { throw "Tool failed ($($process.ExitCode)): $Script`n$errorText`n$output" }
        if (-not $ExpectSuccess -and $process.ExitCode -eq 0) { throw "Tool unexpectedly succeeded: $Script" }
        return $result
    }
    finally { $process.Dispose() }
}

function Get-LayoutArguments {
    param([Parameter(Mandatory)]$Value)
    return [string[]]@(
        '-TaskName', $Value.taskName,
        '-TaskPath', $Value.taskPath,
        '-InstallRoot', $Value.installRoot,
        '-ConfigPath', $Value.configPath,
        '-StatePath', $Value.statePath,
        '-ActionLedgerPath', $Value.actionLedgerPath,
        '-CodexConfigPath', $Value.codexConfigPath,
        '-LogPath', $Value.logPath,
        '-BackupRoot', $Value.backupRoot,
        '-DevelopmentTest',
        '-TestRoot', $testRoot
    )
}

function Set-ControlMode {
    param([Parameter(Mandatory)][ValidateSet('normal', 'degraded', 'startup-fail', 'crash-after-ready')][string]$Mode)
    Write-BridgeAtomicJson -Path $controlPath -Value @{ mode = $Mode; updatedAt = [DateTimeOffset]::Now.ToString('o') }
}

function Wait-File {
    param([Parameter(Mandatory)][string]$Path, [int]$Seconds = 15)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for file: $Path"
}

function New-TestManifest {
    param([Parameter(Mandatory)][string]$Directory, [string]$SourceCommit = 'maintenance-fixture')
    $entries = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object Name -ne 'manifest.json' | Sort-Object Name | ForEach-Object {
        [ordered]@{ path = $_.Name; sha256 = Get-BridgeFileHash $_.FullName }
    })
    $manifest = [ordered]@{
        schema = 'codex-worktree-trust-bridge.build'
        version = 1
        packageVersion = '0.2.2'
        sourceCommit = $SourceCommit
        sourceDirty = $false
        workerBuilt = $true
        maintenanceBuilt = $true
        accepted = $false
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        compilerSha256 = Get-BridgeFileHash $compiler
        sources = @()
        artifacts = $entries
    }
    Write-BridgeAtomicJson -Path (Join-Path $Directory 'manifest.json') -Value $manifest
}

function Register-LegacyTestTask {
    param([Parameter(Mandatory)]$Value)
    $arguments = [CodexTrustBridgeMaintenance.CommandLine]::Join([string[]]@($pwsh, $Value.runtimePath, $Value.configPath))
    $action = New-ScheduledTaskAction -Execute $Value.launcherPath -Argument $arguments -WorkingDirectory $Value.installRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $trigger.Delay = 'PT17S'
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $Value.taskName -TaskPath $Value.taskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Isolated v0.2.1-style maintenance fixture.' -Force | Out-Null
}

function Start-UnrelatedDecoy {
    $decoyDirectory = Join-Path $decoyRoot 'same-basename'
    New-Item -ItemType Directory -Path $decoyDirectory -Force | Out-Null
    $decoyScript = Join-Path $decoyDirectory 'CodexWorktreeTrustBridge.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\MaintenanceDecoy.ps1') -Destination $decoyScript
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwsh
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $decoyScript, '-ConfigPath', (Join-Path $decoyDirectory 'bridge.json'))) {
        [void]$info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Could not start the unrelated decoy.' }
    [void]$process.Handle
    return $process
}

function Assert-DecoyAlive {
    param([Parameter(Mandatory)]$Process)
    $Process.Refresh()
    if ($Process.HasExited) { throw 'Exact bridge maintenance terminated the unrelated same-basename decoy.' }
}

function Remove-TestTask {
    param([Parameter(Mandatory)]$Value)
    try { [void](Stop-BridgeTaskExact -Layout $Value) } catch { }
    $task = Get-BridgeTask $Value
    if ($task) { Unregister-ScheduledTask -TaskName $Value.taskName -TaskPath $Value.taskPath -Confirm:$false -ErrorAction SilentlyContinue }
}

$productionBefore = Get-ProductionFingerprint
Write-BridgeAtomicJson -Path $productionBeforePath -Value $productionBefore
$decoy = $null
$duplicate = $null
$cases = [Collections.Generic.List[object]]::new()

try {
    # Build a controlled v0.2.1-style installation. Its launcher lacks a Job and
    # leaves the runtime/child alive when only the launcher is stopped.
    New-Item -ItemType Directory -Path $layout.installRoot -Force | Out-Null
    $legacyLauncherSource = Join-Path $legacySource 'LegacyLauncher.cs'
    $legacyLines = @(& git -C $root show 'v0.2.1:src/CodexWorktreeTrustBridge.Launcher.cs')
    if ($LASTEXITCODE) { throw 'Could not read the pinned v0.2.1 launcher source.' }
    [IO.File]::WriteAllLines($legacyLauncherSource, $legacyLines, [Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$($layout.launcherPath)" $legacyLauncherSource
    if ($LASTEXITCODE) { throw 'Legacy launcher fixture compilation failed.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\MaintenanceLegacyRuntime.ps1') -Destination $layout.runtimePath
    $childScriptPath = Join-Path $machine 'MaintenanceChild.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\MaintenanceChild.ps1') -Destination $childScriptPath
    [IO.File]::WriteAllText((Join-Path $layout.installRoot 'VERSION'), "0.2.1`r`n", [Text.UTF8Encoding]::new($false))
    foreach ($directory in @((Split-Path -Parent $layout.statePath), (Split-Path -Parent $layout.codexConfigPath))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $configuration = [ordered]@{
        schema = 'codex-worktree-trust-bridge.config'; version = 1; packageVersion = '0.2.1'
        allowedRoots = @((Join-Path $testRoot 'allowed')); uiPollIntervalMs = 750
        reconcileIntervalSeconds = 60; discoveryDepth = 2; trustMode = 'all-directories'
        deniedDialogAction = 'leave-open'; deniedDialogGraceSeconds = 3
        enableConfigTrust = $false; enableUiAutoApprove = $false; pruneMissingManagedEntries = $true
        fixtureControlPath = $controlPath; fixtureReadyPath = $readyPath
        fixtureChildReadyPath = $childReadyPath; fixtureChildScriptPath = $childScriptPath
        customMachineSetting = 'preserve-this-machine'
    }
    Write-BridgeAtomicJson -Path $layout.configPath -Value $configuration
    Write-BridgeAtomicJson -Path $layout.statePath -Value @{ schema = 'fixture-state'; value = 'legacy-state' }
    $codexConfigOriginal = @"
external_setting = 'preserve-before-upgrade'

# BEGIN CODEX WORKTREE TRUST BRIDGE
[projects.'c:\legacy-fixture']
trust_level = "trusted"
# END CODEX WORKTREE TRUST BRIDGE
"@
    Write-BridgeAtomicText -Path $layout.codexConfigPath -Text $codexConfigOriginal
    Set-ControlMode normal
    Register-LegacyTestTask -Value $layout
    Start-ScheduledTask -TaskName $layout.taskName -TaskPath $layout.taskPath
    $legacyPair = Wait-BridgeProcessPair -Layout $layout -TimeoutSeconds 20
    Wait-File $readyPath
    Wait-File $childReadyPath
    $legacyLauncherHash = Get-BridgeFileHash $layout.launcherPath
    $legacyRuntimeHash = Get-BridgeFileHash $layout.runtimePath
    $legacyTask = Get-BridgeTask $layout
    $legacyTriggerDelay = [string]@($legacyTask.Triggers)[0].Delay
    $legacyTaskXml = Export-ScheduledTask -TaskName $layout.taskName -TaskPath $layout.taskPath

    # Create a candidate artifact with the real v0.2.2 launcher/native/helper and
    # a controlled runtime. It emits the real health/process contract but never
    # reads the desktop UI or the user's Codex profile.
    Copy-Item -Path (Join-Path $root '.artifacts\bin\*') -Destination $artifact
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\MaintenanceCandidateRuntime.ps1') `
        -Destination (Join-Path $artifact 'CodexWorktreeTrustBridge.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\MaintenanceChild.ps1') `
        -Destination (Join-Path $artifact 'MaintenanceFixtureChild.ps1')
    New-TestManifest -Directory $artifact
    Copy-Item -LiteralPath $artifact -Destination $corruptArtifact -Recurse
    [IO.File]::AppendAllText((Join-Path $corruptArtifact 'CodexWorktreeTrustBridge.ps1'), "`r`n# corrupt`r`n")

    $decoy = Start-UnrelatedDecoy
    Start-Sleep -Milliseconds 300
    Assert-DecoyAlive $decoy

    # Corrupt artifacts are rejected before backup/stop/mutation.
    $pairBeforeCorrupt = Get-BridgeProcessSet -Layout $layout -Task (Get-BridgeTask $layout)
    $corruptArgs = @('-ArtifactDirectory', $corruptArtifact) + (Get-LayoutArguments $layout) + @('-TimeoutSeconds', '20')
    [void](Invoke-ToolProcess -Script (Join-Path $root 'Install.ps1') -Arguments $corruptArgs -ExpectSuccess:$false)
    $pairAfterCorrupt = Get-BridgeProcessSet -Layout $layout -Task (Get-BridgeTask $layout)
    if ($pairAfterCorrupt.Launcher.pid -ne $pairBeforeCorrupt.Launcher.pid -or
        $pairAfterCorrupt.Runtime.pid -ne $pairBeforeCorrupt.Runtime.pid) { throw 'Corrupt artifact validation mutated the running legacy task.' }
    Assert-DecoyAlive $decoy
    $cases.Add(@{ case = 'manifest corruption preflight'; passed = $true; mutation = $false })

    # A second exact legacy launcher creates an ambiguous identity. Maintenance
    # must fail closed and leave both it and the scheduled instance untouched.
    $duplicateInfo = [Diagnostics.ProcessStartInfo]::new()
    $duplicateInfo.FileName = $layout.launcherPath; $duplicateInfo.UseShellExecute = $false; $duplicateInfo.CreateNoWindow = $true
    foreach ($value in @($pwsh, $layout.runtimePath, $layout.configPath)) { [void]$duplicateInfo.ArgumentList.Add($value) }
    $duplicate = [Diagnostics.Process]::new(); $duplicate.StartInfo = $duplicateInfo
    if (-not $duplicate.Start()) { throw 'Could not create the duplicate identity fixture.' }
    Start-Sleep -Milliseconds 500
    $candidateArgs = @('-ArtifactDirectory', $artifact) + (Get-LayoutArguments $layout) + @('-TimeoutSeconds', '25')
    [void](Invoke-ToolProcess -Script (Join-Path $root 'Install.ps1') -Arguments $candidateArgs -ExpectSuccess:$false)
    Assert-DecoyAlive $decoy
    if ($duplicate.HasExited) { throw 'Ambiguous-identity preflight terminated the duplicate instead of failing closed.' }
    $duplicate.Kill($true); [void]$duplicate.WaitForExit(10000); $duplicate.Dispose(); $duplicate = $null
    $cases.Add(@{ case = 'ambiguous exact launcher identity'; passed = $true; broadKill = $false })

    # Successful v0.2.1-style upgrade. Exact stop must clean the old orphaned
    # runtime and child while preserving the unrelated same-basename decoy.
    Set-ControlMode normal
    $upgradeTool = Invoke-ToolProcess -Script (Join-Path $root 'Install.ps1') -Arguments $candidateArgs
    $upgrade = $upgradeTool.Output | ConvertFrom-Json
    $upgradeBackup = Test-BridgeBackup -BackupDirectory $upgrade.BackupDirectory
    Assert-DecoyAlive $decoy
    foreach ($identity in @($legacyPair.Launcher, $legacyPair.Runtime) + @($legacyPair.Descendants)) {
        if ($identity -and (Test-BridgeProcessIdentityAlive $identity)) { throw 'A captured v0.2.1 process survived successful upgrade.' }
    }
    $statusArgs = Get-LayoutArguments $layout | Where-Object { $_ -notin @('-DevelopmentTest', '-TestRoot', $testRoot) }
    $status = Invoke-ToolProcess -Script (Join-Path $root 'Status.ps1') -Arguments $statusArgs
    if (-not ($status.Output | ConvertFrom-Json).Healthy) { throw 'Positive candidate status was not healthy.' }
    $candidateTask = Get-BridgeTask $layout
    if ([string]@($candidateTask.Triggers)[0].Delay -ne $legacyTriggerDelay) { throw 'Upgrade did not preserve the task trigger.' }
    $currentConfig = Read-BridgeJson -Path $layout.configPath
    if ([string]$currentConfig.customMachineSetting -ne 'preserve-this-machine' -or
        [string]$currentConfig.packageVersion -ne '0.2.2') {
        throw 'Upgrade did not preserve machine-specific configuration while updating packageVersion.'
    }
    if ((Read-BridgeJson -Path $layout.statePath).value -ne 'legacy-state') { throw 'Upgrade overwrote machine-specific state.' }
    $cases.Add(@{ case = 'v0.2.1 upgrade with exact residual cleanup'; passed = $true; backup = $upgrade.BackupDirectory })

    # Negative health must not be reported as ready/healthy.
    Set-ControlMode degraded
    Start-Sleep -Seconds 1
    $negativeStatus = Invoke-ToolProcess -Script (Join-Path $root 'Status.ps1') -Arguments $statusArgs -ExpectSuccess:$false
    $negativeStatusValue = $negativeStatus.Output | ConvertFrom-Json
    if ($negativeStatusValue.State -ne 'DEGRADED') {
        throw "Degraded health produced state '$($negativeStatusValue.State)': $($negativeStatusValue.Error)"
    }
    Set-ControlMode normal
    [void](Wait-BridgeReady -Layout $layout -TimeoutSeconds 15)
    $cases.Add(@{ case = 'status positive and degraded paths'; passed = $true })

    # Ordinary stop and launcher crash must leave no owned runtime/child tree.
    $running = Get-BridgeProcessSet -Layout $layout -Task (Get-BridgeTask $layout)
    [void](Stop-BridgeTaskExact -Layout $layout)
    foreach ($identity in @($running.Launcher, $running.Runtime) + @($running.Descendants)) {
        if ($identity -and (Test-BridgeProcessIdentityAlive $identity)) { throw 'Ordinary exact task stop left an owned process.' }
    }
    Start-ScheduledTask -TaskName $layout.taskName -TaskPath $layout.taskPath
    $running = (Wait-BridgeReady -Layout $layout -TimeoutSeconds 20).ProcessSet
    [void](Stop-BridgeProcessIdentityExact -Identity $running.Launcher)
    foreach ($identity in @($running.Runtime) + @($running.Descendants)) {
        if ($identity -and -not (Wait-BridgeProcessIdentityExit -Identity $identity -TimeoutMilliseconds 10000)) {
            throw 'Launcher crash did not close the Job-owned process tree.'
        }
    }
    Start-ScheduledTask -TaskName $layout.taskName -TaskPath $layout.taskPath
    [void](Wait-BridgeReady -Layout $layout -TimeoutSeconds 20)
    Assert-DecoyAlive $decoy
    $cases.Add(@{ case = 'ordinary stop and launcher crash'; passed = $true; residual = $false })

    # Runtime crash should end the launcher and the controlled child. The task has
    # no restart policy in the preserved XML, so there is no restart loop.
    $running = (Wait-BridgeReady -Layout $layout -TimeoutSeconds 20).ProcessSet
    Set-ControlMode crash-after-ready
    foreach ($identity in @($running.Runtime, $running.Launcher) + @($running.Descendants)) {
        if ($identity -and -not (Wait-BridgeProcessIdentityExit -Identity $identity -TimeoutMilliseconds 15000)) {
            throw 'Runtime crash left an owned process.'
        }
    }
    Set-ControlMode normal
    Start-ScheduledTask -TaskName $layout.taskName -TaskPath $layout.taskPath
    [void](Wait-BridgeReady -Layout $layout -TimeoutSeconds 20)
    $cases.Add(@{ case = 'runtime crash bounded exit'; passed = $true; restartLoop = $false })

    # Rollback merges the original bridge-owned block into the current Codex
    # config while retaining an external edit outside the markers.
    [IO.File]::AppendAllText($layout.codexConfigPath, "`r`nexternal_after_upgrade = 'must-survive-rollback'`r`n", [Text.UTF8Encoding]::new($false))
    $rollbackArgs = @('-InstallReceiptPath', $upgrade.ReceiptPath) + (Get-LayoutArguments $layout) + @('-TimeoutSeconds', '30')
    [void](Invoke-ToolProcess -Script (Join-Path $root 'Rollback.ps1') -Arguments $rollbackArgs)
    if ((Get-BridgeFileHash $layout.launcherPath) -cne $legacyLauncherHash -or
        (Get-BridgeFileHash $layout.runtimePath) -cne $legacyRuntimeHash -or
        (Get-Content -LiteralPath (Join-Path $layout.installRoot 'VERSION') -Raw).Trim() -ne '0.2.1') {
        throw 'Explicit rollback did not restore the original installation.'
    }
    if ([string](Read-BridgeJson -Path $layout.configPath).packageVersion -ne '0.2.1') {
        throw 'Explicit rollback did not restore the original bridge packageVersion.'
    }
    $rolledBackTask = Get-BridgeTask $layout
    if ((Get-BridgeTaskActionDefinition -Layout $layout -Task $rolledBackTask).RuntimePath -ine $layout.runtimePath -or
        [string]@($rolledBackTask.Triggers)[0].Delay -ne $legacyTriggerDelay) { throw 'Explicit rollback did not restore task semantics.' }
    $codexAfterRollback = [IO.File]::ReadAllText($layout.codexConfigPath)
    if (-not $codexAfterRollback.Contains("external_after_upgrade = 'must-survive-rollback'") -or
        -not $codexAfterRollback.Contains("[projects.'c:\legacy-fixture']")) {
        throw 'Rollback lost an external Codex config edit or the original managed block.'
    }
    Assert-DecoyAlive $decoy
    $cases.Add(@{ case = 'explicit rollback with managed-block merge'; passed = $true })

    # Startup failure after file/task mutation must automatically restore the
    # original task and version. The tool itself returns failure plus rollback.
    Set-ControlMode startup-fail
    $failedInstall = Invoke-ToolProcess -Script (Join-Path $root 'Install.ps1') -Arguments $candidateArgs -ExpectSuccess:$false -TimeoutSeconds 90
    if ($failedInstall.Error -notlike '*Rollback*') { throw 'Failed startup did not report its rollback result.' }
    if ((Get-Content -LiteralPath (Join-Path $layout.installRoot 'VERSION') -Raw).Trim() -ne '0.2.1') {
        throw 'Failed startup did not automatically restore v0.2.1.'
    }
    [void](Wait-BridgeProcessPair -Layout $layout -TimeoutSeconds 20)
    Set-ControlMode normal
    Assert-DecoyAlive $decoy
    $cases.Add(@{ case = 'startup failure automatic rollback'; passed = $true })

    # Install once more, then prove a concurrent machine-config edit blocks
    # rollback before stop/mutation. Restore the test-owned file and roll back.
    $upgrade2 = (Invoke-ToolProcess -Script (Join-Path $root 'Install.ps1') -Arguments $candidateArgs).Output | ConvertFrom-Json
    $configBeforeConflict = [IO.File]::ReadAllText($layout.configPath)
    $editedConfig = Read-BridgeJson -Path $layout.configPath
    $editedConfig.externalConcurrentEdit = 'do-not-overwrite'
    Write-BridgeAtomicJson -Path $layout.configPath -Value $editedConfig
    $pairBeforeConflict = (Get-BridgeInstalledStatus -Layout $layout).ProcessSet
    $conflictRollbackArgs = @('-InstallReceiptPath', $upgrade2.ReceiptPath) + (Get-LayoutArguments $layout) + @('-TimeoutSeconds', '30')
    [void](Invoke-ToolProcess -Script (Join-Path $root 'Rollback.ps1') -Arguments $conflictRollbackArgs -ExpectSuccess:$false)
    $pairAfterConflict = (Get-BridgeInstalledStatus -Layout $layout).ProcessSet
    if ($pairAfterConflict.Launcher.pid -ne $pairBeforeConflict.Launcher.pid -or
        (Read-BridgeJson -Path $layout.configPath).externalConcurrentEdit -ne 'do-not-overwrite') {
        throw 'Rollback conflict handling stopped the task or overwrote the newer bridge config.'
    }
    Write-BridgeAtomicText -Path $layout.configPath -Text $configBeforeConflict
    [void](Invoke-ToolProcess -Script (Join-Path $root 'Rollback.ps1') -Arguments $conflictRollbackArgs)
    [void](Wait-BridgeProcessPair -Layout $layout -TimeoutSeconds 20)
    $cases.Add(@{ case = 'bridge-config concurrent edit conflict'; passed = $true; overwrite = $false })

    # Fresh install and explicit uninstall/archive use another isolated task.
    Set-ControlMode normal
    $freshArgs = @('-ArtifactDirectory', $artifact, '-AllowedRoots', (Join-Path $testRoot 'fresh-allowed'),
        '-EnableConfigTrust:$false', '-EnableUiAutoApprove:$false') + (Get-LayoutArguments $freshLayout) + @('-TimeoutSeconds', '25')
    $freshInstall = (Invoke-ToolProcess -Script (Join-Path $root 'Install.ps1') -Arguments $freshArgs).Output | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $freshLayout.configPath) -or -not (Get-BridgeInstalledStatus -Layout $freshLayout).Healthy) {
        throw 'Fresh isolated installation did not become ready.'
    }
    $failedUninstallArgs = (Get-LayoutArguments $freshLayout) + @('-RemoveBridgeState', '-RemoveBridgeConfiguration',
        '-RemoveManagedTrustEntries', '-TestFailureStep', 'after-install-remove')
    $failedUninstall = Invoke-ToolProcess -Script (Join-Path $root 'Uninstall.ps1') -Arguments $failedUninstallArgs -ExpectSuccess:$false
    if ($failedUninstall.Error -notlike '*Rollback*' -or -not (Get-BridgeInstalledStatus -Layout $freshLayout).Healthy) {
        throw 'Injected uninstall failure did not automatically restore the fresh installation.'
    }
    $cases.Add(@{ case = 'uninstall failure automatic rollback'; passed = $true })
    $uninstallArgs = (Get-LayoutArguments $freshLayout) + @('-RemoveBridgeState', '-RemoveBridgeConfiguration', '-RemoveManagedTrustEntries')
    $uninstall = (Invoke-ToolProcess -Script (Join-Path $root 'Uninstall.ps1') -Arguments $uninstallArgs).Output | ConvertFrom-Json
    if ((Get-BridgeTask $freshLayout) -or (Test-Path -LiteralPath $freshLayout.installRoot) -or
        -not (Test-Path -LiteralPath $uninstall.BackupDirectory)) { throw 'Fresh uninstall/archive did not remove the isolated task/install or retain its backup.' }
    $cases.Add(@{ case = 'fresh install and uninstall archive'; passed = $true; backup = $uninstall.BackupDirectory })

    $productionAfter = Get-ProductionFingerprint
    Write-BridgeAtomicJson -Path $productionAfterPath -Value $productionAfter
    if ((Get-TextSha256 ($productionBefore | ConvertTo-Json -Depth 20 -Compress)) -cne
        (Get-TextSha256 ($productionAfter | ConvertTo-Json -Depth 20 -Compress))) {
        throw 'The production bridge task/process/file identity changed during isolated maintenance tests.'
    }
    Assert-DecoyAlive $decoy
    $result = [ordered]@{
        passed = $true
        caseCount = $cases.Count
        cases = $cases.ToArray()
        productionUnchanged = $true
        productionTaskName = 'Codex-Worktree-Trust-Bridge'
        temporaryTasksRemovedByFinally = $true
        releasePublished = $false
        productionDeploymentPerformed = $false
        evidenceDirectory = $testRoot
    }
    Write-BridgeAtomicJson -Path (Join-Path $evidence 'receipt.json') -Value $result
    $result | ConvertTo-Json -Depth 20
}
finally {
    foreach ($value in @($freshLayout, $layout)) { Remove-TestTask $value }
    if ($duplicate) {
        try { if (-not $duplicate.HasExited) { $duplicate.Kill($true); [void]$duplicate.WaitForExit(10000) } } catch { }
        $duplicate.Dispose()
    }
    if ($decoy) {
        try { if (-not $decoy.HasExited) { $decoy.Kill($true); [void]$decoy.WaitForExit(10000) } } catch { }
        $decoy.Dispose()
    }
    $cleanup = [ordered]@{
        observedAt = [DateTimeOffset]::Now.ToString('o')
        primaryTaskAbsent = -not [bool](Get-BridgeTask $layout)
        freshTaskAbsent = -not [bool](Get-BridgeTask $freshLayout)
        productionFingerprintPath = $productionAfterPath
    }
    Write-BridgeAtomicJson -Path (Join-Path $evidence 'cleanup.json') -Value $cleanup
}
