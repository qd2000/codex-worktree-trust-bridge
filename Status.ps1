[CmdletBinding()]
param([string]$TaskName = 'Codex-Worktree-Trust-Bridge')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHome = Join-Path $env:USERPROFILE '.codex'
$installRoot = Join-Path $codexHome 'tools\codex-worktree-trust-bridge'
$runtimePath = Join-Path $installRoot 'CodexWorktreeTrustBridge.ps1'
$configPath = Join-Path $codexHome 'codex-worktree-trust-bridge.json'
$statePath = Join-Path $codexHome 'state\codex-worktree-trust-bridge.json'
$logPath = Join-Path $codexHome 'log\codex-worktree-trust-bridge.log'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $TaskName } else { $null }
$process = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$runtimePath*" } |
    Select-Object -First 1
$config = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } else { $null }
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }

$result = [pscustomobject]@{
    Healthy = [bool]($task -and $task.State -eq 'Running' -and $process)
    Task = if ($task) { [pscustomobject]@{
        Name = $task.TaskName
        State = [string]$task.State
        LastRunTime = $taskInfo.LastRunTime
        LastTaskResult = $taskInfo.LastTaskResult
        Action = @($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" })
    } } else { $null }
    Process = if ($process) { [pscustomobject]@{
        ProcessId = $process.ProcessId
        SessionId = $process.SessionId
        CreationDate = $process.CreationDate
        CommandLine = $process.CommandLine
    } } else { $null }
    PackageVersion = if (Test-Path -LiteralPath (Join-Path $installRoot 'VERSION')) { (Get-Content (Join-Path $installRoot 'VERSION') -Raw).Trim() } else { $null }
    AllowedRoots = if ($config) { @($config.allowedRoots) } else { @() }
    ManagedPathCount = if ($state) { @($state.managedPaths).Count } else { 0 }
    RuntimeHash = if (Test-Path -LiteralPath $runtimePath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $runtimePath).Hash } else { $null }
    RecentLog = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath -Tail 12) } else { @() }
}
$result | ConvertTo-Json -Depth 8
if (-not $result.Healthy) { exit 1 }
