[CmdletBinding()]
param(
    [string[]]$AllowedRoots = @('C:\PROJECT', 'E:\PROJECT'),
    [ValidateSet('git-only', 'all-directories')]
    [string]$TrustMode = 'git-only',
    [ValidateSet('leave-open', 'cancel')]
    [string]$DeniedDialogAction = 'leave-open',
    [ValidateRange(0, 60)]
    [int]$DeniedDialogGraceSeconds = 3,
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'This installer supports Windows only.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git for Windows is required.' }
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$sourceRuntime = Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.ps1'
$sourceLauncher = Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Launcher.cs'
if (-not (Test-Path -LiteralPath $sourceRuntime -PathType Leaf)) { throw "Runtime is missing: $sourceRuntime" }
if (-not (Test-Path -LiteralPath $sourceLauncher -PathType Leaf)) { throw "Launcher source is missing: $sourceLauncher" }

$codexHome = Join-Path $env:USERPROFILE '.codex'
$installRoot = Join-Path $codexHome 'tools\codex-worktree-trust-bridge'
$runtimePath = Join-Path $installRoot 'CodexWorktreeTrustBridge.ps1'
$launcherPath = Join-Path $installRoot 'CodexWorktreeTrustBridge.Launcher.exe'
$versionPath = Join-Path $installRoot 'VERSION'
$configPath = Join-Path $codexHome 'codex-worktree-trust-bridge.json'

# An upgrade without explicit policy arguments keeps the machine's existing
# roots and behavior. Explicit installer arguments remain authoritative.
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $existingConfiguration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($existingConfiguration.schema -eq 'codex-worktree-trust-bridge.config' -and
            [int]$existingConfiguration.version -eq 1) {
            if (-not $PSBoundParameters.ContainsKey('AllowedRoots')) {
                $AllowedRoots = @($existingConfiguration.allowedRoots)
            }
            if (-not $PSBoundParameters.ContainsKey('TrustMode') -and
                $existingConfiguration.PSObject.Properties['trustMode']) {
                $TrustMode = [string]$existingConfiguration.trustMode
            }
            if (-not $PSBoundParameters.ContainsKey('DeniedDialogAction') -and
                $existingConfiguration.PSObject.Properties['deniedDialogAction']) {
                $DeniedDialogAction = [string]$existingConfiguration.deniedDialogAction
            }
            if (-not $PSBoundParameters.ContainsKey('DeniedDialogGraceSeconds') -and
                $existingConfiguration.PSObject.Properties['deniedDialogGraceSeconds']) {
                $DeniedDialogGraceSeconds = [int]$existingConfiguration.deniedDialogGraceSeconds
            }
        }
    }
    catch {
        throw "Existing configuration could not be read safely: $configPath. $($_.Exception.Message)"
    }
}

# Compile before touching the installed task so a missing/broken compiler cannot
# take a healthy existing installation offline.
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compilerPath = $compilerCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $compilerPath) {
    throw 'The Windows .NET Framework C# compiler is required to build the no-console launcher.'
}

$temporaryLauncher = Join-Path $env:TEMP ('CodexWorktreeTrustBridge.Launcher.' + [guid]::NewGuid().ToString('N') + '.exe')
& $compilerPath /nologo /target:winexe /platform:anycpu /optimize+ ("/out:$temporaryLauncher") $sourceLauncher
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryLauncher -PathType Leaf)) {
    Remove-Item -LiteralPath $temporaryLauncher -Force -ErrorAction SilentlyContinue
    throw "No-console launcher compilation failed with exit code $LASTEXITCODE."
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

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
    'CodexWorktreeTrustBridge.ps1',
    'CodexWorktreeTrustBridge.Launcher.exe'
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
try {
    Move-Item -LiteralPath $temporaryLauncher -Destination $launcherPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryLauncher -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryLauncher -Force -ErrorAction SilentlyContinue
    }
}

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
    trustMode = $TrustMode
    deniedDialogAction = $DeniedDialogAction
    deniedDialogGraceSeconds = $DeniedDialogGraceSeconds
    enableConfigTrust = $true
    enableUiAutoApprove = $true
    pruneMissingManagedEntries = $true
}
[IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

$launcherArguments = '"{0}" "{1}" "{2}"' -f $pwsh, $runtimePath, $configPath
$action = New-ScheduledTaskAction -Execute $launcherPath -Argument $launcherArguments -WorkingDirectory $installRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
$trigger.Delay = 'PT10S'
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Portable Codex folder trust config sync, guarded UI auto-approval, and denied-dialog handling bridge.' -Force | Out-Null
$installStartedAt = [DateTimeOffset]::Now
Start-ScheduledTask -TaskName $TaskName

$deadline = (Get-Date).AddSeconds(30)
$launcherProcess = $null
$process = $null
do {
    Start-Sleep -Milliseconds 500
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $launcherProcess = $allProcesses |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $launcherPath } |
        Select-Object -First 1
    $process = $allProcesses |
        Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath -ieq $pwsh -and
            $_.CommandLine -and $_.CommandLine -like "*$runtimePath*"
        } |
        Select-Object -First 1
} while ((-not $launcherProcess -or -not $process) -and (Get-Date) -lt $deadline)
if (-not $launcherProcess -or -not $process) {
    throw 'The bridge task started but its launcher/runtime process pair did not become visible.'
}
if ([int]$process.ParentProcessId -ne [int]$launcherProcess.ProcessId) {
    throw 'The bridge runtime is not owned by the no-console launcher.'
}

$bridgeLogPath = Join-Path $codexHome 'log\codex-worktree-trust-bridge.log'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$readyDeadline = (Get-Date).AddSeconds(60)
$runtimeReady = $false
do {
    Start-Sleep -Milliseconds 500
    $launcherProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($launcherProcess.ProcessId)" -ErrorAction SilentlyContinue
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ProcessId)" -ErrorAction SilentlyContinue
    if (-not $launcherProcess -or -not $process) { break }
    $hasStartLog = $false
    $hasReconciledLog = $false
    if (Test-Path -LiteralPath $bridgeLogPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $bridgeLogPath -Tail 500 -ErrorAction SilentlyContinue)) {
            try {
                $entry = $line | ConvertFrom-Json
                $entryTime = [DateTimeOffset]::Parse([string]$entry.timestamp)
                if ($entry.event -eq 'STARTED' -and
                    [int]$entry.data.pid -eq [int]$process.ProcessId -and
                    [int]$entry.data.launcherPid -eq [int]$launcherProcess.ProcessId -and
                    $entryTime -ge $installStartedAt.AddSeconds(-2) -and
                    [string]$entry.data.trustMode -eq $TrustMode -and
                    [string]$entry.data.deniedDialogAction -eq $DeniedDialogAction -and
                    [int]$entry.data.deniedDialogGraceSeconds -eq $DeniedDialogGraceSeconds) {
                    $hasStartLog = $true
                }
                if ($entry.event -eq 'RECONCILED' -and
                    [int]$entry.data.pid -eq [int]$process.ProcessId -and
                    [int]$entry.data.launcherPid -eq [int]$launcherProcess.ProcessId -and
                    $entryTime -ge $installStartedAt.AddSeconds(-2) -and
                    [string]$entry.data.trustMode -eq $TrustMode) {
                    $hasReconciledLog = $true
                }
            }
            catch {}
        }
    }
    $hasManagedBlock = (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) -and
        ([IO.File]::ReadAllText($codexConfigPath).Contains('# BEGIN CODEX WORKTREE TRUST BRIDGE'))
    $runtimeReady = $hasStartLog -and $hasReconciledLog -and $hasManagedBlock
} while (-not $runtimeReady -and (Get-Date) -lt $readyDeadline)
if (-not $runtimeReady) { throw 'The bridge process started but did not publish matching STARTED, RECONCILED, and config readiness evidence.' }

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
    LauncherPath = $launcherPath
    ConfigPath = $configPath
    AllowedRoots = $normalizedRoots
    TrustMode = $TrustMode
    DeniedDialogAction = $DeniedDialogAction
    DeniedDialogGraceSeconds = $DeniedDialogGraceSeconds
    TaskName = $TaskName
    TaskState = [string]$task.State
    LastTaskResult = $info.LastTaskResult
    ProcessId = $process.ProcessId
    LauncherProcessId = $launcherProcess.ProcessId
    LegacyItemsRemoved = @($legacyItemsRemoved)
} | ConvertTo-Json -Depth 5
