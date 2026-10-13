[CmdletBinding()]
param(
    [string]$ArtifactDirectory,
    [string[]]$AllowedRoots = @('C:\PROJECT', 'E:\PROJECT'),
    [ValidateSet('git-only', 'all-directories')]
    [string]$TrustMode = 'git-only',
    [ValidateSet('leave-open', 'cancel')]
    [string]$DeniedDialogAction = 'leave-open',
    [ValidateRange(0, 60)]
    [int]$DeniedDialogGraceSeconds = 3,
    [bool]$EnableConfigTrust = $true,
    [bool]$EnableUiAutoApprove = $true,
    [string]$TaskName = 'Codex-Worktree-Trust-Bridge',
    [string]$TaskPath = '\',
    [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\tools\codex-worktree-trust-bridge'),
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\codex-worktree-trust-bridge.json'),
    [string]$StatePath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.json'),
    [string]$ActionLedgerPath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.ui-actions.json'),
    [string]$CodexConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$LogPath = (Join-Path $env:USERPROFILE '.codex\log\codex-worktree-trust-bridge.log'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE '.codex\backups\codex-worktree-trust-bridge\maintenance'),
    [switch]$DevelopmentTest,
    [switch]$CanaryDeployment,
    [string]$GrayAuthorizationPath,
    [string]$TestRoot,
    [ValidateRange(5, 180)][int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleCandidates = @(
    (Join-Path $PSScriptRoot 'CodexWorktreeTrustBridge.Maintenance.ps1'),
    (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
)
$module = $moduleCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $module) { throw 'Maintenance implementation is missing.' }
. $module

if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
    $ArtifactDirectory = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'manifest.json')) {
        $PSScriptRoot
    }
    else {
        Join-Path $PSScriptRoot '.artifacts\bin'
    }
}

$layout = New-BridgeMaintenanceLayout -TaskName $TaskName -TaskPath $TaskPath `
    -InstallRoot $InstallRoot -ConfigPath $ConfigPath -StatePath $StatePath `
    -ActionLedgerPath $ActionLedgerPath -CodexConfigPath $CodexConfigPath `
    -LogPath $LogPath -BackupRoot $BackupRoot

$version = (Get-Content -LiteralPath (Join-Path $ArtifactDirectory 'VERSION') -Raw).Trim()
$expandedRoots = @($AllowedRoots | ForEach-Object { [string]$_ -split ',' })
$normalizedRoots = @($expandedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
    ConvertTo-BridgeCanonicalPath $_.Trim(' ', '"', "'")
} | Sort-Object -Unique)
if (-not $normalizedRoots.Count) { throw 'At least one allowed root is required for a fresh installation.' }

$freshConfiguration = [ordered]@{
    schema = 'codex-worktree-trust-bridge.config'
    version = 1
    packageVersion = $version
    allowedRoots = $normalizedRoots
    uiPollIntervalMs = 750
    reconcileIntervalSeconds = 60
    discoveryDepth = 4
    reconcileTimeoutSeconds = 120
    discoveryDirectoryLimit = 5000
    discoveryRepositoryLimit = 256
    discoveryWorktreeLimit = 1024
    gitCommandLimitPerReconcile = 2048
    gitCommandTimeoutSeconds = 10
    gitCleanupTimeoutSeconds = 5
    gitMaximumStandardOutputBytes = 262144
    gitMaximumStandardErrorBytes = 65536
    gitJobMemoryMiB = 128
    gitProcessLimit = 8
    trustMode = $TrustMode
    deniedDialogAction = $DeniedDialogAction
    deniedDialogGraceSeconds = $DeniedDialogGraceSeconds
    enableConfigTrust = $EnableConfigTrust
    enableUiAutoApprove = $EnableUiAutoApprove
    pruneMissingManagedEntries = $true
}

$result = Invoke-BridgeInstall -ArtifactDirectory $ArtifactDirectory -Layout $layout `
    -PwshPath ((Get-Command pwsh.exe -ErrorAction Stop).Source) `
    -FreshConfiguration $freshConfiguration -DevelopmentTest:$DevelopmentTest `
    -CanaryDeployment:$CanaryDeployment -GrayAuthorizationPath $GrayAuthorizationPath `
    -TestRoot $TestRoot -TimeoutSeconds $TimeoutSeconds
$result | ConvertTo-Json -Depth 20
