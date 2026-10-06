[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
$launcherSource = Join-Path $packageRoot 'src\CodexWorktreeTrustBridge.Launcher.cs'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $compiler) { throw 'Windows .NET Framework C# compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex trust launcher smoke-' + [guid]::NewGuid().ToString('N'))
$launcher = Join-Path $testRoot 'CodexWorktreeTrustBridge.Launcher.exe'
$helper = Join-Path $testRoot 'ChildProbe.ps1'
$configPath = Join-Path $testRoot 'probe-config.json'
$resultPath = Join-Path $testRoot 'probe-result.json'

function Get-PeSubsystem {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature.' }
        $stream.Position = $peOffset + 4 + 20 + 68
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ ("/out:$launcher") $launcherSource
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Launcher compilation failed with exit code $LASTEXITCODE."
    }

    $subsystem = Get-PeSubsystem -Path $launcher
    if ($subsystem -ne 2) {
        throw "Launcher PE subsystem is $subsystem, expected 2 (Windows GUI)."
    }

    @'
param([Parameter(Mandatory = $true)][string]$ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleProbeNative {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
$self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$record = [ordered]@{
    childPid = $PID
    parentPid = [int]$self.ParentProcessId
    launcherPidFromEnvironment = [int]$env:CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID
    consoleWindowHandle = [int64][ConsoleProbeNative]::GetConsoleWindow()
    configPath = $ConfigPath
}
[IO.File]::WriteAllText(
    [string]$configuration.outputPath,
    ($record | ConvertTo-Json -Depth 4),
    [Text.UTF8Encoding]::new($false)
)
'@ | Set-Content -LiteralPath $helper -Encoding utf8NoBOM

    [IO.File]::WriteAllText(
        $configPath,
        ([ordered]@{ outputPath = $resultPath } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $launcher
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void]$startInfo.ArgumentList.Add($pwsh)
    [void]$startInfo.ArgumentList.Add($helper)
    [void]$startInfo.ArgumentList.Add($configPath)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Launcher did not start.' }
        $launcherPid = $process.Id
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch {}
            throw 'Launcher smoke timed out.'
        }
        if ($process.ExitCode -ne 0) {
            throw "Launcher returned exit code $($process.ExitCode)."
        }
    }
    finally {
        $process.Dispose()
    }

    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'Child probe did not publish a result.'
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ([int64]$result.consoleWindowHandle -ne 0) {
        throw "Child pwsh owns a console window handle: $($result.consoleWindowHandle)."
    }
    if ([int]$result.parentPid -ne $launcherPid -or
        [int]$result.launcherPidFromEnvironment -ne $launcherPid) {
        throw 'Launcher/child process identity did not match.'
    }

    [pscustomobject]@{
        Passed = $true
        LauncherSubsystem = $subsystem
        LauncherProcessId = $launcherPid
        ChildProcessId = [int]$result.childPid
        ChildConsoleWindowHandle = [int64]$result.consoleWindowHandle
    } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
