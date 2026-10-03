# Codex Worktree Trust Bridge

[![Windows](https://img.shields.io/badge/platform-Windows-0078D4)](https://www.microsoft.com/windows)
[![PowerShell 7](https://img.shields.io/badge/PowerShell-7%2B-5391FE)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Codex Worktree Trust Bridge is a small, portable Windows helper that removes the
repetitive **“Trust this folder?”** step when Codex Desktop opens project
directories. It supports both guarded Git/worktree-only approval and an explicit
opt-in mode for ordinary directories beneath trusted project roots.

It is an independent community utility. It is not an OpenAI product and is not
affiliated with or endorsed by OpenAI.

## Why this exists

Codex Desktop stores trust for individual project paths. Workflows that create
many Git worktrees, temporary experiment directories, generated documentation
folders, or other short-lived project roots can therefore produce many trust
prompts, even when every path lives beneath project roots that you already
control.

The bridge combines two mechanisms in one background process and one Windows
Scheduled Task:

1. it maintains exact `projects.'<path>'.trust_level = "trusted"` entries in
   `%USERPROFILE%\.codex\config.toml`; and
2. it uses Windows UI Automation to invoke the matching Codex Desktop Trust or
   Cancel button.

The bridge does **not** click fixed screen coordinates.

In the default `git-only` mode, approval requires that the displayed path:

- is an absolute, existing directory;
- is inside an explicitly configured allowed root;
- is the exact root of a Git repository or a worktree returned by
  `git worktree list --porcelain`; and
- has an exact trusted entry maintained by the bridge.

In `all-directories` mode, an existing non-reparse directory beneath an allowed
root may also be approved on demand. Paths outside the allowlist, missing paths,
reparse points, or paths that otherwise fail policy are refused. The bridge can
either leave a denied prompt open or automatically invoke the verified Cancel
button after a configurable grace period, preventing one modal from blocking
later prompts.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7 (`pwsh.exe`)
- Git for Windows (`git.exe`)
- Codex Desktop
- an interactive, signed-in Windows session for the same user who runs Codex

The UI automation part cannot operate while the user is fully signed out because
there is no interactive desktop in which to inspect or act on a dialog.

## Quick start

Clone or download the repository, then run:

```powershell
.\Install.cmd
```

The public defaults are conservative:

```text
Allowed roots:             C:\PROJECT, E:\PROJECT
Trust mode:                git-only
Denied dialog action:      leave-open
Denied dialog grace:       3 seconds
```

To install with different roots:

```powershell
.\Install.cmd -AllowedRoots C:\PROJECT,D:\PROJECT
```

To approve every existing ordinary directory beneath the allowed roots and
automatically cancel denied prompts:

```powershell
.\Install.cmd `
  -AllowedRoots C:\PROJECT,D:\PROJECT `
  -TrustMode all-directories `
  -DeniedDialogAction cancel `
  -DeniedDialogGraceSeconds 3
```

The installer is idempotent. Running it again upgrades the installed runtime,
rewrites the bridge configuration, recreates the Scheduled Task, and starts a
fresh bridge process. Pass custom roots and policy options again during an
upgrade because the installer regenerates the JSON configuration from its
arguments.

## What is installed

One Scheduled Task is created:

```text
Codex-Worktree-Trust-Bridge
```

Installed files live under the current Windows user's Codex home:

```text
%USERPROFILE%\.codex\tools\codex-worktree-trust-bridge\
%USERPROFILE%\.codex\codex-worktree-trust-bridge.json
%USERPROFILE%\.codex\state\codex-worktree-trust-bridge.json
%USERPROFILE%\.codex\log\codex-worktree-trust-bridge.log
%USERPROFILE%\.codex\backups\codex-worktree-trust-bridge\
```

The bridge only owns the block between these markers in Codex's `config.toml`:

```toml
# BEGIN CODEX WORKTREE TRUST BRIDGE
# END CODEX WORKTREE TRUST BRIDGE
```

Manually maintained project sections outside that block are preserved.

## Configuration

The installed configuration file is:

```text
%USERPROFILE%\.codex\codex-worktree-trust-bridge.json
```

Example:

```json
{
  "schema": "codex-worktree-trust-bridge.config",
  "version": 1,
  "packageVersion": "0.2.0",
  "allowedRoots": [
    "C:\\PROJECT",
    "E:\\PROJECT"
  ],
  "uiPollIntervalMs": 750,
  "reconcileIntervalSeconds": 60,
  "discoveryDepth": 4,
  "trustMode": "git-only",
  "deniedDialogAction": "leave-open",
  "deniedDialogGraceSeconds": 3,
  "enableConfigTrust": true,
  "enableUiAutoApprove": true,
  "pruneMissingManagedEntries": true
}
```

| Setting | Purpose |
| --- | --- |
| `allowedRoots` | Project trees inside which paths may be approved. Use the narrowest practical roots. |
| `trustMode` | `git-only` approves only registered Git roots/worktrees. `all-directories` also approves ordinary existing directories beneath allowed roots. |
| `deniedDialogAction` | `leave-open` logs a refusal and leaves the modal for a human. `cancel` invokes the verified Cancel button after the grace period. |
| `deniedDialogGraceSeconds` | Delay before a refused prompt is cancelled, allowing transient Git/worktree creation to settle. |
| `uiPollIntervalMs` | How often the interactive process checks for a matching Codex trust dialog. |
| `reconcileIntervalSeconds` | How often Git roots/worktrees and the managed trust block are reconciled. |
| `discoveryDepth` | Maximum directory depth used while finding Git repositories under allowed roots. |
| `enableConfigTrust` | Enables maintenance of exact trusted entries in `config.toml`. |
| `enableUiAutoApprove` | Enables guarded Windows UI Automation approval and cancellation. |
| `pruneMissingManagedEntries` | Compatibility field retained for existing configurations. In v0.2.0, missing, invalid, out-of-policy, and mode-ineligible managed paths are always removed for safety. |

Restart the Scheduled Task after manually editing the JSON configuration:

```powershell
Stop-ScheduledTask -TaskName 'Codex-Worktree-Trust-Bridge'
Start-ScheduledTask -TaskName 'Codex-Worktree-Trust-Bridge'
```

## Trust modes

### `git-only`

This is the public default. The exact folder shown by Codex must be the root of a
Git repository or a registered worktree. Ordinary subdirectories and temporary
non-Git folders are denied.

### `all-directories`

Any existing ordinary directory beneath an allowed root can be approved when
Codex opens it. The bridge adds only the exact path requested by the trust
dialog; it does not pre-populate every subdirectory beneath the root.

Reparse points, junctions, and symbolic-link paths are rejected so a safe-looking
path cannot redirect approval outside an allowed root.

## Denied-dialog handling

`deniedDialogAction` controls what happens after a path fails validation:

- `leave-open` records `REFUSED` and leaves the prompt visible;
- `cancel` records `REFUSED`, waits `deniedDialogGraceSeconds`, verifies the same
  Codex trust-dialog shape, invokes its Cancel button, and records `CANCELLED`.

The grace period avoids immediately cancelling a Git/worktree prompt whose
metadata is still settling. The bridge never cancels an arbitrary window.

## Backups and safe writes

Immediately before every actual change to `%USERPROFILE%\.codex\config.toml`,
the bridge creates a timestamped backup in:

```text
%USERPROFILE%\.codex\backups\codex-worktree-trust-bridge\
```

The newest 20 backups are retained. The updated configuration is first written
to a temporary file and then moved into place. A per-user mutex prevents two
bridge instances from editing the file concurrently.

To restore a backup:

1. stop `Codex-Worktree-Trust-Bridge`;
2. copy the desired backup over `%USERPROFILE%\.codex\config.toml`;
3. inspect the restored file; and
4. start the task again.

## Status and logs

Check the installation:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Status.ps1
```

The status command reports the task, process, package version, configured roots,
trust mode, denied-dialog policy, managed path count, runtime hash, and recent
log records.

The main log is:

```text
%USERPROFILE%\.codex\log\codex-worktree-trust-bridge.log
```

Important events include:

- `STARTED` — runtime started and loaded its configuration;
- `RECONCILED` — discovery and managed-path reconciliation completed;
- `CONFIG_SYNCED` — the managed `config.toml` block changed;
- `APPROVED` — a matching Codex trust dialog was approved;
- `REFUSED` — a dialog or path failed a policy or safety check; and
- `CANCELLED` — a verified denied trust dialog was closed through its Cancel
  button.
- `DIALOG_HANDLER_ERROR` — one trust dialog could not be handled safely; the
  bridge records the isolated failure and continues scanning other dialogs.

## Upgrade

Pull or download a newer release and run `Install.cmd` again. The installer stops
the existing task/process, copies the new runtime, recreates the task, and
verifies startup readiness. Pass custom roots and policy options again when
upgrading.

## Privacy and data handling

The bridge makes no network requests and includes no telemetry. It reads local
Git metadata, the bridge JSON configuration, Codex's local `config.toml`, and the
Codex Desktop accessibility tree. Its state and logs stay under the current
user's `%USERPROFILE%\.codex` directory.

Logs can contain absolute project paths. Redact them before sharing a log in a
public issue. The repository and release archive do not include installed user
configuration, state, logs, backups, tokens, or Codex account data.

## Uninstall

Remove the Scheduled Task and installed runtime:

```powershell
.\Uninstall.cmd
```

By default, uninstalling leaves the current managed trust entries in
`config.toml`. To remove the bridge-owned block as well:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Uninstall.ps1 `
  -RemoveManagedTrustEntries
```

## Troubleshooting

### The task is not healthy

Run `Status.ps1`, then inspect the main log. Confirm that PowerShell 7, Git for
Windows, and Codex Desktop are installed for the same interactive Windows user.

### A trust prompt is refused or cancelled

Check the `REFUSED` or `CANCELLED` record. Common reasons are:

- the folder is outside `allowedRoots`;
- `trustMode` is `git-only` and the folder is not a Git root or registered
  worktree;
- the path or one of its ancestors inside the allowed root is a reparse point;
- the directory no longer exists; or
- a Codex Desktop update changed the dialog's accessible structure.

The bridge intentionally fails closed rather than clicking an unknown dialog.

### Codex Desktop changed after an update

Stop the bridge if the dialog structure has materially changed, open an issue
with redacted logs and the Codex Desktop version, and wait for an adapter update.
Do not post private repository paths, tokens, or complete Codex configuration
files in a public issue.

## Security model and limitations

- Allowed roots are a security boundary. In `git-only` mode, broad roots such as
  `C:\PROJECT` trust every valid Git root/worktree discovered beneath them. In
  `all-directories` mode, any existing non-reparse directory beneath the root can
  be approved when Codex opens it. Prefer narrower roots on shared machines.
- The tool does not bypass Windows access control, Codex authentication, model
  permissions, command approvals, or sandbox policies.
- The tool does not repair a crashed or unresponsive Codex Desktop process.
- The UI adapter is version-sensitive and may need updates when Codex Desktop
  changes its accessibility tree.
- The bridge reads Git metadata and Codex configuration; it does not modify
  repository files, branches, commits, or remotes.

See [SECURITY.md](SECURITY.md) for vulnerability-reporting guidance.

## Development and verification

Parse all PowerShell files:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  [void][scriptblock]::Create((Get-Content -LiteralPath $_.FullName -Raw))
}
```

Run the isolated offline smoke test:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\tests\OfflineSmoke.ps1
```

The test uses a temporary Git repository and worktree, exercises v0.1-compatible
`git-only` defaults, verifies `all-directories` retention and pruning for an
ordinary directory, preserves an existing double-quoted TOML project table
without creating a duplicate, rejects a junction, and removes all temporary
files.

## Releases

Version tags use `vMAJOR.MINOR.PATCH`. Pushing a version tag runs the repository's
release workflow, builds a portable ZIP, and publishes a GitHub Release.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

[MIT](LICENSE)
