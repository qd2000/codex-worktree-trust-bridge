[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(& git -C $root ls-files --cached --others --exclude-standard -- '*.ps1')
if ($LASTEXITCODE) { throw 'Cannot enumerate source scripts.' }
foreach ($file in $files) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "PowerShell parse errors in $file : $($errors -join '; ')" }
}
$gated = @('Install.ps1', 'Uninstall.ps1', 'tests\InstalledSilentStartup.ps1')
foreach ($name in $gated) {
    $path = Join-Path $root $name
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $statements = @($ast.EndBlock.Statements)
    # Never dynamically test an unguarded maintenance entry against this host.
    # Verify the exact harmless prefix before invoking the expected rejection.
    if ($statements.Count -lt 3 -or $statements[0].Extent.Text -ne 'Set-StrictMode -Version Latest' -or
        $statements[1].Extent.Text -ne '$ErrorActionPreference = ''Stop''' -or
        $statements[2] -isnot [Management.Automation.Language.ThrowStatementAst] -or
        $statements[2].Extent.Text -notlike '*V022_MAINTENANCE_NOT_ACCEPTED*') {
        throw "Unsafe test setup: $name is not statically guarded before all maintenance operations."
    }
    $refused = $false
    try { & $path } catch { $refused = $_.Exception.Message -like 'V022_MAINTENANCE_NOT_ACCEPTED:*' }
    if (-not $refused) { throw "Expected maintenance gate did not refuse $name." }
}
$status = Get-Content -LiteralPath (Join-Path $root 'RELEASE_STATUS.json') -Raw | ConvertFrom-Json
if ($status.releaseAllowed -or $status.deploymentAllowed -or $status.sustainedValidationAccepted) {
    throw 'This incomplete development checkpoint must not claim release or deployment acceptance.'
}
$runtime = Get-Content -LiteralPath (Join-Path $root 'src\CodexWorktreeTrustBridge.ps1') -Raw
if ($runtime -match 'System\.Windows\.Automation|UIAutomationClient|FindAll\(') { throw 'UIA leaked back into the long-lived authority runtime.' }
$workflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release.yml') -Raw
if ($workflow -match '\-\-clobber|contents:\s*write') { throw 'The blocked release workflow still permits replacement of published assets.' }
[pscustomobject]@{ passed = $true; parsedScripts = $files.Count; guardedMutationEntries = $gated.Count
    releaseBlocked = $true; authorityHasNoUia = $true } | ConvertTo-Json
