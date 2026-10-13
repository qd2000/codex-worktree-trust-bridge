[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwsh = (Get-Command pwsh.exe).Source
$runRoot = Join-Path $root '.artifacts\test-runs'
$suiteDirectory = Join-Path $root ('.artifacts\core-suite-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $suiteDirectory -Force | Out-Null
$manifest = Join-Path $root '.artifacts\bin\manifest.json'
$manifestHash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
$tests = @(
    'tests\SyntaxAndGuards.ps1', 'tests\PackageIdentitySmoke.ps1', 'tests\LauncherSmoke.ps1',
    'tests\GitChildSmoke.ps1', 'tests\OfflineSmoke.ps1', 'tests\LifecycleStress.ps1',
    'tests\UiWorkerSmoke.ps1', 'tests\WorkerFaults.ps1', 'tests\AuthorityIntegration.ps1'
)
$receipts = [Collections.Generic.List[object]]::new()
$failure = $null
try {
    foreach ($test in $tests) {
        $before = @(Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $global:LASTEXITCODE = 0
        # Use this same observer process rather than adding a second unbudgeted
        # PowerShell controller around each already-bounded experiment.
        & (Join-Path $PSScriptRoot 'Run-Bounded.ps1') -TestFile $test -Seconds 180 -MemoryMiB 512
        $exitCode = $LASTEXITCODE
        $created = @(Get-ChildItem -LiteralPath $runRoot -Directory | Where-Object FullName -notin $before)
        if ($created.Count -ne 1) { throw 'Cannot uniquely identify the bounded test receipt.' }
        $receiptPath = Join-Path $created[0].FullName 'receipt.json'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $receipts.Add(@{ test = $test; passed = $receipt.passed; cleanupVerified = $receipt.cleanupVerified
            elapsedSeconds = $receipt.elapsedSeconds; receipt = $receiptPath })
        if ($exitCode -ne 0 -or -not $receipt.passed -or -not $receipt.cleanupVerified) { throw "Core suite stopped at $test." }
        if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash -ne $manifestHash) { throw 'The build manifest changed during the core suite.' }
    }
}
catch { $failure = $_.Exception.Message }
$result = @{ passed = (-not $failure -and $receipts.Count -eq $tests.Count); error = $failure
    testCount = $receipts.Count; expectedTestCount = $tests.Count; artifactManifestSha256 = $manifestHash
    receipts = $receipts.ToArray(); sustainedValidation = 'NOT_RUN'; installationAcceptance = 'NOT_RUN'
    scope = 'isolated core source/component/regression tests, not release or sustained acceptance' }
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $suiteDirectory 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
$json
if (-not $result.passed) { exit 1 }
