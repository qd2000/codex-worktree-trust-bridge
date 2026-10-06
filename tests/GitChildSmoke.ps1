[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageRoot = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $packageRoot 'src\CodexWorktreeTrustBridge.ps1'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $compiler) { throw 'Windows .NET Framework C# compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex trust git child smoke-' + [guid]::NewGuid().ToString('N'))
$profile = Join-Path $testRoot 'profile'
$codexHome = Join-Path $profile '.codex'
$fakeBin = Join-Path $testRoot 'fake bin'
$fakeGitSource = Join-Path $testRoot 'FakeGit.cs'
$fakeGit = Join-Path $fakeBin 'git.exe'
$probeLog = Join-Path $testRoot 'git-probe.log'
$repo = Join-Path $testRoot 'repo with spaces'
$bridgeConfig = Join-Path $profile 'bridge.json'
$oldUserProfile = $env:USERPROFILE
$oldPath = $env:PATH
$oldProbeLog = $env:CODEX_GIT_PROBE_LOG

try {
    New-Item -ItemType Directory -Force -Path @(
        $codexHome,
        $fakeBin,
        $repo,
        (Join-Path $repo '.git')
    ) | Out-Null

    @'
using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

internal static class Program
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    private static int Main(string[] args)
    {
        string probeLog = Environment.GetEnvironmentVariable("CODEX_GIT_PROBE_LOG");
        if (!String.IsNullOrEmpty(probeLog))
        {
            File.AppendAllText(
                probeLog,
                GetConsoleWindow().ToInt64().ToString(CultureInfo.InvariantCulture) + "|" +
                String.Join("\u001f", args) + Environment.NewLine
            );
        }

        string workingDirectory = Directory.GetCurrentDirectory();
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "-C")
            {
                workingDirectory = Path.GetFullPath(args[i + 1]);
                break;
            }
        }

        if (Array.IndexOf(args, "--show-toplevel") >= 0)
        {
            Console.WriteLine(workingDirectory);
            return 0;
        }
        if (Array.IndexOf(args, "--git-common-dir") >= 0)
        {
            Console.WriteLine(".git");
            return 0;
        }
        if (Array.IndexOf(args, "worktree") >= 0 && Array.IndexOf(args, "--porcelain") >= 0)
        {
            Console.WriteLine("worktree " + workingDirectory);
            Console.WriteLine("HEAD 0000000000000000000000000000000000000000");
            Console.WriteLine("detached");
            Console.WriteLine();
            return 0;
        }

        return 0;
    }
}
'@ | Set-Content -LiteralPath $fakeGitSource -Encoding utf8NoBOM

    & $compiler /nologo /target:exe /platform:anycpu /optimize+ ("/out:$fakeGit") $fakeGitSource
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeGit -PathType Leaf)) {
        throw "Fake git compilation failed with exit code $LASTEXITCODE."
    }

    [IO.File]::WriteAllText(
        (Join-Path $codexHome 'config.toml'),
        "# BEGIN CODEX WORKTREE TRUST BRIDGE`r`n# END CODEX WORKTREE TRUST BRIDGE`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $configuration = [ordered]@{
        schema = 'codex-worktree-trust-bridge.config'
        version = 1
        allowedRoots = @($repo)
        uiPollIntervalMs = 750
        reconcileIntervalSeconds = 60
        discoveryDepth = 2
        trustMode = 'git-only'
        deniedDialogAction = 'leave-open'
        deniedDialogGraceSeconds = 3
        enableConfigTrust = $true
        enableUiAutoApprove = $false
        pruneMissingManagedEntries = $true
    }
    [IO.File]::WriteAllText(
        $bridgeConfig,
        ($configuration | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false)
    )

    $env:USERPROFILE = $profile
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath
    $env:CODEX_GIT_PROBE_LOG = $probeLog
    & $pwsh -NoLogo -NoProfile -File $runtime `
        -ConfigPath $bridgeConfig `
        -InstanceName ('git-child-smoke-' + [guid]::NewGuid().ToString('N')) `
        -Once
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime returned exit code $LASTEXITCODE."
    }

    $probeEntries = @(Get-Content -LiteralPath $probeLog -ErrorAction Stop)
    if ($probeEntries.Count -lt 2) {
        throw "Expected at least two fake git invocations, observed $($probeEntries.Count)."
    }
    $visibleConsoleEntries = @($probeEntries | Where-Object {
        [int64](($_ -split '\|', 2)[0]) -ne 0
    })
    if ($visibleConsoleEntries.Count) {
        throw "A git child observed a console window: $($visibleConsoleEntries -join '; ')"
    }

    [pscustomobject]@{
        Passed = $true
        GitInvocations = $probeEntries.Count
        ConsoleWindowHandles = @($probeEntries | ForEach-Object { [int64](($_ -split '\|', 2)[0]) })
    } | ConvertTo-Json -Depth 5
}
finally {
    $env:USERPROFILE = $oldUserProfile
    $env:PATH = $oldPath
    if ($null -eq $oldProbeLog) {
        Remove-Item Env:CODEX_GIT_PROBE_LOG -ErrorAction SilentlyContinue
    }
    else {
        $env:CODEX_GIT_PROBE_LOG = $oldProbeLog
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
