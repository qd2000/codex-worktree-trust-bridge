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
if (-not $status.gitReconcileImplementationReady -or -not $status.candidateAccepted -or
    -not $status.canaryDeploymentAllowed -or -not $status.fleetDeploymentRequiresGrayAuthorization) {
    throw 'Final candidate/canary/gray-authorization gates are not recorded.'
}
if ($status.releaseAllowed -or $status.deploymentAllowed -or $status.sustainedValidationAccepted) {
    throw 'Release, fleet deployment and sustained acceptance must remain false before the qdspc gray run.'
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

$workflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release.yml') -Raw
if ($workflow -match '\-\-clobber|contents:\s*write') { throw 'The blocked release workflow still permits publication or replacement.' }
$grayValidator = Get-Content -LiteralPath (Join-Path $root 'Validate-Gray.ps1') -Raw
foreach ($required in @('DurationMinutes = 120', '$usable.Count -lt 200', 'cleanupVerified',
    'fleetDeploymentAllowed = $true', 'reconcileCount -ge ($preCleanupReconcile + 2)')) {
    if (-not $grayValidator.Contains($required, [StringComparison]::Ordinal)) {
        throw "Gray validator is missing required gate: $required"
    }
}
$publisher = Get-Content -LiteralPath (Join-Path $root 'tools\Publish-FrozenCandidate.ps1') -Raw
if ($publisher -match '\-\-clobber|release\s+upload') {
    throw 'Frozen-candidate publication contains an overwrite path.'
}
foreach ($required in @('ls-remote --tags', 'release view', 'release create', '--verify-tag')) {
    if (-not $publisher.Contains($required, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Frozen-candidate publication is missing a no-clobber gate: $required"
    }
}

. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
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
    releaseBlocked = $true
    authorityHasNoUia = $true
    boundedGitRunnerGuarded = $true
    unsafeBroadProcessPatterns = 0
} | ConvertTo-Json
