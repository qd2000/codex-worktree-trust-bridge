# Changelog

All notable changes to this project are documented in this file.

The project follows semantic versioning.

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
