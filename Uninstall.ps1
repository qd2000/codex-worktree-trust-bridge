[CmdletBinding()]
param(
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge',
    [string]$TaskPath = '\',
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\tools\codex-worktree-trust-bridge'),
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\codex-worktree-trust-bridge.json'),
    [string]$StatePath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.json'),
    [string]$ActionLedgerPath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.ui-actions.json'),
    [string]$CodexConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$LogPath = (Join-Path $env:USERPROFILE '.codex\log\codex-worktree-trust-bridge.log'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.codex\backups\codex-worktree-trust-bridge\maintenance'),
    [switch]$RemoveBridgeState,
    [switch]$RemoveBridgeConfiguration,
    [switch]$RemoveManagedTrustEntries,
    [switch]$DevelopmentTest,
    [string]$TestRoot,
    [ValidateSet('none', 'after-task-remove', 'after-install-remove')]
    [string]$TestFailureStep = 'none'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = @(
    (Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.Maintenance.ps1'),
    (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $module) { throw 'Maintenance implementation is missing.' }
. $module
$layout = New-BridgeMaintenanceLayout -TaskName $TaskName -TaskPath $TaskPath `
    -InstallRoot $InstallRoot -ConfigPath $ConfigPath -StatePath $StatePath `
    -ActionLedgerPath $ActionLedgerPath -CodexConfigPath $CodexConfigPath `
    -LogPath $LogPath -BackupRoot $BackupRoot
$result = Invoke-BridgeUninstall -Layout $layout -DevelopmentTest:$DevelopmentTest -TestRoot $TestRoot `
    -RemoveBridgeState:$RemoveBridgeState -RemoveBridgeConfiguration:$RemoveBridgeConfiguration `
    -RemoveManagedTrustEntries:$RemoveManagedTrustEntries -TestFailureStep $TestFailureStep
$result | ConvertTo-Json -Depth 20
