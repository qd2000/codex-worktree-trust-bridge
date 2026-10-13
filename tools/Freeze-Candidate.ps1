[CmdletBinding()]
param(
    [string]$ArtifactDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts\bin'),
    [Parameter(Mandatory)][string]$SuiteReceiptPath,
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts\frozen-candidates')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
$artifact = Test-BridgeArtifactDirectory -ArtifactDirectory $ArtifactDirectory -CanaryDeployment
$suitePath = ConvertTo-BridgeCanonicalPath $SuiteReceiptPath
$suite = Read-BridgeJson -Path $suitePath -MaximumBytes 4194304
if (-not [bool]$suite.passed -or [int]$suite.testCount -ne [int]$suite.expectedTestCount -or
    [int]$suite.expectedTestCount -lt 12 -or
    [string]$suite.artifactManifestSha256 -cne $artifact.ManifestSha256 -or
    [string]$suite.maintenanceAcceptance -cne 'ISOLATED_MAINTENANCE_CHAIN_PASSED_PRODUCTION_NOT_RUN' -or
    [string]$suite.gitReconcileAcceptance -cne 'ISOLATED_BOUNDED_GIT_RECONCILE_PASSED_WHEN_SUITE_PASSES' -or
    @($suite.receipts | Where-Object { -not [bool]$_.passed -or -not [bool]$_.cleanupVerified }).Count) {
    throw 'Candidate freeze requires the complete passing suite for this exact manifest.'
}
$head = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify candidate source commit.' }
if (@(& git -C $root status --porcelain)) { throw 'Candidate freeze requires a clean checkout.' }
if ($head -cne [string]$artifact.Manifest.sourceCommit -or [bool]$artifact.Manifest.sourceDirty -or -not [bool]$artifact.Manifest.accepted) {
    throw 'Candidate manifest does not identify this clean accepted checkout.'
}

$OutputRoot = ConvertTo-BridgeCanonicalPath $OutputRoot
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$candidateName = 'codex-worktree-trust-bridge-' + $artifact.Version + '-' + $artifact.ManifestSha256.ToLowerInvariant()
$candidateDirectory = Join-Path $OutputRoot $candidateName
$archivePath = Join-Path $OutputRoot ($candidateName + '.zip')
$receiptPath = Join-Path $OutputRoot ($candidateName + '.freeze.json')
$stage = Join-Path $OutputRoot ('.stage-' + [guid]::NewGuid().ToString('N'))
$verify = Join-Path $OutputRoot ('.verify-' + [guid]::NewGuid().ToString('N'))

try {
    if (Test-Path -LiteralPath $candidateDirectory) {
        $existing = Test-BridgeArtifactDirectory -ArtifactDirectory $candidateDirectory -CanaryDeployment
        if ($existing.ManifestSha256 -cne $artifact.ManifestSha256) { throw 'Existing frozen candidate has a different manifest.' }
    }
    else {
        Copy-BridgeArtifactStage -Artifact $artifact -StageDirectory $stage
        Move-Item -LiteralPath $stage -Destination $candidateDirectory
    }
    $frozen = Test-BridgeArtifactDirectory -ArtifactDirectory $candidateDirectory -CanaryDeployment
    if ($frozen.ManifestSha256 -cne $artifact.ManifestSha256) { throw 'Frozen candidate verification failed.' }

    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($candidateDirectory, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $verify)
    $extracted = Test-BridgeArtifactDirectory -ArtifactDirectory $verify -CanaryDeployment
    if ($extracted.ManifestSha256 -cne $artifact.ManifestSha256) { throw 'Frozen archive extraction differs from the candidate.' }

    $receipt = [ordered]@{
        schema = 'codex-worktree-trust-bridge.candidate-freeze'; version = 1
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        packageVersion = $artifact.Version; sourceCommit = $head
        manifestSha256 = $artifact.ManifestSha256
        candidateDirectory = $candidateDirectory
        archivePath = $archivePath
        archiveSha256 = Get-BridgeFileHash $archivePath
        suiteReceiptPath = $suitePath
        suiteReceiptSha256 = Get-BridgeFileHash $suitePath
        suiteTestCount = [int]$suite.testCount
        artifactCount = @($artifact.Entries).Count
        sourceDirty = $false; accepted = $true; byteIdenticalDeploymentRequired = $true
    }
    Write-BridgeAtomicJson -Path $receiptPath -Value $receipt
    $receipt | ConvertTo-Json -Depth 8
}
finally {
    foreach ($path in @($stage, $verify)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
