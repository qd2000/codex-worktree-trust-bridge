using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using CodexTrustBridge;

internal static class Program
{
    [MTAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 3) return 64;
        string pwsh = Path.GetFullPath(args[0]);
        string runtime = Path.GetFullPath(args[1]);
        string config = Path.GetFullPath(args[2]);
        if (!File.Exists(pwsh) || !File.Exists(runtime) || !File.Exists(config)) return 66;

        string receiptPath = config + ".process.json";
        string identity;
        using (WindowsIdentity user = WindowsIdentity.GetCurrent())
            identity = user.User.Value + "|" + config.ToLowerInvariant();
        string mutexName = "Local\\CodexTrustBridgeLauncher-" + HashText(identity);
        bool acquired = false;
        Dictionary<string, object> receipt = new Dictionary<string, object>();
        using (Mutex mutex = new Mutex(false, mutexName))
        {
            try
            {
                try { acquired = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return 17; // Duplicate launcher; do not overwrite its receipt.

                using (Process self = Process.GetCurrentProcess())
                {
                    string runId = Guid.NewGuid().ToString("N");
                    Environment.SetEnvironmentVariable("CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_PID",
                        self.Id.ToString(CultureInfo.InvariantCulture));
                    Environment.SetEnvironmentVariable("CODEX_WORKTREE_TRUST_BRIDGE_LAUNCHER_START_TICKS",
                        self.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture));
                    Environment.SetEnvironmentVariable("CODEX_WORKTREE_TRUST_BRIDGE_RUN_ID", runId);
                    Environment.SetEnvironmentVariable("CODEX_WORKTREE_TRUST_BRIDGE_LIFECYCLE", "atomic-job-list");

                    receipt["schema"] = "codex-worktree-trust-bridge.process";
                    receipt["version"] = 1;
                    receipt["runId"] = runId;
                    receipt["lifecycle"] = "atomic-job-list-kill-on-close";
                    receipt["launcherPid"] = self.Id;
                    receipt["launcherStartFileTimeUtc"] = self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(CultureInfo.InvariantCulture);
                    receipt["launcherPath"] = Assembly.GetExecutingAssembly().Location;
                    receipt["launcherSha256"] = HashFile(Assembly.GetExecutingAssembly().Location);
                    receipt["runtimePath"] = runtime;
                    receipt["runtimeSha256"] = HashFile(runtime);
                    receipt["pwshPath"] = pwsh;
                    receipt["configPath"] = config;
                    receipt["nativeSha256"] = HashFile(typeof(OwnedProcess).Assembly.Location);

                    string[] childArgs = new string[] {
                        "-MTA", "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
                        "-ExecutionPolicy", "Bypass", "-File", runtime, "-ConfigPath", config
                    };
                    using (OwnedProcess child = OwnedProcess.Start(pwsh, childArgs,
                        Path.GetDirectoryName(runtime), 0, 0, true))
                    {
                        receipt["runtimePid"] = child.Id;
                        receipt["runtimeStartFileTimeUtc"] = child.CreationFileTimeUtc.ToString(CultureInfo.InvariantCulture);
                        Publish(receiptPath, receipt, "owned-suspended", null);
                        child.Resume();
                        Publish(receiptPath, receipt, "running", null);
                        child.WaitForExit(-1);
                        int code = child.ExitCode;
                        receipt["runtimeExitCode"] = code;
                        if (!child.StopAndWait(10000))
                        {
                            Publish(receiptPath, receipt, "cleanup-uncertain", "Owned job did not empty within ten seconds.");
                            return 74;
                        }
                        Publish(receiptPath, receipt, "exited", null);
                        return code;
                    }
                }
            }
            catch (Exception error)
            {
                // No unsafe Process.Start fallback and no restart loop. Native job
                // handles close during stack unwinding even if recording fails.
                try { Publish(receiptPath, receipt, "failed", error.GetType().Name + ": " + error.Message); }
                catch { }
                return 70;
            }
            finally { if (acquired) mutex.ReleaseMutex(); }
        }
    }

    private static void Publish(string path, Dictionary<string, object> data, string phase, string error)
    {
        data["phase"] = phase;
        data["updatedAtUtc"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        data["error"] = error;
        string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(data), new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static string HashText(string text)
    {
        using (SHA256 hash = SHA256.Create())
            return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(text))).Replace("-", "").ToLowerInvariant();
    }

    private static string HashFile(string path)
    {
        using (SHA256 hash = SHA256.Create())
        using (Stream stream = File.OpenRead(path))
            return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }
}
