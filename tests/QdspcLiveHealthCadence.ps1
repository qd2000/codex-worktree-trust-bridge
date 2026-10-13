[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [ValidateRange(60, 600)][int]$DurationSeconds = 150,
    [ValidateRange(1, 10)][int]$SampleIntervalSeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'QDSPC') { throw 'This live-UI cadence test is restricted to QDSPC.' }

$root = Split-Path -Parent $PSScriptRoot
$artifact = [IO.Path]::GetFullPath($ArtifactDirectory)
$launcherPath = Join-Path $artifact 'CodexWorktreeTrustBridge.Launcher.exe'
$runtimePath = Join-Path $artifact 'CodexWorktreeTrustBridge.ps1'
$manifestPath = Join-Path $artifact 'manifest.json'
foreach ($path in @($launcherPath, $runtimePath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Candidate file is missing: $path" }
}

$testRoot = Join-Path $root ('.artifacts\live-ui-health-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$profile = Join-Path $testRoot 'profile'
$codexHome = Join-Path $profile '.codex'
$allowedRoot = Join-Path $testRoot 'allowed'
$configPath = Join-Path $testRoot 'bridge.json'
$healthPath = $configPath + '.health.json'
$processReceiptPath = $configPath + '.process.json'
$samplesPath = Join-Path $testRoot 'samples.jsonl'
$summaryPath = Join-Path $testRoot 'receipt.json'
foreach ($directory in @($codexHome, $allowedRoot)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

$configuration = [ordered]@{
    schema = 'codex-worktree-trust-bridge.config'; version = 1; packageVersion = '0.2.2'
    allowedRoots = @($allowedRoot); uiPollIntervalMs = 750; reconcileIntervalSeconds = 60
    discoveryDepth = 2; reconcileTimeoutSeconds = 30; discoveryDirectoryLimit = 200
    discoveryRepositoryLimit = 32; discoveryWorktreeLimit = 128; gitCommandLimitPerReconcile = 256
    gitCommandTimeoutSeconds = 10; gitCleanupTimeoutSeconds = 5
    gitMaximumStandardOutputBytes = 262144; gitMaximumStandardErrorBytes = 65536
    gitJobMemoryMiB = 128; gitProcessLimit = 8; trustMode = 'git-only'
    deniedDialogAction = 'leave-open'; deniedDialogGraceSeconds = 3
    enableConfigTrust = $false; enableUiAutoApprove = $true; pruneMissingManagedEntries = $true
}
[IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

function Read-SharedJson([string]$Path) {
    $stream = $null; $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd() | ConvertFrom-Json -DateKind String
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Wait-ExactExit($Identity, [int]$TimeoutMilliseconds) {
    if ($null -eq $Identity) { return $true }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $process = $null
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid)
            [void]$process.Handle
            if ($process.HasExited -or $process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$Identity.creationFileTimeUtc) { return $true }
        }
        catch [ArgumentException] { return $true }
        finally { if ($null -ne $process) { $process.Dispose() } }
        Start-Sleep -Milliseconds 100
    } while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return $false
}

$launcher = $null
$processReceipt = $null
$rows = [Collections.Generic.List[object]]::new()
$failure = $null
$oldProfile = $env:USERPROFILE
try {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $launcherPath
    $info.WorkingDirectory = $artifact
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.Environment['USERPROFILE'] = $profile
    $info.Environment['HOME'] = $profile
    foreach ($argument in @((Get-Command pwsh.exe -ErrorAction Stop).Source, $runtimePath, $configPath)) {
        [void]$info.ArgumentList.Add($argument)
    }
    $launcher = [Diagnostics.Process]::new()
    $launcher.StartInfo = $info
    if (-not $launcher.Start()) { throw 'Candidate launcher did not start.' }
    [void]$launcher.Handle
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $readyDeadline = 30.0
    while ($clock.Elapsed.TotalSeconds -lt $readyDeadline -and
        (-not (Test-Path -LiteralPath $healthPath -PathType Leaf) -or -not (Test-Path -LiteralPath $processReceiptPath -PathType Leaf))) {
        if ($launcher.HasExited) { throw "Candidate launcher exited early: $($launcher.ExitCode)" }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $healthPath -PathType Leaf) -or -not (Test-Path -LiteralPath $processReceiptPath -PathType Leaf)) {
        throw 'Candidate did not publish health and process receipts before the deadline.'
    }
    $processReceipt = Read-SharedJson $processReceiptPath
    $previousUpdate = $null
    $lastChangeElapsed = $null
    while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
        if ($launcher.HasExited) { throw "Candidate launcher exited during cadence test: $($launcher.ExitCode)" }
        $health = Read-SharedJson $healthPath
        $updated = [DateTimeOffset]::Parse([string]$health.updatedAtUtc)
        $age = ([DateTimeOffset]::UtcNow - $updated).TotalSeconds
        if ($null -eq $previousUpdate -or $updated -ne $previousUpdate) {
            $lastChangeElapsed = $clock.Elapsed.TotalSeconds
            $previousUpdate = $updated
        }
        $row = [pscustomobject]@{
            elapsedSeconds = $clock.Elapsed.TotalSeconds
            observedAtUtc = [DateTime]::UtcNow.ToString('o')
            healthUpdatedAtUtc = $updated.ToUniversalTime().ToString('o')
            healthAgeSeconds = $age
            secondsSinceObservedHealthChange = $clock.Elapsed.TotalSeconds - [double]$lastChangeElapsed
            healthy = [bool]$health.healthy
            uiState = [string]$health.ui.state
            uiScanCount = [long]$health.ui.scanCount
            workerGeneration = [long]$health.ui.workerGeneration
            reconcileCount = [long]$health.reconcileCount
            gitCommandCount = [long]$health.git.commandCount
        }
        $rows.Add($row)
        Add-Content -LiteralPath $samplesPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
        Start-Sleep -Seconds $SampleIntervalSeconds
    }
}
catch { $failure = $_ }
finally {
    if ($null -ne $launcher) {
        try {
            if (-not $launcher.HasExited) { $launcher.Kill() }
            [void]$launcher.WaitForExit(15000)
        }
        catch { if ($null -eq $failure) { $failure = $_ } }
        finally { $launcher.Dispose() }
    }
}

$runtimeIdentity = if ($null -ne $processReceipt) { [pscustomobject]@{
    pid = [int]$processReceipt.runtimePid
    creationFileTimeUtc = [long]$processReceipt.runtimeStartFileTimeUtc
} } else { $null }
$cleanupVerified = Wait-ExactExit -Identity $runtimeIdentity -TimeoutMilliseconds 10000
$maxAge = if ($rows.Count) { [double](($rows | Measure-Object healthAgeSeconds -Maximum).Maximum) } else { [double]::PositiveInfinity }
$maxNoChange = if ($rows.Count) { [double](($rows | Measure-Object secondsSinceObservedHealthChange -Maximum).Maximum) } else { [double]::PositiveInfinity }
$healthySamples = @($rows | Where-Object healthy).Count
$receipt = [ordered]@{
    schema = 'codex-worktree-trust-bridge.live-ui-health-cadence'; version = 1
    observedAtUtc = [DateTime]::UtcNow.ToString('o'); hostName = $env:COMPUTERNAME
    passed = ($null -eq $failure -and $cleanupVerified -and $rows.Count -ge 60 -and $maxAge -le 45 -and $healthySamples -gt 0)
    error = if ($failure) { $failure.Exception.ToString() } else { $null }
    artifactManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    durationSeconds = if ($rows.Count) { [double]$rows[-1].elapsedSeconds } else { 0 }
    sampleCount = $rows.Count; healthySamples = $healthySamples
    maximumHealthAgeSeconds = $maxAge; maximumObservedNoChangeSeconds = $maxNoChange
    cleanupVerified = $cleanupVerified; samplesPath = $samplesPath
    productionTaskMutated = $false; uiActionRequested = $false; evidenceDirectory = $testRoot
}
[IO.File]::WriteAllText($summaryPath, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 8
if (-not $receipt.passed) { exit 1 }
