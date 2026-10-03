[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $packageRoot 'src\CodexWorktreeTrustBridge.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-trust-bridge-smoke-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$worktree = Join-Path $testRoot 'repo-worktree'
$staleWorktree = Join-Path $testRoot 'stale-worktree'
$plainDirectory = Join-Path $testRoot 'plain-directory'
$migrationDirectory = Join-Path $testRoot 'migration-directory'
$pruneDirectory = Join-Path $testRoot 'prune-directory'
$doubleQuotedDirectory = Join-Path $testRoot 'double-quoted-directory'
$commentedDoubleQuotedDirectory = Join-Path $testRoot 'commented-double-quoted-directory'
$unicodeShortDirectory = Join-Path $testRoot 'unicode-short'
$unicodeLongDirectory = Join-Path $testRoot 'unicode-long'
$junction = Join-Path $testRoot 'plain-directory-junction'
$junctionPhysicalRoot = Join-Path $testRoot 'junction-physical-root'
$junctionAllowedRoot = Join-Path $testRoot 'junction-allowed-root'
$junctionChild = Join-Path $junctionAllowedRoot 'child'
$oldUserProfile = $env:USERPROFILE

function Get-PathKey {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
}

function New-TestProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TrustMode,
        [Parameter(Mandatory = $true)][string[]]$SeededPaths,
        [string]$AllowedRoot = $testRoot,
        [bool]$PruneMissingManagedEntries = $true,
        [switch]$OmitNewSettings
    )
    $profile = Join-Path $testRoot $Name
    $codexHome = Join-Path $profile '.codex'
    $bridgeConfig = Join-Path $profile 'bridge.json'
    New-Item -ItemType Directory -Force -Path $codexHome | Out-Null

    $builder = [Text.StringBuilder]::new()
    [void]$builder.AppendLine('# BEGIN CODEX WORKTREE TRUST BRIDGE')
    foreach ($path in $SeededPaths) {
        $key = Get-PathKey $path
        [void]$builder.AppendLine("[projects.'$key']")
        [void]$builder.AppendLine('trust_level = "trusted"')
        [void]$builder.AppendLine()
    }
    [void]$builder.AppendLine('# END CODEX WORKTREE TRUST BRIDGE')
    [IO.File]::WriteAllText((Join-Path $codexHome 'config.toml'), $builder.ToString(), [Text.UTF8Encoding]::new($false))

    $configuration = [ordered]@{
        schema = 'codex-worktree-trust-bridge.config'
        version = 1
        allowedRoots = @($AllowedRoot)
        uiPollIntervalMs = 750
        reconcileIntervalSeconds = 60
        discoveryDepth = 4
        enableConfigTrust = $true
        enableUiAutoApprove = $false
        pruneMissingManagedEntries = $PruneMissingManagedEntries
    }
    if (-not $OmitNewSettings) {
        $configuration.trustMode = $TrustMode
        $configuration.deniedDialogAction = 'cancel'
        $configuration.deniedDialogGraceSeconds = 0
    }
    [IO.File]::WriteAllText($bridgeConfig, ($configuration | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Profile = $profile
        CodexHome = $codexHome
        BridgeConfig = $bridgeConfig
        StatePath = Join-Path $codexHome 'state\codex-worktree-trust-bridge.json'
        CodexConfig = Join-Path $codexHome 'config.toml'
    }
}

function Set-ScenarioPolicy {
    param(
        [Parameter(Mandatory = $true)]$Scenario,
        [Parameter(Mandatory = $true)][string]$TrustMode,
        [bool]$PruneMissingManagedEntries = $true
    )
    $configuration = Get-Content -LiteralPath $Scenario.BridgeConfig -Raw | ConvertFrom-Json
    $configuration | Add-Member -NotePropertyName trustMode -NotePropertyValue $TrustMode -Force
    $configuration | Add-Member -NotePropertyName pruneMissingManagedEntries -NotePropertyValue $PruneMissingManagedEntries -Force
    [IO.File]::WriteAllText(
        $Scenario.BridgeConfig,
        ($configuration | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-ManualDoubleQuotedProjectSection {
    param(
        [Parameter(Mandatory = $true)]$Scenario,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('trusted', 'untrusted')]
        [string]$TrustLevel = 'untrusted',
        [string]$EncodedKey,
        [string]$InlineComment
    )
    $key = if ([string]::IsNullOrEmpty($EncodedKey)) {
        (Get-PathKey $Path).Replace('\', '\\').Replace('"', '\"')
    }
    else { $EncodedKey }
    $comment = if ([string]::IsNullOrWhiteSpace($InlineComment)) { '' } else { ' # ' + $InlineComment.Trim() }
    $section = "[projects.`"$key`"]$comment`r`ntrust_level = `"$TrustLevel`"`r`n`r`n"
    $existing = [IO.File]::ReadAllText($Scenario.CodexConfig)
    [IO.File]::WriteAllText(
        $Scenario.CodexConfig,
        $section + $existing,
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-BridgeOnce {
    param([Parameter(Mandatory = $true)]$Scenario)
    $env:USERPROFILE = $Scenario.Profile
    & pwsh.exe -NoLogo -NoProfile -File $runtime `
        -ConfigPath $Scenario.BridgeConfig `
        -InstanceName ('smoke-' + [guid]::NewGuid().ToString('N')) `
        -Once
    if ($LASTEXITCODE -ne 0) { throw "Runtime smoke failed with exit $LASTEXITCODE." }
}

function Get-ManagedPaths {
    param([Parameter(Mandatory = $true)]$Scenario)
    $state = Get-Content -LiteralPath $Scenario.StatePath -Raw | ConvertFrom-Json
    return @($state.managedPaths)
}

function Assert-ContainsPath {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    if ($null -eq $Paths) { $Paths = @() }
    $key = Get-PathKey $Expected
    if ($key -notin $Paths) { throw "Missing managed path: $key" }
}

function Assert-DoesNotContainPath {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Unexpected
    )
    if ($null -eq $Paths) { $Paths = @() }
    $key = Get-PathKey $Unexpected
    if ($key -in $Paths) { throw "Unexpected managed path: $key" }
}

try {
    New-Item -ItemType Directory -Force -Path @(
        $repo,
        $plainDirectory,
        $migrationDirectory,
        $pruneDirectory,
        $doubleQuotedDirectory,
        $commentedDoubleQuotedDirectory,
        $unicodeShortDirectory,
        $unicodeLongDirectory,
        $junctionPhysicalRoot,
        (Join-Path $junctionPhysicalRoot 'child')
    ) | Out-Null
    & git.exe -C $repo init --initial-branch=main | Out-Null
    & git.exe -C $repo config user.name 'Codex Trust Bridge Smoke' | Out-Null
    & git.exe -C $repo config user.email 'smoke@example.invalid' | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'README.txt') -Value 'smoke' -Encoding utf8
    & git.exe -C $repo add README.txt
    & git.exe -C $repo commit -m 'smoke baseline' | Out-Null
    & git.exe -C $repo worktree add --detach $worktree HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create smoke worktree.' }
    & git.exe -C $repo worktree add --detach $staleWorktree HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create stale-worktree fixture.' }
    Remove-Item -LiteralPath (Join-Path $staleWorktree '.git') -Force
    New-Item -ItemType Junction -Path $junction -Target $plainDirectory | Out-Null
    New-Item -ItemType Junction -Path $junctionAllowedRoot -Target $junctionPhysicalRoot | Out-Null

    # A v0.1-style configuration without the new fields must retain git-only behavior.
    $gitOnly = New-TestProfile -Name 'profile-git-only' -TrustMode 'git-only' `
        -SeededPaths @($plainDirectory, $junction) -OmitNewSettings
    Invoke-BridgeOnce $gitOnly
    $gitOnlyManaged = Get-ManagedPaths $gitOnly
    Assert-ContainsPath $gitOnlyManaged $repo
    Assert-ContainsPath $gitOnlyManaged $worktree
    Assert-DoesNotContainPath $gitOnlyManaged $plainDirectory
    Assert-DoesNotContainPath $gitOnlyManaged $junction
    Assert-DoesNotContainPath $gitOnlyManaged $staleWorktree

    # all-directories retains exact ordinary directories, but it must not proactively
    # trust a stale Git registration and must still reject reparse points.
    $allDirectories = New-TestProfile -Name 'profile-all-directories' -TrustMode 'all-directories' `
        -SeededPaths @($plainDirectory, $migrationDirectory, $junction)
    Invoke-BridgeOnce $allDirectories
    $allManaged = Get-ManagedPaths $allDirectories
    Assert-ContainsPath $allManaged $repo
    Assert-ContainsPath $allManaged $worktree
    Assert-ContainsPath $allManaged $plainDirectory
    Assert-ContainsPath $allManaged $migrationDirectory
    Assert-DoesNotContainPath $allManaged $junction
    Assert-DoesNotContainPath $allManaged $staleWorktree

    # Switching back to git-only must revoke ordinary-directory trust immediately.
    Set-ScenarioPolicy -Scenario $allDirectories -TrustMode 'git-only'
    Invoke-BridgeOnce $allDirectories
    $afterModeMigration = Get-ManagedPaths $allDirectories
    Assert-ContainsPath $afterModeMigration $repo
    Assert-ContainsPath $afterModeMigration $worktree
    Assert-DoesNotContainPath $afterModeMigration $plainDirectory
    Assert-DoesNotContainPath $afterModeMigration $migrationDirectory
    Assert-DoesNotContainPath $afterModeMigration $staleWorktree

    # Missing paths must be pruned even when the legacy pruning switch is false;
    # historical state cannot remain an active authorization.
    $noPruneBypass = New-TestProfile -Name 'profile-no-prune-bypass' -TrustMode 'all-directories' `
        -SeededPaths @($pruneDirectory) -PruneMissingManagedEntries:$false
    Invoke-BridgeOnce $noPruneBypass
    $beforeRemoval = Get-ManagedPaths $noPruneBypass
    Assert-ContainsPath $beforeRemoval $pruneDirectory
    Remove-Item -LiteralPath $pruneDirectory -Recurse -Force
    Invoke-BridgeOnce $noPruneBypass
    $afterRemoval = Get-ManagedPaths $noPruneBypass
    Assert-DoesNotContainPath $afterRemoval $pruneDirectory
    $configText = Get-Content -LiteralPath $noPruneBypass.CodexConfig -Raw
    if ($configText.Contains((Get-PathKey $pruneDirectory))) {
        throw 'Removed ordinary directory remains in the managed config block.'
    }

    # An existing double-quoted TOML project table must be recognized as the
    # same semantic path, preserved, and never duplicated with a literal key.
    $doubleQuoted = New-TestProfile -Name 'profile-double-quoted-key' -TrustMode 'all-directories' `
        -SeededPaths @(
            $doubleQuotedDirectory,
            $commentedDoubleQuotedDirectory,
            $unicodeShortDirectory,
            $unicodeLongDirectory
        )
    Add-ManualDoubleQuotedProjectSection -Scenario $doubleQuoted `
        -Path $doubleQuotedDirectory -TrustLevel untrusted
    Add-ManualDoubleQuotedProjectSection -Scenario $doubleQuoted `
        -Path $commentedDoubleQuotedDirectory -TrustLevel untrusted `
        -InlineComment 'manual decision'
    $unicodeShortKey = (Get-PathKey $unicodeShortDirectory).Replace('\', '\\').Replace('unicode-short', 'unicode-\u0073hort')
    Add-ManualDoubleQuotedProjectSection -Scenario $doubleQuoted `
        -Path $unicodeShortDirectory -TrustLevel untrusted `
        -EncodedKey $unicodeShortKey
    $unicodeLongKey = (Get-PathKey $unicodeLongDirectory).Replace('\', '\\').Replace('unicode-long', 'unicode-\U0000006cong')
    Add-ManualDoubleQuotedProjectSection -Scenario $doubleQuoted `
        -Path $unicodeLongDirectory -TrustLevel untrusted `
        -EncodedKey $unicodeLongKey
    Invoke-BridgeOnce $doubleQuoted
    $doubleQuotedManaged = Get-ManagedPaths $doubleQuoted
    Assert-ContainsPath $doubleQuotedManaged $doubleQuotedDirectory
    Assert-ContainsPath $doubleQuotedManaged $commentedDoubleQuotedDirectory
    Assert-ContainsPath $doubleQuotedManaged $unicodeShortDirectory
    Assert-ContainsPath $doubleQuotedManaged $unicodeLongDirectory
    $doubleQuotedConfig = Get-Content -LiteralPath $doubleQuoted.CodexConfig -Raw
    $doubleQuotedKey = (Get-PathKey $doubleQuotedDirectory).Replace('\', '\\').Replace('"', '\"')
    $doubleQuotedHeader = "[projects.`"$doubleQuotedKey`"]"
    $literalHeader = "[projects.'$(Get-PathKey $doubleQuotedDirectory)']"
    if ([regex]::Matches($doubleQuotedConfig, [regex]::Escape($doubleQuotedHeader)).Count -ne 1) {
        throw 'The existing double-quoted project table was not preserved exactly once.'
    }
    if ($doubleQuotedConfig.Contains($literalHeader)) {
        throw 'A duplicate literal project table was appended for a double-quoted path.'
    }
    $commentedKey = (Get-PathKey $commentedDoubleQuotedDirectory).Replace('\', '\\').Replace('"', '\"')
    $commentedHeader = "[projects.`"$commentedKey`"] # manual decision"
    if ([regex]::Matches($doubleQuotedConfig, [regex]::Escape($commentedHeader)).Count -ne 1) {
        throw 'The commented double-quoted project table was not preserved exactly once.'
    }
    foreach ($path in @($commentedDoubleQuotedDirectory, $unicodeShortDirectory, $unicodeLongDirectory)) {
        $unexpectedLiteralHeader = "[projects.'$(Get-PathKey $path)']"
        if ($doubleQuotedConfig.Contains($unexpectedLiteralHeader)) {
            throw "A duplicate literal project table was appended for $path."
        }
    }
    if ([regex]::Matches($doubleQuotedConfig, [regex]::Escape("[projects.`"$unicodeShortKey`"]")).Count -ne 1) {
        throw 'The short Unicode escape project table was not preserved exactly once.'
    }
    if ([regex]::Matches($doubleQuotedConfig, [regex]::Escape("[projects.`"$unicodeLongKey`"]")).Count -ne 1) {
        throw 'The long Unicode escape project table was not preserved exactly once.'
    }

    # An allowed root that is itself beneath a junction is rejected because
    # ancestry validation continues above the configured root to the drive root.
    $junctionRootScenario = New-TestProfile -Name 'profile-junction-root' -TrustMode 'all-directories' `
        -SeededPaths @($junctionChild) -AllowedRoot $junctionAllowedRoot
    Invoke-BridgeOnce $junctionRootScenario
    $junctionRootManaged = Get-ManagedPaths $junctionRootScenario
    Assert-DoesNotContainPath $junctionRootManaged $junctionChild

    if ($configText.Contains('# BEGIN CODEX AUTO WORKTREE TRUST')) {
        throw 'Legacy managed block was not removed.'
    }

    [pscustomobject]@{
        Passed = $true
        GitOnlyManagedCount = @($gitOnlyManaged).Count
        AllDirectoriesManagedCount = @($allManaged).Count
        AfterModeMigrationManagedCount = @($afterModeMigration).Count
        AfterRemovalManagedCount = @($afterRemoval).Count
        JunctionRootManagedCount = @($junctionRootManaged).Count
        DoubleQuotedManagedCount = @($doubleQuotedManaged).Count
        GitRoots = @((Get-PathKey $repo), (Get-PathKey $worktree))
        StaleWorktree = Get-PathKey $staleWorktree
        OrdinaryDirectory = Get-PathKey $plainDirectory
        ReparsePoint = Get-PathKey $junction
        ReparseAllowedRoot = Get-PathKey $junctionAllowedRoot
    } | ConvertTo-Json -Depth 5
}
finally {
    $env:USERPROFILE = $oldUserProfile
    if (Test-Path -LiteralPath $repo -PathType Container) {
        & git.exe -C $repo worktree remove $worktree --force 2>$null | Out-Null
        & git.exe -C $repo worktree remove $staleWorktree --force 2>$null | Out-Null
        & git.exe -C $repo worktree prune 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
