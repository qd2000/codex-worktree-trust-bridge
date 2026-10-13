[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root '.artifacts\bin'
Add-Type -Path (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll')
$testRoot = Join-Path $root ('.artifacts\authority-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $testRoot 'fixture'
$candidateDirectory = Join-Path $testRoot 'candidate'
$profile = Join-Path $testRoot 'profile'
$allowed = Join-Path $testRoot 'allowed'
foreach ($directory in @($fixtureDirectory, $candidateDirectory, (Join-Path $profile '.codex'), $allowed)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
Copy-Item -Path (Join-Path $bin '*') -Destination $candidateDirectory
$fixtureExe = & (Join-Path $PSScriptRoot 'Build-DialogFixture.ps1') -OutputDirectory $fixtureDirectory
$folder = Join-Path $allowed 'accepted-folder'
$denied = Join-Path $allowed 'explicitly-denied-folder'
$concurrent = Join-Path $allowed 'concurrent-write-test'
foreach ($directory in @($folder, $denied, $concurrent)) { New-Item -ItemType Directory -Path $directory | Out-Null }
$fixtureConfig = Join-Path $fixtureDirectory 'fixture.json'
@{ folder = $folder; seconds = 180; noise = 64 } | ConvertTo-Json | Set-Content -LiteralPath $fixtureConfig -Encoding utf8NoBOM
$configPath = Join-Path $profile '.codex\bridge.json'
$configuration = @{
    schema = 'codex-worktree-trust-bridge.config'; version = 1; allowedRoots = @($allowed)
    uiPollIntervalMs = 750; reconcileIntervalSeconds = 60; discoveryDepth = 2
    trustMode = 'all-directories'; deniedDialogAction = 'cancel'; deniedDialogGraceSeconds = 0
    enableConfigTrust = $true; enableUiAutoApprove = $true; pruneMissingManagedEntries = $true
    testFixtureDirectory = $fixtureDirectory; testFolder = $folder; testDenied = $denied
    testConcurrent = $concurrent; testResultPath = (Join-Path $testRoot 'integration.json')
}
$configuration | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
$codexConfig = Join-Path $profile '.codex\config.toml'
[IO.File]::WriteAllText($codexConfig, "keep_setting = 'untouched'`r`n", [Text.UTF8Encoding]::new($false))

# The only test seam is the source-derived main-loop adapter and controlled root
# supplier below. No fixture mode or bypass exists in the shipping target lookup.
$source = [IO.File]::ReadAllText((Join-Path $bin 'CodexWorktreeTrustBridge.ps1')).Replace("`r`n", "`n")
$boundary = $source.IndexOf("`ntry {`n    try { `$HasInstanceMutex", [StringComparison]::Ordinal)
if ($boundary -lt 0) { throw 'Could not find the source-derived runtime entry boundary.' }
$prefix = $source.Substring(0, $boundary).Replace('Set-StrictMode -Version Latest', '$InstanceName = "integration-$PID"' + "`n" + 'Set-StrictMode -Version Latest')
$body = @'
trap {
    try { @{ passed = $false; error = $_.Exception.ToString(); stack = $_.ScriptStackTrace } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $BridgeConfig.testResultPath -Encoding utf8NoBOM } catch { }
    exit 1
}
$ConfigMutex.Dispose()
$ConfigMutex = [Threading.Mutex]::new($false, "Local\CodexTrustBridge-IsolatedConfigTest-$PID")
$testFixture = [string]$BridgeConfig.testFixtureDirectory
$caseNames = [Collections.Generic.List[string]]::new()
$sequence = 0
function Read-ControlledStatus {
    $stream = [IO.File]::Open((Join-Path $testFixture 'status.json'), [IO.FileMode]::Open,
        [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
}
function Wait-ControlledStatus {
    param([Parameter(Mandatory)][scriptblock]$Condition, [string]$Description = 'controlled fixture state')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $status = Read-ControlledStatus
        if (& $Condition $status) { return $status }
        if ($clock.Elapsed.TotalSeconds -ge 5) {
            throw "Timed out waiting for $Description. Last status: $($status | ConvertTo-Json -Compress -Depth 5)"
        }
        Start-Sleep -Milliseconds 25
    } while ($true)
}
function Get-VerifiedCodexTargets {
    $status = Read-ControlledStatus
    return @{ pid = $status.pid; hwnd = $status.hwnd; executable = $status.executable; createdFileTimeUtc = $status.createdFileTimeUtc }
}
function Advance-ControlledDialog {
    param([string]$Mode, [string]$Folder = ([string]$BridgeConfig.testFolder))
    $script:sequence++
    Write-AtomicBridgeJson -Path (Join-Path $testFixture 'command.json') -Value @{ sequence = $sequence; mode = $Mode; folder = $Folder }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ((Read-ControlledStatus).sequence -ne $sequence) {
        if ($clock.Elapsed.TotalSeconds -gt 5) { throw 'Controlled dialog did not change before the deadline.' }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 100
    $Ui.NextScan = 0; $Ui.NextAttempt = 0
    [void](Invoke-UiScan)
}
try {
    $HasInstanceMutex = $InstanceMutex.WaitOne(0)
    if (-not $HasInstanceMutex) { throw 'Isolated authority mutex was unavailable.' }
    Initialize-UiSupervisor
    if ($Ui.State -ne 'IDLE') { throw "Isolated authority initialization failed: $($Ui.Reason)" }
    Invoke-Reconcile
    $script:ActualUiRequest = (Get-Command Invoke-UiRequest).ScriptBlock
    $script:DropOneReply = $true
    function Invoke-UiRequest {
        param([string]$Operation, [object[]]$Roots = @(), [string]$Token, [string]$Action)
        $response = & $script:ActualUiRequest @PSBoundParameters
        if ($Operation -eq 'invoke' -and $script:DropOneReply) {
            $script:DropOneReply = $false
            throw 'Injected lost response after the controlled Invoke completed.'
        }
        return $response
    }
    [void](Invoke-UiScan)
    if ((Read-ControlledStatus).approved -ne 1 -or $UiAttempts.Count -ne 1 -or $Ui.Failures -ne 1) {
        throw 'Lost-response fixture did not retain exactly one uncertain action.'
    }
    if (-not (Test-ExactTrustedEntry ([string]$BridgeConfig.testFolder))) { throw 'Approved exact folder was not written.' }
    $caseNames.Add('durable uncertain action after lost invocation response')
    $Ui.NextScan = 0; $Ui.NextAttempt = 0
    [void](Invoke-UiScan)
    if ((Read-ControlledStatus).approved -ne 1 -or $Ui.Generation -ne 2) { throw 'Worker recovery repeated a prior authorization.' }
    Write-BridgeHealth -Force
    $health = Get-Content -LiteralPath "$ConfigPath.health.json" -Raw | ConvertFrom-Json
    if ($health.healthy -or -not $health.uncertainUiOutcome) { throw 'Uncertain action was falsely reported healthy.' }
    $caseNames.Add('worker recovery does not replay authorization or claim healthy')
    $UiAttempts.Clear()
    Initialize-UiSupervisor
    if ($UiAttempts.Count -ne 1) { throw 'Durable action intent did not survive state reload.' }
    $Ui.NextScan = 0; $Ui.NextAttempt = 0
    [void](Invoke-UiScan)
    if ((Read-ControlledStatus).approved -ne 1) { throw 'State rehydration repeated the action.' }
    $caseNames.Add('durable action ledger rehydration')
    Advance-ControlledDialog -Mode closed
    if ($UiAttempts.Count -ne 0) { throw 'Verified dialog disappearance did not reconcile the action ledger.' }
    Advance-ControlledDialog -Mode valid
    if ((Read-ControlledStatus).approved -ne 2) { throw 'A new controlled dialog was not approved exactly once.' }
    $caseNames.Add('new dialog authorized only after prior disappearance was verified')

    Advance-ControlledDialog -Mode closed
    $deniedKey = Get-CanonicalPath ([string]$BridgeConfig.testDenied)
    [IO.File]::AppendAllText($CodexConfigPath, "`r`n[projects.'$deniedKey']`r`ntrust_level = 'untrusted'`r`n", [Text.UTF8Encoding]::new($false))
    Advance-ControlledDialog -Mode valid -Folder ([string]$BridgeConfig.testDenied)
    # InvokePattern dispatch is complete when Invoke returns, but the WPF Click
    # handler may publish its test-only counter a few milliseconds later. Wait
    # for that externally observable state rather than racing the UI thread.
    $status = Wait-ControlledStatus -Description 'one controlled cancellation' -Condition {
        param($value) [int]$value.cancelled -eq 1
    }
    if ($status.approved -ne 2 -or $status.cancelled -ne 1 -or (Test-ExactTrustedEntry $deniedKey)) {
        throw "Explicit manual denial was not preserved while cancelling the controlled denied dialog. Status: $($status | ConvertTo-Json -Compress -Depth 5)"
    }
    $caseNames.Add('manual denial and controlled Cancel semantics preserved')

    $script:RealBackup = (Get-Command Backup-CodexConfig).ScriptBlock
    function Backup-CodexConfig {
        $backup = & $script:RealBackup
        [IO.File]::AppendAllText($CodexConfigPath, "`r`n# concurrent external edit must survive`r`n", [Text.UTF8Encoding]::new($false))
        return $backup
    }
    [void]$ManagedPaths.Add((Get-CanonicalPath ([string]$BridgeConfig.testConcurrent)))
    $rejected = $false
    try { Update-CodexTrustConfig $ManagedPaths } catch { $rejected = $_.Exception.Message -like '*changed while preparing*' }
    if (-not $rejected -or (Test-ExactTrustedEntry ([string]$BridgeConfig.testConcurrent))) { throw 'Concurrent modification was overwritten or not detected.' }
    $text = [IO.File]::ReadAllText($CodexConfigPath)
    if (-not $text.Contains('# concurrent external edit must survive') -or -not $text.Contains("keep_setting = 'untouched'")) {
        throw 'Unrelated or concurrent configuration content was lost.'
    }
    Set-Item -Path Function:Backup-CodexConfig -Value $script:RealBackup
    Update-CodexTrustConfig $ManagedPaths
    if (-not (Test-ExactTrustedEntry ([string]$BridgeConfig.testConcurrent))) { throw 'Fresh reconciliation after a conflict failed.' }
    if (-not [IO.File]::ReadAllText($CodexConfigPath).Contains('# concurrent external edit must survive')) { throw 'Conflict retry erased the newer content.' }
    $caseNames.Add('preimage conflict abort and fresh merge preserve concurrent edits')
    $latePath = Join-Path (Split-Path -Parent ([string]$BridgeConfig.testConcurrent)) 'late-ui-guard-test'
    New-Item -ItemType Directory -Path $latePath | Out-Null
    [void]$ManagedPaths.Add((Get-CanonicalPath $latePath))
    $previousHash = (Get-FileHash -LiteralPath $CodexConfigPath -Algorithm SHA256).Hash
    $refused = $false
    try { Update-CodexTrustConfig -ManagedPaths $ManagedPaths -BeforeCommit { throw 'Injected invalid UI at the commit boundary.' } }
    catch { $refused = $_.Exception.Message -eq 'Injected invalid UI at the commit boundary.' }
    if (-not $refused -or (Get-FileHash -LiteralPath $CodexConfigPath -Algorithm SHA256).Hash -ne $previousHash -or
        (Test-ExactTrustedEntry $latePath)) { throw 'Failed late UI validation still changed the config.' }
    [void]$ManagedPaths.Remove((Get-CanonicalPath $latePath))
    $caseNames.Add('late UI validation failure leaves the config unchanged')
    $rejectedPath = Join-Path (Split-Path -Parent ([string]$BridgeConfig.testConcurrent)) 'failed-ui-intent-not-managed'
    New-Item -ItemType Directory -Path $rejectedPath | Out-Null
    $rejectedKey = Get-CanonicalPath $rejectedPath
    $refused = $false
    try { [void](Ensure-ManagedTrust -Path $rejectedPath -BeforeWrite { throw 'Injected failed UI intent.' }) }
    catch { $refused = $_.Exception.Message -eq 'Injected failed UI intent.' }
    if (-not $refused -or $ManagedPaths.Contains($rejectedKey) -or (Test-ExactTrustedEntry $rejectedPath)) {
        throw 'A failed UI validation left a managed path that a later reconcile could trust.'
    }
    Invoke-Reconcile
    if (Test-ExactTrustedEntry $rejectedPath) { throw 'Reconcile persisted an earlier rejected UI intent.' }
    $caseNames.Add('failed UI intent is absent from both managed state and later reconciliation')
    $backups = @(Get-ChildItem -LiteralPath $BackupDirectory -File)
    if ($backups.Count -lt 2) { throw 'Expected config backups were not created.' }
    $caseNames.Add('backups and preservation of unrelated settings')
    @{ passed = $true; cases = $caseNames.ToArray(); approvals = $status.approved; cancellations = $status.cancelled
        sourceScope = 'source-derived policy, supervisor and config functions with controlled target supplier; shipping launcher and worker'
        backupCount = $backups.Count } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BridgeConfig.testResultPath -Encoding utf8NoBOM
}
finally {
    try { Stop-UiWorker }
    finally {
        if ($HasInstanceMutex) { $InstanceMutex.ReleaseMutex() }
        $InstanceMutex.Dispose(); $ConfigMutex.Dispose()
    }
}
'@
$adapter = Join-Path $candidateDirectory 'AuthorityAdapter.ps1'
[IO.File]::WriteAllText($adapter, $prefix + "`r`n" + $body, [Text.UTF8Encoding]::new($false))
$fixture = $null; $candidate = $null
$originalProfile = $env:USERPROFILE
try {
    $fixture = [CodexTrustBridge.OwnedProcess]::Start($fixtureExe, [string[]]@($fixtureConfig), $fixtureDirectory, 192MB, 8, $false)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath (Join-Path $fixtureDirectory 'status.json'))) {
        if ($fixture.HasExited -or $clock.Elapsed.TotalSeconds -gt 10) { throw 'Integration fixture failed to start.' }
        Start-Sleep -Milliseconds 50
    }
    $env:USERPROFILE = $profile
    $pwsh = (Get-Command pwsh.exe).Source
    $candidate = [CodexTrustBridge.OwnedProcess]::Start((Join-Path $candidateDirectory 'CodexWorktreeTrustBridge.Launcher.exe'),
        [string[]]@($pwsh, $adapter, $configPath), $candidateDirectory, 384MB, 24, $false)
    $env:USERPROFILE = $originalProfile
    if (-not $candidate.WaitForExit(90000)) { throw 'Authority integration exceeded its deadline.' }
    if ($candidate.ExitCode -ne 0) {
        $failurePath = Join-Path $testRoot 'integration.json'
        $detail = if (Test-Path -LiteralPath $failurePath) { Get-Content -LiteralPath $failurePath -Raw } else { 'No adapter failure receipt.' }
        throw "Authority integration failed with exit $($candidate.ExitCode); evidence: $testRoot; $detail"
    }
    $resultPath = Join-Path $testRoot 'integration.json'
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'Authority exited without a test receipt.' }
    Get-Content -LiteralPath $resultPath
    [pscustomobject]@{ evidenceDirectory = $testRoot; adapterSha256 = (Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash } | ConvertTo-Json
}
finally {
    $env:USERPROFILE = $originalProfile
    foreach ($owned in @($candidate, $fixture)) {
        if ($null -ne $owned) { try { if (-not $owned.StopAndWait(10000)) { throw 'Integration job cleanup is uncertain.' } } finally { $owned.Dispose() } }
    }
}
