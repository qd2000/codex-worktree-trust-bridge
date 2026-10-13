[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root '.artifacts\bin'
Add-Type -Path (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll')
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$testRoot = Join-Path $root ('.artifacts\lifecycle-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$newLauncher = Join-Path $bin 'CodexWorktreeTrustBridge.Launcher.exe'
$runtime = Join-Path $testRoot 'ControlledRuntime.ps1'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$records = [Collections.Generic.List[object]]::new()

@'
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$self = [Diagnostics.Process]::GetCurrentProcess()
$grand = [Diagnostics.Process]::new()
try {
    $grand.StartInfo.FileName = (Get-Command pwsh.exe).Source
    $grand.StartInfo.UseShellExecute = $false
    $grand.StartInfo.CreateNoWindow = $true
    foreach ($arg in @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 60')) { $grand.StartInfo.ArgumentList.Add($arg) }
    if (-not $grand.Start()) { throw 'Cannot start controlled grandchild.' }
    $ready = @{ pid = $PID; birth = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
        grandchildPid = $grand.Id; grandchildBirth = $grand.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() }
    [IO.File]::WriteAllText($config.ready, ($ready | ConvertTo-Json))
    if ($config.normalExit) { Start-Sleep -Milliseconds 250 } else { Start-Sleep -Seconds 60 }
}
finally { $grand.Dispose(); $self.Dispose() }
'@ | Set-Content -LiteralPath $runtime -Encoding utf8NoBOM

function Wait-Ready {
    param([string]$Path)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 10) {
        if (Test-Path -LiteralPath $Path) {
            try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { }
        }
        Start-Sleep -Milliseconds 20
    }
    throw 'Controlled child did not publish identity before its deadline.'
}

function Get-ExactProcess {
    param([int]$ProcessId, [string]$Birth)
    $p = [Diagnostics.Process]::GetProcessById($ProcessId)
    try {
        [void]$p.Handle
        if ($p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $Birth) { throw 'Process birth identity changed.' }
        return $p
    }
    catch { $p.Dispose(); throw }
}

function Invoke-LauncherCase {
    param([string]$Launcher, [string]$Mode, [int]$Index)
    $config = Join-Path $testRoot "case-$Mode-$Index.json"
    $readyPath = "$config.ready"
    @{ ready = $readyPath; normalExit = ($Mode -eq 'normal') } | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding utf8NoBOM
    $owned = $null; $child = $null; $grand = $null; $launcherProcess = $null; $duplicate = $null
    $started = [DateTime]::UtcNow
    try {
        $owned = [CodexTrustBridge.OwnedProcess]::Start($Launcher, [string[]]@($pwsh, $runtime, $config), $testRoot, 512MB, 16, $false)
        $ready = Wait-Ready $readyPath
        $child = Get-ExactProcess -ProcessId $ready.pid -Birth $ready.birth
        $grand = Get-ExactProcess -ProcessId $ready.grandchildPid -Birth $ready.grandchildBirth
        if ($Mode -eq 'duplicate') {
            $duplicate = [CodexTrustBridge.OwnedProcess]::Start($Launcher, [string[]]@($pwsh, $runtime, $config), $testRoot, 256MB, 8, $false)
            if (-not $duplicate.WaitForExit(10000) -or $duplicate.ExitCode -ne 17) { throw 'Duplicate launcher was not rejected with exit 17.' }
            if ($child.HasExited -or $owned.HasExited) { throw 'Duplicate launch interrupted the existing instance.' }
        }
        if ($Mode -ne 'normal') {
            $launcherProcess = Get-ExactProcess -ProcessId $owned.Id -Birth $owned.CreationFileTimeUtc.ToString()
            $launcherProcess.Kill() # Exact retained process handle, never a name match.
        }
        if ($Mode -eq 'legacy-control') {
            $residual = -not $child.WaitForExit(500)
            if (-not $residual) { throw 'Legacy control did not reproduce the expected residual process.' }
            $records.Add(@{ mode = $Mode; legacyResidualObserved = $true; childPid = $child.Id; startedAtUtc = $started.ToString('o') })
        }
        else {
            if (-not $child.WaitForExit(10000) -or -not $grand.WaitForExit(10000) -or -not $owned.WaitForExit(10000)) {
                throw "Residual process after $Mode."
            }
            if ($Mode -eq 'normal' -and $owned.ExitCode -ne 0) { throw 'Normal launcher exit was not successful.' }
            if (@($owned.GetProcessIds()).Count -ne 0) { throw 'Owning job still contains a process.' }
            $records.Add(@{ mode = $Mode; residual = $false; childPid = $child.Id; grandchildPid = $grand.Id; startedAtUtc = $started.ToString('o') })
        }
    }
    finally {
        foreach ($job in @($duplicate, $owned)) {
            if ($null -ne $job) {
                try { if (-not $job.StopAndWait(10000)) { throw 'Test-owned job cleanup is uncertain.' } }
                finally { $job.Dispose() }
            }
        }
        foreach ($p in @($launcherProcess, $child, $grand)) { if ($null -ne $p) { $p.Dispose() } }
    }
}

# Reproduce the v0.2.1 lifecycle defect without invoking the bridge's real
# runtime, configuration, UIA, Scheduled Task, or unrelated process tree.
$legacySource = Join-Path $testRoot 'LegacyLauncher.cs'
$legacyText = @(& git -C $root show 'v0.2.1:src/CodexWorktreeTrustBridge.Launcher.cs')
if ($LASTEXITCODE) { throw 'Cannot read the pinned legacy launcher source.' }
[IO.File]::WriteAllLines($legacySource, $legacyText, [Text.UTF8Encoding]::new($false))
$legacyLauncher = Join-Path $testRoot 'LegacyLauncher.exe'
& $compiler /nologo /target:winexe /optimize+ "/out:$legacyLauncher" $legacySource
if ($LASTEXITCODE) { throw 'Legacy control build failed.' }
Invoke-LauncherCase -Launcher $legacyLauncher -Mode legacy-control -Index 0
for ($i = 0; $i -lt 25; $i++) {
    $mode = if ($i % 5 -eq 0) { 'duplicate' } elseif ($i % 2 -eq 0) { 'normal' } else { 'launcher-crash' }
    Invoke-LauncherCase -Launcher $newLauncher -Mode $mode -Index $i
}

# A deliberately suspended runtime must already belong to the kill-on-close
# job. Terminating its creator before Resume must not leave a suspended orphan.
$creatorSource = Join-Path $testRoot 'SuspendedCreator.cs'
@'
using System;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;
using CodexTrustBridge;
internal static class SuspendedCreator {
    static int Main(string[] args) {
        using (OwnedProcess child = OwnedProcess.Start(args[0], new string[] { "-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 60" }, Path.GetDirectoryName(args[1]), 256L*1024*1024, 4, true)) {
            File.WriteAllText(args[1], new JavaScriptSerializer().Serialize(new { pid = child.Id, birth = child.CreationFileTimeUtc.ToString() }));
            Thread.Sleep(60000);
        }
        return 0;
    }
}
'@ | Set-Content -LiteralPath $creatorSource -Encoding utf8NoBOM
Copy-Item -LiteralPath (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll') -Destination $testRoot
$creator = Join-Path $testRoot 'SuspendedCreator.exe'
& $compiler /nologo /target:winexe /optimize+ "/out:$creator" "/reference:$(Join-Path $testRoot 'CodexWorktreeTrustBridge.Native.dll')" /reference:System.Web.Extensions.dll $creatorSource
if ($LASTEXITCODE) { throw 'Suspended-creator fixture build failed.' }
for ($i = 0; $i -lt 10; $i++) {
    $readyPath = Join-Path $testRoot "suspended-$i.ready"
    $owned = $null; $p = $null; $child = $null
    try {
        $owned = [CodexTrustBridge.OwnedProcess]::Start($creator, [string[]]@($pwsh, $readyPath), $testRoot, 384MB, 8, $false)
        $ready = Wait-Ready $readyPath
        $child = Get-ExactProcess -ProcessId $ready.pid -Birth $ready.birth
        $p = Get-ExactProcess -ProcessId $owned.Id -Birth $owned.CreationFileTimeUtc.ToString()
        $p.Kill()
        if (-not $child.WaitForExit(10000)) { throw 'Suspended child survived its owner.' }
        $records.Add(@{ mode = 'pre-resume-owner-crash'; childPid = $child.Id; residual = $false })
    }
    finally {
        if ($null -ne $owned) { try { if (-not $owned.StopAndWait(10000)) { throw 'Suspended test cleanup uncertain.' } } finally { $owned.Dispose() } }
        foreach ($item in @($child, $p)) { if ($null -ne $item) { $item.Dispose() } }
    }
}
$result = @{ passed = $true; legacyControl = 'residual reproduced and then removed by the test-owned job'
    newLauncherCycles = 25; preResumeCrashCycles = 10; cases = $records.ToArray(); evidenceDirectory = $testRoot }
$json = $result | ConvertTo-Json -Depth 7
[IO.File]::WriteAllText((Join-Path $testRoot 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
$json
