# One-time, reviewable source migration. Never run against an installation.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'src\CodexWorktreeTrustBridge.ps1'
$text = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
$begin = $text.IndexOf('function Get-CodexRootElements {', [StringComparison]::Ordinal)
$end = $text.IndexOf("try {`n    `$HasInstanceMutex = `$InstanceMutex.WaitOne(0)", [StringComparison]::Ordinal)
if ($begin -lt 0 -or $end -le $begin) { throw 'Expected original UIA boundaries not found; migration must not be replayed.' }
$text = $text.Substring(0, $begin) + '. (Join-Path $PSScriptRoot ''CodexWorktreeTrustBridge.Supervision.ps1'')' + "`n`n" + $text.Substring($end)
$text = $text.Replace("Add-Type -AssemblyName UIAutomationClient`nAdd-Type -AssemblyName UIAutomationTypes`n", '')
$text = $text.Replace('function Ensure-ManagedTrust {' + "`n" + '    param([Parameter(Mandatory = $true)][string]$Path)',
    'function Ensure-ManagedTrust {' + "`n" + '    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$BeforeWrite)')
$text = $text.Replace('    $canonical = $validation.Path' + "`n" + '    [void]$ManagedPaths.Add($canonical)',
    '    $canonical = $validation.Path' + "`n" + '    if ($BeforeWrite) { & $BeforeWrite }' + "`n" + '    [void]$ManagedPaths.Add($canonical)')
$text = $text.Replace('function Invoke-Reconcile {' + "`n", 'function Invoke-Reconcile {' + "`n" + '    $script:LastReconcileSucceeded = $false' + "`n")
$text = $text.Replace("    Write-BridgeLog -Event 'RECONCILED'", '    $script:LastReconcileSucceeded = $true' + "`n" + '    $script:ReconcileCount++' + "`n" + "    Write-BridgeLog -Event 'RECONCILED'")
$text = $text.Replace('    $HasInstanceMutex = $InstanceMutex.WaitOne(0)',
    '    try { $HasInstanceMutex = $InstanceMutex.WaitOne(0) }' + "`n" + '    catch [Threading.AbandonedMutexException] { $HasInstanceMutex = $true }')
$text = $text.Replace('    Import-LegacyManagedPaths' + "`n", '    Initialize-UiSupervisor' + "`n" + '    Import-LegacyManagedPaths' + "`n")
$text = $text.Replace('        if (-not $Once) { Start-Sleep -Milliseconds $UiPollIntervalMs }',
    '        Write-BridgeHealth' + "`n" + '        if (-not $Once) { Start-Sleep -Milliseconds $UiPollIntervalMs }')
$text = $text.Replace('    if ($HasInstanceMutex) { [void]$InstanceMutex.ReleaseMutex() }',
    '    if ($HasInstanceMutex) {' + "`n" +
    '        try { Stop-UiWorker; Write-BridgeHealth -Force }' + "`n" +
    '        finally { [void]$InstanceMutex.ReleaseMutex() }' + "`n" + '    }')
$identity = @'
$versionPath = Join-Path $PSScriptRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) { $versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION' }
$PackageVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
$SourceManifestHash = if (Test-Path -LiteralPath $manifestPath) { (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash } else { $null }
$script:LastReconcileSucceeded = $false
$script:ReconcileCount = 0

'@
$text = $text.Replace('$NewBeginMarker =', $identity + "`n" + '$NewBeginMarker =')
$text = $text.Replace('    $record = [ordered]@{', @'
    $Data['pid'] = $PID
    $Data['launcherPid'] = $LauncherProcessId
    $Data['packageVersion'] = $PackageVersion
    $Data['runId'] = $env:CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID
    $record = [ordered]@{
'@)
# The old main was exactly one direct scan call; removing UIA must not alter
# path eligibility, denial policy, TOML parsing or reconciliation semantics.
if ($text.Contains('FindAll(') -or $text.Contains('System.Windows.Automation')) { throw 'UIA remained in the authority runtime.' }
[IO.File]::WriteAllText($path, $text.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
Write-Output 'Runtime UIA implementation replaced by isolated supervision module.'
