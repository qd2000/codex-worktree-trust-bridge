using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            return 64;
        }

        string pwshPath = args[0];
        string runtimePath = args[1];
        string configPath = args[2];

        if (!File.Exists(pwshPath) || !File.Exists(runtimePath) || !File.Exists(configPath))
        {
            return 66;
        }

        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = pwshPath;
            startInfo.Arguments = JoinArguments(new string[]
            {
                "-STA",
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                runtimePath,
                "-ConfigPath",
                configPath
            });
            startInfo.WorkingDirectory = Path.GetDirectoryName(runtimePath);
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            startInfo.EnvironmentVariables["CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID"] =
                Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture);

            using (Process child = Process.Start(startInfo))
            {
                if (child == null)
                {
                    return 70;
                }

                child.WaitForExit();
                return child.ExitCode;
            }
        }
        catch
        {
            return 70;
        }
    }

    private static string JoinArguments(string[] values)
    {
        StringBuilder commandLine = new StringBuilder();
        for (int i = 0; i < values.Length; i++)
        {
            if (i > 0)
            {
                commandLine.Append(' ');
            }

            commandLine.Append(QuoteArgument(values[i]));
        }

        return commandLine.ToString();
    }

    // Implements the Windows CommandLineToArgvW/CRT quoting rules so paths with
    // spaces and trailing backslashes are passed to pwsh without shell parsing.
    private static string QuoteArgument(string value)
    {
        if (value == null || value.Length == 0)
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new char[] { ' ', '\t', '\r', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        StringBuilder quoted = new StringBuilder();
        quoted.Append('"');
        int backslashes = 0;

        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                quoted.Append('\\', (backslashes * 2) + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }

            quoted.Append('\\', backslashes);
            quoted.Append(character);
            backslashes = 0;
        }

        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }
}
