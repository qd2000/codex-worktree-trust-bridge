# Changelog

All notable changes to this project are documented in this file.

The project follows semantic versioning.

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
