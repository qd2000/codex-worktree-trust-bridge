[CmdletBinding()]
param(
    [ValidateRange(1, 20)]
    [int]$Iterations = 5,
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120,
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHome = Join-Path $env:USERPROFILE '.codex'
$installRoot = Join-Path $codexHome 'tools\codex-worktree-trust-bridge'
$launcherPath = Join-Path $installRoot 'CodexWorktreeTrustBridge.Launcher.exe'
$runtimePath = Join-Path $installRoot 'CodexWorktreeTrustBridge.ps1'
$logPath = Join-Path $codexHome 'log\codex-worktree-trust-bridge.log'

function Get-BridgeProcesses {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        Launchers = @($all | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath -ieq $launcherPath
        })
        Runtimes = @($all | Where-Object {
            $_.Name -ieq 'pwsh.exe' -and $_.CommandLine -and $_.CommandLine -like "*$runtimePath*"
        })
    }
}

function Stop-BridgeProcesses {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(8)
    do {
        $processes = Get-BridgeProcesses
        if (-not $processes.Launchers.Count -and -not $processes.Runtimes.Count) { return }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    foreach ($process in @($processes.Runtimes) + @($processes.Launchers)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Get-MatchingLogEvidence {
    param(
        [Parameter(Mandatory = $true)][int]$RuntimePid,
        [Parameter(Mandatory = $true)][int]$LauncherPid,
        [Parameter(Mandatory = $true)][DateTimeOffset]$NotBefore
    )
    $started = $false
    $reconciled = $false
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        return [pscustomobject]@{ Started = $false; Reconciled = $false }
    }
    foreach ($line in @(Get-Content -LiteralPath $logPath -Tail 1500 -ErrorAction SilentlyContinue)) {
        try {
            $entry = $line | ConvertFrom-Json
            $timestamp = [DateTimeOffset]::Parse([string]$entry.timestamp)
            if ($timestamp -lt $NotBefore.AddSeconds(-2)) { continue }
            if ($entry.event -eq 'STARTED' -and
                [int]$entry.data.pid -eq $RuntimePid -and
                [int]$entry.data.launcherPid -eq $LauncherPid) {
                $started = $true
            }
            if ($entry.event -eq 'RECONCILED' -and
                [int]$entry.data.pid -eq $RuntimePid -and
                [int]$entry.data.launcherPid -eq $LauncherPid) {
                $reconciled = $true
            }
        }
        catch {}
    }
    return [pscustomobject]@{ Started = $started; Reconciled = $reconciled }
}

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "Installed launcher is missing: $launcherPath"
}
if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
    throw "Installed runtime is missing: $runtimePath"
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if ($task.Actions.Count -ne 1 -or [IO.Path]::GetFullPath([string]$task.Actions[0].Execute) -ine [IO.Path]::GetFullPath($launcherPath)) {
    throw 'Scheduled Task does not execute the no-console launcher.'
}
if ([string]$task.Principal.LogonType -ne 'Interactive') {
    throw "Scheduled Task logon type is $($task.Principal.LogonType), expected Interactive."
}

$results = [Collections.Generic.List[object]]::new()
try {
    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        Stop-BridgeProcesses
        $startedAt = [DateTimeOffset]::Now
        Start-ScheduledTask -TaskName $TaskName

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $ready = $false
        do {
            Start-Sleep -Milliseconds 250
            $processes = Get-BridgeProcesses
            if ($processes.Launchers.Count -eq 1 -and $processes.Runtimes.Count -eq 1) {
                $launcher = $processes.Launchers[0]
                $runtime = $processes.Runtimes[0]
                if ([int]$runtime.ParentProcessId -eq [int]$launcher.ProcessId) {
                    $evidence = Get-MatchingLogEvidence `
                        -RuntimePid ([int]$runtime.ProcessId) `
                        -LauncherPid ([int]$launcher.ProcessId) `
                        -NotBefore $startedAt
                    $ready = $evidence.Started -and $evidence.Reconciled
                }
            }
        } while (-not $ready -and (Get-Date) -lt $deadline)

        if (-not $ready) {
            throw "Iteration $iteration did not reach a matching STARTED/RECONCILED process pair."
        }

        $launcherWindow = [int64](Get-Process -Id $launcher.ProcessId -ErrorAction Stop).MainWindowHandle
        $runtimeWindow = [int64](Get-Process -Id $runtime.ProcessId -ErrorAction Stop).MainWindowHandle
        if ($launcherWindow -ne 0 -or $runtimeWindow -ne 0) {
            throw "Iteration $iteration exposed a visible main window (launcher=$launcherWindow, runtime=$runtimeWindow)."
        }

        [void]$results.Add([pscustomobject]@{
            Iteration = $iteration
            LauncherProcessId = [int]$launcher.ProcessId
            RuntimeProcessId = [int]$runtime.ProcessId
            LauncherMainWindowHandle = $launcherWindow
            RuntimeMainWindowHandle = $runtimeWindow
            Started = $evidence.Started
            Reconciled = $evidence.Reconciled
        })
    }

    [pscustomobject]@{
        Passed = $true
        Iterations = $Iterations
        TaskName = $TaskName
        TaskAction = [string]$task.Actions[0].Execute
        TriggerDelay = @($task.Triggers | ForEach-Object { $_.Delay })
        Results = @($results)
    } | ConvertTo-Json -Depth 8
}
finally {
    # Leave the bridge in its normal running state after the test.
    $processes = Get-BridgeProcesses
    if ($processes.Launchers.Count -ne 1 -or $processes.Runtimes.Count -ne 1) {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}
