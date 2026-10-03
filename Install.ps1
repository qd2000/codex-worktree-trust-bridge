[CmdletBinding()]
param(
    [string[]]$AllowedRoots = @('C:\PROJECT', 'E:\PROJECT'),
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'This installer supports Windows only.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required.' }
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$sourceRuntime = Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.ps1'
if (-not (Test-Path -LiteralPath $sourceRuntime -PathType Leaf)) { throw "Runtime is missing: $sourceRuntime" }

$codexHome = Join-Path $env:USERPROFILE '.codex'
$installRoot = Join-Path $codexHome 'tools\codex-worktree-trust-bridge'
$runtimePath = Join-Path $installRoot 'CodexWorktreeTrustBridge.ps1'
$versionPath = Join-Path $installRoot 'VERSION'
$configPath = Join-Path $codexHome 'codex-worktree-trust-bridge.json'

$legacyTaskNames = @(
    'Codex-Worktree-Trust-Sync',
    'Codex-Worktree-Trust-UI-AutoApprove',
    'Codex-Worktree-Trust-UI-AutoApprove-V2'
)
foreach ($legacyTaskName in $legacyTaskNames) {
    $legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    if (-not $legacyTask) { continue }
    if ($legacyTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

$oldRuntimePatterns = @(
    'sync-worktree-trust.ps1',
    'codex-trust-ui-autoapprove.ps1',
    'codex-trust-ui-autoapprove.mjs',
    'CodexWorktreeTrustBridge.ps1'
)
$shutdownDeadline = (Get-Date).AddSeconds(15)
do {
    $oldProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $commandLine = $_.CommandLine
        $_.ProcessId -ne $PID -and $commandLine -and
        ($oldRuntimePatterns | Where-Object { $commandLine -like "*$_*" })
    })
    if (-not $oldProcesses.Count) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $shutdownDeadline)

foreach ($oldProcess in $oldProcesses) {
    Stop-Process -Id $oldProcess.ProcessId -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Copy-Item -LiteralPath $sourceRuntime -Destination $runtimePath -Force
[IO.File]::WriteAllText($versionPath, $version + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

$expandedRoots = @($AllowedRoots | ForEach-Object { [string]$_ -split ',' })
$normalizedRoots = @($expandedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
    $rootText = $_.Trim()
    while ($rootText.Length -ge 2 -and
        (($rootText.StartsWith("'") -and $rootText.EndsWith("'")) -or
         ($rootText.StartsWith('"') -and $rootText.EndsWith('"')))) {
        $rootText = $rootText.Substring(1, $rootText.Length - 2).Trim()
    }
    [IO.Path]::GetFullPath($rootText).TrimEnd('\', '/')
} | Sort-Object -Unique)

$configuration = [ordered]@{
    schema = 'codex-worktree-trust-bridge.config'
    version = 1
    packageVersion = $version
    allowedRoots = $normalizedRoots
    uiPollIntervalMs = 750
    reconcileIntervalSeconds = 60
    discoveryDepth = 4
    enableConfigTrust = $true
    enableUiAutoApprove = $true
    pruneMissingManagedEntries = $true
}
[IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$arguments = @(
    '-STA', '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runtimePath),
    '-ConfigPath', ('"{0}"' -f $configPath)
) -join ' '
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Portable Codex worktree trust config sync and UI auto-approval bridge.' -Force | Out-Null
$installStartedAt = [DateTimeOffset]::Now
Start-ScheduledTask -TaskName $TaskName

$deadline = (Get-Date).AddSeconds(30)
$process = $null
do {
    Start-Sleep -Milliseconds 500
    $process = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$runtimePath*" } |
        Select-Object -First 1
} while (-not $process -and (Get-Date) -lt $deadline)
if (-not $process) { throw 'The bridge task started but no runtime process became visible.' }

$bridgeLogPath = Join-Path $codexHome 'log\codex-worktree-trust-bridge.log'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$readyDeadline = (Get-Date).AddSeconds(60)
$runtimeReady = $false
do {
    Start-Sleep -Milliseconds 500
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ProcessId)" -ErrorAction SilentlyContinue
    if (-not $process) { break }
    $hasStartLog = $false
    if (Test-Path -LiteralPath $bridgeLogPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $bridgeLogPath -Tail 30 -ErrorAction SilentlyContinue)) {
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.event -eq 'STARTED' -and
                    [int]$entry.data.pid -eq [int]$process.ProcessId -and
                    [DateTimeOffset]::Parse([string]$entry.timestamp) -ge $installStartedAt.AddSeconds(-2)) {
                    $hasStartLog = $true
                    break
                }
            }
            catch {}
        }
    }
    $hasManagedBlock = (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) -and
        ([IO.File]::ReadAllText($codexConfigPath).Contains('# BEGIN CODEX WORKTREE TRUST BRIDGE'))
    $runtimeReady = $hasStartLog -and $hasManagedBlock
} while (-not $runtimeReady -and (Get-Date) -lt $readyDeadline)
if (-not $runtimeReady) { throw 'The bridge process started but did not publish its log/config readiness evidence.' }

$legacyItemsRemoved = [Collections.Generic.List[string]]::new()
$legacyFiles = @(
    (Join-Path $codexHome 'scripts\sync-worktree-trust.ps1'),
    (Join-Path $codexHome 'scripts\codex-trust-ui-autoapprove.ps1'),
    (Join-Path $codexHome 'scripts\codex-trust-ui-autoapprove.mjs'),
    (Join-Path $codexHome 'scripts\start-codex-trust-ui-autoapprove.ps1'),
    (Join-Path $codexHome 'worktree-trust-ui-allowlist.json')
)
foreach ($legacyFile in $legacyFiles) {
    if (Test-Path -LiteralPath $legacyFile -PathType Leaf) {
        Remove-Item -LiteralPath $legacyFile -Force
        [void]$legacyItemsRemoved.Add($legacyFile)
    }
}

$legacyLogPaths = @(
    (Join-Path $codexHome 'log\worktree-trust-sync.log'),
    (Join-Path $codexHome 'log\worktree-trust-ui-autoapprove.log')
)
$legacyLogPaths += @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'log') -Filter 'worktree-trust-ui-autoapprove.pre-final.*.log' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
foreach ($legacyLog in $legacyLogPaths | Sort-Object -Unique) {
    if (Test-Path -LiteralPath $legacyLog -PathType Leaf) {
        Remove-Item -LiteralPath $legacyLog -Force
        [void]$legacyItemsRemoved.Add($legacyLog)
    }
}

$legacyBackupDirectory = Join-Path $codexHome 'trust-backups'
if (Test-Path -LiteralPath $legacyBackupDirectory -PathType Container) {
    Remove-Item -LiteralPath $legacyBackupDirectory -Recurse -Force
    [void]$legacyItemsRemoved.Add($legacyBackupDirectory)
}

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
    Installed = $true
    PackageVersion = $version
    InstallRoot = $installRoot
    RuntimePath = $runtimePath
    ConfigPath = $configPath
    AllowedRoots = $normalizedRoots
    TaskName = $TaskName
    TaskState = [string]$task.State
    LastTaskResult = $info.LastTaskResult
    ProcessId = $process.ProcessId
    LegacyItemsRemoved = @($legacyItemsRemoved)
} | ConvertTo-Json -Depth 5
