# Changelog

All notable changes to this project are documented in this file.

The project follows semantic versioning.

## [0.2.2] - Unreleased; implementation and acceptance incomplete

### Implemented in the development branch

- Atomically create the runtime in a kill-on-close Windows Job Object, including
  the pre-resume ownership window; reject duplicate launchers and publish
  process-birth and artifact identities.
- Move UIA to a dedicated MTA worker with bounded traversal, frame size, memory,
  request deadline, token lifetime, diagnostics, and circuit-open recovery.
- Retain durable uncertain-action intents so worker recovery does not blindly
  repeat a potentially completed authorization. Keep configuration writes in
  the authority process and revalidate the observed dialog before writing.
- Preserve config backups and add preimage conflict detection and atomic file
  replacement. Replacement errors latch an explicit uncertain-write state.
- Require current-user Store package registration and an exact executable path
  when a full-trust Codex process lacks a token package identity.
- Require live process-birth, manifest, UI/resource health and worker evidence
  for status; a recent reconcile alone is not sufficient for `HEALTHY`.
- Add bounded lifecycle, controlled-dialog, fault-injection, authority/config,
  and old/new observation-only resource tests.
- Add exact task-action/process-birth identity for maintenance stops; no image-
  name, basename, wildcard or command-line-substring process termination is used.
- Add hash-verified host-local backups, same-volume staged installation,
  machine-specific configuration preservation, startup-readiness verification,
  explicit rollback, automatic failed-start rollback and automatic failed-
  uninstall rollback.
- Add rollback conflict protection for bridge configuration and managed-block
  merge semantics that preserve unrelated later Codex configuration edits.
- Add an isolated eleven-case maintenance matrix covering corrupt artifacts,
  ambiguous identity, v0.2.1 residual cleanup, status degradation, crashes,
  explicit/automatic rollback, concurrent edits and fresh install/uninstall.

### Remaining release blockers

- Git/reconcile-only resource comparison and at least two continuous hours of
  representative gray observation against a frozen final artifact are pending.
- A single accepted binary artifact must be used by the release and all hosts.
  No tag, GitHub release, candidate installation or fleet rollout is claimed.

## [0.2.1] - 2026-10-06

### Added

- A tiny Windows GUI-subsystem launcher that starts the PowerShell runtime with
  `UseShellExecute = false`, `CreateNoWindow = true`, and hidden window style.
- Launcher smoke coverage that verifies the PE GUI subsystem, parent/child
  identity, paths containing spaces, and a zero console-window handle.
- A console-subsystem fake Git probe that verifies every real runtime Git child
  is created with a zero console-window handle.
- Installed-task stress coverage for repeated silent starts and matching
  `STARTED`/`RECONCILED` process evidence.

### Changed

- The Scheduled Task now starts the no-console launcher after interactive user
  logon instead of starting `pwsh.exe` directly.
- Git subprocesses are created without a shell or console window and have their
  output captured explicitly.
- Upgrades preserve existing roots and trust/dialog policy unless those options
  are explicitly supplied to the installer.
- Status now validates the launcher/runtime parent-child pair, current log
  evidence, duplicate processes, and task action identity.

## [0.2.0] - 2026-10-03

### Added

- Configurable `trustMode` with conservative `git-only` behavior and an opt-in
  `all-directories` mode for ordinary directories beneath allowed roots.
- Configurable denied-dialog handling through `deniedDialogAction`, including a
  guarded automatic Cancel action and `deniedDialogGraceSeconds`.
- Exact-path reparse-point checks to prevent junction or symbolic-link approval
  from escaping an allowed root.
- Recognition of both TOML literal-string and basic-string project table keys,
  preventing duplicate semantic project tables during synchronization.
- Status output for trust mode and denied-dialog policy.
- Offline coverage for backward-compatible v0.1 configuration, ordinary
  directory retention/pruning, and reparse-point rejection.

### Changed

- Reconciliation now retains bridge-approved ordinary directories while they
  remain eligible and removes missing, invalid, or mode-ineligible paths.
- Installer supports `-TrustMode`, `-DeniedDialogAction`, and
  `-DeniedDialogGraceSeconds`.
- Dialog controls are validated before persistent trust is granted; a malformed
  dialog is isolated so it cannot starve later prompts.
- Installer readiness now requires matching `STARTED` and successful
  `RECONCILED` evidence from the newly started process.

## [0.1.0] - 2026-10-03

### Added

- One-process bridge that combines Codex `config.toml` trust synchronization and
  guarded Windows UI Automation approval.
- Recursive discovery of Git repository roots and registered worktrees beneath
  explicitly configured allowed roots.
- Exact-path validation against `git worktree list --porcelain` before approval.
- One-click Windows installation, status inspection, upgrade, and uninstall
  scripts.
- Timestamped pre-write backups of Codex `config.toml`, atomic replacement, and
  retention of the newest 20 backups.
- State and structured JSON-line logging for audit and troubleshooting.
- Isolated offline smoke test.
- Automated GitHub Release workflow with a portable ZIP artifact.
