[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$wpf = Join-Path (Split-Path -Parent $compiler) 'WPF'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$target = Join-Path $OutputDirectory 'ControlledDialog.exe'
$compilerOutput = @(& $compiler /nologo /target:winexe /optimize+ "/out:$target" /reference:System.Web.Extensions.dll `
    "/reference:$(Join-Path $wpf 'PresentationFramework.dll')" "/reference:$(Join-Path $wpf 'PresentationCore.dll')" `
    "/reference:$(Join-Path $wpf 'WindowsBase.dll')" "/reference:$(Join-Path $wpf 'UIAutomationTypes.dll')" `
    /reference:System.Xaml.dll (Join-Path $PSScriptRoot 'fixtures\ControlledDialog.cs'))
if ($LASTEXITCODE) { throw "Controlled UI fixture build failed ($LASTEXITCODE): $($compilerOutput -join '; ')" }
$target
