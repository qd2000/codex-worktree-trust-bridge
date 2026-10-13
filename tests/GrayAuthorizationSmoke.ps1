[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
$artifact = Join-Path $root '.artifacts\bin'
$testRoot = Join-Path $root ('.artifacts\gray-auth-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function Write-GrayReceipt {
    param([string]$Path, [hashtable]$Overrides = @{})
    $manifestPath = Join-Path $artifact 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $value = [ordered]@{
        schema = 'codex-worktree-trust-bridge.gray-authorization'
        version = 1
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        passed = $true
        hostName = 'QDSPC'
        qdspcCanaryPassed = $true
        fleetDeploymentAllowed = $true
        candidateManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        sourceCommit = [string]$manifest.sourceCommit
        durationSeconds = 7200.0
        totalSamples = 241
        usableSamples = 221
        cleanupVerified = $true
        resourceGatePassed = $true
        activityGatePassed = $true
        integrityGatePassed = $true
    }
    foreach ($key in $Overrides.Keys) { $value[$key] = $Overrides[$key] }
    [IO.File]::WriteAllText($Path, ($value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Assert-Rejected {
    param([string]$Receipt, [string]$Label)
    $rejected = $false
    try { [void](Test-BridgeArtifactDirectory -ArtifactDirectory $artifact -GrayAuthorizationPath $Receipt) }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid gray authorization was accepted: $Label" }
}

try {
    $manifest = Get-Content -LiteralPath (Join-Path $artifact 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.sourceDirty -or -not $manifest.accepted) {
        throw 'Gray authorization smoke requires the clean accepted final-candidate artifact.'
    }
    $canary = Test-BridgeArtifactDirectory -ArtifactDirectory $artifact -CanaryDeployment
    if ($canary.DeploymentMode -ne 'canary') { throw 'Clean candidate did not enter canary mode.' }

    $missingRejected = $false
    try { [void](Test-BridgeArtifactDirectory -ArtifactDirectory $artifact) }
    catch { $missingRejected = $_.Exception.Message -like '*requires the qdspc gray-authorization receipt*' }
    if (-not $missingRejected) { throw 'Fleet deployment did not reject a missing gray authorization.' }

    $valid = Join-Path $testRoot 'valid.json'
    Write-GrayReceipt $valid
    $fleet = Test-BridgeArtifactDirectory -ArtifactDirectory $artifact -GrayAuthorizationPath $valid
    if ($fleet.DeploymentMode -ne 'fleet' -or -not $fleet.GrayAuthorizationSha256) {
        throw 'Valid gray authorization did not unlock the exact fleet artifact.'
    }

    $cases = @(
        @{ name = 'short-duration'; overrides = @{ durationSeconds = 7199.0 } },
        @{ name = 'insufficient-samples'; overrides = @{ usableSamples = 199 } },
        @{ name = 'cleanup-failed'; overrides = @{ cleanupVerified = $false } },
        @{ name = 'wrong-host'; overrides = @{ hostName = 'NOT-QDSPC' } },
        @{ name = 'wrong-manifest'; overrides = @{ candidateManifestSha256 = ('0' * 64) } },
        @{ name = 'wrong-source'; overrides = @{ sourceCommit = ('0' * 40) } },
        @{ name = 'resource-failed'; overrides = @{ resourceGatePassed = $false } },
        @{ name = 'activity-failed'; overrides = @{ activityGatePassed = $false } },
        @{ name = 'integrity-failed'; overrides = @{ integrityGatePassed = $false } },
        @{ name = 'fleet-not-authorized'; overrides = @{ fleetDeploymentAllowed = $false } }
    )
    foreach ($case in $cases) {
        $path = Join-Path $testRoot ($case.name + '.json')
        Write-GrayReceipt -Path $path -Overrides $case.overrides
        Assert-Rejected -Receipt $path -Label $case.name
    }

    [pscustomobject]@{
        passed = $true
        canaryAccepted = $true
        fleetRequiresGrayAuthorization = $true
        validGrayAccepted = $true
        invalidGrayCasesRejected = $cases.Count
        manifestSha256 = $fleet.ManifestSha256
    } | ConvertTo-Json -Depth 6
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
