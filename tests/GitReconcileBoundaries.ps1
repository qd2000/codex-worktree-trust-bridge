[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $root '.artifacts\bin\CodexWorktreeTrustBridge.ps1'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '64-bit .NET Framework compiler is required.' }
$testRoot = Join-Path $root ('.artifacts\git-reconcile-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$profile = Join-Path $testRoot 'profile'
$codexHome = Join-Path $profile '.codex'
$fakeBin = Join-Path $testRoot 'fake-bin'
$allowedRoot = Join-Path $testRoot 'allowed'
$repo = Join-Path $allowedRoot 'repo with spaces'
$staleRepo = Join-Path $allowedRoot 'stale backup marker'
$treeRoot = Join-Path $testRoot 'directory-budget-root'
$configPath = Join-Path $profile 'bridge.json'
$controlPath = Join-Path $testRoot 'mode.txt'
$logPath = Join-Path $testRoot 'git-processes.log'
$samplesPath = Join-Path $testRoot 'resources.jsonl'
$adapterDirectory = Join-Path $testRoot 'candidate'
$adapterPath = Join-Path $adapterDirectory 'GitReconcileAdapter.ps1'
$fakeGit = Join-Path $fakeBin 'git.exe'
$oldProfile = $env:USERPROFILE
$oldPath = $env:PATH
$oldControl = $env:CODEX_GIT_BOUNDARY_CONTROL
$oldLog = $env:CODEX_GIT_BOUNDARY_LOG
$oldRepo = $env:CODEX_GIT_BOUNDARY_REPO
$oldStale = $env:CODEX_GIT_BOUNDARY_STALE
$oldSamples = $env:CODEX_GIT_RESOURCE_SAMPLES
$oldRunId = $env:CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID

function Write-Mode([string]$Mode) {
    [IO.File]::WriteAllText($controlPath, $Mode, [Text.UTF8Encoding]::new($false))
}

try {
    foreach ($directory in @($codexHome, $fakeBin, $allowedRoot, $repo, (Join-Path $repo '.git'), $staleRepo, (Join-Path $staleRepo '.git'), $treeRoot, $adapterDirectory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $root '.artifacts\bin\*') -Destination $adapterDirectory
    foreach ($index in 1..4) {
        $worktree = Join-Path $repo "wt$index"
        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $worktree '.git'), "gitdir: controlled`r`n")
    }
    & $compiler /nologo /target:exe /platform:anycpu /optimize+ "/out:$fakeGit" `
        (Join-Path $PSScriptRoot 'fixtures\BoundedFakeGit.cs')
    if ($LASTEXITCODE) { throw "Controlled Git fixture compilation failed: $LASTEXITCODE" }

    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'),
        "external_setting = 'preserve'`r`n`r`n# BEGIN CODEX WORKTREE TRUST BRIDGE`r`n# END CODEX WORKTREE TRUST BRIDGE`r`n",
        [Text.UTF8Encoding]::new($false))
    $configuration = [ordered]@{
        schema = 'codex-worktree-trust-bridge.config'; version = 1
        allowedRoots = @($allowedRoot, $treeRoot); uiPollIntervalMs = 750
        reconcileIntervalSeconds = 60; discoveryDepth = 2; reconcileTimeoutSeconds = 10
        discoveryDirectoryLimit = 100; discoveryRepositoryLimit = 2; discoveryWorktreeLimit = 4
        # Keep the fixture timeout well below production's 10-second default,
        # but leave scheduler headroom for normal short-lived fake Git commands
        # when the complete suite is under load. The controlled hang still
        # exceeds this bound and must fail closed.
        gitCommandLimitPerReconcile = 64; gitCommandTimeoutSeconds = 3; gitCleanupTimeoutSeconds = 3
        gitMaximumStandardOutputBytes = 4096; gitMaximumStandardErrorBytes = 4096
        gitJobMemoryMiB = 64; gitProcessLimit = 4
        trustMode = 'git-only'; deniedDialogAction = 'leave-open'; deniedDialogGraceSeconds = 3
        enableConfigTrust = $true; enableUiAutoApprove = $false; pruneMissingManagedEntries = $true
    }
    [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Mode normal

    $source = [IO.File]::ReadAllText($runtime).Replace("`r`n", "`n")
    $boundary = $source.IndexOf("`ntry {`n    try { `$HasInstanceMutex", [StringComparison]::Ordinal)
    if ($boundary -lt 0) { throw 'Runtime main-loop boundary was not found.' }
    $prefix = $source.Substring(0, $boundary)
    $body = @'
$HasInstanceMutex = $InstanceMutex.WaitOne(0)
if (-not $HasInstanceMutex) { throw 'Isolated reconcile mutex is unavailable.' }
$caseResults = [Collections.Generic.List[object]]::new()
$resourceRows = [Collections.Generic.List[object]]::new()
function Set-TestMode([string]$Mode) {
    [IO.File]::WriteAllText($env:CODEX_GIT_BOUNDARY_CONTROL, $Mode, [Text.UTF8Encoding]::new($false))
}
function Get-HashOrNull([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}
function Assert-NoFixtureProcess {
    if (-not (Test-Path -LiteralPath $env:CODEX_GIT_BOUNDARY_LOG)) { return }
    foreach ($line in @(Get-Content -LiteralPath $env:CODEX_GIT_BOUNDARY_LOG)) {
        $parts = $line -split '\|', 5
        foreach ($pair in @(@([int]$parts[0], [long]$parts[1]), @([int]$parts[2], [long]$parts[3]))) {
            if ($pair[0] -le 0) { continue }
            $process = $null
            try {
                $process = [Diagnostics.Process]::GetProcessById($pair[0])
                [void]$process.Handle
                if ($process.HasExited) { continue }
                $start = $process.StartTime
                if ($null -ne $start -and $start.ToUniversalTime().ToFileTimeUtc() -eq $pair[1]) {
                    throw "Controlled Git process remains alive: $($pair[0])."
                }
            }
            catch [ArgumentException] { }
            catch [InvalidOperationException] { }
            catch [ComponentModel.Win32Exception] { }
            finally { if ($null -ne $process) { $process.Dispose() } }
        }
    }
}
function Invoke-FailureCase([string]$Mode, [string]$ExpectedKind, [scriptblock]$BeforeRecovery) {
    $configHash = Get-HashOrNull $CodexConfigPath
    $stateHash = Get-HashOrNull $StatePath
    $beforeManaged = @($ManagedPaths | Sort-Object) -join "`n"
    Set-TestMode $Mode
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $failed = $false
    $message = $null
    try { Invoke-Reconcile } catch { $failed = $true; $message = $_.Exception.Message }
    if (-not $failed) { throw "Expected reconcile failure for $Mode." }
    if ($LastReconcileSucceeded) { throw "Failed reconcile $Mode reported success." }
    if ((Get-HashOrNull $CodexConfigPath) -cne $configHash -or (Get-HashOrNull $StatePath) -cne $stateHash -or
        (@($ManagedPaths | Sort-Object) -join "`n") -cne $beforeManaged) {
        throw "Failed reconcile $Mode changed managed state or config."
    }
    Write-BridgeHealth -Force
    $health = Get-Content -LiteralPath "$ConfigPath.health.json" -Raw | ConvertFrom-Json
    if ($health.healthy -or $health.lastReconcileSucceeded) { throw "Failed reconcile $Mode was falsely healthy." }
    if ($ExpectedKind -and [string]$health.git.lastFailureKind -ne $ExpectedKind) {
        throw "Failure kind for $Mode was '$($health.git.lastFailureKind)', expected '$ExpectedKind'."
    }
    Assert-NoFixtureProcess
    $caseResults.Add(@{ case = $Mode; failedClosed = $true; durationMs = $clock.ElapsedMilliseconds; error = $message })
    if ($BeforeRecovery) { & $BeforeRecovery }
    Set-TestMode normal
    Invoke-Reconcile
    Write-BridgeHealth -Force
    $recovered = Get-Content -LiteralPath "$ConfigPath.health.json" -Raw | ConvertFrom-Json
    if (-not $recovered.healthy -or -not $recovered.git.healthy) { throw "Healthy reconcile did not recover after $Mode." }
}
function Get-Slope([object[]]$Rows, [string]$Property) {
    $meanX = ($Rows | Measure-Object -Property elapsedSeconds -Average).Average
    $meanY = ($Rows | Measure-Object -Property $Property -Average).Average
    $variance = 0.0; $covariance = 0.0
    foreach ($row in $Rows) {
        $x = [double]$row.elapsedSeconds - $meanX
        $variance += $x * $x
        $covariance += $x * ([double]$row.$Property - $meanY)
    }
    if ($variance -eq 0) { return 0.0 }
    return $covariance / $variance * 60.0
}
try {
    Initialize-UiSupervisor
    Invoke-Reconcile
    Write-BridgeHealth -Force
    $baselineHealth = Get-Content -LiteralPath "$ConfigPath.health.json" -Raw | ConvertFrom-Json
    if (-not $baselineHealth.healthy -or $ManagedPaths.Count -ne 1) { throw 'Baseline controlled reconcile was not healthy.' }
    $staleEvents = @(Get-Content -LiteralPath $LogPath | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_.event -eq 'GIT_ROOT_SKIPPED' -and [string]$_.data.path -ieq $env:CODEX_GIT_BOUNDARY_STALE })
    if ($staleEvents.Count -ne 1) { throw 'Stale .git marker was not isolated exactly once.' }
    $caseResults.Add(@{ case = 'normal discovery'; passed = $true; managedCount = $ManagedPaths.Count })
    $caseResults.Add(@{ case = 'stale .git marker skipped'; passed = $true; path = $env:CODEX_GIT_BOUNDARY_STALE })

    Invoke-FailureCase hang timeout
    Invoke-FailureCase stdout-overflow output-limit
    Invoke-FailureCase stderr-overflow output-limit
    Invoke-FailureCase exit-42 exit
    Invoke-FailureCase invalid-utf8 invalid-utf8
    Invoke-FailureCase malformed-common $null

    $script:GitCommandLimitPerReconcile = 64
    $script:DiscoveryWorktreeLimit = 4
    $script:DiscoveryRepositoryLimit = 2
    Invoke-FailureCase worktree-overflow $null
    $script:DiscoveryWorktreeLimit = 32
    $script:GitCommandLimitPerReconcile = 8
    Invoke-FailureCase command-overflow $null
    $script:GitCommandLimitPerReconcile = 64

    $secondRepo = Join-Path (Split-Path -Parent $env:CODEX_GIT_BOUNDARY_REPO) 'second-repo'
    New-Item -ItemType Directory -Path (Join-Path $secondRepo '.git') -Force | Out-Null
    Invoke-FailureCase normal $null { Remove-Item -LiteralPath $secondRepo -Recurse -Force }

    $tree = [string]$AllowedRoots[1]
    foreach ($index in 1..110) { New-Item -ItemType Directory -Path (Join-Path $tree "d$index") -Force | Out-Null }
    Invoke-FailureCase normal $null { Get-ChildItem -LiteralPath $tree -Directory | Remove-Item -Recurse -Force }

    Set-TestMode normal
    foreach ($index in 1..10) { Invoke-Reconcile }
    $measurement = [Diagnostics.Stopwatch]::StartNew()
    foreach ($index in 1..100) {
        Invoke-Reconcile
        $self = [Diagnostics.Process]::GetCurrentProcess()
        try {
            $self.Refresh()
            $row = [pscustomobject]@{
                elapsedSeconds = $measurement.Elapsed.TotalSeconds
                privateBytes = $self.PrivateMemorySize64
                workingSetBytes = $self.WorkingSet64
                handles = $self.HandleCount
                managedHeapBytes = [GC]::GetTotalMemory($false)
                gitCommands = $GitMetrics.commandCount
                reconciles = $ReconcileCount
            }
            $resourceRows.Add($row)
            Add-Content -LiteralPath $env:CODEX_GIT_RESOURCE_SAMPLES -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
        }
        finally { $self.Dispose() }
        Start-Sleep -Milliseconds 250
    }
    Assert-NoFixtureProcess
    if ($resourceRows.Count -lt 30) { throw 'Insufficient reconcile resource samples.' }
    $memorySlopeBytesPerMinute = Get-Slope $resourceRows.ToArray() privateBytes
    $handleSlopePerMinute = Get-Slope $resourceRows.ToArray() handles
    $privatePeak = ($resourceRows | Measure-Object -Property privateBytes -Maximum).Maximum
    $handlesPeak = ($resourceRows | Measure-Object -Property handles -Maximum).Maximum
    if ($privatePeak -gt 256MB -or $handlesPeak -gt 1000 -or
        $memorySlopeBytesPerMinute / 1MB -gt 0.25 -or $handleSlopePerMinute -gt 0.2) {
        throw "Reconcile resource gate failed: peak=$privatePeak memorySlopeMiBMin=$($memorySlopeBytesPerMinute / 1MB) handlesPeak=$handlesPeak handleSlope=$handleSlopePerMinute"
    }
    Write-BridgeHealth -Force
    $finalHealth = Get-Content -LiteralPath "$ConfigPath.health.json" -Raw | ConvertFrom-Json
    if (-not $finalHealth.healthy -or $finalHealth.git.activeCount -ne 0 -or -not $finalHealth.git.lastCleanupVerified) {
        throw 'Final Git/reconcile health is not clean.'
    }
    $caseResults.Add(@{ case = '100 repeated reconciles'; passed = $true; samples = $resourceRows.Count
        privatePeakBytes = $privatePeak; handlesPeak = $handlesPeak
        privateSlopeMiBPerMinute = $memorySlopeBytesPerMinute / 1MB; handlesSlopePerMinute = $handleSlopePerMinute })
    [pscustomobject]@{
        passed = $true; cases = $caseResults.ToArray(); caseCount = $caseResults.Count
        resourceSamples = $resourceRows.Count; finalHealth = $finalHealth
        evidenceDirectory = (Split-Path -Parent $env:CODEX_GIT_RESOURCE_SAMPLES)
    } | ConvertTo-Json -Depth 12
}
finally {
    try { Stop-UiWorker } catch { }
    if ($HasInstanceMutex) { $InstanceMutex.ReleaseMutex() }
    $InstanceMutex.Dispose(); $ConfigMutex.Dispose()
}
'@
    [IO.File]::WriteAllText($adapterPath, ($prefix + "`r`n" + $body), [Text.UTF8Encoding]::new($false))

    $env:USERPROFILE = $profile
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    $env:CODEX_GIT_BOUNDARY_CONTROL = $controlPath
    $env:CODEX_GIT_BOUNDARY_LOG = $logPath
    $env:CODEX_GIT_BOUNDARY_REPO = $repo
    $env:CODEX_GIT_BOUNDARY_STALE = $staleRepo
    $env:CODEX_GIT_RESOURCE_SAMPLES = $samplesPath
    $env:CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID = 'git-reconcile-' + [guid]::NewGuid().ToString('N')
    $resultText = & $adapterPath -ConfigPath $configPath -InstanceName ('git-reconcile-' + [guid]::NewGuid().ToString('N'))
    if (-not $?) { throw 'Git/reconcile adapter failed.' }
    $result = $resultText | ConvertFrom-Json
    if (-not $result.passed) { throw 'Git/reconcile adapter did not pass.' }
    $receiptPath = Join-Path $testRoot 'receipt.json'
    [IO.File]::WriteAllText($receiptPath, ($result | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json -Depth 14
}
finally {
    $env:USERPROFILE = $oldProfile
    $env:PATH = $oldPath
    foreach ($pair in @(
        @('CODEX_GIT_BOUNDARY_CONTROL', $oldControl),
        @('CODEX_GIT_BOUNDARY_LOG', $oldLog),
        @('CODEX_GIT_BOUNDARY_REPO', $oldRepo),
        @('CODEX_GIT_BOUNDARY_STALE', $oldStale),
        @('CODEX_GIT_RESOURCE_SAMPLES', $oldSamples),
        @('CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID', $oldRunId)
    )) {
        if ($null -eq $pair[1]) { Remove-Item ("Env:" + $pair[0]) -ErrorAction SilentlyContinue }
        else { Set-Item ("Env:" + $pair[0]) -Value $pair[1] }
    }
}
