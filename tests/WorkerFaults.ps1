[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root '.artifacts\bin'
Add-Type -Path (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll')
$testRoot = Join-Path $root ('.artifacts\worker-faults-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll') -Destination $testRoot
Copy-Item -LiteralPath (Join-Path $bin 'CodexWorktreeTrustBridge.Supervision.ps1') -Destination $testRoot
$fixtureSource = Join-Path $testRoot 'FaultWorker.cs'
@'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Threading;
using CodexTrustBridge;
internal static class FaultWorker {
    [MTAThread] static int Main(string[] args) {
        try {
            string mode = Environment.GetEnvironmentVariable("TRUST_BRIDGE_TEST_FAULT");
            if (mode == "wrong-peer" && args.Length == 1) {
                ProcessStartInfo info = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, CommandLine.Join(new string[] { args[0], "peer" }));
                info.UseShellExecute = false; info.CreateNoWindow = true;
                using (Process child = Process.Start(info)) Thread.Sleep(60000);
                return 0;
            }
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", args[0], PipeDirection.InOut, PipeOptions.Asynchronous)) {
                pipe.Connect(10000);
                if (args.Length > 1) { Thread.Sleep(60000); return 0; }
                Frames.ReadAsync(pipe).GetAwaiter().GetResult();
                if (mode == "exit") return 91;
                if (mode == "oversize-frame") { byte[] invalid = BitConverter.GetBytes(65537); pipe.Write(invalid, 0, invalid.Length); pipe.Flush(); Thread.Sleep(60000); return 0; }
                if (mode == "soft-budget" || mode == "hard-budget") {
                    byte[] allocation = new byte[96*1024*1024];
                    for (int i = 0; i < allocation.Length; i += 4096) allocation[i] = 17;
                    Thread.Sleep(60000);
                    GC.KeepAlive(allocation);
                    return 0;
                }
                Thread.Sleep(60000); // Deliberately unresponsive test provider.
            }
            return 0;
        }
        catch (OutOfMemoryException) { return 92; }
        catch { return 93; }
    }
}
'@ | Set-Content -LiteralPath $fixtureSource -Encoding utf8NoBOM
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$worker = Join-Path $testRoot 'CodexWorktreeTrustBridge.UiWorker.exe'
& $compiler /nologo /target:winexe /optimize+ "/out:$worker" "/reference:$(Join-Path $testRoot 'CodexWorktreeTrustBridge.Native.dll')" $fixtureSource
if ($LASTEXITCODE) { throw 'Fault-injection worker compilation failed.' }
$StateDirectory = $testRoot
$ConfigPath = Join-Path $testRoot 'bridge.json'
[IO.File]::WriteAllText($ConfigPath, '{}')
$PackageVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$SourceManifestHash = (Get-FileHash -LiteralPath (Join-Path $bin 'manifest.json') -Algorithm SHA256).Hash
$LauncherProcessId = $null; $EnableUiAutoApprove = $true
$LastReconcileSucceeded = $true; $ReconcileCount = 1; $ConfigWriteUncertain = $false
function Write-BridgeLog {
    param([string]$Event, [hashtable]$Data)
    @{ event = $Event; data = $Data; utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 10 -Compress |
        Add-Content -LiteralPath (Join-Path $testRoot 'faults.jsonl') -Encoding utf8
}
$originalMode = $env:TRUST_BRIDGE_TEST_FAULT
$cases = [Collections.Generic.List[object]]::new()
try {
    foreach ($mode in @('timeout', 'soft-budget', 'hard-budget', 'oversize-frame', 'exit', 'wrong-peer')) {
        . (Join-Path $testRoot 'CodexWorktreeTrustBridge.Supervision.ps1')
        $Ui.State = 'IDLE'
        $Ui.TimeoutMs = if ($mode -eq 'timeout') { 1500 } else { 5000 }
        $Ui.SoftBytes = if ($mode -eq 'hard-budget') { 256MB } else { 64MB }
        $Ui.HardBytes = if ($mode -eq 'hard-budget') { 64MB } else { 128MB }
        $UiAttempts['uncertain-fixture'] = @{ dialogKey = 'uncertain-fixture'; status = 'outcome-uncertain'
            rootPid = $PID; createdFileTimeUtc = '1'; folder = $testRoot; action = 'approve' }
        Save-UiAttempts
        $ledgerHash = (Get-FileHash -LiteralPath $UiAttemptsPath -Algorithm SHA256).Hash
        $env:TRUST_BRIDGE_TEST_FAULT = $mode
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $message = $null
        try { [void](Invoke-UiRequest -Operation scan -Roots @()); throw 'Fault fixture unexpectedly returned a response.' }
        catch { $message = $_.Exception.Message; Register-UiFault -Reason $message }
        if ($message -eq 'Fault fixture unexpectedly returned a response.') { throw $message }
        if ($Ui.State -ne 'DEGRADED' -or $null -ne $Ui.Process -or $null -ne $Ui.Pipe) { throw "Worker fault $mode did not clean up and degrade." }
        if ($mode -eq 'timeout' -and ($message -notlike '*end-to-end deadline*' -or $timer.Elapsed.TotalSeconds -gt 3.5)) { throw 'End-to-end timeout was not enforced.' }
        if ($mode -eq 'soft-budget' -and $message -notlike '*memory budget exceeded*') { throw "Soft budget was not observable: $message" }
        if ($mode -eq 'wrong-peer' -and $message -notlike '*pipe peer*') { throw "Unexpected pipe peer was not rejected: $message" }
        if ($mode -eq 'hard-budget' -and $message -notlike '*exited*') { throw "Hard budget fixture did not exit: $message" }
        if ((Get-FileHash -LiteralPath $UiAttemptsPath -Algorithm SHA256).Hash -ne $ledgerHash -or $UiAttempts.Count -ne 1) { throw 'Fault cleanup modified an unresolved authorization intent.' }
        Write-BridgeHealth -Force
        $health = Get-Content -LiteralPath "$ConfigPath.health.json" -Raw | ConvertFrom-Json
        if ($health.healthy -or -not $health.uncertainUiOutcome) { throw 'Fault state was incorrectly reported healthy.' }
        $cases.Add(@{ mode = $mode; result = 'fault contained, job cleanup verified, ledger unchanged, health degraded'
            elapsedSeconds = $timer.Elapsed.TotalSeconds; message = $message; softBytes = $Ui.SoftBytes; hardBytes = $Ui.HardBytes })
    }
    Register-UiFault -Reason 'second injected failure'
    Register-UiFault -Reason 'third injected failure'
    $generation = $Ui.Generation
    for ($i = 0; $i -lt 25; $i++) { [void](Invoke-UiScan) }
    if ($Ui.State -ne 'CIRCUIT_OPEN' -or $Ui.Generation -ne $generation) { throw 'Circuit-open state restarted the worker.' }
    $cases.Add(@{ mode = 'circuit-open'; polls = 25; additionalWorkerStarts = 0 })
    $result = @{ passed = $true; cases = $cases.ToArray(); caseCount = $cases.Count
        budgets = 'lowered only inside the isolated fault harness; shipping 256/384 MiB defaults unchanged'
        evidenceDirectory = $testRoot }
    $json = $result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $testRoot 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
    $json
}
finally {
    Stop-UiWorker
    $env:TRUST_BRIDGE_TEST_FAULT = $originalMode
}
