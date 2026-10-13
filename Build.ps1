[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '.artifacts\bin'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The existing Windows .NET Framework compiler is required.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory -eq $PSScriptRoot -or $OutputDirectory -eq (Join-Path $PSScriptRoot 'src')) {
    throw 'Build outputs must not overwrite source directories.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$native = Join-Path $OutputDirectory 'CodexWorktreeTrustBridge.Native.dll'
& $compiler /nologo /target:library /platform:anycpu /optimize+ "/out:$native" `
    (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Native.cs')
if ($LASTEXITCODE) { throw "Native helper compilation failed: $LASTEXITCODE" }
$launcher = Join-Path $OutputDirectory 'CodexWorktreeTrustBridge.Launcher.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$launcher" `
    "/reference:$native" /reference:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Launcher.cs')
if ($LASTEXITCODE) { throw "Launcher compilation failed: $LASTEXITCODE" }

$workerSource = Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.UiWorker.cs'
$workerBuilt = $false
if (Test-Path -LiteralPath $workerSource -PathType Leaf) {
    $framework = Split-Path -Parent $compiler
    $wpf = Join-Path $framework 'WPF'
    $worker = Join-Path $OutputDirectory 'CodexWorktreeTrustBridge.UiWorker.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$worker" `
        "/reference:$native" /reference:System.Web.Extensions.dll `
        "/reference:$(Join-Path $wpf 'UIAutomationClient.dll')" `
        "/reference:$(Join-Path $wpf 'UIAutomationTypes.dll')" `
        "/reference:$(Join-Path $wpf 'WindowsBase.dll')" $workerSource
    if ($LASTEXITCODE) { throw "UI worker compilation failed: $LASTEXITCODE" }
    $workerBuilt = $true
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.ps1') -Destination $OutputDirectory -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Destination $OutputDirectory -Force
foreach ($name in @('CodexWorktreeTrustBridge.Supervision.ps1', 'CodexWorktreeTrustBridge.Lifecycle.ps1')) {
    $source = Join-Path $PSScriptRoot "src\$name"
    if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination $OutputDirectory -Force }
}
$commit = (& git -C $PSScriptRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE) { throw 'Cannot identify source commit.' }
$dirty = [bool]@(& git -C $PSScriptRoot status --porcelain)
if ($LASTEXITCODE) { throw 'Cannot inspect source state.' }
$sourcePaths = @('Build.ps1', 'VERSION') + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -File |
    Sort-Object Name | ForEach-Object { 'src/' + $_.Name })
$sources = @($sourcePaths | ForEach-Object { [ordered]@{
    path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant()
} })
$artifacts = @(Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object Name -ne 'manifest.json' |
    Sort-Object Name | ForEach-Object { [ordered]@{
        path = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    } })
$manifest = [ordered]@{
    schema = 'codex-worktree-trust-bridge.build'; version = 1
    packageVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
    sourceCommit = $commit; sourceDirty = $dirty; workerBuilt = $workerBuilt
    accepted = $false; builtAtUtc = [DateTime]::UtcNow.ToString('o')
    compilerSha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash.ToLowerInvariant()
    sources = $sources; artifacts = $artifacts
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Built = $true; Directory = $OutputDirectory; WorkerBuilt = $workerBuilt; SourceDirty = $dirty; Accepted = $false } | ConvertTo-Json
