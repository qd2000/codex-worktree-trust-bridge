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
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if ($OutputDirectory -eq $sourceRoot -or $OutputDirectory -eq (Join-Path $sourceRoot 'src') -or
    $OutputDirectory -eq [IO.Path]::GetPathRoot($OutputDirectory)) {
    throw 'Build outputs must not overwrite source or filesystem roots.'
}
$parent = Split-Path -Parent $OutputDirectory
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$stage = Join-Path $parent ('.codex-worktree-trust-bridge.build-' + [guid]::NewGuid().ToString('N'))
$previous = Join-Path $parent ('.codex-worktree-trust-bridge.previous-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    $native = Join-Path $stage 'CodexWorktreeTrustBridge.Native.dll'
    & $compiler /nologo /target:library /platform:anycpu /optimize+ "/out:$native" `
        (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Native.cs')
    if ($LASTEXITCODE) { throw "Native helper compilation failed: $LASTEXITCODE" }

    $launcher = Join-Path $stage 'CodexWorktreeTrustBridge.Launcher.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$launcher" `
        "/reference:$native" /reference:System.Web.Extensions.dll `
        (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.Launcher.cs')
    if ($LASTEXITCODE) { throw "Launcher compilation failed: $LASTEXITCODE" }

    $framework = Split-Path -Parent $compiler
    $wpf = Join-Path $framework 'WPF'
    $worker = Join-Path $stage 'CodexWorktreeTrustBridge.UiWorker.exe'
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$worker" `
        "/reference:$native" /reference:System.Web.Extensions.dll `
        "/reference:$(Join-Path $wpf 'UIAutomationClient.dll')" `
        "/reference:$(Join-Path $wpf 'UIAutomationTypes.dll')" `
        "/reference:$(Join-Path $wpf 'WindowsBase.dll')" `
        (Join-Path $PSScriptRoot 'src\CodexWorktreeTrustBridge.UiWorker.cs')
    if ($LASTEXITCODE) { throw "UI worker compilation failed: $LASTEXITCODE" }

    $copies = [ordered]@{
        'src\CodexWorktreeTrustBridge.ps1' = 'CodexWorktreeTrustBridge.ps1'
        'src\CodexWorktreeTrustBridge.Supervision.ps1' = 'CodexWorktreeTrustBridge.Supervision.ps1'
        'src\CodexWorktreeTrustBridge.Maintenance.ps1' = 'CodexWorktreeTrustBridge.Maintenance.ps1'
        'Install.ps1' = 'Install.ps1'
        'Install.cmd' = 'Install.cmd'
        'Uninstall.ps1' = 'Uninstall.ps1'
        'Uninstall.cmd' = 'Uninstall.cmd'
        'Rollback.ps1' = 'Rollback.ps1'
        'Rollback.cmd' = 'Rollback.cmd'
        'Backup.ps1' = 'Backup.ps1'
        'Backup.cmd' = 'Backup.cmd'
        'Stop.ps1' = 'Stop.ps1'
        'Stop.cmd' = 'Stop.cmd'
        'Status.ps1' = 'Status.ps1'
        'VERSION' = 'VERSION'
        'RELEASE_STATUS.json' = 'RELEASE_STATUS.json'
    }
    foreach ($pair in $copies.GetEnumerator()) {
        $source = Join-Path $PSScriptRoot $pair.Key
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Build input is missing: $($pair.Key)" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $pair.Value)
    }

    $commit = (& git -C $PSScriptRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE) { throw 'Cannot identify source commit.' }
    $dirty = [bool]@(& git -C $PSScriptRoot status --porcelain)
    if ($LASTEXITCODE) { throw 'Cannot inspect source state.' }
    $sourcePaths = @('Build.ps1', 'VERSION', 'RELEASE_STATUS.json', 'Install.ps1', 'Install.cmd',
        'Uninstall.ps1', 'Uninstall.cmd', 'Rollback.ps1', 'Rollback.cmd', 'Backup.ps1', 'Backup.cmd',
        'Stop.ps1', 'Stop.cmd', 'Status.ps1') +
        @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -File |
            Sort-Object Name | ForEach-Object { 'src/' + $_.Name })
    $sources = @($sourcePaths | Sort-Object -Unique | ForEach-Object { [ordered]@{
        path = $_
        sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant()
    } })
    $artifacts = @(Get-ChildItem -LiteralPath $stage -File | Sort-Object Name | ForEach-Object { [ordered]@{
        path = $_.Name
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    } })
    $manifest = [ordered]@{
        schema = 'codex-worktree-trust-bridge.build'
        version = 1
        packageVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
        sourceCommit = $commit
        sourceDirty = $dirty
        workerBuilt = $true
        maintenanceBuilt = $true
        accepted = $false
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        compilerSha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash.ToLowerInvariant()
        sources = $sources
        artifacts = $artifacts
    }
    [IO.File]::WriteAllText((Join-Path $stage 'manifest.json'), ($manifest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    $movedPrevious = $false
    if (Test-Path -LiteralPath $OutputDirectory) {
        Move-Item -LiteralPath $OutputDirectory -Destination $previous
        $movedPrevious = $true
    }
    try {
        Move-Item -LiteralPath $stage -Destination $OutputDirectory
    }
    catch {
        if ($movedPrevious -and -not (Test-Path -LiteralPath $OutputDirectory) -and (Test-Path -LiteralPath $previous)) {
            Move-Item -LiteralPath $previous -Destination $OutputDirectory
        }
        throw
    }
    if ($movedPrevious -and (Test-Path -LiteralPath $previous)) { Remove-Item -LiteralPath $previous -Recurse -Force }
    [pscustomobject]@{
        Built = $true
        Directory = $OutputDirectory
        WorkerBuilt = $true
        MaintenanceBuilt = $true
        SourceDirty = $dirty
        Accepted = $false
        SourceCommit = $commit
        ArtifactCount = $artifacts.Count
    } | ConvertTo-Json
}
finally {
    foreach ($path in @($stage, $previous)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
