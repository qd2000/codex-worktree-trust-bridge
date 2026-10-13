[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $root '.artifacts\test-runs'
$suiteDirectory = Join-Path $root ('.artifacts\core-suite-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $suiteDirectory -Force | Out-Null
$manifest = Join-Path $root '.artifacts\bin\manifest.json'
$manifestHash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
$tests = @(
    @{ Path = 'tests\SyntaxAndGuards.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\PackageIdentitySmoke.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\LauncherSmoke.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\GitChildSmoke.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\OfflineSmoke.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\LifecycleStress.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\UiWorkerSmoke.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\WorkerFaults.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\AuthorityIntegration.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\GitReconcileBoundaries.ps1'; Seconds = 600; MemoryMiB = 768 },
    @{ Path = 'tests\GrayAuthorizationSmoke.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\MaintenanceMoveRetry.ps1'; Seconds = 180; MemoryMiB = 512 },
    @{ Path = 'tests\MaintenanceLifecycle.ps1'; Seconds = 600; MemoryMiB = 768 }
)
$receipts = [Collections.Generic.List[object]]::new()
$failure = $null
try {
    foreach ($definition in $tests) {
        $before = @(Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'Run-Bounded.ps1') -TestFile $definition.Path `
            -Seconds $definition.Seconds -MemoryMiB $definition.MemoryMiB
        $exitCode = $LASTEXITCODE
        $created = @(Get-ChildItem -LiteralPath $runRoot -Directory | Where-Object FullName -notin $before)
        if ($created.Count -ne 1) { throw 'Cannot uniquely identify the bounded test receipt.' }
        $receiptPath = Join-Path $created[0].FullName 'receipt.json'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $receipts.Add(@{
            test = $definition.Path
            passed = $receipt.passed
            cleanupVerified = $receipt.cleanupVerified
            elapsedSeconds = $receipt.elapsedSeconds
            deadlineSeconds = $definition.Seconds
            memoryBudgetMiB = $definition.MemoryMiB
            receipt = $receiptPath
        })
        if ($exitCode -ne 0 -or -not $receipt.passed -or -not $receipt.cleanupVerified) { throw "Core suite stopped at $($definition.Path)." }
        if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash -ne $manifestHash) { throw 'The build manifest changed during the core suite.' }
    }
}
catch { $failure = $_.Exception.Message }
$result = @{
    passed = (-not $failure -and $receipts.Count -eq $tests.Count)
    error = $failure
    testCount = $receipts.Count
    expectedTestCount = $tests.Count
    artifactManifestSha256 = $manifestHash
    receipts = $receipts.ToArray()
    maintenanceAcceptance = 'ISOLATED_MAINTENANCE_CHAIN_PASSED_PRODUCTION_NOT_RUN'
    sustainedValidation = 'NOT_RUN'
    productionInstallation = 'NOT_RUN'
    releasePublication = 'NOT_RUN'
    gitReconcileAcceptance = 'ISOLATED_BOUNDED_GIT_RECONCILE_PASSED_WHEN_SUITE_PASSES'
    scope = 'isolated source/component/security/Git-reconcile/maintenance tests; not sustained, release or deployment acceptance'
}
$json = $result | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $suiteDirectory 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
$json
if (-not $result.passed) { exit 1 }
