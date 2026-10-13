Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'Codex Worktree Trust Bridge maintenance supports Windows only.' }

if (-not ('CodexTrustBridgeMaintenance.CommandLine' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexTrustBridgeMaintenance
{
    public static class CommandLine
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr value);

        public static string[] Split(string commandLine)
        {
            if (String.IsNullOrWhiteSpace(commandLine)) return new string[0];
            int count;
            IntPtr values = CommandLineToArgvW(commandLine, out count);
            if (values == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                string[] result = new string[count];
                for (int i = 0; i < count; i++)
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * IntPtr.Size));
                return result;
            }
            finally { LocalFree(values); }
        }

        public static string Join(string[] values)
        {
            StringBuilder builder = new StringBuilder();
            foreach (string value in values)
            {
                if (builder.Length != 0) builder.Append(' ');
                builder.Append(Quote(value));
            }
            return builder.ToString();
        }

        private static string Quote(string value)
        {
            if (String.IsNullOrEmpty(value)) return "\"\"";
            if (value.IndexOfAny(new char[] { ' ', '\t', '\r', '\n', '\v', '"' }) < 0) return value;
            StringBuilder quoted = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"')
                {
                    quoted.Append('\\', slashes * 2 + 1).Append('"');
                    slashes = 0;
                    continue;
                }
                quoted.Append('\\', slashes).Append(character);
                slashes = 0;
            }
            quoted.Append('\\', slashes * 2).Append('"');
            return quoted.ToString();
        }
    }
}
'@
}

function ConvertTo-BridgeCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-BridgePathInside {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $childPath = ConvertTo-BridgeCanonicalPath $Child
    $parentPath = ConvertTo-BridgeCanonicalPath $Parent
    return $childPath -ieq $parentPath -or
        $childPath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-BridgeFileHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-BridgeJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 1048576
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file is missing: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt $MaximumBytes) { throw "JSON file exceeds its bounded size: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Write-BridgeAtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $pathValue = ConvertTo-BridgeCanonicalPath $Path
    $parent = Split-Path -Parent $pathValue
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($pathValue) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $pathValue -PathType Leaf) {
            [IO.File]::Replace($temporary, $pathValue, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporary, $pathValue)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Write-BridgeAtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-BridgeAtomicText -Path $Path -Text ($Value | ConvertTo-Json -Depth 20)
}

function Copy-BridgeAtomicFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $sourceValue = ConvertTo-BridgeCanonicalPath $Source
    $destinationValue = ConvertTo-BridgeCanonicalPath $Destination
    if (-not (Test-Path -LiteralPath $sourceValue -PathType Leaf)) { throw "Atomic copy source is missing: $sourceValue" }
    $parent = Split-Path -Parent $destinationValue
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($destinationValue) + '.copy-' + [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $sourceValue -Destination $temporary
        if ((Get-BridgeFileHash $temporary) -cne (Get-BridgeFileHash $sourceValue)) { throw 'Atomic copy staging hash mismatch.' }
        if (Test-Path -LiteralPath $destinationValue -PathType Leaf) {
            [IO.File]::Replace($temporary, $destinationValue, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporary, $destinationValue)
        }
        if ((Get-BridgeFileHash $destinationValue) -cne (Get-BridgeFileHash $sourceValue)) { throw 'Atomic copy destination hash mismatch.' }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function New-BridgeMaintenanceLayout {
    [CmdletBinding()]
    param(
        [string]$TaskName = 'Codex-Worktree-Trust-Bridge',
        [string]$TaskPath = '\',
        [string]$InstallRoot = (Join-Path $env:USERPROFILE '.codex\tools\codex-worktree-trust-bridge'),
        [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\codex-worktree-trust-bridge.json'),
        [string]$StatePath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.json'),
        [string]$ActionLedgerPath = (Join-Path $env:USERPROFILE '.codex\state\codex-worktree-trust-bridge.ui-actions.json'),
        [string]$CodexConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
        [string]$LogPath = (Join-Path $env:USERPROFILE '.codex\log\codex-worktree-trust-bridge.log'),
        [string]$BackupRoot = (Join-Path $env:USERPROFILE '.codex\backups\codex-worktree-trust-bridge\maintenance')
    )
    if ([string]::IsNullOrWhiteSpace($TaskName) -or $TaskName.Length -gt 180 -or $TaskName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'TaskName is invalid.'
    }
    if ([string]::IsNullOrWhiteSpace($TaskPath)) { $TaskPath = '\' }
    if (-not $TaskPath.StartsWith('\')) { $TaskPath = '\' + $TaskPath }
    if (-not $TaskPath.EndsWith('\')) { $TaskPath += '\' }
    $layout = [ordered]@{
        schema = 'codex-worktree-trust-bridge.layout'
        version = 1
        taskName = $TaskName
        taskPath = $TaskPath
        installRoot = ConvertTo-BridgeCanonicalPath $InstallRoot
        configPath = ConvertTo-BridgeCanonicalPath $ConfigPath
        statePath = ConvertTo-BridgeCanonicalPath $StatePath
        actionLedgerPath = ConvertTo-BridgeCanonicalPath $ActionLedgerPath
        codexConfigPath = ConvertTo-BridgeCanonicalPath $CodexConfigPath
        logPath = ConvertTo-BridgeCanonicalPath $LogPath
        backupRoot = ConvertTo-BridgeCanonicalPath $BackupRoot
    }
    $layout.healthPath = $layout.configPath + '.health.json'
    $layout.processReceiptPath = $layout.configPath + '.process.json'
    $layout.runtimePath = Join-Path $layout.installRoot 'CodexWorktreeTrustBridge.ps1'
    $layout.launcherPath = Join-Path $layout.installRoot 'CodexWorktreeTrustBridge.Launcher.exe'
    $layout.workerPath = Join-Path $layout.installRoot 'CodexWorktreeTrustBridge.UiWorker.exe'
    $layout.manifestPath = Join-Path $layout.installRoot 'manifest.json'
    return [pscustomobject]$layout
}

function Assert-BridgeMaintenanceScope {
    param(
        [Parameter(Mandatory)]$Layout,
        [switch]$DevelopmentTest,
        [string]$TestRoot
    )
    if (-not $DevelopmentTest) { return }
    if ([string]::IsNullOrWhiteSpace($TestRoot)) { throw 'DevelopmentTest requires TestRoot.' }
    $testRootValue = ConvertTo-BridgeCanonicalPath $TestRoot
    if ($Layout.taskName -notlike 'Codex-Worktree-Trust-Bridge-Test-*') {
        throw 'DevelopmentTest requires a unique test task name.'
    }
    if ($Layout.taskPath -ne '\') { throw 'DevelopmentTest tasks must use the root task folder for deterministic cleanup.' }
    foreach ($path in @(
        $Layout.installRoot, $Layout.configPath, $Layout.statePath, $Layout.actionLedgerPath,
        $Layout.codexConfigPath, $Layout.logPath, $Layout.backupRoot, $Layout.healthPath,
        $Layout.processReceiptPath
    )) {
        if (-not (Test-BridgePathInside -Child $path -Parent $testRootValue)) {
            throw "DevelopmentTest path escapes TestRoot: $path"
        }
    }
    $productionTask = Get-ScheduledTask -TaskName 'Codex-Worktree-Trust-Bridge' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($productionTask -and $Layout.taskName -eq $productionTask.TaskName) {
        throw 'DevelopmentTest cannot target the production task.'
    }
}

function Test-BridgeSafeArtifactName {
    param([Parameter(Mandatory)][string]$Name)
    return $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$' -and
        [IO.Path]::GetFileName($Name) -ceq $Name
}

function Test-BridgeArtifactDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [switch]$DevelopmentTest
    )
    $directory = ConvertTo-BridgeCanonicalPath $ArtifactDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Artifact directory is missing: $directory" }
    $manifestPath = Join-Path $directory 'manifest.json'
    $manifest = Read-BridgeJson -Path $manifestPath -MaximumBytes 1048576
    if ($manifest.schema -ne 'codex-worktree-trust-bridge.build' -or [int]$manifest.version -ne 1) {
        throw 'Unsupported artifact manifest.'
    }
    $entries = @($manifest.artifacts)
    if ($entries.Count -lt 6 -or $entries.Count -gt 64) { throw 'Artifact manifest file count is outside the allowed range.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $name = [string]$entry.path
        $hash = [string]$entry.sha256
        if (-not (Test-BridgeSafeArtifactName $name) -or $hash -notmatch '^[a-fA-F0-9]{64}$' -or -not $names.Add($name)) {
            throw "Unsafe or duplicate artifact manifest entry: $name"
        }
        $path = Join-Path $directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Artifact is missing: $name" }
        if ((Get-BridgeFileHash $path) -cne $hash.ToLowerInvariant()) { throw "Artifact hash mismatch: $name" }
    }
    $actualNames = @(Get-ChildItem -LiteralPath $directory -File | Select-Object -ExpandProperty Name)
    $expectedNames = @('manifest.json') + @($entries | ForEach-Object { [string]$_.path })
    foreach ($actualName in $actualNames) {
        if ($actualName -notin $expectedNames) { throw "Unexpected file in artifact directory: $actualName" }
    }
    foreach ($expectedName in $expectedNames) {
        if ($expectedName -notin $actualNames) { throw "Expected artifact file was not enumerated: $expectedName" }
    }
    $versionPath = Join-Path $directory 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw 'VERSION is absent from the artifact.' }
    $version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    if ($version -cne [string]$manifest.packageVersion) { throw 'VERSION and artifact manifest disagree.' }
    if (-not $DevelopmentTest) {
        if ([bool]$manifest.sourceDirty -or -not [bool]$manifest.accepted) {
            throw 'Production installation requires a clean accepted artifact.'
        }
        $releaseStatusPath = Join-Path $directory 'RELEASE_STATUS.json'
        $releaseStatus = Read-BridgeJson -Path $releaseStatusPath -MaximumBytes 65536
        if (-not [bool]$releaseStatus.releaseAllowed -or -not [bool]$releaseStatus.deploymentAllowed -or
            -not [bool]$releaseStatus.maintenanceImplementationReady) {
            throw 'Production installation remains blocked by release/deployment status.'
        }
    }
    return [pscustomobject]@{
        Directory = $directory
        Manifest = $manifest
        ManifestPath = $manifestPath
        ManifestSha256 = Get-BridgeFileHash $manifestPath
        Version = $version
        Entries = $entries
    }
}

function Get-BridgeTask {
    param([Parameter(Mandatory)]$Layout)
    return Get-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -ErrorAction SilentlyContinue
}

function Get-BridgeTaskActionDefinition {
    param([Parameter(Mandatory)]$Layout, $Task)
    if ($null -eq $Task) { return $null }
    if (@($Task.Actions).Count -ne 1) { throw 'Bridge task must contain exactly one action.' }
    $action = @($Task.Actions)[0]
    $execute = ConvertTo-BridgeCanonicalPath ([Environment]::ExpandEnvironmentVariables([string]$action.Execute).Trim('"'))
    $arguments = [CodexTrustBridgeMaintenance.CommandLine]::Split([Environment]::ExpandEnvironmentVariables([string]$action.Arguments))
    if ($arguments.Count -ne 3) { throw 'Bridge task action must contain exactly pwsh, runtime and config arguments.' }
    $pwsh = ConvertTo-BridgeCanonicalPath $arguments[0]
    $runtime = ConvertTo-BridgeCanonicalPath $arguments[1]
    $config = ConvertTo-BridgeCanonicalPath $arguments[2]
    if ($config -ine $Layout.configPath) { throw 'Bridge task configuration path does not match the requested maintenance layout.' }
    return [pscustomobject]@{
        LauncherPath = $execute
        PwshPath = $pwsh
        RuntimePath = $runtime
        ConfigPath = $config
        Arguments = $arguments
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace([string]$action.WorkingDirectory)) { Split-Path -Parent $execute } else { ConvertTo-BridgeCanonicalPath ([string]$action.WorkingDirectory) }
    }
}

function Test-BridgePathToken {
    param([string]$Left, [string]$Right)
    try { return (ConvertTo-BridgeCanonicalPath $Left) -ieq (ConvertTo-BridgeCanonicalPath $Right) }
    catch { return $false }
}

function Test-BridgeLauncherCommandLine {
    param([Parameter(Mandatory)]$Process, [Parameter(Mandatory)]$Action)
    if (-not $Process.CommandLine) { return $false }
    try { $tokens = [CodexTrustBridgeMaintenance.CommandLine]::Split([string]$Process.CommandLine) }
    catch { return $false }
    if ($tokens.Count -ne 4) { return $false }
    return (Test-BridgePathToken $tokens[0] $Action.LauncherPath) -and
        (Test-BridgePathToken $tokens[1] $Action.PwshPath) -and
        (Test-BridgePathToken $tokens[2] $Action.RuntimePath) -and
        (Test-BridgePathToken $tokens[3] $Action.ConfigPath)
}

function Test-BridgeRuntimeCommandLine {
    param([Parameter(Mandatory)]$Process, [Parameter(Mandatory)]$Action)
    if (-not $Process.CommandLine) { return $false }
    try { $tokens = [CodexTrustBridgeMaintenance.CommandLine]::Split([string]$Process.CommandLine) }
    catch { return $false }
    if ($tokens.Count -lt 5 -or -not (Test-BridgePathToken $tokens[0] $Action.PwshPath)) { return $false }
    $fileValues = [Collections.Generic.List[string]]::new()
    $configValues = [Collections.Generic.List[string]]::new()
    for ($index = 1; $index -lt $tokens.Count; $index++) {
        if ([string]$tokens[$index] -ieq '-File' -and $index + 1 -lt $tokens.Count) {
            $fileValues.Add([string]$tokens[++$index])
            continue
        }
        if ([string]$tokens[$index] -ieq '-ConfigPath' -and $index + 1 -lt $tokens.Count) {
            $configValues.Add([string]$tokens[++$index])
        }
    }
    return $fileValues.Count -eq 1 -and $configValues.Count -eq 1 -and
        (Test-BridgePathToken $fileValues[0] $Action.RuntimePath) -and
        (Test-BridgePathToken $configValues[0] $Action.ConfigPath)
}

function ConvertTo-BridgeProcessIdentity {
    param([Parameter(Mandatory)]$CimProcess, [Parameter(Mandatory)][string]$Role)
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$CimProcess.ProcessId)
        [void]$process.Handle
        $birth = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        return [pscustomobject]@{
            role = $Role
            pid = [int]$process.Id
            creationFileTimeUtc = [long]$birth
            parentPid = [int]$CimProcess.ParentProcessId
            executablePath = ConvertTo-BridgeCanonicalPath ([string]$CimProcess.ExecutablePath)
            commandLineSha256 = if ($CimProcess.CommandLine) {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$CimProcess.CommandLine)
                $hash = [Security.Cryptography.SHA256]::Create()
                try { ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
                finally { $hash.Dispose() }
            } else { $null }
        }
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Get-BridgeProcessSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Layout,
        $Task = (Get-BridgeTask $Layout),
        [switch]$AllowMissingPair
    )
    if ($null -eq $Task) {
        return [pscustomobject]@{ Task = $null; Action = $null; Launcher = $null; Runtime = $null; Descendants = @() }
    }
    $action = Get-BridgeTaskActionDefinition -Layout $Layout -Task $Task
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $launchers = @($all | Where-Object {
        $_.ExecutablePath -and (Test-BridgePathToken $_.ExecutablePath $action.LauncherPath) -and
        (Test-BridgeLauncherCommandLine -Process $_ -Action $action)
    })
    if ($launchers.Count -gt 1) { throw 'Multiple exact launcher processes match the task; maintenance fails closed.' }
    $launcher = if ($launchers.Count -eq 1) { $launchers[0] } else { $null }
    $runtimes = @()
    if ($null -ne $launcher) {
        $runtimes = @($all | Where-Object {
            [int]$_.ParentProcessId -eq [int]$launcher.ProcessId -and $_.ExecutablePath -and
            (Test-BridgePathToken $_.ExecutablePath $action.PwshPath) -and
            (Test-BridgeRuntimeCommandLine -Process $_ -Action $action)
        })
    }
    if ($runtimes.Count -gt 1) { throw 'Multiple exact runtime processes match the task; maintenance fails closed.' }
    $runtime = if ($runtimes.Count -eq 1) { $runtimes[0] } else { $null }
    if (-not $AllowMissingPair -and [string]$Task.State -eq 'Running' -and ($null -eq $launcher -or $null -eq $runtime)) {
        throw 'Running task does not have one exact launcher/runtime process pair.'
    }
    $descendantRows = [Collections.Generic.List[object]]::new()
    if ($null -ne $launcher) {
        $known = [Collections.Generic.HashSet[int]]::new()
        [void]$known.Add([int]$launcher.ProcessId)
        if ($null -ne $runtime) { [void]$known.Add([int]$runtime.ProcessId) }
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($row in $all) {
                if (-not $known.Contains([int]$row.ProcessId) -and $known.Contains([int]$row.ParentProcessId)) {
                    [void]$known.Add([int]$row.ProcessId)
                    $descendantRows.Add($row)
                    $changed = $true
                }
            }
        }
    }
    return [pscustomobject]@{
        Task = $Task
        Action = $action
        Launcher = if ($launcher) { ConvertTo-BridgeProcessIdentity -CimProcess $launcher -Role launcher } else { $null }
        Runtime = if ($runtime) { ConvertTo-BridgeProcessIdentity -CimProcess $runtime -Role runtime } else { $null }
        Descendants = @($descendantRows | ForEach-Object { ConvertTo-BridgeProcessIdentity -CimProcess $_ -Role descendant })
    }
}

function Test-BridgeProcessIdentityAlive {
    param([Parameter(Mandatory)]$Identity)
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid)
        [void]$process.Handle
        if ($process.HasExited) { return $false }
        if ($process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$Identity.creationFileTimeUtc) { return $false }
        $path = ConvertTo-BridgeCanonicalPath $process.MainModule.FileName
        return $path -ieq [string]$Identity.executablePath
    }
    catch [ArgumentException] { return $false }
    catch [InvalidOperationException] { return $false }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Stop-BridgeProcessIdentityExact {
    param([Parameter(Mandatory)]$Identity, [switch]$EntireTree)
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$Identity.pid)
        [void]$process.Handle
        if ($process.HasExited) { return $false }
        if ($process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$Identity.creationFileTimeUtc -or
            (ConvertTo-BridgeCanonicalPath $process.MainModule.FileName) -ine [string]$Identity.executablePath) {
            throw "Process identity changed before exact stop: PID $($Identity.pid)"
        }
        if ($EntireTree) { $process.Kill($true) } else { $process.Kill() }
        return $true
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Wait-BridgeProcessIdentityExit {
    param([Parameter(Mandatory)]$Identity, [ValidateRange(0, 60000)][int]$TimeoutMilliseconds = 10000)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (-not (Test-BridgeProcessIdentityAlive $Identity)) { return $true }
        Start-Sleep -Milliseconds 100
    } while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return -not (Test-BridgeProcessIdentityAlive $Identity)
}

function Stop-BridgeTaskExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Layout,
        [ValidateRange(1, 30)][int]$GraceSeconds = 5
    )
    $task = Get-BridgeTask $Layout
    if ($null -eq $task) {
        return [pscustomobject]@{ taskExisted = $false; captured = @(); forced = @(); cleanupVerified = $true }
    }
    $processSet = Get-BridgeProcessSet -Layout $Layout -Task $task -AllowMissingPair
    if ([string]$task.State -eq 'Running' -and ($null -eq $processSet.Launcher -or $null -eq $processSet.Runtime)) {
        throw 'Cannot stop a running task without one exact captured launcher/runtime pair.'
    }
    $captured = @($processSet.Launcher, $processSet.Runtime) + @($processSet.Descendants) |
        Where-Object { $null -ne $_ }
    if ([string]$task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -ErrorAction Stop
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $deadline -and @($captured | Where-Object { Test-BridgeProcessIdentityAlive $_ }).Count) {
        Start-Sleep -Milliseconds 100
    }
    $forced = [Collections.Generic.List[object]]::new()
    if ($processSet.Launcher -and (Test-BridgeProcessIdentityAlive $processSet.Launcher)) {
        [void](Stop-BridgeProcessIdentityExact -Identity $processSet.Launcher -EntireTree)
        $forced.Add($processSet.Launcher)
    }
    if ($processSet.Runtime -and (Test-BridgeProcessIdentityAlive $processSet.Runtime)) {
        [void](Stop-BridgeProcessIdentityExact -Identity $processSet.Runtime -EntireTree)
        $forced.Add($processSet.Runtime)
    }
    foreach ($identity in @($processSet.Descendants)) {
        if (Test-BridgeProcessIdentityAlive $identity) {
            [void](Stop-BridgeProcessIdentityExact -Identity $identity -EntireTree)
            $forced.Add($identity)
        }
    }
    foreach ($identity in $captured) {
        if (-not (Wait-BridgeProcessIdentityExit -Identity $identity -TimeoutMilliseconds 10000)) {
            throw "Exact bridge process did not exit: $($identity.role) PID $($identity.pid)"
        }
    }
    $remaining = Get-BridgeProcessSet -Layout $Layout -Task (Get-BridgeTask $Layout) -AllowMissingPair
    if ($remaining.Launcher -or $remaining.Runtime -or @($remaining.Descendants).Count) {
        throw 'A new exact task-owned process appeared during maintenance stop.'
    }
    return [pscustomobject]@{
        taskExisted = $true
        captured = $captured
        forced = $forced.ToArray()
        cleanupVerified = $true
    }
}

function Get-BridgeLayoutFiles {
    param([Parameter(Mandatory)]$Layout)
    return @(
        [pscustomobject]@{ label = 'bridge-config'; path = $Layout.configPath; policy = 'exact-conflict' }
        [pscustomobject]@{ label = 'bridge-state'; path = $Layout.statePath; policy = 'exact' }
        [pscustomobject]@{ label = 'ui-actions'; path = $Layout.actionLedgerPath; policy = 'exact' }
        [pscustomobject]@{ label = 'codex-config'; path = $Layout.codexConfigPath; policy = 'managed-block' }
        [pscustomobject]@{ label = 'health'; path = $Layout.healthPath; policy = 'volatile-delete' }
        [pscustomobject]@{ label = 'process-receipt'; path = $Layout.processReceiptPath; policy = 'volatile-delete' }
    )
}

function Get-BridgeRelativeFiles {
    param([Parameter(Mandatory)][string]$Root)
    $rootValue = ConvertTo-BridgeCanonicalPath $Root
    if (-not (Test-Path -LiteralPath $rootValue -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $rootValue -File -Recurse | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            path = [IO.Path]::GetRelativePath($rootValue, $_.FullName).Replace('\', '/')
            sha256 = Get-BridgeFileHash $_.FullName
            length = [long]$_.Length
        }
    })
}

function Test-BridgeDirectoryAgainstEntries {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Entries)
    $actual = @(Get-BridgeRelativeFiles $Root)
    if ($actual.Count -ne @($Entries).Count) { throw "Directory file count differs from its manifest: $Root" }
    $actualMap = @{}
    foreach ($entry in $actual) { $actualMap[[string]$entry.path] = $entry }
    foreach ($expected in @($Entries)) {
        $path = [string]$expected.path
        if (-not $actualMap.ContainsKey($path) -or $actualMap[$path].sha256 -cne [string]$expected.sha256) {
            throw "Directory manifest mismatch: $path"
        }
    }
}

function New-BridgeQuiescedBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Layout)
    New-Item -ItemType Directory -Path $Layout.backupRoot -Force | Out-Null
    $backup = Join-Path $Layout.backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $task = Get-BridgeTask $Layout
    $taskXml = $null
    $taskState = 'Absent'
    $processSet = $null
    try {
        if ($task) {
            $taskState = [string]$task.State
            $taskXml = Export-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath
            Write-BridgeAtomicText -Path (Join-Path $backup 'task.xml') -Text $taskXml
            $processSet = Get-BridgeProcessSet -Layout $Layout -Task $task -AllowMissingPair
            if ($taskState -eq 'Running' -and ($null -eq $processSet.Launcher -or $null -eq $processSet.Runtime)) {
                throw 'Backup cannot quiesce an unverified running process pair.'
            }
        }
        $stopReceipt = Stop-BridgeTaskExact -Layout $Layout
        $payload = Join-Path $backup 'payload'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        $installExisted = Test-Path -LiteralPath $Layout.installRoot -PathType Container
        if ($installExisted) {
            Copy-Item -LiteralPath $Layout.installRoot -Destination (Join-Path $payload 'install') -Recurse
        }
        $externalRoot = Join-Path $payload 'external'
        New-Item -ItemType Directory -Path $externalRoot -Force | Out-Null
        $external = [Collections.Generic.List[object]]::new()
        foreach ($item in Get-BridgeLayoutFiles $Layout) {
            $exists = Test-Path -LiteralPath $item.path -PathType Leaf
            $backupRelative = $null
            $hash = $null
            if ($exists) {
                $extension = [IO.Path]::GetExtension([string]$item.path)
                $backupRelative = ('payload/external/' + $item.label + $extension).Replace('\', '/')
                $destination = Join-Path $backup ($backupRelative.Replace('/', '\'))
                Copy-Item -LiteralPath $item.path -Destination $destination
                $hash = Get-BridgeFileHash $destination
                if ($hash -cne (Get-BridgeFileHash $item.path)) { throw "Backup copy hash mismatch: $($item.path)" }
            }
            $external.Add([ordered]@{
                label = $item.label
                originalPath = ConvertTo-BridgeCanonicalPath $item.path
                policy = $item.policy
                existed = [bool]$exists
                sha256 = $hash
                backupRelativePath = $backupRelative
            })
        }
        $manifestEntries = @(Get-BridgeRelativeFiles $backup | Where-Object { $_.path -notin @('backup-manifest.json', 'backup-receipt.json') })
        $backupManifest = [ordered]@{
            schema = 'codex-worktree-trust-bridge.backup-manifest'
            version = 1
            entries = $manifestEntries
        }
        $backupManifestPath = Join-Path $backup 'backup-manifest.json'
        Write-BridgeAtomicJson -Path $backupManifestPath -Value $backupManifest
        $receipt = [ordered]@{
            schema = 'codex-worktree-trust-bridge.backup'
            version = 1
            complete = $true
            createdAt = [DateTimeOffset]::Now.ToString('o')
            hostName = $env:COMPUTERNAME
            userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            layout = $Layout
            task = [ordered]@{
                existed = [bool]$task
                state = $taskState
                xmlRelativePath = if ($task) { 'task.xml' } else { $null }
                xmlSha256 = if ($task) { Get-BridgeFileHash (Join-Path $backup 'task.xml') } else { $null }
            }
            processSet = if ($processSet) { [ordered]@{
                launcher = $processSet.Launcher
                runtime = $processSet.Runtime
                descendants = @($processSet.Descendants)
            } } else { $null }
            stop = $stopReceipt
            install = [ordered]@{
                existed = [bool]$installExisted
                backupRelativePath = if ($installExisted) { 'payload/install' } else { $null }
                entries = if ($installExisted) { @(Get-BridgeRelativeFiles (Join-Path $payload 'install')) } else { @() }
            }
            external = $external.ToArray()
            manifestRelativePath = 'backup-manifest.json'
            manifestSha256 = Get-BridgeFileHash $backupManifestPath
        }
        Write-BridgeAtomicJson -Path (Join-Path $backup 'backup-receipt.json') -Value $receipt
        return [pscustomobject]@{ BackupDirectory = $backup; Receipt = $receipt; ReceiptPath = Join-Path $backup 'backup-receipt.json' }
    }
    catch {
        $failure = $_
        $restartFailure = $null
        try {
            $taskAfter = Get-BridgeTask $Layout
            if ($task -and $taskState -eq 'Running' -and $taskAfter) {
                if ([string]$taskAfter.State -ne 'Running') {
                    Start-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -ErrorAction Stop
                }
                [void](Wait-BridgeProcessPair -Layout $Layout -TimeoutSeconds 30)
            }
        }
        catch { $restartFailure = $_.Exception.Message }
        if ($restartFailure) {
            throw "Backup failed: $($failure.Exception.Message). Original task recovery also failed: $restartFailure"
        }
        throw $failure
    }
}

function Test-BridgeBackup {
    param([Parameter(Mandatory)][string]$BackupDirectory)
    $backup = ConvertTo-BridgeCanonicalPath $BackupDirectory
    $receiptPath = Join-Path $backup 'backup-receipt.json'
    $receipt = Read-BridgeJson -Path $receiptPath -MaximumBytes 4194304
    if ($receipt.schema -ne 'codex-worktree-trust-bridge.backup' -or [int]$receipt.version -ne 1 -or -not [bool]$receipt.complete) {
        throw 'Backup receipt is incomplete or unsupported.'
    }
    $manifestPath = Join-Path $backup ([string]$receipt.manifestRelativePath)
    if ((Get-BridgeFileHash $manifestPath) -cne [string]$receipt.manifestSha256) { throw 'Backup manifest hash mismatch.' }
    $manifest = Read-BridgeJson -Path $manifestPath -MaximumBytes 4194304
    if ($manifest.schema -ne 'codex-worktree-trust-bridge.backup-manifest' -or [int]$manifest.version -ne 1) {
        throw 'Unsupported backup manifest.'
    }
    foreach ($entry in @($manifest.entries)) {
        $relative = [string]$entry.path
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('..') -or $relative.Contains(':')) { throw 'Unsafe backup manifest path.' }
        $path = Join-Path $backup ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-BridgeFileHash $path) -cne [string]$entry.sha256) {
            throw "Backup payload hash mismatch: $relative"
        }
    }
    return [pscustomobject]@{ BackupDirectory = $backup; Receipt = $receipt; Manifest = $manifest; ReceiptPath = $receiptPath }
}

function Set-BridgeConfigurationPackageVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PackageVersion
    )
    $configuration = Read-BridgeJson -Path $Path -MaximumBytes 1048576
    if ($configuration.schema -ne 'codex-worktree-trust-bridge.config' -or [int]$configuration.version -ne 1) {
        throw 'Existing bridge configuration has an unsupported schema.'
    }
    $configuration.packageVersion = $PackageVersion
    Write-BridgeAtomicJson -Path $Path -Value $configuration
}

function Copy-BridgeArtifactStage {
    param([Parameter(Mandatory)]$Artifact, [Parameter(Mandatory)][string]$StageDirectory)
    New-Item -ItemType Directory -Path $StageDirectory -Force | Out-Null
    foreach ($entry in @($Artifact.Entries)) {
        Copy-Item -LiteralPath (Join-Path $Artifact.Directory ([string]$entry.path)) -Destination (Join-Path $StageDirectory ([string]$entry.path))
    }
    Copy-Item -LiteralPath $Artifact.ManifestPath -Destination (Join-Path $StageDirectory 'manifest.json')
    foreach ($entry in @($Artifact.Entries)) {
        $path = Join-Path $StageDirectory ([string]$entry.path)
        if ((Get-BridgeFileHash $path) -cne ([string]$entry.sha256).ToLowerInvariant()) { throw "Staged artifact hash mismatch: $($entry.path)" }
    }
    if ((Get-BridgeFileHash (Join-Path $StageDirectory 'manifest.json')) -cne $Artifact.ManifestSha256) {
        throw 'Staged manifest hash mismatch.'
    }
}

function Set-BridgeInstallDirectory {
    param([Parameter(Mandatory)]$Artifact, [Parameter(Mandatory)]$Layout)
    $parent = Split-Path -Parent $Layout.installRoot
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('.codex-worktree-trust-bridge.stage-' + [guid]::NewGuid().ToString('N'))
    $quarantine = Join-Path $parent ('.codex-worktree-trust-bridge.previous-' + [guid]::NewGuid().ToString('N'))
    $movedCurrent = $false
    try {
        Copy-BridgeArtifactStage -Artifact $Artifact -StageDirectory $stage
        if (Test-Path -LiteralPath $Layout.installRoot) {
            Move-Item -LiteralPath $Layout.installRoot -Destination $quarantine
            $movedCurrent = $true
        }
        Move-Item -LiteralPath $stage -Destination $Layout.installRoot
        Test-BridgeDirectoryAgainstEntries -Root $Layout.installRoot -Entries (@($Artifact.Entries) + @([pscustomobject]@{
            path = 'manifest.json'; sha256 = $Artifact.ManifestSha256
        }))
        if ($movedCurrent -and (Test-Path -LiteralPath $quarantine)) { Remove-Item -LiteralPath $quarantine -Recurse -Force }
    }
    catch {
        $failure = $_
        if (-not (Test-Path -LiteralPath $Layout.installRoot) -and $movedCurrent -and (Test-Path -LiteralPath $quarantine)) {
            Move-Item -LiteralPath $quarantine -Destination $Layout.installRoot
        }
        throw $failure
    }
    finally {
        foreach ($path in @($stage, $quarantine)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Set-BridgeTaskXmlAction {
    param(
        [Parameter(Mandatory)][string]$Xml,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    [xml]$document = $Xml
    $namespace = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespace.AddNamespace('t', $document.DocumentElement.NamespaceURI)
    $exec = $document.SelectSingleNode('//t:Actions/t:Exec', $namespace)
    if ($null -eq $exec -or $document.SelectNodes('//t:Actions/*', $namespace).Count -ne 1) {
        throw 'Task XML does not contain exactly one Exec action.'
    }
    function Set-TaskXmlValue {
        param([string]$Name, [string]$Value)
        $node = $exec.SelectSingleNode("t:$Name", $namespace)
        if ($null -eq $node) {
            $node = $document.CreateElement($Name, $document.DocumentElement.NamespaceURI)
            [void]$exec.AppendChild($node)
        }
        $node.InnerText = $Value
    }
    Set-TaskXmlValue -Name Command -Value $LauncherPath
    Set-TaskXmlValue -Name Arguments -Value $Arguments
    Set-TaskXmlValue -Name WorkingDirectory -Value $WorkingDirectory
    return $document.OuterXml
}

function Register-BridgeTaskForArtifact {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath,
        [string]$PreservedTaskXml
    )
    $arguments = [CodexTrustBridgeMaintenance.CommandLine]::Join([string[]]@(
        $PwshPath, $Layout.runtimePath, $Layout.configPath
    ))
    if ($PreservedTaskXml) {
        $xml = Set-BridgeTaskXmlAction -Xml $PreservedTaskXml -LauncherPath $Layout.launcherPath -Arguments $arguments -WorkingDirectory $Layout.installRoot
        Register-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -Xml $xml -Force | Out-Null
        return
    }
    $action = New-ScheduledTaskAction -Execute $Layout.launcherPath -Argument $arguments -WorkingDirectory $Layout.installRoot
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $trigger.Delay = 'PT10S'
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Codex folder trust bridge with bounded UI worker and owned process lifecycle.' -Force | Out-Null
}

function Wait-BridgeProcessPair {
    param([Parameter(Mandatory)]$Layout, [ValidateRange(1, 120)][int]$TimeoutSeconds = 30)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $task = Get-BridgeTask $Layout
        if ($task) {
            try {
                $set = Get-BridgeProcessSet -Layout $Layout -Task $task -AllowMissingPair
                if ($set.Launcher -and $set.Runtime) { return $set }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 200
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Timed out waiting for one exact launcher/runtime pair.'
}

function Get-BridgeInstalledStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Layout)
    try {
        $task = Get-BridgeTask $Layout
        if ($null -eq $task) { return [pscustomobject]@{ Healthy = $false; State = 'NOT_INSTALLED'; Error = $null } }
        $set = Get-BridgeProcessSet -Layout $Layout -Task $task -AllowMissingPair
        if ([string]$task.State -ne 'Running') { return [pscustomobject]@{ Healthy = $false; State = 'STOPPED'; Error = $null; ProcessSet = $set } }
        if (-not $set.Launcher -or -not $set.Runtime) { return [pscustomobject]@{ Healthy = $false; State = 'PROCESS_PAIR_INVALID'; Error = $null; ProcessSet = $set } }
        $artifact = Test-BridgeArtifactDirectory -ArtifactDirectory $Layout.installRoot -DevelopmentTest
        $manifest = $artifact.Manifest
        $manifestHash = $artifact.ManifestSha256
        $processReceipt = Read-BridgeJson -Path $Layout.processReceiptPath -MaximumBytes 262144
        $health = Read-BridgeJson -Path $Layout.healthPath -MaximumBytes 262144
        if ($processReceipt.schema -ne 'codex-worktree-trust-bridge.process' -or [int]$processReceipt.version -ne 1 -or
            $health.schema -ne 'codex-worktree-trust-bridge.health' -or [int]$health.version -ne 1) {
            throw 'Unsupported process or health receipt schema.'
        }
        $ageSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$health.updatedAtUtc)).TotalSeconds
        if ($ageSeconds -lt 0 -or $ageSeconds -gt 45) { throw 'Bridge health receipt is stale.' }
        if ([string]$processReceipt.phase -cne 'running' -or
            [string]$processReceipt.lifecycle -cne 'atomic-job-list-kill-on-close' -or
            [int]$processReceipt.launcherPid -ne [int]$set.Launcher.pid -or
            [int]$processReceipt.runtimePid -ne [int]$set.Runtime.pid -or
            [long]$processReceipt.launcherStartFileTimeUtc -ne [long]$set.Launcher.creationFileTimeUtc -or
            [long]$processReceipt.runtimeStartFileTimeUtc -ne [long]$set.Runtime.creationFileTimeUtc -or
            [string]$processReceipt.runId -cne [string]$health.runId -or
            [int]$health.pid -ne [int]$set.Runtime.pid -or [int]$health.launcherPid -ne [int]$set.Launcher.pid) {
            throw 'Live process identities do not match health/startup receipts.'
        }
        if (-not (Test-BridgePathToken ([string]$processReceipt.launcherPath) $Layout.launcherPath) -or
            -not (Test-BridgePathToken ([string]$processReceipt.runtimePath) $Layout.runtimePath) -or
            -not (Test-BridgePathToken ([string]$processReceipt.configPath) $Layout.configPath) -or
            -not (Test-BridgePathToken ([string]$processReceipt.pwshPath) $set.Action.PwshPath) -or
            [string]$processReceipt.launcherSha256 -ine (Get-BridgeFileHash $Layout.launcherPath) -or
            [string]$processReceipt.runtimeSha256 -ine (Get-BridgeFileHash $Layout.runtimePath) -or
            [string]$processReceipt.nativeSha256 -ine (Get-BridgeFileHash (Join-Path $Layout.installRoot 'CodexWorktreeTrustBridge.Native.dll'))) {
            throw 'Startup receipt paths or artifact hashes do not match the installed task.'
        }
        if ([string]$health.packageVersion -cne [string]$manifest.packageVersion -or
            [string]$health.sourceManifestSha256 -ine $manifestHash) {
            throw 'Live runtime does not identify the installed artifact manifest.'
        }
        $uiState = [string]$health.ui.state
        if ([bool]$health.healthy -and $uiState -notin @('HEALTHY', 'IDLE', 'DISABLED')) {
            throw "Health is true while the UI subsystem is $uiState."
        }
        foreach ($guard in @(
            @{ Name = 'uncertainUiOutcome'; Bad = $true },
            @{ Name = 'configWriteUncertain'; Bad = $true },
            @{ Name = 'resourceHealthy'; Bad = $false }
        )) {
            $property = $health.PSObject.Properties[$guard.Name]
            if ($null -ne $property -and [bool]$property.Value -eq [bool]$guard.Bad) {
                throw "Health guard is not satisfied: $($guard.Name)"
            }
        }
        $ready = [bool]$health.healthy
        return [pscustomobject]@{
            Healthy = $ready
            State = if ($ready) { 'HEALTHY' } else { 'DEGRADED' }
            Error = $null
            Task = $task
            ProcessSet = $set
            Health = $health
            ProcessReceipt = $processReceipt
            ManifestSha256 = $manifestHash
            PackageVersion = [string]$manifest.packageVersion
        }
    }
    catch {
        return [pscustomobject]@{ Healthy = $false; State = 'UNVERIFIED'; Error = $_.Exception.Message }
    }
}

function Wait-BridgeReady {
    param([Parameter(Mandatory)]$Layout, [ValidateRange(1, 180)][int]$TimeoutSeconds = 60)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    do {
        $last = Get-BridgeInstalledStatus -Layout $Layout
        if ($last.Healthy) { return $last }
        Start-Sleep -Milliseconds 250
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $detail = if ($last) { "$($last.State): $($last.Error)" } else { 'no status' }
    throw "Bridge did not reach verified readiness: $detail"
}

function Get-BridgeManagedBlock {
    param([AllowEmptyString()][string]$Text)
    foreach ($markers in @(
        @('# BEGIN CODEX WORKTREE TRUST BRIDGE', '# END CODEX WORKTREE TRUST BRIDGE'),
        @('# BEGIN CODEX AUTO WORKTREE TRUST', '# END CODEX AUTO WORKTREE TRUST')
    )) {
        $match = [regex]::Match($Text, '(?s)' + [regex]::Escape($markers[0]) + '.*?' + [regex]::Escape($markers[1]))
        if ($match.Success) { return $match.Value }
    }
    return ''
}

function Remove-BridgeManagedBlocks {
    param([AllowEmptyString()][string]$Text)
    $result = $Text
    foreach ($markers in @(
        @('# BEGIN CODEX WORKTREE TRUST BRIDGE', '# END CODEX WORKTREE TRUST BRIDGE'),
        @('# BEGIN CODEX AUTO WORKTREE TRUST', '# END CODEX AUTO WORKTREE TRUST')
    )) {
        $result = [regex]::Replace($result, '(?s)\r?\n?' + [regex]::Escape($markers[0]) + '.*?' + [regex]::Escape($markers[1]) + '\r?\n?', '')
    }
    return $result.TrimEnd()
}

function Merge-BridgeCodexConfigRollback {
    param([Parameter(Mandatory)][string]$CurrentPath, [string]$BackupPath, [bool]$BackupExisted)
    $current = if (Test-Path -LiteralPath $CurrentPath -PathType Leaf) { [IO.File]::ReadAllText($CurrentPath) } else { '' }
    $backup = if ($BackupExisted) { [IO.File]::ReadAllText($BackupPath) } else { '' }
    $base = Remove-BridgeManagedBlocks $current
    $block = Get-BridgeManagedBlock $backup
    $updated = $base
    if ($block) {
        if ($updated.Length) { $updated = $updated + [Environment]::NewLine + [Environment]::NewLine }
        $updated += $block
    }
    if ($updated.Length) { $updated = $updated.TrimEnd() + [Environment]::NewLine }
    if ($updated -ne $current) { Write-BridgeAtomicText -Path $CurrentPath -Text $updated }
}

function Restore-BridgeInstallDirectory {
    param([Parameter(Mandatory)]$Backup, [Parameter(Mandatory)]$Layout)
    $parent = Split-Path -Parent $Layout.installRoot
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('.codex-worktree-trust-bridge.rollback-' + [guid]::NewGuid().ToString('N'))
    $quarantine = Join-Path $parent ('.codex-worktree-trust-bridge.failed-' + [guid]::NewGuid().ToString('N'))
    $movedCurrent = $false
    try {
        if ([bool]$Backup.Receipt.install.existed) {
            Copy-Item -LiteralPath (Join-Path $Backup.BackupDirectory ([string]$Backup.Receipt.install.backupRelativePath)) -Destination $stage -Recurse
            Test-BridgeDirectoryAgainstEntries -Root $stage -Entries @($Backup.Receipt.install.entries)
        }
        if (Test-Path -LiteralPath $Layout.installRoot) {
            Move-Item -LiteralPath $Layout.installRoot -Destination $quarantine
            $movedCurrent = $true
        }
        if ([bool]$Backup.Receipt.install.existed) { Move-Item -LiteralPath $stage -Destination $Layout.installRoot }
        if ($movedCurrent -and (Test-Path -LiteralPath $quarantine)) { Remove-Item -LiteralPath $quarantine -Recurse -Force }
    }
    catch {
        $failure = $_
        if (-not (Test-Path -LiteralPath $Layout.installRoot) -and $movedCurrent -and (Test-Path -LiteralPath $quarantine)) {
            Move-Item -LiteralPath $quarantine -Destination $Layout.installRoot
        }
        throw $failure
    }
    finally {
        foreach ($path in @($stage, $quarantine)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Restore-BridgeExternalFiles {
    param([Parameter(Mandatory)]$Backup, [Parameter(Mandatory)]$Layout)
    foreach ($entry in @($Backup.Receipt.external)) {
        $destination = ConvertTo-BridgeCanonicalPath ([string]$entry.originalPath)
        $expected = @(
            $Layout.configPath, $Layout.statePath, $Layout.actionLedgerPath, $Layout.codexConfigPath,
            $Layout.healthPath, $Layout.processReceiptPath
        )
        if ($destination -notin $expected) { throw "Backup attempts to restore an unexpected path: $destination" }
        $source = if ($entry.backupRelativePath) { Join-Path $Backup.BackupDirectory (([string]$entry.backupRelativePath).Replace('/', '\')) } else { $null }
        switch ([string]$entry.policy) {
            'exact-conflict' {
                if ([bool]$entry.existed) {
                    Copy-BridgeAtomicFile -Source $source -Destination $destination
                }
                elseif (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            }
            'exact' {
                if ([bool]$entry.existed) {
                    Copy-BridgeAtomicFile -Source $source -Destination $destination
                }
                elseif (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            }
            'managed-block' {
                Merge-BridgeCodexConfigRollback -CurrentPath $destination -BackupPath $source -BackupExisted ([bool]$entry.existed)
            }
            'volatile-delete' {
                if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            }
            default { throw "Unsupported rollback policy: $($entry.policy)" }
        }
    }
}

function Restore-BridgeTaskFromBackup {
    param([Parameter(Mandatory)]$Backup, [Parameter(Mandatory)]$Layout)
    $current = Get-BridgeTask $Layout
    if ($current) { Unregister-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -Confirm:$false }
    if ([bool]$Backup.Receipt.task.existed) {
        $xmlPath = Join-Path $Backup.BackupDirectory ([string]$Backup.Receipt.task.xmlRelativePath)
        if ((Get-BridgeFileHash $xmlPath) -cne [string]$Backup.Receipt.task.xmlSha256) { throw 'Task XML backup hash mismatch.' }
        Register-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -Xml ([IO.File]::ReadAllText($xmlPath)) -Force | Out-Null
    }
}

function Test-BridgeConfigRollbackConflict {
    param([Parameter(Mandatory)]$Backup, [Parameter(Mandatory)]$InstallReceipt)
    $configEntry = @($Backup.Receipt.external | Where-Object { $_.label -eq 'bridge-config' })
    if ($configEntry.Count -ne 1) { throw 'Backup does not contain one bridge-config record.' }
    $currentExists = Test-Path -LiteralPath ([string]$configEntry[0].originalPath) -PathType Leaf
    $currentHash = if ($currentExists) { Get-BridgeFileHash ([string]$configEntry[0].originalPath) } else { $null }
    $expectedExists = [bool]$InstallReceipt.postInstall.bridgeConfigExisted
    $expectedHash = [string]$InstallReceipt.postInstall.bridgeConfigSha256
    if ($currentExists -ne $expectedExists -or ($expectedExists -and $currentHash -cne $expectedHash)) {
        throw 'Bridge configuration changed after installation; rollback refuses to overwrite the newer content.'
    }
}

function Invoke-BridgeRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallReceiptPath,
        [Parameter(Mandatory)]$Layout,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 45
    )
    $installReceipt = Read-BridgeJson -Path $InstallReceiptPath -MaximumBytes 4194304
    if ($installReceipt.schema -ne 'codex-worktree-trust-bridge.install' -or [int]$installReceipt.version -ne 1) {
        throw 'Unsupported install receipt.'
    }
    $backupReceiptPath = Join-Path ([string]$installReceipt.backupDirectory) 'backup-receipt.json'
    if ([string]::IsNullOrWhiteSpace([string]$installReceipt.backupReceiptSha256) -or
        -not (Test-Path -LiteralPath $backupReceiptPath -PathType Leaf) -or
        (Get-BridgeFileHash $backupReceiptPath) -cne [string]$installReceipt.backupReceiptSha256) {
        throw 'Install receipt does not bind the expected backup receipt hash.'
    }
    $backup = Test-BridgeBackup -BackupDirectory ([string]$installReceipt.backupDirectory)
    foreach ($name in @('taskName', 'taskPath', 'installRoot', 'configPath', 'statePath', 'actionLedgerPath', 'codexConfigPath')) {
        if ([string]$backup.Receipt.layout[$name] -ine [string]$Layout.$name) { throw "Rollback layout mismatch: $name" }
    }
    Test-BridgeConfigRollbackConflict -Backup $backup -InstallReceipt $installReceipt
    [void](Stop-BridgeTaskExact -Layout $Layout)
    Restore-BridgeInstallDirectory -Backup $backup -Layout $Layout
    Restore-BridgeExternalFiles -Backup $backup -Layout $Layout
    Restore-BridgeTaskFromBackup -Backup $backup -Layout $Layout
    $verification = $null
    if ([bool]$backup.Receipt.task.existed -and [string]$backup.Receipt.task.state -eq 'Running') {
        Start-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath
        $verification = Wait-BridgeProcessPair -Layout $Layout -TimeoutSeconds $TimeoutSeconds
    }
    $rollbackReceipt = [ordered]@{
        schema = 'codex-worktree-trust-bridge.rollback'
        version = 1
        completedAt = [DateTimeOffset]::Now.ToString('o')
        installReceiptPath = ConvertTo-BridgeCanonicalPath $InstallReceiptPath
        backupDirectory = $backup.BackupDirectory
        restoredTaskState = [string]$backup.Receipt.task.state
        verification = if ($verification) { [ordered]@{
            launcher = $verification.Launcher
            runtime = $verification.Runtime
        } } else { $null }
        passed = $true
    }
    $path = Join-Path $backup.BackupDirectory ('rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
    Write-BridgeAtomicJson -Path $path -Value $rollbackReceipt
    return [pscustomobject]@{ Passed = $true; ReceiptPath = $path; Receipt = $rollbackReceipt }
}

function Invoke-BridgeInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$PwshPath,
        [hashtable]$FreshConfiguration,
        [switch]$DevelopmentTest,
        [string]$TestRoot,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 60
    )
    Assert-BridgeMaintenanceScope -Layout $Layout -DevelopmentTest:$DevelopmentTest -TestRoot $TestRoot
    $artifact = Test-BridgeArtifactDirectory -ArtifactDirectory $ArtifactDirectory -DevelopmentTest:$DevelopmentTest
    $pwsh = ConvertTo-BridgeCanonicalPath $PwshPath
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw "PowerShell executable is missing: $pwsh" }
    $backup = New-BridgeQuiescedBackup -Layout $Layout
    $preservedXml = if ([bool]$backup.Receipt.task.existed) {
        [IO.File]::ReadAllText((Join-Path $backup.BackupDirectory ([string]$backup.Receipt.task.xmlRelativePath)))
    } else { $null }
    $installReceiptPath = Join-Path $backup.BackupDirectory 'install-receipt.json'
    $mutationStarted = $false
    $postInstallConfigExists = $false
    $postInstallConfigHash = $null
    try {
        $mutationStarted = $true
        Set-BridgeInstallDirectory -Artifact $artifact -Layout $Layout
        if (-not (Test-Path -LiteralPath $Layout.configPath -PathType Leaf)) {
            if ($null -eq $FreshConfiguration) { throw 'Fresh installation requires an explicit configuration.' }
            Write-BridgeAtomicJson -Path $Layout.configPath -Value $FreshConfiguration
        }
        else {
            Set-BridgeConfigurationPackageVersion -Path $Layout.configPath -PackageVersion $artifact.Version
        }
        $postInstallConfigExists = Test-Path -LiteralPath $Layout.configPath -PathType Leaf
        $postInstallConfigHash = if ($postInstallConfigExists) { Get-BridgeFileHash $Layout.configPath } else { $null }
        $existingTask = Get-BridgeTask $Layout
        if ($existingTask) { Unregister-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -Confirm:$false }
        Register-BridgeTaskForArtifact -Layout $Layout -PwshPath $pwsh -PreservedTaskXml $preservedXml
        Start-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath
        $ready = Wait-BridgeReady -Layout $Layout -TimeoutSeconds $TimeoutSeconds
        if ((Test-Path -LiteralPath $Layout.configPath -PathType Leaf) -ne $postInstallConfigExists -or
            ($postInstallConfigExists -and (Get-BridgeFileHash $Layout.configPath) -cne $postInstallConfigHash)) {
            throw 'Bridge configuration changed during installation readiness; installation will not claim success.'
        }
        $installedTaskXmlPath = Join-Path $backup.BackupDirectory 'installed-task.xml'
        Write-BridgeAtomicText -Path $installedTaskXmlPath -Text (Export-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath)
        $receipt = [ordered]@{
            schema = 'codex-worktree-trust-bridge.install'
            version = 1
            completedAt = [DateTimeOffset]::Now.ToString('o')
            passed = $true
            developmentTest = [bool]$DevelopmentTest
            backupDirectory = $backup.BackupDirectory
            backupReceiptSha256 = Get-BridgeFileHash $backup.ReceiptPath
            layout = $Layout
            artifact = [ordered]@{
                directory = $artifact.Directory
                packageVersion = $artifact.Version
                manifestSha256 = $artifact.ManifestSha256
                sourceCommit = [string]$artifact.Manifest.sourceCommit
                sourceDirty = [bool]$artifact.Manifest.sourceDirty
                accepted = [bool]$artifact.Manifest.accepted
            }
            postInstall = [ordered]@{
                bridgeConfigExisted = $postInstallConfigExists
                bridgeConfigSha256 = $postInstallConfigHash
                taskXmlSha256 = Get-BridgeFileHash $installedTaskXmlPath
                launcher = $ready.ProcessSet.Launcher
                runtime = $ready.ProcessSet.Runtime
                runId = [string]$ready.Health.runId
            }
        }
        Write-BridgeAtomicJson -Path $installReceiptPath -Value $receipt
        return [pscustomobject]@{ Passed = $true; ReceiptPath = $installReceiptPath; Receipt = $receipt; BackupDirectory = $backup.BackupDirectory }
    }
    catch {
        $failure = $_
        $rollback = $null
        if ($mutationStarted) {
            try {
                $preReceipt = [ordered]@{
                    schema = 'codex-worktree-trust-bridge.install'
                    version = 1
                    passed = $false
                    backupDirectory = $backup.BackupDirectory
                    backupReceiptSha256 = Get-BridgeFileHash $backup.ReceiptPath
                    postInstall = [ordered]@{
                        bridgeConfigExisted = $postInstallConfigExists
                        bridgeConfigSha256 = $postInstallConfigHash
                    }
                }
                Write-BridgeAtomicJson -Path $installReceiptPath -Value $preReceipt
                $rollback = Invoke-BridgeRollback -InstallReceiptPath $installReceiptPath -Layout $Layout -TimeoutSeconds $TimeoutSeconds
            }
            catch { $rollback = [pscustomobject]@{ Passed = $false; Error = $_.Exception.Message } }
        }
        $rollbackText = if ($rollback) { ($rollback | ConvertTo-Json -Depth 6 -Compress) } else { 'not attempted' }
        throw "Installation failed: $($failure.Exception.Message). Rollback: $rollbackText"
    }
}

function Invoke-BridgeUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Layout,
        [switch]$DevelopmentTest,
        [string]$TestRoot,
        [switch]$RemoveBridgeState,
        [switch]$RemoveBridgeConfiguration,
        [switch]$RemoveManagedTrustEntries,
        [ValidateSet('none', 'after-task-remove', 'after-install-remove')]
        [string]$TestFailureStep = 'none'
    )
    Assert-BridgeMaintenanceScope -Layout $Layout -DevelopmentTest:$DevelopmentTest -TestRoot $TestRoot
    if (-not $DevelopmentTest -and $TestFailureStep -ne 'none') { throw 'Failure injection is restricted to DevelopmentTest.' }
    if (-not $DevelopmentTest) {
        $manifest = Read-BridgeJson -Path $Layout.manifestPath -MaximumBytes 1048576
        if (-not [bool]$manifest.accepted) { throw 'Production uninstall remains blocked for an unaccepted installation.' }
    }
    $backup = New-BridgeQuiescedBackup -Layout $Layout
    $rollbackReceiptPath = Join-Path $backup.BackupDirectory 'uninstall-rollback-install.json'
    $configExpectedExists = Test-Path -LiteralPath $Layout.configPath -PathType Leaf
    $configExpectedHash = if ($configExpectedExists) { Get-BridgeFileHash $Layout.configPath } else { $null }
    $mutationStarted = $false
    try {
        $mutationStarted = $true
        $task = Get-BridgeTask $Layout
        if ($task) { Unregister-ScheduledTask -TaskName $Layout.taskName -TaskPath $Layout.taskPath -Confirm:$false }
        if ($TestFailureStep -eq 'after-task-remove') { throw 'Injected uninstall failure after task removal.' }
        if (Test-Path -LiteralPath $Layout.installRoot) { Remove-Item -LiteralPath $Layout.installRoot -Recurse -Force }
        if ($TestFailureStep -eq 'after-install-remove') { throw 'Injected uninstall failure after install removal.' }
        foreach ($path in @($Layout.healthPath, $Layout.processReceiptPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if ($RemoveBridgeState) {
            foreach ($path in @($Layout.statePath, $Layout.actionLedgerPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            }
        }
        if ($RemoveBridgeConfiguration -and (Test-Path -LiteralPath $Layout.configPath)) {
            Remove-Item -LiteralPath $Layout.configPath -Force
            $configExpectedExists = $false
            $configExpectedHash = $null
        }
        if ($RemoveManagedTrustEntries -and (Test-Path -LiteralPath $Layout.codexConfigPath -PathType Leaf)) {
            $text = [IO.File]::ReadAllText($Layout.codexConfigPath)
            $updated = Remove-BridgeManagedBlocks $text
            if ($updated.Length) { $updated = $updated.TrimEnd() + [Environment]::NewLine }
            Write-BridgeAtomicText -Path $Layout.codexConfigPath -Text $updated
        }
        $receipt = [ordered]@{
            schema = 'codex-worktree-trust-bridge.uninstall'
            version = 1
            passed = $true
            completedAt = [DateTimeOffset]::Now.ToString('o')
            backupDirectory = $backup.BackupDirectory
            backupReceiptSha256 = Get-BridgeFileHash $backup.ReceiptPath
            taskRemoved = -not [bool](Get-BridgeTask $Layout)
            installRemoved = -not (Test-Path -LiteralPath $Layout.installRoot)
            bridgeConfigurationRemoved = [bool]$RemoveBridgeConfiguration
            bridgeStateRemoved = [bool]$RemoveBridgeState
            managedTrustEntriesRemoved = [bool]$RemoveManagedTrustEntries
        }
        $path = Join-Path $backup.BackupDirectory 'uninstall-receipt.json'
        Write-BridgeAtomicJson -Path $path -Value $receipt
        return [pscustomobject]@{ Passed = $true; ReceiptPath = $path; BackupDirectory = $backup.BackupDirectory; Receipt = $receipt }
    }
    catch {
        $failure = $_
        $rollback = $null
        if ($mutationStarted) {
            try {
                Write-BridgeAtomicJson -Path $rollbackReceiptPath -Value ([ordered]@{
                    schema = 'codex-worktree-trust-bridge.install'
                    version = 1
                    passed = $false
                    backupDirectory = $backup.BackupDirectory
                    backupReceiptSha256 = Get-BridgeFileHash $backup.ReceiptPath
                    postInstall = [ordered]@{
                        bridgeConfigExisted = [bool]$configExpectedExists
                        bridgeConfigSha256 = $configExpectedHash
                    }
                })
                $rollback = Invoke-BridgeRollback -InstallReceiptPath $rollbackReceiptPath -Layout $Layout
            }
            catch { $rollback = [pscustomobject]@{ Passed = $false; Error = $_.Exception.Message } }
        }
        $rollbackText = if ($rollback) { $rollback | ConvertTo-Json -Depth 6 -Compress } else { 'not attempted' }
        throw "Uninstall failed after backup $($backup.BackupDirectory): $($failure.Exception.Message). Rollback: $rollbackText"
    }
}
