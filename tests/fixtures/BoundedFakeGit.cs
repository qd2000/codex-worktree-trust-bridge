using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

internal static class BoundedFakeGit
{
    private static string Env(string name)
    {
        string value = Environment.GetEnvironmentVariable(name);
        if (String.IsNullOrWhiteSpace(value)) throw new InvalidOperationException("Missing fixture environment: " + name);
        return value;
    }

    private static void Log(string mode, int childPid, long childBirth)
    {
        string path = Env("CODEX_GIT_BOUNDARY_LOG");
        using (Process self = Process.GetCurrentProcess())
        {
            string line = String.Join("|", new string[] {
                self.Id.ToString(CultureInfo.InvariantCulture),
                self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(CultureInfo.InvariantCulture),
                childPid.ToString(CultureInfo.InvariantCulture),
                childBirth.ToString(CultureInfo.InvariantCulture),
                mode
            }) + Environment.NewLine;
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    using (FileStream stream = new FileStream(path, FileMode.Append, FileAccess.Write,
                        FileShare.ReadWrite | FileShare.Delete))
                    using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false)))
                    { writer.Write(line); }
                    return;
                }
                catch (IOException)
                {
                    if (attempt >= 10) throw;
                    Thread.Sleep(10 * (attempt + 1));
                }
            }
        }
    }

    private static string Mode()
    {
        string path = Env("CODEX_GIT_BOUNDARY_CONTROL");
        return File.Exists(path) ? File.ReadAllText(path).Trim() : "normal";
    }

    private static bool Has(string[] args, string value)
    { return Array.IndexOf(args, value) >= 0; }

    private static string WorkingDirectory(string[] args)
    {
        for (int index = 0; index + 1 < args.Length; index++)
            if (args[index] == "-C") return Path.GetFullPath(args[index + 1]);
        return Directory.GetCurrentDirectory();
    }

    private static void WriteRepeated(Stream stream, byte value, int count)
    {
        byte[] buffer = new byte[1024];
        for (int index = 0; index < buffer.Length; index++) buffer[index] = value;
        while (count > 0)
        {
            int current = Math.Min(buffer.Length, count);
            stream.Write(buffer, 0, current);
            stream.Flush();
            count -= current;
        }
    }

    private static int Main(string[] args)
    {
        if (Has(args, "--fixture-child-hang"))
        {
            Thread.Sleep(TimeSpan.FromMinutes(10));
            return 0;
        }

        string mode = Mode();
        if (mode == "hang")
        {
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = Assembly.GetExecutingAssembly().Location;
            info.Arguments = "--fixture-child-hang";
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            using (Process child = Process.Start(info))
            {
                Log(mode, child.Id, child.StartTime.ToUniversalTime().ToFileTimeUtc());
                Thread.Sleep(TimeSpan.FromMinutes(10));
            }
            return 0;
        }

        Log(mode, 0, 0);
        if (mode == "stdout-overflow")
        {
            WriteRepeated(Console.OpenStandardOutput(), (byte)'A', 16384);
            return 0;
        }
        if (mode == "stderr-overflow")
        {
            WriteRepeated(Console.OpenStandardError(), (byte)'E', 16384);
            return 0;
        }
        if (mode == "invalid-utf8")
        {
            byte[] invalid = new byte[] { 0xff, 0xfe, 0xfd, 0x0a };
            Console.OpenStandardOutput().Write(invalid, 0, invalid.Length);
            return 0;
        }
        if (mode == "exit-42")
        {
            Console.Error.WriteLine("controlled non-zero Git result");
            return 42;
        }

        string root = Path.GetFullPath(Env("CODEX_GIT_BOUNDARY_REPO"));
        string working = WorkingDirectory(args);
        string stale = Environment.GetEnvironmentVariable("CODEX_GIT_BOUNDARY_STALE");
        if (!String.IsNullOrWhiteSpace(stale) &&
            String.Equals(Path.GetFullPath(stale), working, StringComparison.OrdinalIgnoreCase) &&
            Has(args, "--git-common-dir"))
        {
            Console.Error.WriteLine("fatal: not a git repository: (NULL)");
            return 128;
        }
        if (Has(args, "--show-toplevel"))
        {
            Console.WriteLine(working);
            return 0;
        }
        if (Has(args, "--git-common-dir"))
        {
            if (mode == "malformed-common")
            {
                Console.WriteLine(Path.Combine(root, ".git"));
                Console.WriteLine("unexpected-second-line");
            }
            else Console.WriteLine(Path.Combine(root, ".git"));
            return 0;
        }
        if (Has(args, "worktree") && Has(args, "--porcelain"))
        {
            int children = 0;
            if (mode == "worktree-overflow") children = 4;
            if (mode == "command-overflow") children = 3;
            Console.WriteLine("worktree " + root);
            Console.WriteLine("HEAD 0000000000000000000000000000000000000000");
            Console.WriteLine("detached");
            Console.WriteLine();
            for (int index = 1; index <= children; index++)
            {
                Console.WriteLine("worktree " + Path.Combine(root, "wt" + index));
                Console.WriteLine("HEAD 0000000000000000000000000000000000000000");
                Console.WriteLine("detached");
                Console.WriteLine();
            }
            return 0;
        }
        return 0;
    }
}
