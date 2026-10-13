[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root '.artifacts\bin'
Add-Type -Path (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll')
$testRoot = Join-Path $root ('.artifacts\ui-memory-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $testRoot 'fixture'
$StateDirectory = $testRoot
New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
$fixtureExe = & (Join-Path $PSScriptRoot 'Build-DialogFixture.ps1') -OutputDirectory $fixtureDirectory
$fixtureConfig = Join-Path $fixtureDirectory 'fixture.json'
$allowed = Join-Path $testRoot 'authorized-observation-only-folder'
New-Item -ItemType Directory -Path $allowed -Force | Out-Null
$secondsPerVersion = 120
$pollMs = 750
@{ folder = $allowed; seconds = 300; noise = 600 } | ConvertTo-Json | Set-Content -LiteralPath $fixtureConfig -Encoding utf8NoBOM
function Write-BridgeLog {
    param([string]$Event, [hashtable]$Data)
    @{ event = $Event; data = $Data; utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath (Join-Path $testRoot 'supervisor.jsonl') -Encoding utf8
}
. (Join-Path $bin 'CodexWorktreeTrustBridge.Supervision.ps1')
$fixture = $null; $legacy = $null
$oldSamples = [Collections.Generic.List[object]]::new()
$newSamples = [Collections.Generic.List[object]]::new()
$oldAborted = $null
$probe = Join-Path $testRoot 'LegacyStaReadOnlyProbe.ps1'
# This intentionally reproduces only the v0.2.1 scan shape and STA binding.
# Roots are a controlled HWND rather than a process-name search. There are no
# configuration writes, InvokePattern calls, or live business-window queries.
@'
param([string]$InputPath, [string]$OutputPath, [int]$Seconds = 120, [int]$PollMs = 750)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
trap {
    try { [IO.File]::WriteAllText(($OutputPath + '.error.json'), (@{ error = $_.Exception.ToString(); stack = $_.ScriptStackTrace } | ConvertTo-Json)) } catch { }
    exit 1
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$target = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
$identity = [Diagnostics.Process]::GetProcessById($target.pid)
try {
    if ($identity.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $target.createdFileTimeUtc) { throw 'Fixture identity changed.' }
}
finally { $identity.Dispose() }
function Observe-LegacyScan {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new([long]$target.hwnd))
    $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $candidates = [Collections.Generic.List[object]]::new()
    $seen = @{}
    for ($i = 0; $i -lt $elements.Count; $i++) {
        $element = $elements.Item($i)
        if ($element.Current.ControlType -ne [System.Windows.Automation.ControlType]::ListItem) { continue }
        $name = $element.Current.Name
        if (-not [IO.Path]::IsPathFullyQualified($name)) { continue }
        $parent = $element
        while ($null -ne $parent) {
            if ($parent.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $parent.Current.ClassName -like '*codex-dialog*') {
                $key = $name + '|' + ($parent.GetRuntimeId() -join '.')
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $candidates.Add(@{ Folder = $name; Dialog = $parent }) }
                break
            }
            $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($parent)
        }
    }
    return @{ elements = $elements.Count; candidateCount = $candidates.Count }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$scans = 0
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
    $scan = Observe-LegacyScan
    $scans++
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $sample = @{ elapsedSeconds = $clock.Elapsed.TotalSeconds; timestampUtc = [DateTime]::UtcNow.ToString('o')
            pid = $PID; createdFileTimeUtc = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
            privateBytes = $self.PrivateMemorySize64; workingSetBytes = $self.WorkingSet64; handles = $self.HandleCount
            managedHeapBytes = [GC]::GetTotalMemory($false); gen0 = [GC]::CollectionCount(0); gen1 = [GC]::CollectionCount(1); gen2 = [GC]::CollectionCount(2)
            scanCount = $scans; elements = $scan.elements; candidates = $scan.candidateCount; apartment = [Threading.Thread]::CurrentThread.GetApartmentState().ToString() }
        Add-Content -LiteralPath $OutputPath -Value ($sample | ConvertTo-Json -Compress) -Encoding utf8
    }
    finally { $self.Dispose() }
    Start-Sleep -Milliseconds $PollMs
}
'@ | Set-Content -LiteralPath $probe -Encoding utf8NoBOM

function Summarize-Samples {
    param([object[]]$Samples)
    $usable = @($Samples | Where-Object { $_.elapsedSeconds -ge 30 })
    if ($usable.Count -lt 10) { return @{ usableSamples = $usable.Count; result = 'insufficient post-warm-up samples' } }
    $meanX = ($usable | Measure-Object -Property elapsedSeconds -Average).Average
    $meanMemory = ($usable | Measure-Object -Property privateBytes -Average).Average
    $meanHandles = ($usable | Measure-Object -Property handles -Average).Average
    $variance = 0.0; $memoryCovariance = 0.0; $handleCovariance = 0.0
    foreach ($sample in $usable) {
        $x = $sample.elapsedSeconds - $meanX
        $variance += $x * $x
        $memoryCovariance += $x * ($sample.privateBytes - $meanMemory)
        $handleCovariance += $x * ($sample.handles - $meanHandles)
    }
    return @{
        sampleCount = $Samples.Count; usableSamples = $usable.Count; warmupSeconds = 30
        durationSeconds = $Samples[-1].elapsedSeconds
        privatePeakMiB = ($Samples | Measure-Object -Property privateBytes -Maximum).Maximum / 1MB
        workingSetPeakMiB = ($Samples | Measure-Object -Property workingSetBytes -Maximum).Maximum / 1MB
        handlesPeak = ($Samples | Measure-Object -Property handles -Maximum).Maximum
        privateGrowthMiBPerMinute = $memoryCovariance / $variance * 60 / 1MB
        handlesGrowthPerMinute = $handleCovariance / $variance * 60
        managedHeapFirstMiB = $usable[0].managedHeapBytes / 1MB
        managedHeapLastMiB = $usable[-1].managedHeapBytes / 1MB
        completedScans = $Samples[-1].scanCount
    }
}

$sanityRows = @(0..19 | ForEach-Object { @{
    elapsedSeconds = 30.0 + $_; privateBytes = 100MB + $_ * 1MB / 60
    workingSetBytes = 50MB; handles = 100; managedHeapBytes = 10MB; scanCount = $_ + 1
} })
$sanity = Summarize-Samples -Samples $sanityRows
if ([Math]::Abs($sanity.privateGrowthMiBPerMinute - 1.0) -gt 0.00001 -or $sanity.handlesGrowthPerMinute -ne 0) {
    throw 'Resource-statistics sanity check failed before the experiment.'
}

try {
    $fixture = [CodexTrustBridge.OwnedProcess]::Start($fixtureExe, [string[]]@($fixtureConfig), $fixtureDirectory, 192MB, 8, $false)
    $statusPath = Join-Path $fixtureDirectory 'status.json'
    $readyClock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $statusPath)) {
        if ($fixture.HasExited -or $readyClock.Elapsed.TotalSeconds -gt 10) { throw 'Controlled fixture did not start.' }
        Start-Sleep -Milliseconds 50
    }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -AsHashtable
    $target = @{ pid = $status.pid; createdFileTimeUtc = $status.createdFileTimeUtc; hwnd = $status.hwnd; executable = $status.executable }
    $inputPath = Join-Path $testRoot 'target.json'
    $target | ConvertTo-Json | Set-Content -LiteralPath $inputPath -Encoding utf8NoBOM
    $oldLog = Join-Path $testRoot 'legacy-managed.jsonl'
    $pwsh = (Get-Command pwsh.exe).Source
    $legacy = [CodexTrustBridge.OwnedProcess]::Start($pwsh,
        [string[]]@('-STA', '-NoLogo', '-NoProfile', '-File', $probe, '-InputPath', $inputPath, '-OutputPath', $oldLog,
            '-Seconds', $secondsPerVersion.ToString(), '-PollMs', $pollMs.ToString()), $testRoot, 256MB, 8, $false)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not $legacy.HasExited) {
        $sample = $legacy.Sample()
        @{ elapsedSeconds = $clock.Elapsed.TotalSeconds; sample = $sample } | ConvertTo-Json -Depth 5 -Compress |
            Add-Content -LiteralPath (Join-Path $testRoot 'legacy-external.jsonl') -Encoding utf8
        if ($sample.PrivateBytes -gt 256MB -or $clock.Elapsed.TotalSeconds -gt $secondsPerVersion + 15) {
            $oldAborted = 'Legacy resource/deadline guard triggered.'
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ($legacy.HasExited -and $legacy.ExitCode -ne 0) { $oldAborted = "Legacy observer exited $($legacy.ExitCode); see the probe error receipt. Cause is not inferred from exit code alone." }
    if (-not $legacy.StopAndWait(10000)) { throw 'Legacy observer cleanup is uncertain.' }
    $legacy.Dispose(); $legacy = $null
    if (Test-Path -LiteralPath $oldLog) {
        foreach ($line in Get-Content -LiteralPath $oldLog) { $oldSamples.Add(($line | ConvertFrom-Json -AsHashtable)) }
    }
    if ($oldSamples.Count -lt 10) { throw 'Legacy observer produced insufficient evidence; do not claim an old/new comparison.' }

    $clock.Restart()
    while ($clock.Elapsed.TotalSeconds -lt $secondsPerVersion) {
        $reply = Invoke-UiRequest -Operation scan -Roots @($target)
        if (-not $reply.ok -or @($reply.candidates).Count -ne 1) { throw "Candidate scan failed: $($reply | ConvertTo-Json -Depth 6 -Compress)" }
        $sample = $Ui.Process.Sample()
        $row = @{ elapsedSeconds = $clock.Elapsed.TotalSeconds; timestampUtc = [DateTime]::UtcNow.ToString('o')
            pid = $sample.ProcessId; createdFileTimeUtc = $sample.CreationFileTimeUtc.ToString()
            privateBytes = $sample.PrivateBytes; workingSetBytes = $sample.WorkingSetBytes; handles = $sample.Handles
            managedHeapBytes = $reply.managedHeapBytes; gen0 = $reply.gen0Collections; gen1 = $reply.gen1Collections; gen2 = $reply.gen2Collections
            scanCount = $reply.scanCount; visited = $reply.visited; candidates = @($reply.candidates).Count; apartment = $reply.apartment }
        $newSamples.Add($row)
        Add-Content -LiteralPath (Join-Path $testRoot 'candidate.jsonl') -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
        Start-Sleep -Milliseconds $pollMs
    }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -AsHashtable
    if ($status.approved -ne 0 -or $status.cancelled -ne 0) { throw 'Observation-only benchmark caused a UI action.' }
    $result = @{
        experimentCompleted = $true; sustainedAcceptance = 'NOT_RUN'; sourceOrDeploymentAcceptance = $false
        workload = 'same controlled HWND, 600 background elements, one trust dialog, observation only'
        requestedSecondsPerVersion = $secondsPerVersion; requestedPollMilliseconds = $pollMs
        baseline = 'instrumented v0.2.1 STA full-descendants UIA scan path; not the unmodified whole runtime; no Git/reconcile'
        legacyAbort = $oldAborted; legacy = Summarize-Samples -Samples $oldSamples.ToArray()
        candidate = Summarize-Samples -Samples $newSamples.ToArray()
        candidateManifestSha256 = (Get-FileHash -LiteralPath (Join-Path $bin 'manifest.json') -Algorithm SHA256).Hash
        legacyProbeSha256 = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash
        evidenceDirectory = $testRoot
    }
    $json = $result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $testRoot 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
    $json
}
finally {
    Stop-UiWorker
    foreach ($job in @($legacy, $fixture)) {
        if ($null -ne $job) { try { if (-not $job.StopAndWait(10000)) { throw 'Memory experiment cleanup uncertain.' } } finally { $job.Dispose() } }
    }
}
