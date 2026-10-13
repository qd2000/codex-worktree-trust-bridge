using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace CodexTrustBridge
{
    internal sealed class KernelHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal KernelHandle(IntPtr value) : base(true) { SetHandle(value); }
        protected override bool ReleaseHandle() { return Native.CloseHandle(handle); }
    }

    public sealed class ProcessSample
    {
        public int ProcessId;
        public long CreationFileTimeUtc;
        public long PrivateBytes;
        public long WorkingSetBytes;
        public int Handles;
        public int ActiveJobProcesses;
    }

    // Owns a kernel job, not a process-name pattern. No breakaway flag or
    // inheritable job handle is used. JOB_LIST makes ownership part of creation,
    // including when the creating process dies before CreateProcess returns.
    public sealed class OwnedProcess : IDisposable
    {
        private KernelHandle job;
        private KernelHandle process;
        private KernelHandle thread;
        private bool resumed;
        public int Id { get; private set; }
        public long CreationFileTimeUtc { get; private set; }

        private OwnedProcess() { }

        public static OwnedProcess Start(string executable, string[] arguments,
            string directory, long memoryLimitBytes, int processLimit, bool suspended)
        {
            if (!Path.IsPathRooted(executable) || !File.Exists(executable))
                throw new ArgumentException("An existing absolute executable path is required.");
            if (memoryLimitBytes < 0 || processLimit < 0)
                throw new ArgumentOutOfRangeException("Negative job limits are not allowed.");
            OwnedProcess owned = new OwnedProcess();
            IntPtr attributes = IntPtr.Zero;
            IntPtr jobList = IntPtr.Zero;
            bool initialized = false;
            try
            {
                owned.job = new KernelHandle(Native.CreateJobObjectW(IntPtr.Zero, null));
                if (owned.job.IsInvalid) throw Native.Error("CreateJobObject");
                Native.ExtendedLimits limits = new Native.ExtendedLimits();
                limits.Basic.LimitFlags = 0x00002000; // KILL_ON_JOB_CLOSE
                if (memoryLimitBytes != 0)
                {
                    limits.Basic.LimitFlags |= 0x00000300; // PROCESS_MEMORY | JOB_MEMORY
                    limits.ProcessMemoryLimit = new UIntPtr((ulong)memoryLimitBytes);
                    limits.JobMemoryLimit = new UIntPtr((ulong)memoryLimitBytes);
                }
                if (processLimit != 0)
                {
                    limits.Basic.LimitFlags |= 0x00000008; // ACTIVE_PROCESS
                    limits.Basic.ActiveProcessLimit = (uint)processLimit;
                }
                if (!Native.SetInformationJobObject(owned.job, 9, ref limits,
                    (uint)Marshal.SizeOf(typeof(Native.ExtendedLimits))))
                    throw Native.Error("SetInformationJobObject");

                IntPtr size = IntPtr.Zero;
                Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                if (size == IntPtr.Zero) throw Native.Error("Attribute-list size");
                attributes = Marshal.AllocHGlobal(size);
                if (!Native.InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
                    throw Native.Error("InitializeProcThreadAttributeList");
                initialized = true;
                jobList = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobList, owned.job.DangerousGetHandle());
                if (!Native.UpdateProcThreadAttribute(attributes, 0,
                    new IntPtr(0x0002000d), jobList, new IntPtr(IntPtr.Size),
                    IntPtr.Zero, IntPtr.Zero))
                    throw Native.Error("PROC_THREAD_ATTRIBUTE_JOB_LIST");

                Native.StartupInfoEx startup = new Native.StartupInfoEx();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(Native.StartupInfoEx));
                startup.StartupInfo.dwFlags = 1; // STARTF_USESHOWWINDOW
                startup.StartupInfo.wShowWindow = 0;
                startup.AttributeList = attributes;
                Native.ProcessInformation info;
                string[] command = new string[arguments.Length + 1];
                command[0] = executable;
                Array.Copy(arguments, 0, command, 1, arguments.Length);
                // Always create suspended *and already in the job*. There is no
                // unattached suspended-child window and no unsafe legacy fallback.
                const uint flags = 0x08000000 | 0x00080000 | 0x00000004;
                if (!Native.CreateProcessW(executable,
                    new StringBuilder(CommandLine.Join(command)), IntPtr.Zero,
                    IntPtr.Zero, false, flags, IntPtr.Zero, directory, ref startup, out info))
                    throw Native.Error("CreateProcess with atomic job ownership");
                owned.process = new KernelHandle(info.hProcess);
                owned.thread = new KernelHandle(info.hThread);
                owned.Id = (int)info.dwProcessId;
                long exit, kernel, user, creation;
                if (!Native.GetProcessTimes(owned.process, out creation, out exit, out kernel, out user))
                    throw Native.Error("GetProcessTimes");
                owned.CreationFileTimeUtc = creation;
                bool member;
                if (!Native.IsProcessInJob(owned.process, owned.job, out member) || !member)
                    throw new InvalidOperationException("Created process is not in the owning job.");
                if (!suspended) owned.Resume();
                return owned;
            }
            catch
            {
                owned.Dispose(); // Closing our sole job handle kills only our children.
                throw;
            }
            finally
            {
                if (initialized) Native.DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
                GC.KeepAlive(owned.job);
            }
        }

        public void Resume()
        {
            if (resumed) throw new InvalidOperationException("Child was already resumed.");
            if (Native.ResumeThread(thread) == UInt32.MaxValue) throw Native.Error("ResumeThread");
            resumed = true;
            thread.Dispose();
            thread = null;
        }

        public bool WaitForExit(int milliseconds)
        {
            uint result = Native.WaitForSingleObject(process,
                milliseconds < 0 ? UInt32.MaxValue : (uint)milliseconds);
            if (result == 0) return true;
            if (result == 258) return false;
            throw Native.Error("WaitForSingleObject");
        }

        public bool HasExited { get { return WaitForExit(0); } }

        public int ExitCode
        {
            get
            {
                if (!HasExited) throw new InvalidOperationException("Process is still running.");
                uint code;
                if (!Native.GetExitCodeProcess(process, out code)) throw Native.Error("GetExitCodeProcess");
                return unchecked((int)code);
            }
        }

        public int[] GetProcessIds()
        {
            const int capacity = 256;
            int size = 8 + capacity * IntPtr.Size;
            IntPtr data = Marshal.AllocHGlobal(size);
            try
            {
                uint returned;
                if (!Native.QueryInformationJobObject(job, 3, data, (uint)size, out returned))
                    throw Native.Error("Query job process identities");
                int count = Marshal.ReadInt32(data, 4);
                if (count < 0 || count > capacity) throw new InvalidDataException("Job identity list overflow.");
                int[] ids = new int[count];
                for (int i = 0; i < count; i++)
                    ids[i] = checked((int)Marshal.ReadIntPtr(data, 8 + i * IntPtr.Size).ToInt64());
                return ids;
            }
            finally { Marshal.FreeHGlobal(data); }
        }

        public ProcessSample Sample()
        {
            Native.MemoryCounters counters = new Native.MemoryCounters();
            counters.cb = (uint)Marshal.SizeOf(typeof(Native.MemoryCounters));
            if (!Native.GetProcessMemoryInfo(process, ref counters, counters.cb))
                throw Native.Error("GetProcessMemoryInfo");
            uint handles;
            if (!Native.GetProcessHandleCount(process, out handles))
                throw Native.Error("GetProcessHandleCount");
            return new ProcessSample {
                ProcessId = Id, CreationFileTimeUtc = CreationFileTimeUtc,
                PrivateBytes = checked((long)counters.PrivateUsage.ToUInt64()),
                WorkingSetBytes = checked((long)counters.WorkingSetSize.ToUInt64()),
                Handles = checked((int)handles), ActiveJobProcesses = GetProcessIds().Length
            };
        }

        // Exit verification is explicit. Dispose alone is never a cleanup receipt.
        public bool StopAndWait(int milliseconds)
        {
            if (!Native.TerminateJobObject(job, 0xE022)) throw Native.Error("TerminateJobObject");
            Stopwatch clock = Stopwatch.StartNew();
            do
            {
                if (GetProcessIds().Length == 0) return true;
                Thread.Sleep(20);
            } while (clock.ElapsedMilliseconds < milliseconds);
            return GetProcessIds().Length == 0;
        }

        public void Dispose()
        {
            if (job != null) { job.Dispose(); job = null; }
            if (thread != null) { thread.Dispose(); thread = null; }
            if (process != null) { process.Dispose(); process = null; }
        }
    }

    public static class CommandLine
    {
        public static string[] Split(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return new string[0];
            int count;
            IntPtr values = Native.CommandLineToArgvW(value, out count);
            if (values == IntPtr.Zero) throw Native.Error("CommandLineToArgvW");
            try
            {
                string[] result = new string[count];
                for (int i = 0; i < count; i++)
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * IntPtr.Size));
                return result;
            }
            finally { Native.LocalFree(values); }
        }

        public static string Join(string[] values)
        {
            StringBuilder result = new StringBuilder();
            foreach (string value in values)
            {
                if (result.Length != 0) result.Append(' ');
                result.Append(Quote(value));
            }
            return result.ToString();
        }

        public static string Quote(string value)
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
            return quoted.Append('\\', slashes * 2).Append('"').ToString();
        }
    }

    public static class PackageIdentity
    {
        public sealed class RegistrationProof
        {
            public string Family;
            public string FullName;
            public string InstallPath;
            public string Executable;
            public string Origin;
        }

        public static RegistrationProof VerifyRegisteredStoreExecutable(string executable, string family)
        {
            // Some full-trust desktop children have no token package identity.
            // Do not fall back to a process name, WindowsApps-looking string,
            // unregistered staged package, developer package, or publisher text.
            // Require current-user registration + OS Store origin + exact path.
            executable = Path.GetFullPath(executable);
            uint count = 0, characters = 0;
            int code = Native.GetPackagesByPackageFamily(family, ref count, IntPtr.Zero, ref characters, IntPtr.Zero);
            if (code == 0 && count == 0) return null;
            if (code != 122 || count == 0 || count > 32 || characters == 0 || characters > 65536)
                throw new Win32Exception(code, "Cannot bound the current-user package registration query.");
            uint capacity = count;
            IntPtr names = Marshal.AllocHGlobal(checked((int)count * IntPtr.Size));
            IntPtr strings = Marshal.AllocHGlobal(checked((int)characters * 2));
            try
            {
                code = Native.GetPackagesByPackageFamily(family, ref count, names, ref characters, strings);
                if (code != 0 || count > capacity) throw new Win32Exception(code, "Package registration changed during lookup.");
                RegistrationProof result = null;
                for (int i = 0; i < count; i++)
                {
                    string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(names, i * IntPtr.Size));
                    int origin;
                    code = Native.GetStagedPackageOrigin(name, out origin);
                    if (code != 0) throw new Win32Exception(code, "Cannot verify the registered package origin.");
                    if (origin != 3) continue; // PackageOrigin_Store; no dev/unsigned fallback.
                    uint pathLength = 0;
                    code = Native.GetStagedPackagePathByFullName(name, ref pathLength, null);
                    if (code != 122 || pathLength == 0 || pathLength > 32768)
                        throw new Win32Exception(code, "Cannot bound the registered package path.");
                    StringBuilder path = new StringBuilder((int)pathLength);
                    code = Native.GetStagedPackagePathByFullName(name, ref pathLength, path);
                    if (code != 0) throw new Win32Exception(code, "Cannot resolve the registered package path.");
                    string install = Path.GetFullPath(path.ToString());
                    string expected = Path.GetFullPath(Path.Combine(install, "app", "ChatGPT.exe"));
                    if (!String.Equals(expected, executable, StringComparison.OrdinalIgnoreCase)) continue;
                    foreach (string item in new string[] { install, Path.Combine(install, "app"), expected })
                        if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                            throw new InvalidOperationException("A registered target path contains a reparse point.");
                    if (result != null) throw new InvalidOperationException("Multiple package registrations identify the same target executable.");
                    result = new RegistrationProof { Family = family, FullName = name,
                        InstallPath = install, Executable = expected, Origin = "Store" };
                }
                return result;
            }
            finally { Marshal.FreeHGlobal(strings); Marshal.FreeHGlobal(names); }
        }

        public static string GetFamily(Process process)
        {
            uint length = 0;
            int code = Native.GetPackageFamilyName(process.Handle, ref length, null);
            if (code == 15700) return null; // APPMODEL_ERROR_NO_PACKAGE
            if (code != 122 || length == 0 || length > 256)
                throw new Win32Exception(code, "Cannot verify target package identity.");
            StringBuilder value = new StringBuilder((int)length);
            code = Native.GetPackageFamilyName(process.Handle, ref length, value);
            if (code != 0) throw new Win32Exception(code, "Cannot read target package identity.");
            GC.KeepAlive(process);
            return value.ToString();
        }
    }

    // Length-prefixed, bounded IPC. A dead worker is handled by closing the pipe;
    // no read may allocate a worker-supplied unbounded line or message.
    public static class Frames
    {
        public const int MaximumBytes = 65536;
        private static readonly Encoding Utf8 = new UTF8Encoding(false, true);

        public static async Task<string> ReadAsync(Stream stream)
        {
            byte[] header = new byte[4];
            await ReadExactly(stream, header).ConfigureAwait(false);
            int size = BitConverter.ToInt32(header, 0);
            if (size <= 0 || size > MaximumBytes) throw new InvalidDataException("IPC frame length rejected.");
            byte[] body = new byte[size];
            await ReadExactly(stream, body).ConfigureAwait(false);
            return Utf8.GetString(body);
        }

        private static async Task ReadExactly(Stream stream, byte[] data)
        {
            int offset = 0;
            while (offset < data.Length)
            {
                int count = await stream.ReadAsync(data, offset, data.Length - offset).ConfigureAwait(false);
                if (count == 0) throw new EndOfStreamException("UI worker pipe closed.");
                offset += count;
            }
        }

        public static async Task WriteAsync(Stream stream, string value)
        {
            byte[] body = Utf8.GetBytes(value);
            if (body.Length == 0 || body.Length > MaximumBytes) throw new InvalidDataException("IPC message too large.");
            byte[] header = BitConverter.GetBytes(body.Length);
            await stream.WriteAsync(header, 0, header.Length).ConfigureAwait(false);
            await stream.WriteAsync(body, 0, body.Length).ConfigureAwait(false);
        }

        public static int ClientProcessId(IntPtr pipe)
        {
            uint id;
            if (!Native.GetNamedPipeClientProcessId(pipe, out id)) throw Native.Error("GetNamedPipeClientProcessId");
            return checked((int)id);
        }
    }

    internal static class Native
    {
        internal static Win32Exception Error(string operation)
        {
            int code = Marshal.GetLastWin32Error();
            return new Win32Exception(code, operation + " failed (Win32 " + code + ").");
        }
        [StructLayout(LayoutKind.Sequential)] internal struct BasicLimits
        {
            internal long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters
        { internal ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ExtendedLimits
        {
            internal BasicLimits Basic;
            internal IoCounters Io;
            internal UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct StartupInfo
        {
            internal int cb;
            internal string lpReserved, lpDesktop, lpTitle;
            internal uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            internal short wShowWindow, cbReserved2;
            internal IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct StartupInfoEx
        { internal StartupInfo StartupInfo; internal IntPtr AttributeList; }
        [StructLayout(LayoutKind.Sequential)] internal struct ProcessInformation
        { internal IntPtr hProcess, hThread; internal uint dwProcessId, dwThreadId; }
        [StructLayout(LayoutKind.Sequential)] internal struct MemoryCounters
        {
            internal uint cb, PageFaultCount;
            internal UIntPtr PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage,
                QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage,
                PagefileUsage, PeakPagefileUsage, PrivateUsage;
        }
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool SetInformationJobObject(KernelHandle job, int info, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool QueryInformationJobObject(KernelHandle job, int info, IntPtr data, uint length, out uint returned);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool TerminateJobObject(KernelHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool IsProcessInJob(KernelHandle process, KernelHandle job, out bool result);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(KernelHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint WaitForSingleObject(KernelHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetExitCodeProcess(KernelHandle process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetProcessTimes(KernelHandle process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetProcessHandleCount(KernelHandle process, out uint count);
        [DllImport("psapi.dll", SetLastError = true)] internal static extern bool GetProcessMemoryInfo(KernelHandle process, ref MemoryCounters counters, uint size);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CommandLineToArgvW(string command, out int count);
        [DllImport("kernel32.dll")] internal static extern IntPtr LocalFree(IntPtr value);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint id);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern int GetPackageFamilyName(IntPtr process, ref uint length, StringBuilder family);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern int GetPackagesByPackageFamily(string family, ref uint count, IntPtr names, ref uint length, IntPtr buffer);
        [DllImport("kernelbase.dll", CharSet = CharSet.Unicode)] internal static extern int GetStagedPackageOrigin(string fullName, out int origin);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern int GetStagedPackagePathByFullName(string fullName, ref uint length, StringBuilder path);
    }
}
