[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $packageRoot 'src\CodexWorktreeTrustBridge.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-trust-bridge-smoke-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$worktree = Join-Path $testRoot 'repo-worktree'
$profile = Join-Path $testRoot 'profile'
$codexHome = Join-Path $profile '.codex'
$configPath = Join-Path $profile 'bridge.json'
$oldUserProfile = $env:USERPROFILE

try {
    New-Item -ItemType Directory -Force -Path $repo, $codexHome | Out-Null
    & git.exe -C $repo init --initial-branch=main | Out-Null
    & git.exe -C $repo config user.name 'Codex Trust Bridge Smoke' | Out-Null
    & git.exe -C $repo config user.email 'smoke@example.invalid' | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'README.txt') -Value 'smoke' -Encoding utf8
    & git.exe -C $repo add README.txt
    & git.exe -C $repo commit -m 'smoke baseline' | Out-Null
    & git.exe -C $repo worktree add --detach $worktree HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create smoke worktree.' }

    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), '', [Text.UTF8Encoding]::new($false))
    $configuration = [ordered]@{
        schema = 'codex-worktree-trust-bridge.config'
        version = 1
        allowedRoots = @($testRoot)
        uiPollIntervalMs = 750
        reconcileIntervalSeconds = 60
        discoveryDepth = 4
        enableConfigTrust = $true
        enableUiAutoApprove = $false
        pruneMissingManagedEntries = $true
    }
    [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

    $env:USERPROFILE = $profile
    & pwsh.exe -NoLogo -NoProfile -File $runtime -ConfigPath $configPath -InstanceName ('smoke-' + [guid]::NewGuid().ToString('N')) -Once
    if ($LASTEXITCODE -ne 0) { throw "Runtime smoke failed with exit $LASTEXITCODE." }

    $statePath = Join-Path $codexHome 'state\codex-worktree-trust-bridge.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $managed = @($state.managedPaths)
    $expected = @(
        [IO.Path]::GetFullPath($repo).TrimEnd('\').ToLowerInvariant(),
        [IO.Path]::GetFullPath($worktree).TrimEnd('\').ToLowerInvariant()
    )
    foreach ($path in $expected) {
        if ($path -notin $managed) { throw "Missing managed path: $path" }
    }
    $configText = Get-Content -LiteralPath (Join-Path $codexHome 'config.toml') -Raw
    if (-not $configText.Contains('# BEGIN CODEX WORKTREE TRUST BRIDGE')) { throw 'Managed config block is missing.' }
    if ($configText.Contains('# BEGIN CODEX AUTO WORKTREE TRUST')) { throw 'Legacy managed block was not removed.' }

    [pscustomobject]@{
        Passed = $true
        ManagedCount = $managed.Count
        ExpectedPaths = $expected
    } | ConvertTo-Json -Depth 4
}
finally {
    $env:USERPROFILE = $oldUserProfile
    if (Test-Path -LiteralPath $repo -PathType Container) {
        & git.exe -C $repo worktree remove $worktree --force 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
