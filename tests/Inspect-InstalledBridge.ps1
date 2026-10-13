[CmdletBinding()]
param([string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$homePath = Join-Path $env:USERPROFILE '.codex'
$root = Join-Path $homePath 'tools\codex-worktree-trust-bridge'
$launcher = Join-Path $root 'CodexWorktreeTrustBridge.Launcher.exe'
$runtime = Join-Path $root 'CodexWorktreeTrustBridge.ps1'
$configuration = Join-Path $homePath 'codex-worktree-trust-bridge.json'
$task = Get-ScheduledTask -TaskName 'Codex-Worktree-Trust-Bridge' -ErrorAction SilentlyContinue
$processes = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='CodexWorktreeTrustBridge.Launcher.exe'")
# Substring selection is observation only, explicitly not authorization to stop.
$matches = @($processes | Where-Object {
    $_.ExecutablePath -ieq $launcher -or ($_.CommandLine -and $_.CommandLine.Contains($runtime))
})
$items = @($matches | ForEach-Object {
    $osProcess = $_
    $p = $null
    try {
        $p = Get-Process -Id $osProcess.ProcessId -ErrorAction Stop
        $p.Refresh()
        [pscustomobject]@{
            pid = $p.Id; parentPid = $osProcess.ParentProcessId; sessionId = $osProcess.SessionId
            createdAt = $osProcess.CreationDate; executable = $osProcess.ExecutablePath
            commandLine = $osProcess.CommandLine; privateBytes = $p.PrivateMemorySize64
            workingSetBytes = $p.WorkingSet64; handles = $p.HandleCount
            identityUse = 'observation-only; fresh exact identity required before any stop'
        }
    }
    finally { if ($null -ne $p) { $p.Dispose() } }
})
$files = @($launcher, $runtime, (Join-Path $root 'VERSION'), $configuration)
$hashes = @($files | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object {
    [pscustomobject]@{ path = $_; sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$config = if (Test-Path -LiteralPath $configuration) { Get-Content -LiteralPath $configuration -Raw | ConvertFrom-Json }
$result = [ordered]@{
    schema = 'codex-worktree-trust-bridge.preflight'; version = 1
    observedAt = [DateTimeOffset]::Now.ToString('o'); hostName = $env:COMPUTERNAME
    packageVersion = if (Test-Path -LiteralPath (Join-Path $root 'VERSION')) { (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim() } else { $null }
    taskState = if ($task) { [string]$task.State } else { 'missing' }
    taskActions = if ($task) { @($task.Actions | Select-Object Execute, Arguments, WorkingDirectory) } else { @() }
    processes = $items; hashes = $hashes
    allowedRoots = if ($config) { @($config.allowedRoots) } else { @() }
    systemMemory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory |
        Select-Object CommittedBytes, CommitLimit, AvailableMBytes
    mutationPerformed = $false
}
$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
    [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
}
$json
