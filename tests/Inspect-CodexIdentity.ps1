[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root '.artifacts\bin\CodexWorktreeTrustBridge.Native.dll')
$results = @(
    foreach ($p in @(Get-Process ChatGPT -ErrorAction SilentlyContinue)) {
        try {
            if ($p.MainWindowHandle -eq 0) { continue }
            $family = [CodexTrustBridge.PackageIdentity]::GetFamily($p)
            $registration = [CodexTrustBridge.PackageIdentity]::VerifyRegisteredStoreExecutable($p.MainModule.FileName, 'OpenAI.Codex_2p2nqsd0c76g0')
            [pscustomobject]@{ pid = $p.Id; creationFileTimeUtc = $p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
                hwnd = $p.MainWindowHandle.ToInt64(); executable = $p.MainModule.FileName
                tokenPackageFamily = $family; registeredStorePackage = $registration
                acceptedByTargetPolicy = (($null -ne $registration) -and (-not $family -or $family -eq 'OpenAI.Codex_2p2nqsd0c76g0')) }
        }
        finally { $p.Dispose() }
    }
)
$result = @{ observedAtUtc = [DateTime]::UtcNow.ToString('o'); targets = $results; uiaInvoked = $false; mutationPerformed = $false }
New-Item -ItemType Directory -Path (Join-Path $root '.artifacts\evidence') -Force | Out-Null
$json = $result | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $root '.artifacts\evidence\codex-package-identity.json'), $json, [Text.UTF8Encoding]::new($false))
$json
