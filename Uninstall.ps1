[CmdletBinding()]
param(
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge',
    [switch]$RemoveManagedTrustEntries
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHome = Join-Path $env:USERPROFILE '.codex'
$installRoot = Join-Path $codexHome 'tools\codex-worktree-trust-bridge'
$configPath = Join-Path $codexHome 'codex-worktree-trust-bridge.json'
$statePath = Join-Path $codexHome 'state\codex-worktree-trust-bridge.json'
$codexConfigPath = Join-Path $codexHome 'config.toml'
$archiveRoot = Join-Path $codexHome 'tools\_uninstalled'
$archive = Join-Path $archiveRoot ('codex-worktree-trust-bridge-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Start-Sleep -Milliseconds 750
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
New-Item -ItemType Directory -Force -Path $archive | Out-Null
foreach ($path in @($installRoot, $configPath, $statePath)) {
    if (Test-Path -LiteralPath $path) {
        Move-Item -LiteralPath $path -Destination $archive -Force
    }
}

if ($RemoveManagedTrustEntries -and (Test-Path -LiteralPath $codexConfigPath -PathType Leaf)) {
    $text = [IO.File]::ReadAllText($codexConfigPath)
    $begin = [regex]::Escape('# BEGIN CODEX WORKTREE TRUST BRIDGE')
    $end = [regex]::Escape('# END CODEX WORKTREE TRUST BRIDGE')
    $updated = [regex]::Replace($text, "(?s)\r?\n?$begin.*?$end\r?\n?", '').TrimEnd() + [Environment]::NewLine
    [IO.File]::WriteAllText($codexConfigPath, $updated, [Text.UTF8Encoding]::new($false))
}

[pscustomobject]@{
    Uninstalled = $true
    TaskRemoved = -not [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    Archive = $archive
    ManagedTrustEntriesRemoved = [bool]$RemoveManagedTrustEntries
} | ConvertTo-Json
