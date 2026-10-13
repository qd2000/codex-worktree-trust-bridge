[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
function Get-ConfigurationString {
    param([string]$Name, [string]$Default)
    $property = $configuration.PSObject.Properties[$Name]
    if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return [string]$property.Value
    }
    return $Default
}
$controlPath = Get-ConfigurationString -Name fixtureControlPath -Default ($ConfigPath + '.fixture-control.json')
$readyPath = Get-ConfigurationString -Name fixtureReadyPath -Default ($ConfigPath + '.fixture-ready.json')
$childReadyPath = Get-ConfigurationString -Name fixtureChildReadyPath -Default ($ConfigPath + '.fixture-child-ready.txt')
$childScript = Get-ConfigurationString -Name fixtureChildScriptPath -Default (Join-Path $PSScriptRoot 'MaintenanceFixtureChild.ps1')
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$healthPath = $ConfigPath + '.health.json'
$errorPath = $ConfigPath + '.fixture-error.json'

trap {
    try {
        [IO.File]::WriteAllText($errorPath, (@{
            timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            error = $_.Exception.ToString()
            stack = $_.ScriptStackTrace
        } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    }
    catch { }
    exit 99
}

function Write-AtomicJson {
    param([string]$Path, $Value)
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        for ($attempt = 0; ; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) {
                    [IO.File]::Replace($temporary, $Path, [NullString]::Value)
                }
                else {
                    [IO.File]::Move($temporary, $Path)
                }
                break
            }
            catch [IO.IOException] {
                if ($attempt -ge 5 -or -not (Test-Path -LiteralPath $temporary)) { throw }
                Start-Sleep -Milliseconds (20 * [Math]::Pow(2, $attempt))
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Read-Mode {
    if (-not (Test-Path -LiteralPath $controlPath)) { return 'normal' }
    return [string](Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json).mode
}

if ((Read-Mode) -eq 'startup-fail') { exit 71 }
if (-not (Test-Path -LiteralPath $childScript -PathType Leaf)) { throw "Candidate fixture child script is missing: $childScript" }

$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = (Get-Command pwsh.exe -ErrorAction Stop).Source
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $childScript, '-ReadyPath', $childReadyPath)) {
    [void]$info.ArgumentList.Add($argument)
}
$child = [Diagnostics.Process]::new()
$child.StartInfo = $info
if (-not $child.Start()) { throw 'Candidate fixture child did not start.' }
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    Write-AtomicJson -Path $readyPath -Value ([ordered]@{
        pid = $PID
        creationFileTimeUtc = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
        childPid = $child.Id
        childCreationFileTimeUtc = $child.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    })
    $first = $true
    while ($true) {
        $mode = Read-Mode
        $healthy = $mode -in @('normal', 'crash-after-ready')
        Write-AtomicJson -Path $healthPath -Value ([ordered]@{
            schema = 'codex-worktree-trust-bridge.health'
            version = 1
            updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            packageVersion = $version
            runId = $env:CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID
            pid = $PID
            creationFileTimeUtc = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
            launcherPid = [int]$env:CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID
            healthy = $healthy
            sourceManifestSha256 = $manifestHash
            reconcileCount = 1
            lastReconcileSucceeded = $true
            ui = @{ state = $(if ($healthy) { 'DISABLED' } else { 'CIRCUIT_OPEN' }); workerActive = $false }
        })
        if ($mode -eq 'crash-after-ready' -and -not $first) { exit 72 }
        $first = $false
        Start-Sleep -Milliseconds 250
    }
}
finally {
    $self.Dispose()
    $child.Dispose()
}
