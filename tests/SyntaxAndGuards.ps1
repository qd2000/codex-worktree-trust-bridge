[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(& git -C $root ls-files --cached --others --exclude-standard -- '*.ps1')
if ($LASTEXITCODE) { throw 'Cannot enumerate source scripts.' }
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "PowerShell parse errors in $file : $($errors -join '; ')" }
}

$legacyTest = Join-Path $root 'tests\InstalledSilentStartup.ps1'
$legacyRejected = $false
try { & $legacyTest } catch { $legacyRejected = $_.Exception.Message -like 'V022_LEGACY_LIVE_TEST_DISABLED:*' }
if (-not $legacyRejected) { throw 'The unsafe legacy live-task test is not fail-closed.' }

$status = Get-Content -LiteralPath (Join-Path $root 'RELEASE_STATUS.json') -Raw | ConvertFrom-Json
if (-not $status.maintenanceImplementationReady) { throw 'Maintenance implementation readiness was not recorded.' }
if (-not $status.gitReconcileImplementationReady -or -not $status.fleetDeploymentRequiresGrayAuthorization) {
    throw 'Git/reconcile or gray-authorization gates are not recorded.'
}
if ([bool]$status.candidateAccepted -ne [bool]$status.canaryDeploymentAllowed) {
    throw 'Candidate acceptance and canary permission disagree.'
}
if ([string]$status.state -ceq 'released-and-deployed') {
    foreach ($requiredBoolean in @('sustainedValidationAccepted', 'releaseAllowed',
        'deploymentAllowed', 'releasePublished', 'fleetDeploymentCompleted')) {
        if (-not [bool]$status.$requiredBoolean) {
            throw "Final release status is missing required acceptance: $requiredBoolean"
        }
    }
    foreach ($requiredHash in @('sourceCommit', 'manifestSha256', 'archiveSha256', 'grayAuthorizationSha256')) {
        if ([string]$status.$requiredHash -notmatch '^[a-f0-9]{40}$|^[a-f0-9]{64}$') {
            throw "Final release status is missing a valid identity: $requiredHash"
        }
    }
    if ([int]$status.verifiedHostCount -lt 3 -or
        -not (Test-Path -LiteralPath (Join-Path $root ([string]$status.report)) -PathType Leaf)) {
        throw 'Final release status is missing fleet verification or its public report.'
    }
}
elseif (-not [bool]$status.candidateAccepted -and
    ([string]$status.state).IndexOf('suite-pending', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'A revoked or in-progress candidate is missing an explicit pending-suite state.'
}

$runtime = Get-Content -LiteralPath (Join-Path $root 'src\CodexWorktreeTrustBridge.ps1') -Raw
if ($runtime -match 'System\.Windows\.Automation|UIAutomationClient|FindAll\(') { throw 'UIA leaked back into the long-lived authority runtime.' }
if ($runtime -match 'ReadToEnd(?:Async)?\s*\(|WaitForExit\s*\(|RedirectStandardOutput\s*=') {
    throw 'An unbounded legacy Git process/output pattern leaked back into the authority runtime.'
}
$boundedRunner = Get-Content -LiteralPath (Join-Path $root 'src\CodexWorktreeTrustBridge.BoundedProcess.cs') -Raw
foreach ($required in @('PROC_THREAD_ATTRIBUTE_JOB_LIST', 'PROC_THREAD_ATTRIBUTE_HANDLE_LIST',
    'StandardOutputLimitExceeded', 'StandardErrorLimitExceeded', 'CleanupVerified')) {
    if (-not $boundedRunner.Contains($required, [StringComparison]::Ordinal)) {
        throw "Bounded process runner is missing required contract marker: $required"
    }
}
$maintenance = Get-Content -LiteralPath (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1') -Raw
foreach ($unsafe in @('Stop-Process', 'CommandLine -like', 'Get-Process pwsh', 'Get-Process -Name pwsh')) {
    if ($maintenance.Contains($unsafe, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe broad process-control pattern is present: $unsafe" }
}

$legacyWorkflow = Join-Path $root '.github\workflows\release.yml'
if (Test-Path -LiteralPath $legacyWorkflow) {
    throw 'The obsolete v0.2.2 pre-release blocking workflow still exists.'
}
$grayValidator = Get-Content -LiteralPath (Join-Path $root 'Validate-Gray.ps1') -Raw
foreach ($required in @('DurationMinutes = 120', '$usable.Count -lt 200', 'cleanupVerified',
    'fleetDeploymentAllowed = $true', 'reconcileCount -ge ($preCleanupReconcile + 2)',
    'AllowMissing', 'transientDescendantSamplesSkipped')) {
    if (-not $grayValidator.Contains($required, [StringComparison]::Ordinal)) {
        throw "Gray validator is missing required gate: $required"
    }
}
$publisher = Get-Content -LiteralPath (Join-Path $root 'tools\Publish-FrozenCandidate.ps1') -Raw
if ($publisher -match '\-\-clobber|release\s+upload') {
    throw 'Frozen-candidate publication contains an overwrite path.'
}
$freezer = Get-Content -LiteralPath (Join-Path $root 'tools\Freeze-Candidate.ps1') -Raw
foreach ($required in @('LiveHealthReceiptPath', 'live-ui-health-cadence',
    'productionTaskMutated', 'maximumHealthAgeSeconds', 'liveHealthReceiptSha256')) {
    if (-not $freezer.Contains($required, [StringComparison]::Ordinal)) {
        throw "Candidate freeze is missing a live-QDSPC health gate: $required"
    }
}
foreach ($required in @('ls-remote --tags', 'release view', 'release create', '--verify-tag')) {
    if (-not $publisher.Contains($required, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Frozen-candidate publication is missing a no-clobber gate: $required"
    }
}

. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
$syntheticRows = @(
    [pscustomobject]@{ ProcessId = 200; ParentProcessId = 100; Birth = 900 },
    [pscustomobject]@{ ProcessId = 201; ParentProcessId = 100; Birth = 1100 },
    [pscustomobject]@{ ProcessId = 202; ParentProcessId = 201; Birth = 1200 },
    [pscustomobject]@{ ProcessId = 203; ParentProcessId = 200; Birth = 1300 }
)
$syntheticRoot = [pscustomobject]@{ pid = 100; creationFileTimeUtc = 1000 }
$syntheticResolver = {
    param($Row)
    [pscustomobject]@{
        pid = [int]$Row.ProcessId
        creationFileTimeUtc = [long]$Row.Birth
        parentPid = [int]$Row.ParentProcessId
        executablePath = 'C:\controlled.exe'
    }
}
$selectedSynthetic = @(Get-BridgeVerifiedDescendantIdentities -AllProcesses $syntheticRows `
    -RootIdentities @($syntheticRoot) -IdentityResolver $syntheticResolver)
$selectedSyntheticPids = @($selectedSynthetic.pid | Sort-Object)
if (($selectedSyntheticPids -join ',') -ne '201,202') {
    throw "PID-reuse-safe descendant selection failed: $($selectedSyntheticPids -join ',')"
}
$artifact = Join-Path $root '.artifacts\bin'
$manifest = Get-Content -LiteralPath (Join-Path $artifact 'manifest.json') -Raw | ConvertFrom-Json
if (-not $manifest.sourceDirty -and -not $manifest.accepted) { throw 'Clean final candidate manifest is not accepted.' }
if (-not $manifest.sourceDirty) {
    [void](Test-BridgeArtifactDirectory -ArtifactDirectory $artifact -CanaryDeployment)
    $fleetRejected = $false
    try { [void](Test-BridgeArtifactDirectory -ArtifactDirectory $artifact) }
    catch { $fleetRejected = $_.Exception.Message -like '*gray-authorization receipt*' }
    if (-not $fleetRejected) { throw 'Fleet installation did not require a qdspc gray authorization.' }
}

$guardRoot = Join-Path $root ('.artifacts\guard-' + [guid]::NewGuid().ToString('N'))
try {
    $dateProbePath = Join-Path $guardRoot 'utc-date-probe.json'
    $dateProbeValue = [DateTime]::UtcNow.ToString('o')
    Write-BridgeAtomicJson -Path $dateProbePath -Value @{ updatedAtUtc = $dateProbeValue }
    $dateProbe = Read-BridgeJson -Path $dateProbePath
    if ($dateProbe.updatedAtUtc -isnot [string] -or [string]$dateProbe.updatedAtUtc -cne $dateProbeValue) {
        throw 'Maintenance JSON parsing did not preserve the exact UTC timestamp string.'
    }
    $dateProbeAge = [Math]::Abs(([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$dateProbe.updatedAtUtc)).TotalSeconds)
    if ($dateProbeAge -gt 5) { throw "Fresh UTC receipt was misclassified by $dateProbeAge seconds." }

    $productionNameLayout = New-BridgeMaintenanceLayout -TaskName 'Codex-Worktree-Trust-Bridge' `
        -InstallRoot (Join-Path $guardRoot 'install') -ConfigPath (Join-Path $guardRoot 'bridge.json') `
        -StatePath (Join-Path $guardRoot 'state.json') -ActionLedgerPath (Join-Path $guardRoot 'actions.json') `
        -CodexConfigPath (Join-Path $guardRoot 'config.toml') -LogPath (Join-Path $guardRoot 'bridge.log') `
        -BackupRoot (Join-Path $guardRoot 'backups')
    $rejected = $false
    try { Assert-BridgeMaintenanceScope -Layout $productionNameLayout -DevelopmentTest -TestRoot $guardRoot }
    catch { $rejected = $_.Exception.Message -like '*unique test task name*' }
    if (-not $rejected) { throw 'DevelopmentTest accepted the production task name.' }

    $escapeLayout = New-BridgeMaintenanceLayout -TaskName ('Codex-Worktree-Trust-Bridge-Test-' + [guid]::NewGuid().ToString('N')) `
        -InstallRoot (Join-Path ([IO.Path]::GetTempPath()) ('outside-' + [guid]::NewGuid().ToString('N'))) `
        -ConfigPath (Join-Path $guardRoot 'bridge.json') -StatePath (Join-Path $guardRoot 'state.json') `
        -ActionLedgerPath (Join-Path $guardRoot 'actions.json') -CodexConfigPath (Join-Path $guardRoot 'config.toml') `
        -LogPath (Join-Path $guardRoot 'bridge.log') -BackupRoot (Join-Path $guardRoot 'backups')
    $rejected = $false
    try { Assert-BridgeMaintenanceScope -Layout $escapeLayout -DevelopmentTest -TestRoot $guardRoot }
    catch { $rejected = $_.Exception.Message -like '*escapes TestRoot*' }
    if (-not $rejected) { throw 'DevelopmentTest accepted a mutable path outside TestRoot.' }
}
finally {
    if (Test-Path -LiteralPath $guardRoot) { Remove-Item -LiteralPath $guardRoot -Recurse -Force }
}

[pscustomobject]@{
    passed = $true
    parsedScripts = $files.Count
    maintenanceImplementationReady = $true
    cleanCandidateCanaryAccepted = (-not $manifest.sourceDirty)
    fleetRequiresGrayAuthorization = $true
    developmentScopeGuards = $true
    releasePublished = [bool]$status.releasePublished
    fleetDeploymentCompleted = [bool]$status.fleetDeploymentCompleted
    authorityHasNoUia = $true
    boundedGitRunnerGuarded = $true
    pidReuseSafeDescendantSelection = $true
    utcReceiptDatePreserved = $true
    liveQdspcHealthRequiredForFreeze = $true
    unsafeBroadProcessPatterns = 0
} | ConvertTo-Json
