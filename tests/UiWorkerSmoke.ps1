[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root '.artifacts\bin'
Add-Type -Path (Join-Path $bin 'CodexWorktreeTrustBridge.Native.dll')
$testRoot = Join-Path $root ('.artifacts\ui-worker-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $testRoot 'fixture'
$StateDirectory = $testRoot
New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
$fixtureExe = & (Join-Path $PSScriptRoot 'Build-DialogFixture.ps1') -OutputDirectory $fixtureDirectory
$fixtureConfig = Join-Path $fixtureDirectory 'fixture.json'
$allowed = Join-Path $testRoot 'authorized-test-folder'
New-Item -ItemType Directory -Path $allowed -Force | Out-Null
@{ folder = $allowed; seconds = 180; noise = 256 } | ConvertTo-Json | Set-Content -LiteralPath $fixtureConfig -Encoding utf8NoBOM
function Write-BridgeLog {
    param([string]$Event, [hashtable]$Data)
    @{ event = $Event; data = $Data; utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath (Join-Path $testRoot 'worker.jsonl') -Encoding utf8
}
. (Join-Path $bin 'CodexWorktreeTrustBridge.Supervision.ps1')
$fixture = $null
$cases = [Collections.Generic.List[string]]::new()
$commandSequence = 0

function Read-Fixture {
    $path = Join-Path $fixtureDirectory 'status.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $stream = $null; $reader = $null
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
    }
    catch [IO.IOException] { return $null }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}
function Wait-Fixture {
    param([scriptblock]$Condition)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 10) {
        if ($fixture.HasExited) { throw "Controlled fixture exited: $($fixture.ExitCode)" }
        $status = Read-Fixture
        if ($status -and (& $Condition $status)) { return $status }
        Start-Sleep -Milliseconds 50
    }
    throw 'Controlled fixture did not satisfy the condition before its deadline.'
}
function Set-FixtureMode {
    param([string]$Mode)
    $script:commandSequence++
    Write-AtomicBridgeJson -Path (Join-Path $fixtureDirectory 'command.json') -Value @{ sequence = $commandSequence; mode = $Mode }
    [void](Wait-Fixture { param($s) $s.sequence -eq $commandSequence })
    Start-Sleep -Milliseconds 100
}
try {
    $fixture = [CodexTrustBridge.OwnedProcess]::Start($fixtureExe, [string[]]@($fixtureConfig), $fixtureDirectory, 192MB, 8, $false)
    $status = Wait-Fixture { param($s) $s.hwnd -ne 0 }
    if ($status.pid -ne $fixture.Id -or $status.createdFileTimeUtc -ne $fixture.CreationFileTimeUtc.ToString()) { throw 'Fixture identity mismatch.' }
    $target = @{ pid = $status.pid; createdFileTimeUtc = $status.createdFileTimeUtc; hwnd = $status.hwnd; executable = $status.executable }
    $reply = Invoke-UiRequest -Operation scan -Roots @($target)
    if (-not $reply.ok -or @($reply.candidates).Count -ne 1) { throw "Expected one controlled trust candidate: $($reply | ConvertTo-Json -Depth 8 -Compress)" }
    if ($reply.apartment -ne 'MTA') { throw 'Worker did not run UIA in MTA.' }
    $proposal = $reply.candidates[0]
    if ($proposal.folder -ne $allowed.ToLowerInvariant()) { throw 'Observed folder differs from the authorized fixture folder.' }
    $cases.Add('bounded MTA scan with background controls')
    $validated = Invoke-UiRequest -Operation validate -Token $proposal.token
    if (-not $validated.ok) { throw "Proposal validation failed: $($validated.error)" }
    $invoked = Invoke-UiRequest -Operation invoke -Token $proposal.token -Action approve
    if (-not $invoked.ok) { throw "Controlled approval failed: $($invoked.error)" }
    [void](Wait-Fixture { param($s) $s.approved -eq 1 })
    $repeat = Invoke-UiRequest -Operation invoke -Token $proposal.token -Action approve
    if ($repeat.ok) { throw 'Consumed token was accepted again.' }
    $cases.Add('single-use action token')

    $reply = Invoke-UiRequest -Operation scan -Roots @($target)
    $proposal = $reply.candidates[0]
    Set-FixtureMode duplicate-trust
    $stale = Invoke-UiRequest -Operation invoke -Token $proposal.token -Action cancel
    if ($stale.ok) { throw 'Changed dialog was invoked using a stale proposal.' }
    $cases.Add('changed-dialog rejection before invocation')
    foreach ($mode in @('duplicate-trust', 'two-paths', 'no-cancel', 'disabled-trust')) {
        Set-FixtureMode $mode
        $reply = Invoke-UiRequest -Operation scan -Roots @($target)
        if (-not $reply.ok -or @($reply.candidates).Count -ne 0 -or @($reply.seenDialogs).Count -ne 1) {
            throw "Ambiguous fixture $mode was not retained as seen-but-not-actionable: $($reply | ConvertTo-Json -Compress -Depth 6)"
        }
        $cases.Add("refused $mode")
    }
    Set-FixtureMode valid
    $wrong = $target.Clone(); $wrong.createdFileTimeUtc = '0'
    $reply = Invoke-UiRequest -Operation scan -Roots @($wrong)
    if ($reply.ok) { throw 'Wrong process birth identity was accepted.' }
    $cases.Add('process birth identity rejection')
    $reply = Invoke-UiRequest -Operation scan -Roots @($target)
    $token = $reply.candidates[0].token
    Stop-UiWorker
    $reply = Invoke-UiRequest -Operation validate -Token $token
    if ($reply.ok) { throw 'Old worker token survived a worker generation change.' }
    $cases.Add('cross-generation stale token rejection')
    Set-FixtureMode closed
    $reply = Invoke-UiRequest -Operation scan -Roots @($target)
    if (-not $reply.ok -or @($reply.candidates).Count -ne 0 -or @($reply.seenDialogs).Count -ne 0) { throw 'Closed dialog remained actionable.' }
    $cases.Add('closed-window-element lifecycle')
    $status = Read-Fixture
    if ($status.approved -ne 1 -or $status.cancelled -ne 0) { throw 'An unrequested action was performed on the controlled fixture.' }

    $badFrame = [IO.MemoryStream]::new([BitConverter]::GetBytes([int]65537))
    $rejected = $false
    try { [void][CodexTrustBridge.Frames]::ReadAsync($badFrame).GetAwaiter().GetResult() }
    catch { $rejected = $true }
    finally { $badFrame.Dispose() }
    if (-not $rejected) { throw 'Oversize IPC frame was accepted.' }
    $cases.Add('bounded frame length')
    $result = @{ passed = $true; cases = $cases.ToArray(); caseCount = $cases.Count
        workerSample = $Ui.LastProcessSample; workerMetrics = $Ui.LastWorkerMetrics
        fixtureApprovals = $status.approved; fixtureCancellations = $status.cancelled; evidenceDirectory = $testRoot }
    $json = $result | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $testRoot 'receipt.json'), $json, [Text.UTF8Encoding]::new($false))
    $json
}
finally {
    Stop-UiWorker
    if ($null -ne $fixture) { try { if (-not $fixture.StopAndWait(10000)) { throw 'Controlled UI fixture cleanup is uncertain.' } } finally { $fixture.Dispose() } }
}
