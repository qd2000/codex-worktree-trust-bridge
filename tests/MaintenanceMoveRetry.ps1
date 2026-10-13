[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')

$testRoot = Join-Path $root ('.artifacts\maintenance-move-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $testRoot 'source'
$destination = Join-Path $testRoot 'destination'
$file = Join-Path $source 'locked.txt'
$ready = Join-Path $testRoot 'ready.txt'
$lockScript = Join-Path $testRoot 'Hold-Lock.ps1'
$process = $null
try {
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    [IO.File]::WriteAllText($file, 'controlled lock fixture')
    @'
param([string]$Path,[string]$ReadyPath)
$stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
try {
    [IO.File]::WriteAllText($ReadyPath,$PID.ToString())
    Start-Sleep -Milliseconds 1500
}
finally { $stream.Dispose() }
'@ | Set-Content -LiteralPath $lockScript -Encoding utf8NoBOM

    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',$lockScript,'-Path',$file,'-ReadyPath',$ready)) {
        [void]$info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Could not start the controlled file-lock fixture.' }
    [void]$process.Handle
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready)) {
        if ($process.HasExited -or $clock.Elapsed.TotalSeconds -gt 10) { throw 'File-lock fixture did not become ready.' }
        Start-Sleep -Milliseconds 25
    }

    $moveClock = [Diagnostics.Stopwatch]::StartNew()
    Move-BridgeDirectoryBounded -Source $source -Destination $destination -TimeoutMilliseconds 10000
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'locked.txt')) -or (Test-Path -LiteralPath $source)) {
        throw 'Bounded directory move did not complete atomically after the sharing conflict cleared.'
    }
    if ($moveClock.ElapsedMilliseconds -lt 500) {
        throw 'Controlled sharing conflict did not exercise the bounded retry path.'
    }
    if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'File-lock fixture did not exit cleanly.' }

    $source2 = Join-Path $testRoot 'source-existing-destination'
    $destination2 = Join-Path $testRoot 'destination-already-exists'
    New-Item -ItemType Directory -Path $source2,$destination2 -Force | Out-Null
    $rejected = $false
    try { Move-BridgeDirectoryBounded -Source $source2 -Destination $destination2 }
    catch { $rejected = $_.Exception.Message -like '*destination already exists*' }
    if (-not $rejected -or -not (Test-Path -LiteralPath $source2) -or -not (Test-Path -LiteralPath $destination2)) {
        throw 'Pre-existing destination was not rejected without mutation.'
    }

    [pscustomobject]@{
        passed = $true
        sharingRetryElapsedMilliseconds = $moveClock.ElapsedMilliseconds
        sharingConflictCleared = $true
        existingDestinationRejected = $true
        cleanupVerified = $true
        evidenceDirectory = $testRoot
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($null -ne $process) {
        try { if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(10000) } } catch { }
        $process.Dispose()
    }
}
