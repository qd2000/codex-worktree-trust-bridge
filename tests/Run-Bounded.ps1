[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestFile,
    [ValidateRange(10, 600)][int]$Seconds = 180,
    [ValidateRange(128, 1024)][int]$MemoryMiB = 512
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testPath = [IO.Path]::GetFullPath((Join-Path $root $TestFile))
if (-not $testPath.StartsWith($PSScriptRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $testPath -PathType Leaf)) { throw 'Select an existing test inside this checkout.' }
$native = Join-Path $root '.artifacts\bin\CodexWorktreeTrustBridge.Native.dll'
Add-Type -Path $native
$run = Join-Path $root ('.artifacts\test-runs\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$wrapper = Join-Path $run 'Execute.ps1'
@'
param([string]$TestFile, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
try {
    & $TestFile *> (Join-Path $OutputPath 'test-output.txt')
    if (-not $?) { throw 'Test script reported failure.' }
    [IO.File]::WriteAllText((Join-Path $OutputPath 'execution.json'), '{"passed":true}')
    exit 0
}
catch {
    $result = @{ passed = $false; error = $_.Exception.ToString(); stack = $_.ScriptStackTrace }
    [IO.File]::WriteAllText((Join-Path $OutputPath 'execution.json'), ($result | ConvertTo-Json -Depth 5))
    exit 1
}
'@ | Set-Content -LiteralPath $wrapper -Encoding utf8NoBOM
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$child = $null
$clock = [Diagnostics.Stopwatch]::StartNew()
$clean = $false
$failure = $null
$exitCode = $null
$samples = 0
$observer = [Diagnostics.Process]::GetCurrentProcess()
$observer.Refresh()
$childJobLimit = ($MemoryMiB * 1MB) - $observer.PrivateMemorySize64 - 32MB
if ($childJobLimit -lt 64MB) { $observer.Dispose(); throw 'The budget is too small for the test observer and a 64 MiB child workload.' }
try {
    $child = [CodexTrustBridge.OwnedProcess]::Start($pwsh,
        [string[]]@('-NoLogo', '-NoProfile', '-File', $wrapper, '-TestFile', $testPath, '-OutputPath', $run),
        $root, $childJobLimit, 64, $false)
    do {
        $ids = @($child.GetProcessIds())
        $totalPrivate = 0L; $totalWorking = 0L; $totalHandles = 0L
        foreach ($processId in $ids) {
            $p = $null
            try {
                $p = [Diagnostics.Process]::GetProcessById($processId)
                $totalPrivate += $p.PrivateMemorySize64
                $totalWorking += $p.WorkingSet64
                $totalHandles += $p.HandleCount
            }
            catch [ArgumentException] { }
            finally { if ($null -ne $p) { $p.Dispose() } }
        }
        $observer.Refresh()
        $totalPrivate += $observer.PrivateMemorySize64
        $totalWorking += $observer.WorkingSet64
        $totalHandles += $observer.HandleCount
        $sample = @{ elapsedSeconds = $clock.Elapsed.TotalSeconds; timestampUtc = [DateTime]::UtcNow.ToString('o')
            rootPid = $child.Id; rootBirth = $child.CreationFileTimeUtc.ToString(); processIds = $ids
            privateBytes = $totalPrivate; workingSetBytes = $totalWorking; handles = $totalHandles
            observerPid = $observer.Id; observerIncluded = $true; childJobLimitBytes = $childJobLimit }
        Add-Content -LiteralPath (Join-Path $run 'resources.jsonl') -Value ($sample | ConvertTo-Json -Depth 5 -Compress) -Encoding utf8
        $samples++
        if ($child.HasExited) { $exitCode = $child.ExitCode; break }
        if ($clock.Elapsed.TotalSeconds -gt $Seconds) { throw 'Bounded test deadline exceeded.' }
        if ($totalPrivate -gt $MemoryMiB * 1MB) { throw 'Bounded test aggregate memory budget exceeded.' }
        Start-Sleep -Milliseconds 250
    } while ($true)
    if ($exitCode -ne 0) { throw "Test process exited with code $exitCode." }
}
catch { $failure = $_.Exception.Message }
finally {
    if ($null -ne $child) {
        try { $clean = $child.StopAndWait(10000) }
        catch { $failure = "Cleanup verification failed: $($_.Exception.Message)" }
        finally { $child.Dispose() }
    }
    $observer.Dispose()
}
$receipt = @{ test = $TestFile; passed = (-not $failure -and $clean); error = $failure; exitCode = $exitCode
    cleanupVerified = $clean; elapsedSeconds = $clock.Elapsed.TotalSeconds; sampleCount = $samples
    memoryBudgetMiB = $MemoryMiB; observerIncluded = $true; childJobLimitBytes = $childJobLimit
    deadlineSeconds = $Seconds; evidenceDirectory = $run }
$json = $receipt | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $run 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
$json
if (Test-Path -LiteralPath (Join-Path $run 'execution.json')) { Get-Content -LiteralPath (Join-Path $run 'execution.json') }
if (-not $receipt.passed) { exit 1 }
