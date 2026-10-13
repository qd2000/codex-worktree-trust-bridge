[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FreezeReceiptPath,
    [Parameter(Mandatory)][string]$GrayAuthorizationPath,
    [string]$Tag = 'v0.2.2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\CodexWorktreeTrustBridge.Maintenance.ps1')
if ($Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Only a final semantic-version tag is accepted.' }
$freeze = Read-BridgeJson -Path $FreezeReceiptPath -MaximumBytes 1048576
$gray = Read-BridgeJson -Path $GrayAuthorizationPath -MaximumBytes 1048576
if ($freeze.schema -ne 'codex-worktree-trust-bridge.candidate-freeze' -or [int]$freeze.version -ne 1 -or
    -not [bool]$freeze.accepted -or -not [bool]$freeze.byteIdenticalDeploymentRequired) {
    throw 'Candidate freeze receipt is invalid.'
}
if ($gray.schema -ne 'codex-worktree-trust-bridge.gray-authorization' -or [int]$gray.version -ne 1 -or
    -not [bool]$gray.passed -or -not [bool]$gray.cleanupVerified -or
    -not [bool]$gray.fleetDeploymentAllowed -or [string]$gray.hostName -ine 'QDSPC' -or
    [string]$gray.candidateManifestSha256 -cne [string]$freeze.manifestSha256 -or
    [string]$gray.sourceCommit -cne [string]$freeze.sourceCommit) {
    throw 'Gray authorization does not accept this frozen candidate.'
}
$archive = ConvertTo-BridgeCanonicalPath ([string]$freeze.archivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
    (Get-BridgeFileHash $archive) -cne [string]$freeze.archiveSha256) {
    throw 'Frozen archive is missing or changed.'
}
$head = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne [string]$freeze.sourceCommit -or @(& git -C $root status --porcelain)) {
    throw 'Publication requires the exact clean frozen source commit.'
}
if (& git -C $root tag --list $Tag) { throw "Local tag already exists: $Tag" }
$remoteTag = @(& git -C $root ls-remote --tags origin ("refs/tags/" + $Tag))
if ($LASTEXITCODE -ne 0) { throw 'Cannot verify remote tag absence.' }
if ($remoteTag.Count) { throw "Remote tag already exists: $Tag" }
& gh release view $Tag --repo qd2000/codex-worktree-trust-bridge *> $null
if ($LASTEXITCODE -eq 0) { throw "GitHub Release already exists: $Tag" }

& git -C $root tag -a $Tag $head -m "Codex Worktree Trust Bridge $Tag"
if ($LASTEXITCODE -ne 0) { throw 'Could not create the release tag.' }
try {
    & git -C $root push origin $Tag
    if ($LASTEXITCODE -ne 0) { throw 'Could not push the release tag.' }
    $notes = @"
Exact frozen v0.2.2 artifact.

Source: $head
Manifest SHA-256: $($freeze.manifestSha256)
Archive SHA-256: $($freeze.archiveSha256)
QDSPC gray authorization SHA-256: $((Get-BridgeFileHash $GrayAuthorizationPath))

The uploaded asset is the byte-identical archive tested on QDSPC. It is not rebuilt by GitHub Actions.
"@
    $notesPath = Join-Path ([IO.Path]::GetTempPath()) ('trust-bridge-release-' + [guid]::NewGuid().ToString('N') + '.md')
    try {
        [IO.File]::WriteAllText($notesPath, $notes, [Text.UTF8Encoding]::new($false))
        & gh release create $Tag $archive --repo qd2000/codex-worktree-trust-bridge `
            --verify-tag --title "Codex Worktree Trust Bridge $Tag" --notes-file $notesPath
        if ($LASTEXITCODE -ne 0) { throw 'GitHub Release creation failed; the tag remains for explicit reconciliation.' }
    }
    finally { Remove-Item -LiteralPath $notesPath -Force -ErrorAction SilentlyContinue }
}
catch { throw }

[pscustomobject]@{
    published = $true; tag = $Tag; sourceCommit = $head
    manifestSha256 = [string]$freeze.manifestSha256
    archiveSha256 = [string]$freeze.archiveSha256
    grayAuthorizationSha256 = Get-BridgeFileHash $GrayAuthorizationPath
} | ConvertTo-Json -Depth 5
