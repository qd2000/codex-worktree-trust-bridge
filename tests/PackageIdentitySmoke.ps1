[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root '.artifacts\bin\CodexWorktreeTrustBridge.Native.dll')
$family = 'OpenAI.Codex_2p2nqsd0c76g0'
$pwsh = (Get-Command pwsh.exe).Source
foreach ($path in @($pwsh, (Join-Path $root 'fake-WindowsApps\OpenAI.Codex_0.0.0.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'))) {
    if ($null -ne [CodexTrustBridge.PackageIdentity]::VerifyRegisteredStoreExecutable($path, $family)) {
        throw 'An executable outside the registered package was accepted.'
    }
}
$positive = 0
foreach ($p in @(Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
    try {
        if ($p.MainWindowHandle -eq 0) { continue }
        $proof = [CodexTrustBridge.PackageIdentity]::VerifyRegisteredStoreExecutable($p.MainModule.FileName, $family)
        if ($null -ne $proof) { $positive++ }
    }
    finally { $p.Dispose() }
}
$values = [string[]]@('C:\Program Files\example.exe', '-File', 'C:\with spaces\trailing\', '', 'embedded"quote', 'plain')
$roundTrip = [CodexTrustBridge.CommandLine]::Split([CodexTrustBridge.CommandLine]::Join($values))
if ($values.Count -ne $roundTrip.Count) { throw 'Command-line argument count changed.' }
for ($i = 0; $i -lt $values.Count; $i++) { if ($values[$i] -cne $roundTrip[$i]) { throw "Command-line argument $i changed." } }
[pscustomobject]@{ passed = $true; rejectedUnregisteredPaths = 2; actualRegisteredStoreWindows = $positive
    actualWindowCheck = $(if ($positive) { 'observed' } else { 'not available; no positive claim' })
    commandLineRoundTrip = $true; uiActionsPerformed = 0 } | ConvertTo-Json
