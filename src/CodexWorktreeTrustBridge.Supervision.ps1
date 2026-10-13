# Loaded by the runtime after its policy/configuration functions. No UIA types
# are loaded into the long-lived PowerShell authority process.
$script:UiClock = [Diagnostics.Stopwatch]::StartNew()
$script:Ui = @{
    State = 'STARTING'; Reason = $null; Process = $null; Pipe = $null
    Failures = 0; Generation = 0; ScanCount = 0; NextScan = 0.0; NextAttempt = 0.0
    LastScanUtc = $null; LastWorkerMetrics = $null; LastProcessSample = $null
    SoftBytes = 256MB; HardBytes = 384MB; TimeoutMs = 10000; RestartLimit = 3
}
$script:UiAttempts = @{}
$script:UiRejectionCooldown = @{}
$script:UiAttemptsPath = Join-Path $StateDirectory 'codex-worktree-trust-bridge.ui-actions.json'
$script:LastHealthAt = -30.0

function Write-AtomicBridgeJson {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
        for ($attempt = 0; ; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $Path) }
                break
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                # Retry only known pre-mutation sharing/lock failures, never an
                # uncertain replacement result. The destination stays intact.
                if ($attempt -ge 4 -or ($cause.HResult -band 65535) -notin @(32, 33) -or
                    -not (Test-Path -LiteralPath $temporary)) { throw }
                Start-Sleep -Milliseconds (25 * [Math]::Pow(2, $attempt))
            }
        }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Save-UiAttempts {
    if ($UiAttempts.Count -gt 256) { throw 'Action ledger capacity exceeded; manual reconciliation is required.' }
    $entries = @($UiAttempts.GetEnumerator() | ForEach-Object { $_.Value })
    $payload = @{
        schema = 'codex-worktree-trust-bridge.ui-actions'; version = 1; entries = $entries
    }
    if ([Text.Encoding]::UTF8.GetByteCount(($payload | ConvertTo-Json -Depth 12 -Compress)) -gt 65536) {
        throw 'Action ledger exceeds its byte budget; no UI action may follow this failed durable intent.'
    }
    Write-AtomicBridgeJson -Path $UiAttemptsPath -Value $payload
}

function Initialize-UiSupervisor {
    if (-not $EnableUiAutoApprove) { $Ui.State = 'DISABLED'; return }
    try {
        if ($env:CODEX_WORKTREE_TRUST_BRIDGE_LIFECYCLE -ne 'atomic-job-list') {
            throw 'UI automation requires the owning v0.2.2 launcher; direct unsupervised UI execution is refused.'
        }
        $native = Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.Native.dll'
        if (-not (Test-Path -LiteralPath $native -PathType Leaf)) { throw 'Native ownership library is absent.' }
        if (-not ('CodexTrustBridge.OwnedProcess' -as [type])) { Add-Type -Path $native }
        if (Test-Path -LiteralPath $UiAttemptsPath -PathType Leaf) {
            if ((Get-Item -LiteralPath $UiAttemptsPath).Length -gt 65536) { throw 'Action ledger exceeds its size budget.' }
            $saved = Get-Content -LiteralPath $UiAttemptsPath -Raw | ConvertFrom-Json -AsHashtable
            if ($saved.schema -ne 'codex-worktree-trust-bridge.ui-actions' -or $saved.version -ne 1 -or @($saved.entries).Count -gt 256) {
                throw 'Action ledger is invalid; do not discard uncertain authorization history.'
            }
            foreach ($entry in @($saved.entries)) {
                if (-not $entry.dialogKey -or -not $entry.rootPid -or -not $entry.createdFileTimeUtc) { throw 'Invalid action identity.' }
                $UiAttempts[[string]$entry.dialogKey] = $entry
            }
        }
        $Ui.State = 'IDLE'
    }
    catch {
        $Ui.State = 'CIRCUIT_OPEN'
        $Ui.Reason = $_.Exception.Message
        Write-BridgeLog -Event 'UI_DISABLED_UNSAFE_START' -Data @{ reason = $Ui.Reason }
    }
}

function Get-VerifiedCodexTargets {
    $targets = [Collections.Generic.List[object]]::new()
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try { $session = $self.SessionId } finally { $self.Dispose() }
    foreach ($process in @(Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            if ($process.HasExited -or $process.SessionId -ne $session -or $process.MainWindowHandle -eq 0) { continue }
            # Full-trust desktop children may lack a token package identity.
            # Require an OS-registered Store package and its exact executable
            # path as well; never accept a name or WindowsApps prefix alone.
            $family = [CodexTrustBridge.PackageIdentity]::GetFamily($process)
            if ($family -and $family -ne 'OpenAI.Codex_2p2nqsd0c76g0') { throw "Unexpected window process package family: $($process.Id)" }
            $registration = [CodexTrustBridge.PackageIdentity]::VerifyRegisteredStoreExecutable($process.MainModule.FileName, 'OpenAI.Codex_2p2nqsd0c76g0')
            if ($null -eq $registration) { throw "Unverified Codex window registration: $($process.Id)" }
            if ($targets.Count -eq 16) { throw 'Too many target windows.' }
            $targets.Add(@{
                pid = $process.Id; createdFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
                hwnd = $process.MainWindowHandle.ToInt64(); executable = $process.MainModule.FileName
            })
        }
        finally { $process.Dispose() }
    }
    return $targets.ToArray()
}

function Stop-UiWorker {
    # Closing the pipe also releases any outstanding asynchronous read/write.
    if ($null -ne $Ui.Pipe) { $Ui.Pipe.Dispose(); $Ui.Pipe = $null }
    if ($null -ne $Ui.Process) {
        $owned = $Ui.Process
        $Ui.Process = $null
        try {
            if (-not $owned.StopAndWait(10000)) {
                $Ui.State = 'CLEANUP_UNCERTAIN'
                throw 'UI job did not become empty within the cleanup deadline.'
            }
        }
        finally { $owned.Dispose() }
    }
}

function Register-UiFault {
    param([string]$Reason)
    $Ui.Failures++
    $Ui.Reason = $Reason
    try { Stop-UiWorker }
    catch { $Ui.State = 'CLEANUP_UNCERTAIN'; $Ui.Reason += ' | ' + $_.Exception.Message }
    if ($Ui.State -ne 'CLEANUP_UNCERTAIN') {
        $Ui.State = if ($Ui.Failures -ge $Ui.RestartLimit) { 'CIRCUIT_OPEN' } else { 'DEGRADED' }
    }
    $Ui.NextAttempt = $UiClock.Elapsed.TotalSeconds + [Math]::Min(60, 5 * [Math]::Pow(2, $Ui.Failures - 1))
    Write-BridgeLog -Event 'UI_WORKER_FAULT' -Data @{
        reason = $Ui.Reason; state = $Ui.State; failureCount = $Ui.Failures; generation = $Ui.Generation
        lastSample = $Ui.LastProcessSample; recovery = 'bounded worker-only recovery; no action replay'
    }
}

function Wait-UiTask {
    param([Threading.Tasks.Task]$Task, [double]$DeadlineSeconds = ($UiClock.Elapsed.TotalSeconds + $Ui.TimeoutMs / 1000.0))
    do {
        if ($UiClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) { throw 'UI worker request exceeded its end-to-end deadline.' }
        if ($null -ne $Ui.Process) {
            if ($Ui.Process.HasExited) { throw "UI worker exited ($($Ui.Process.ExitCode))." }
            $sample = $Ui.Process.Sample()
            $Ui.LastProcessSample = $sample
            if ($sample.PrivateBytes -gt $Ui.SoftBytes) { throw "UI worker soft memory budget exceeded: $($sample.PrivateBytes)." }
            if ($sample.Handles -gt 1000) { throw "UI worker handle budget exceeded: $($sample.Handles)." }
        }
        if ($Task.IsCompleted) { return $Task.GetAwaiter().GetResult() }
        [Threading.Thread]::Sleep(100)
    } while ($true)
}

function Start-UiWorker {
    param([double]$DeadlineSeconds = ($UiClock.Elapsed.TotalSeconds + $Ui.TimeoutMs / 1000.0))
    if ($null -ne $Ui.Process) { return }
    $worker = Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.UiWorker.exe'
    if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { throw 'UI worker executable is absent.' }
    $name = 'CodexTrustBridge-' + [guid]::NewGuid().ToString('N')
    $options = [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly
    $Ui.Pipe = [IO.Pipes.NamedPipeServerStream]::new($name, [IO.Pipes.PipeDirection]::InOut, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte, $options, 65536, 65536)
    $connection = $Ui.Pipe.WaitForConnectionAsync()
    $Ui.Process = [CodexTrustBridge.OwnedProcess]::Start($worker, [string[]]@($name), $PSScriptRoot, $Ui.HardBytes, 8, $false)
    $Ui.Generation++
    [void](Wait-UiTask -Task $connection -DeadlineSeconds $DeadlineSeconds)
    $peer = [CodexTrustBridge.Frames]::ClientProcessId($Ui.Pipe.SafePipeHandle.DangerousGetHandle())
    if ($peer -ne $Ui.Process.Id) { throw 'UI pipe peer does not match the owned worker process.' }
    Write-BridgeLog -Event 'UI_WORKER_STARTED' -Data @{
        workerPid = $Ui.Process.Id; workerCreationFileTimeUtc = $Ui.Process.CreationFileTimeUtc.ToString()
        generation = $Ui.Generation; softBytes = $Ui.SoftBytes; hardBytes = $Ui.HardBytes
        timeoutMs = $Ui.TimeoutMs; memoryBudgetStatus = 'provisional until representative acceptance'
    }
}

function Invoke-UiRequest {
    param([string]$Operation, [object[]]$Roots = @(), [string]$Token, [string]$Action)
    $deadline = $UiClock.Elapsed.TotalSeconds + $Ui.TimeoutMs / 1000.0
    Start-UiWorker -DeadlineSeconds $deadline
    $id = [guid]::NewGuid().ToString('N')
    $request = @{ version = 1; id = $id; operation = $Operation; roots = $Roots; token = $Token; action = $Action }
    $json = $request | ConvertTo-Json -Compress -Depth 8
    [void](Wait-UiTask -Task ([CodexTrustBridge.Frames]::WriteAsync($Ui.Pipe, $json)) -DeadlineSeconds $deadline)
    $responseText = Wait-UiTask -Task ([CodexTrustBridge.Frames]::ReadAsync($Ui.Pipe)) -DeadlineSeconds $deadline
    $reply = $responseText | ConvertFrom-Json -AsHashtable
    if ($reply['version'] -ne 1 -or $reply['id'] -cne $id -or $reply['ok'] -isnot [bool]) { throw 'UI worker response identity is invalid.' }
    $Ui.LastWorkerMetrics = @{
        managedHeapBytes = $reply['managedHeapBytes']; gen0 = $reply['gen0Collections']
        gen1 = $reply['gen1Collections']; gen2 = $reply['gen2Collections']; apartment = $reply['apartment']
        cachedTokens = $reply['cachedTokens']; visited = $reply['visited']
    }
    return $reply
}

function Remove-ClosedUiAttempts {
    param([object[]]$Roots, [string[]]$Seen)
    $changed = $false
    foreach ($key in @($UiAttempts.Keys)) {
        $entry = $UiAttempts[$key]
        $observedRoot = @($Roots | Where-Object { $_.pid -eq $entry.rootPid -and $_.createdFileTimeUtc -eq $entry.createdFileTimeUtc })
        $gone = $observedRoot.Count -gt 0 -and $key -notin $Seen
        if (-not $gone -and $observedRoot.Count -eq 0) {
            $process = $null
            try {
                $process = [Diagnostics.Process]::GetProcessById([int]$entry.rootPid)
                $gone = $process.HasExited -or $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $entry.createdFileTimeUtc
            }
            catch [ArgumentException] { $gone = $true }
            catch { $gone = $false } # Access failure is not evidence of disappearance.
            finally { if ($null -ne $process) { $process.Dispose() } }
        }
        if ($gone) { $UiAttempts.Remove($key); $changed = $true }
    }
    if ($changed) { Save-UiAttempts }
}

function Invoke-UiScan {
    if (-not $EnableUiAutoApprove -or $Ui.State -in @('DISABLED', 'CIRCUIT_OPEN', 'CLEANUP_UNCERTAIN', 'RESOURCE_DEGRADED', 'STOPPED')) { return 0 }
    if ($UiClock.Elapsed.TotalSeconds -lt [Math]::Max($Ui.NextScan, $Ui.NextAttempt)) { return 0 }
    try {
        $roots = @(Get-VerifiedCodexTargets)
        if (-not $roots.Count) {
            # No UIA calls and no clearing uncertain actions just because a window
            # has no visible main handle. A minimized dialog may still exist.
            if ($null -ne $Ui.Process) {
                Stop-UiWorker
                Write-BridgeLog -Event 'UI_WORKER_IDLE_STOP' -Data @{ reason = 'No verified target window; durable action intents are retained.'; generation = $Ui.Generation }
            }
            $Ui.State = 'IDLE'
            $Ui.NextScan = $UiClock.Elapsed.TotalSeconds + 5
            Remove-ClosedUiAttempts -Roots @() -Seen @()
            return 0
        }
        $reply = Invoke-UiRequest -Operation scan -Roots $roots
        if (-not $reply.ok) { throw "UI scan rejected: $($reply.error)" }
        $candidates = @($reply.candidates)
        $seen = @($reply.seenDialogs)
        $rejections = @($reply.rejectedDialogs)
        if ($candidates.Count -gt 16 -or $seen.Count -gt 64 -or $rejections.Count -gt 64) { throw 'UI scan response exceeds declared bounds.' }
        $Ui.State = 'HEALTHY'
        $Ui.Reason = $null
        $Ui.ScanCount++
        $Ui.LastScanUtc = [DateTime]::UtcNow.ToString('o')
        $Ui.NextScan = $UiClock.Elapsed.TotalSeconds + $(if ($candidates.Count) { $UiPollIntervalMs / 1000.0 } else { 2.0 })
        Remove-ClosedUiAttempts -Roots $roots -Seen $seen
        foreach ($dictionary in @($RefusalCooldown, $DenialFirstSeen, $UiRejectionCooldown)) {
            foreach ($key in @($dictionary.Keys)) { if ($key -notin $seen) { $dictionary.Remove($key) } }
        }
        foreach ($rejection in $rejections) {
            $key = [string]$rejection.dialogKey
            if (-not $key -or $key -notin $seen -or ([string]$rejection.reason).Length -gt 512) { throw 'Malformed rejection diagnostic.' }
            $now = $UiClock.Elapsed.TotalSeconds
            if (-not $UiRejectionCooldown.ContainsKey($key) -or $now - $UiRejectionCooldown[$key] -ge 30) {
                Write-BridgeLog -Event 'DIALOG_ISOLATED' -Data @{ dialogIdentity = $key; reason = $rejection.reason }
                $UiRejectionCooldown[$key] = $now
            }
        }
        foreach ($candidate in $candidates) {
            $key = [string]$candidate.dialogKey
            if (-not $key -or $key -notin $seen -or -not $candidate.token -or -not $candidate.folder) { throw 'Malformed dialog proposal.' }
            if ($UiAttempts.ContainsKey($key)) { continue }
            $validation = Ensure-ManagedTrust -Path $candidate.folder -BeforeWrite {
                $validated = Invoke-UiRequest -Operation validate -Token $candidate.token
                if (-not $validated.ok) { throw "Dialog changed before config write: $($validated.error)" }
            }
            $action = 'approve'
            if (-not $validation.Ok) {
                $now = [DateTimeOffset]::UtcNow
                if (-not $DenialFirstSeen.ContainsKey($key) -or $DenialFirstSeen[$key].Reason -ne $validation.Reason) {
                    $DenialFirstSeen[$key] = @{ FirstSeen = $now; Reason = $validation.Reason }
                }
                if (-not $RefusalCooldown.ContainsKey($key) -or ($now - $RefusalCooldown[$key]).TotalSeconds -ge 30) {
                    Write-BridgeLog -Event 'REFUSED' -Data @{ folder = $candidate.folder; reason = $validation.Reason; dialogIdentity = $key }
                    $RefusalCooldown[$key] = $now
                }
                if ($DeniedDialogAction -ne 'cancel' -or ($now - $DenialFirstSeen[$key].FirstSeen).TotalSeconds -lt $DeniedDialogGraceSeconds) { continue }
                $action = 'cancel'
            }
            if ($UiAttempts.Count -ge 256) { throw 'Unresolved action ledger is full; refusing further UI actions.' }
            $UiAttempts[$key] = @{
                dialogKey = $key; folder = [string]$candidate.folder; action = $action; status = 'outcome-uncertain'
                rootPid = [int]$candidate.root.pid; createdFileTimeUtc = [string]$candidate.root.createdFileTimeUtc
                preparedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
            # Durable before Invoke. A worker crash, timeout, or lost response can
            # never silently turn an uncertain attempt into an automatic retry.
            Save-UiAttempts
            $invoked = Invoke-UiRequest -Operation invoke -Token $candidate.token -Action $action
            if (-not $invoked.ok) {
                Write-BridgeLog -Event 'UI_ACTION_UNCERTAIN' -Data @{ dialogIdentity = $key; action = $action; reason = $invoked.error }
                return 0
            }
            $UiAttempts[$key].status = 'completed'
            Save-UiAttempts
            $event = if ($action -eq 'approve') { 'APPROVED' } else { 'CANCELLED' }
            Write-BridgeLog -Event $event -Data @{ folder = $candidate.folder; dialogIdentity = $key; action = $action; generation = $Ui.Generation }
            return 1
        }
        return 0
    }
    catch {
        Register-UiFault -Reason $_.Exception.Message
        return 0
    }
}

function Write-BridgeHealth {
    param([switch]$Force)
    if (-not $Force -and $UiClock.Elapsed.TotalSeconds - $LastHealthAt -lt 15) { return }
    $script:LastHealthAt = $UiClock.Elapsed.TotalSeconds
    if ($null -ne $Ui.Process) {
        try {
            if ($Ui.Process.HasExited) { throw 'UI worker exited between requests.' }
            $Ui.LastProcessSample = $Ui.Process.Sample()
            if ($Ui.LastProcessSample.PrivateBytes -gt $Ui.SoftBytes -or $Ui.LastProcessSample.Handles -gt 1000) {
                throw 'Idle UI worker exceeded its resource budget.'
            }
        }
        catch { Register-UiFault -Reason $_.Exception.Message }
    }
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $self.Refresh()
        $resource = @{ privateBytes = $self.PrivateMemorySize64; workingSetBytes = $self.WorkingSet64; handles = $self.HandleCount; managedHeapBytes = [GC]::GetTotalMemory($false) }
        $birth = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    }
    finally { $self.Dispose() }
    $uncertain = $false
    foreach ($entry in $UiAttempts.Values) { if ($entry.status -eq 'outcome-uncertain') { $uncertain = $true } }
    $resourceHealthy = $resource.privateBytes -le 256MB -and $resource.handles -le 1000
    if (-not $resourceHealthy -and $Ui.State -notin @('RESOURCE_DEGRADED', 'CLEANUP_UNCERTAIN')) {
        try { Stop-UiWorker; $Ui.State = 'RESOURCE_DEGRADED' }
        catch { $Ui.State = 'CLEANUP_UNCERTAIN' }
        $Ui.Reason = 'Authority runtime exceeded its resource guard; UI actions are disabled without restarting the bridge.'
        Write-BridgeLog -Event 'RESOURCE_DEGRADED' -Data @{ parent = $resource; state = $Ui.State }
    }
    $gitHealthy = $GitMetrics.activeCount -eq 0 -and $GitMetrics.lastCleanupVerified
    $healthy = $LastReconcileSucceeded -and -not $ReconcileInProgress -and $gitHealthy -and
        $Ui.State -in @('HEALTHY', 'IDLE', 'DISABLED') -and -not $uncertain -and
        $resourceHealthy -and -not $ConfigWriteUncertain
    Write-AtomicBridgeJson -Path "$ConfigPath.health.json" -Value @{
        schema = 'codex-worktree-trust-bridge.health'; version = 1; updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        packageVersion = $PackageVersion; runId = $env:CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID
        pid = $PID; creationFileTimeUtc = $birth; launcherPid = $LauncherProcessId
        healthy = $healthy; sourceManifestSha256 = $SourceManifestHash; parent = $resource
        resourceHealthy = $resourceHealthy; uncertainUiOutcome = $uncertain
        configWriteUncertain = $ConfigWriteUncertain
        reconcileCount = $ReconcileCount; lastReconcileSucceeded = $LastReconcileSucceeded
        reconcile = @{
            inProgress = $ReconcileInProgress; lastStartedUtc = $LastReconcileStartedUtc
            lastDurationMs = $LastReconcileDurationMs; lastFailure = $LastReconcileFailure
            timeoutSeconds = $ReconcileTimeoutSeconds; lastBudget = $ReconcileBudget
        }
        git = @{
            healthy = $gitHealthy; commandCount = $GitMetrics.commandCount
            failureCount = $GitMetrics.failureCount; timeoutCount = $GitMetrics.timeoutCount
            outputLimitCount = $GitMetrics.outputLimitCount; invalidUtf8Count = $GitMetrics.invalidUtf8Count
            cleanupFailureCount = $GitMetrics.cleanupFailureCount; activeCount = $GitMetrics.activeCount
            lastDurationMs = $GitMetrics.lastDurationMs; maximumDurationMs = $GitMetrics.maximumDurationMs
            lastExitCode = $GitMetrics.lastExitCode; lastFailureKind = $GitMetrics.lastFailureKind
            lastFailure = $GitMetrics.lastFailure; lastFailureUtc = $GitMetrics.lastFailureUtc
            lastCleanupVerified = $GitMetrics.lastCleanupVerified
            peakJobMemoryBytes = $GitMetrics.peakJobMemoryBytes
            maximumActiveProcesses = $GitMetrics.maximumActiveProcesses
            timeoutMs = $GitCommandTimeoutMs; cleanupTimeoutMs = $GitCleanupTimeoutMs
            maximumStandardOutputBytes = $GitMaximumStandardOutputBytes
            maximumStandardErrorBytes = $GitMaximumStandardErrorBytes
            jobMemoryMiB = $GitJobMemoryMiB; processLimit = $GitProcessLimit
        }
        ui = @{
            state = $Ui.State; reason = $Ui.Reason; workerGeneration = $Ui.Generation; failureCount = $Ui.Failures
            scanCount = $Ui.ScanCount; lastScanUtc = $Ui.LastScanUtc
            worker = $(if ($null -ne $Ui.Process) { $Ui.LastProcessSample } else { $null })
            lastWorkerSample = $Ui.LastProcessSample; workerActive = ($null -ne $Ui.Process)
            managed = $Ui.LastWorkerMetrics; pendingActions = $UiAttempts.Count
            softBytes = $Ui.SoftBytes; hardBytes = $Ui.HardBytes; timeoutMs = $Ui.TimeoutMs
        }
    }
}
