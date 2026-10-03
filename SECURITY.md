# Security Policy

## Supported versions

Only the latest published release is actively supported.

## Reporting a vulnerability

Please use GitHub's private security-advisory feature for this repository when
available. Do not publish credentials, private repository paths, complete Codex
configuration files, or unredacted logs in a public issue.

When reporting a problem, include only the minimum information required to
reproduce it:

- the bridge version;
- the Windows and PowerShell versions;
- the Codex Desktop version;
- a redacted description of the allowed-root layout; and
- redacted `REFUSED` or `SCAN_ERROR` log entries.

The bridge deliberately fails closed. In `git-only` mode, a dialog is not
approved unless its path, Git registration, managed trust entry, and UI shape
all pass validation. In `all-directories` mode, Git registration is replaced by
an explicit existing-directory check beneath an allowed root; reparse points are
still rejected. Both Trust and Cancel controls must be uniquely identified and
support Windows UI Automation invocation before persistent trust is written.
Automatic cancellation is limited to verified Codex trust dialogs and never
clicks an unknown window. A malformed dialog is logged and isolated rather than
blocking later prompts.
