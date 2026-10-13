[CmdletBinding()]
param(
    [string]$NativeAssembly = (Join-Path (Split-Path -Parent $PSScriptRoot) '.artifacts\bin\CodexWorktreeTrustBridge.Native.dll'),
    [ValidateRange(1, 100)][int]$Iterations = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -Path ([IO.Path]::GetFullPath($NativeAssembly))
$rows = [Collections.Generic.List[object]]::new()
$self = [Diagnostics.Process]::GetCurrentProcess()
try { $session = $self.SessionId } finally { $self.Dispose() }

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $targets = 0
    $processes = 0
    foreach ($process in @(Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            $processes++
            if ($process.HasExited -or $process.SessionId -ne $session -or $process.MainWindowHandle -eq 0) { continue }
            $family = [CodexTrustBridge.PackageIdentity]::GetFamily($process)
            if ($family -and $family -ne 'OpenAI.Codex_2p2nqsd0c76g0') { throw 'Unexpected package family.' }
            $registration = [CodexTrustBridge.PackageIdentity]::VerifyRegisteredStoreExecutable(
                $process.MainModule.FileName, 'OpenAI.Codex_2p2nqsd0c76g0')
            if ($null -eq $registration) { throw 'Target registration verification failed.' }
            [void]$process.StartTime
            [void]$process.MainModule.FileName
            $targets++
        }
        finally { $process.Dispose() }
    }
    $rows.Add([pscustomobject]@{
        iteration = $iteration
        elapsedMilliseconds = $clock.Elapsed.TotalMilliseconds
        processCount = $processes
        targetCount = $targets
    })
}

[pscustomobject]@{
    passed = $true
    iterations = $Iterations
    maximumMilliseconds = ($rows | Measure-Object elapsedMilliseconds -Maximum).Maximum
    averageMilliseconds = ($rows | Measure-Object elapsedMilliseconds -Average).Average
    rows = $rows.ToArray()
    mutationPerformed = $false
    uiaInvoked = $false
} | ConvertTo-Json -Depth 6
