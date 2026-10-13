# Security Policy

## v0.2.2 development status and boundaries

This branch is not an accepted release. Exact-identity backup, stop, installation,
upgrade, rollback and uninstall now have isolated maintenance coverage, but the
development artifact remains unaccepted and the release/deployment gates remain
closed. The old live-production-task stress implementation was removed rather
than retaining its name/substring process-control behavior.

Maintenance resolves one exact Scheduled Task action and parses its full launcher
arguments. It owns a launcher only when executable and complete arguments match;
a runtime must additionally match the expected PowerShell executable, `-File`,
`-ConfigPath` and parent launcher. PID, executable path and creation time are
revalidated immediately before forced termination. Ambiguous identity fails
closed, and same-basename decoys are not terminated.

Candidate files and hashes are verified before task stop. Backups include task
XML, the complete install directory, local bridge policy/state/action ledger,
Codex managed block and process identities. Installation uses staged directory
replacement. Rollback rejects a changed bridge configuration and merges only the
managed Codex block, preserving unrelated later edits. These protections do not
override Windows administrators or turn the file system into an adversarial
transactional database.

The new authority process keeps path/Git/deny/TOML policy and config writes. UIA
objects remain local to a separate MTA worker. Bounded messages carry only
process/window identities, paths and short-lived tokens, not AutomationElements.
Both controls and the exact displayed path must still validate before an action.
An uncertain invocation is durably recorded and not automatically replayed after
a worker restart. Verified disappearance is required to clear a live dialog's
action identity. Malformed dialogs are isolated and reported without clicking.

Target selection requires current-user registration of the expected Store
package and its exact registered executable, not a process name or a
WindowsApps-looking path. A missing token package identity is permitted only
with that independently checked registration and Store-origin proof. This is
not a sandbox against an administrator who can modify trusted installed files.

ConfigMutex serializes cooperating bridge writers. Hash guards detect external
edits before replacement and preserve the newer file on those conflicts. This
is not a filesystem compare-and-swap transaction against arbitrary external
writers; there is still a pre-check/replacement race requiring further review.
An uncertain replacement must not be blindly retried or rolled back over newer
content. No claim of complete adversarial concurrent-writer safety is made.

The 256/384 MiB worker soft/hard limits are provisional containment budgets.
Timeout, budget, peer, protocol and crash failures are observable and recovery
is bounded; none of this proves the entire underlying UIA leak mechanism.
There is no forced GC, working-set trimming or periodic whole-bridge restart.
Private host logs, process command lines, trust configuration, and test artifacts
remain local and must not be uploaded as public release assets.

Git commands are independently created inside a kill-on-close Job Object. Only
the three standard handles are inherited. Stdout/stderr are captured in bounded
temporary files and decoded with strict UTF-8; command time, cleanup time,
output bytes, Job memory and active process count have explicit limits. Timeout
or any limit breach terminates the owned tree and is never treated as truncated
success. Reconcile additionally bounds elapsed time and directory, repository,
worktree and command counts. An incomplete discovery preserves the previous
managed trust state and forces unhealthy status until a complete run succeeds.

Canary and fleet installation are separate authorities. A clean accepted
candidate can be installed first only on QDSPC. Local/T113 require a QDSPC gray
authorization bound to the exact manifest and source commit. The receipt must
contain at least two hours, 200 usable post-warm-up samples, resource/activity/
integrity passes and verified removal of the controlled Git workload from disk,
bridge state and Codex configuration. Failed or partially cleaned gray runs
cannot authorize fleet deployment. Publication refuses existing tags/releases
and uploads only the frozen archive tested on QDSPC; it does not rebuild or
replace an existing asset.

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
