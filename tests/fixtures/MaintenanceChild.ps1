[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReadyPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path (Split-Path -Parent $ReadyPath) -Force | Out-Null
[IO.File]::WriteAllText($ReadyPath, $PID.ToString(), [Text.UTF8Encoding]::new($false))
while ($true) { Start-Sleep -Seconds 1 }
