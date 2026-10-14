# Changelog

All notable changes to this project are documented in this file.

The project follows semantic versioning.

## [0.2.2] - 2026-10-14

### Added and changed

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
- Retry install-directory renames only for bounded Windows sharing/access
  conflicts while the source still exists and destination is still absent;
  uncertain or permanent outcomes continue to fail closed.
- Add an isolated eleven-case maintenance matrix covering corrupt artifacts,
  ambiguous identity, v0.2.1 residual cleanup, status degradation, crashes,
  explicit/automatic rollback, concurrent edits and fresh install/uninstall.
- Replace unbounded Git `WaitForExit`/`ReadToEndAsync` execution with an atomic
  Job-owned process runner, bounded output files, strict UTF-8, time, memory,
  process-count and cleanup limits.
- Make reconcile transactional and deadline/budget bounded. Incomplete Git or
  discovery results preserve the prior trust state and force unhealthy status.
- Add twelve Git/reconcile fault and resource cases, including hanging
  descendants, output limits, malformed output, discovery budgets and 100
  repeated reconciles with memory/handle slope checks.
- Isolate stale backup `.git` markers only when Git deterministically reports
  exit 128 with `not a git repository`; every other Git failure remains
  reconcile-critical and preserves the previous managed state.
- Raise the bounded default reconcile deadline from 30 to 120 seconds after a
  real two-root host completed a read-only reconcile in about 87 seconds.
- Add clean-candidate freeze receipts, a QDSPC-only two-hour gray validator and
  exact-manifest authorization required before Local/T113 deployment.
- Treat only a short-lived descendant that exits after an exact process-tree
  snapshot as absent at resource-sampling time, record the skipped identity,
  and continue to fail on Launcher/Runtime loss, live executable mismatch or
  other identity uncertainty.
- Add non-clobbering publication of the previously frozen ZIP after QDSPC gray
  authorization; GitHub does not rebuild the tested asset.

### Release validation and rollout

- The final clean source is commit
  `668c5e4c09d32267bbf91a59117e22bf3bce4771`; the accepted manifest SHA-256 is
  `832cbf8eb7eddf7eb67695102b57d6823e2a1073ce5f1135a7c6ed4063c60dc6`.
- The byte-identical published ZIP has SHA-256
  `a373662471719eb69d5371886b1b051d47d82138c5ed71b7330e0237ba35866e`.
- The final candidate passed the complete 14-group bounded suite, exact
  maintenance/rollback tests and live UI cadence checks.
- A representative two-hour canary run recorded 220 post-warm-up samples,
  174,813,184-byte aggregate Private Bytes peak, 0.0341 MiB/minute aggregate
  growth slope, 1,360-handle peak, no Git timeout/output/cleanup failure and
  verified removal of the controlled workload.
- The same manifest was deployed sequentially to three Windows hosts. Each host
  retained its own allowlist and trust/dialog policy, reported `HEALTHY`, had no
  v0.2.1 process residue and retained a hash-verified rollback backup.
- The annotated `v0.2.2` tag and GitHub Release point to the accepted source and
  exact canary-tested asset; GitHub did not rebuild the archive.

### Historical pre-release findings

- An earlier candidate was revoked after a broad real-world root exposed stale
  `.git` markers. Automatic rollback succeeded and rollout stopped before the
  next host. The final implementation skips only Git's exact bounded
  `not a git repository` result; all other failures remain reconcile-critical.
- A later candidate was revoked when the gray validator raced a naturally exited
  short-lived Git descendant. The bridge stayed healthy and rollback succeeded.
  The final validator tolerates only a descendant proven to have exited after an
  exact process-tree snapshot; Launcher or Runtime identity loss still fails.

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
