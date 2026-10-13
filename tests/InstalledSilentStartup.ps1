[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

throw 'V022_LEGACY_LIVE_TEST_DISABLED: use tests\MaintenanceLifecycle.ps1. The legacy production-task mutation test has been removed rather than retaining name/substr-based process control.'
