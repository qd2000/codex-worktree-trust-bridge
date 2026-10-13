using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace CodexTrustBridge
{
    public sealed class BoundedProcessResult
    {
        public int ProcessId;
        public long CreationFileTimeUtc;
        public int ExitCode;
        public bool TimedOut;
        public bool StandardOutputLimitExceeded;
        public bool StandardErrorLimitExceeded;
        public bool InvalidUtf8;
        public bool CleanupVerified;
        public long DurationMilliseconds;
        public long StandardOutputBytes;
        public long StandardErrorBytes;
        public string StandardOutput;
        public string StandardError;
        public long PeakRootPrivateBytes;
        public int PeakRootHandles;
        public long PeakJobMemoryBytes;
        public int MaximumActiveProcesses;

        public bool Succeeded
        {
            get
            {
                return ExitCode == 0 && !TimedOut && !StandardOutputLimitExceeded &&
                    !StandardErrorLimitExceeded && !InvalidUtf8 && CleanupVerified;
            }
        }
    }

    // Executes a child atomically inside a kill-on-close Job Object. Output is
    // redirected to bounded temporary files rather than accumulated by an
    // unbounded line/string reader. The handle-list attribute prevents the child
    // from inheriting unrelated handles from the authority process.
    public static class BoundedProcessRunner
    {
        private const uint KillOnJobClose = 0x00002000;
        private const uint ActiveProcessLimit = 0x00000008;
        private const uint ProcessMemoryLimit = 0x00000100;
        private const uint JobMemoryLimit = 0x00000200;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint CreateSuspended = 0x00000004;
        private const uint StartfUseShowWindow = 0x00000001;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint DuplicateSameAccess = 0x00000002;
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        public static BoundedProcessResult Run(
            string executable,
            string[] arguments,
            string directory,
            int timeoutMilliseconds,
            int cleanupMilliseconds,
            int maximumStandardOutputBytes,
            int maximumStandardErrorBytes,
            long jobMemoryLimitBytes,
            int processLimit)
        {
            if (String.IsNullOrWhiteSpace(executable) || !Path.IsPathRooted(executable) || !File.Exists(executable))
                throw new ArgumentException("An existing absolute executable path is required.");
            if (String.IsNullOrWhiteSpace(directory) || !Path.IsPathRooted(directory) || !Directory.Exists(directory))
                throw new ArgumentException("An existing absolute working directory is required.");
            if (arguments == null) throw new ArgumentNullException("arguments");
            if (timeoutMilliseconds < 100 || cleanupMilliseconds < 100 ||
                maximumStandardOutputBytes < 1 || maximumStandardErrorBytes < 1 ||
                jobMemoryLimitBytes < 0 || processLimit < 1)
                throw new ArgumentOutOfRangeException("Invalid bounded-process limits.");

            string token = Guid.NewGuid().ToString("N");
            string outputPath = Path.Combine(Path.GetTempPath(), "codex-trust-git-" + token + ".out");
            string errorPath = Path.Combine(Path.GetTempPath(), "codex-trust-git-" + token + ".err");
            FileStream output = null, error = null, input = null;
            KernelHandle childOutput = null, childError = null, childInput = null;
            KernelHandle job = null, process = null, thread = null;
            IntPtr attributes = IntPtr.Zero, jobList = IntPtr.Zero, handleList = IntPtr.Zero;
            bool attributesInitialized = false;
            BoundedProcessResult result = new BoundedProcessResult { ExitCode = Int32.MinValue };
            Stopwatch clock = Stopwatch.StartNew();
            try
            {
                output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.ReadWrite,
                    FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
                error = new FileStream(errorPath, FileMode.CreateNew, FileAccess.ReadWrite,
                    FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
                input = new FileStream("NUL", FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                childOutput = DuplicateInheritable(output.SafeFileHandle);
                childError = DuplicateInheritable(error.SafeFileHandle);
                childInput = DuplicateInheritable(input.SafeFileHandle);

                job = new KernelHandle(BoundedNative.CreateJobObjectW(IntPtr.Zero, null));
                if (job.IsInvalid) throw Error("CreateJobObject");
                BoundedNative.ExtendedLimits limits = new BoundedNative.ExtendedLimits();
                limits.Basic.LimitFlags = KillOnJobClose | ActiveProcessLimit;
                limits.Basic.ActiveProcessLimit = (uint)processLimit;
                if (jobMemoryLimitBytes != 0)
                {
                    limits.Basic.LimitFlags |= ProcessMemoryLimit | JobMemoryLimit;
                    limits.ProcessMemoryLimit = new UIntPtr((ulong)jobMemoryLimitBytes);
                    limits.JobMemoryLimit = new UIntPtr((ulong)jobMemoryLimitBytes);
                }
                if (!BoundedNative.SetInformationJobObject(job, 9, ref limits,
                    (uint)Marshal.SizeOf(typeof(BoundedNative.ExtendedLimits))))
                    throw Error("SetInformationJobObject");

                IntPtr attributeBytes = IntPtr.Zero;
                BoundedNative.InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeBytes);
                if (attributeBytes == IntPtr.Zero) throw Error("Attribute-list size");
                attributes = Marshal.AllocHGlobal(attributeBytes);
                if (!BoundedNative.InitializeProcThreadAttributeList(attributes, 2, 0, ref attributeBytes))
                    throw Error("InitializeProcThreadAttributeList");
                attributesInitialized = true;

                jobList = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobList, job.DangerousGetHandle());
                if (!BoundedNative.UpdateProcThreadAttribute(attributes, 0,
                    new IntPtr(0x0002000d), jobList, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                    throw Error("PROC_THREAD_ATTRIBUTE_JOB_LIST");

                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, childInput.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size, childOutput.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, childError.DangerousGetHandle());
                if (!BoundedNative.UpdateProcThreadAttribute(attributes, 0,
                    new IntPtr(0x00020002), handleList, new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                    throw Error("PROC_THREAD_ATTRIBUTE_HANDLE_LIST");

                BoundedNative.StartupInfoEx startup = new BoundedNative.StartupInfoEx();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(BoundedNative.StartupInfoEx));
                startup.StartupInfo.dwFlags = StartfUseShowWindow | StartfUseStdHandles;
                startup.StartupInfo.wShowWindow = 0;
                startup.StartupInfo.hStdInput = childInput.DangerousGetHandle();
                startup.StartupInfo.hStdOutput = childOutput.DangerousGetHandle();
                startup.StartupInfo.hStdError = childError.DangerousGetHandle();
                startup.AttributeList = attributes;
                string[] command = new string[arguments.Length + 1];
                command[0] = executable;
                Array.Copy(arguments, 0, command, 1, arguments.Length);
                BoundedNative.ProcessInformation information;
                uint flags = CreateNoWindow | ExtendedStartupInfoPresent | CreateSuspended;
                if (!BoundedNative.CreateProcessW(executable, new StringBuilder(CommandLine.Join(command)),
                    IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, directory,
                    ref startup, out information))
                    throw Error("CreateProcess with atomic Job and bounded output handles");
                process = new KernelHandle(information.hProcess);
                thread = new KernelHandle(information.hThread);
                result.ProcessId = checked((int)information.dwProcessId);
                long exitTime, kernelTime, userTime, creationTime;
                if (!BoundedNative.GetProcessTimes(process, out creationTime, out exitTime, out kernelTime, out userTime))
                    throw Error("GetProcessTimes");
                result.CreationFileTimeUtc = creationTime;
                bool inJob;
                if (!BoundedNative.IsProcessInJob(process, job, out inJob) || !inJob)
                    throw new InvalidOperationException("Bounded child is not in the owning Job.");

                // Parent copies are no longer needed once CreateProcess returns.
                childInput.Dispose(); childInput = null;
                childOutput.Dispose(); childOutput = null;
                childError.Dispose(); childError = null;
                input.Dispose(); input = null;

                if (BoundedNative.ResumeThread(thread) == UInt32.MaxValue) throw Error("ResumeThread");
                thread.Dispose(); thread = null;

                bool terminate = false;
                do
                {
                    long outputBytes = output.Length;
                    long errorBytes = error.Length;
                    if (outputBytes > maximumStandardOutputBytes)
                    {
                        result.StandardOutputLimitExceeded = true;
                        terminate = true;
                    }
                    if (errorBytes > maximumStandardErrorBytes)
                    {
                        result.StandardErrorLimitExceeded = true;
                        terminate = true;
                    }
                    if (clock.ElapsedMilliseconds >= timeoutMilliseconds)
                    {
                        result.TimedOut = true;
                        terminate = true;
                    }
                    SampleRoot(process, result);
                    int active = GetActiveProcessCount(job);
                    if (active > result.MaximumActiveProcesses) result.MaximumActiveProcesses = active;
                    if (active == 0) break;
                    if (terminate)
                    {
                        if (!BoundedNative.TerminateJobObject(job, 0xE023)) throw Error("TerminateJobObject");
                        break;
                    }
                    Thread.Sleep(20);
                } while (true);

                Stopwatch cleanup = Stopwatch.StartNew();
                while (GetActiveProcessCount(job) != 0 && cleanup.ElapsedMilliseconds < cleanupMilliseconds)
                    Thread.Sleep(20);
                result.CleanupVerified = GetActiveProcessCount(job) == 0;
                uint exitCode;
                if (BoundedNative.GetExitCodeProcess(process, out exitCode))
                    result.ExitCode = unchecked((int)exitCode);
                result.PeakJobMemoryBytes = GetPeakJobMemory(job);

                result.StandardOutputBytes = output.Length;
                result.StandardErrorBytes = error.Length;
                byte[] outputBytesFinal = ReadBounded(output, maximumStandardOutputBytes);
                byte[] errorBytesFinal = ReadBounded(error, maximumStandardErrorBytes);
                try
                {
                    result.StandardOutput = StrictUtf8.GetString(outputBytesFinal);
                    result.StandardError = StrictUtf8.GetString(errorBytesFinal);
                }
                catch (DecoderFallbackException)
                {
                    result.InvalidUtf8 = true;
                    result.StandardOutput = null;
                    result.StandardError = null;
                }
                result.DurationMilliseconds = clock.ElapsedMilliseconds;
                return result;
            }
            finally
            {
                if (process != null && job != null)
                {
                    try
                    {
                        if (GetActiveProcessCount(job) != 0)
                        {
                            BoundedNative.TerminateJobObject(job, 0xE024);
                            Stopwatch cleanup = Stopwatch.StartNew();
                            while (GetActiveProcessCount(job) != 0 && cleanup.ElapsedMilliseconds < cleanupMilliseconds)
                                Thread.Sleep(20);
                        }
                    }
                    catch { }
                }
                if (attributesInitialized) BoundedNative.DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
                if (thread != null) thread.Dispose();
                if (process != null) process.Dispose();
                if (job != null) job.Dispose();
                if (childInput != null) childInput.Dispose();
                if (childOutput != null) childOutput.Dispose();
                if (childError != null) childError.Dispose();
                if (input != null) input.Dispose();
                if (output != null) output.Dispose();
                if (error != null) error.Dispose();
                TryDelete(outputPath);
                TryDelete(errorPath);
            }
        }

        private static KernelHandle DuplicateInheritable(SafeFileHandle source)
        {
            IntPtr duplicate;
            IntPtr current = BoundedNative.GetCurrentProcess();
            if (!BoundedNative.DuplicateHandle(current, source.DangerousGetHandle(), current,
                out duplicate, 0, true, DuplicateSameAccess))
                throw Error("DuplicateHandle");
            return new KernelHandle(duplicate);
        }

        private static byte[] ReadBounded(FileStream stream, int maximumBytes)
        {
            stream.Position = 0;
            int length = checked((int)Math.Min(stream.Length, maximumBytes));
            byte[] result = new byte[length];
            int offset = 0;
            while (offset < result.Length)
            {
                int count = stream.Read(result, offset, result.Length - offset);
                if (count == 0) break;
                offset += count;
            }
            if (offset == result.Length) return result;
            byte[] shortResult = new byte[offset];
            Buffer.BlockCopy(result, 0, shortResult, 0, offset);
            return shortResult;
        }

        private static int GetActiveProcessCount(KernelHandle job)
        {
            const int capacity = 128;
            int bytes = 8 + capacity * IntPtr.Size;
            IntPtr buffer = Marshal.AllocHGlobal(bytes);
            try
            {
                uint returned;
                if (!BoundedNative.QueryInformationJobObject(job, 3, buffer, (uint)bytes, out returned))
                    throw Error("QueryInformationJobObject process list");
                int count = Marshal.ReadInt32(buffer, 4);
                if (count < 0 || count > capacity)
                    throw new InvalidDataException("Bounded process Job exceeded its identity-list capacity.");
                return count;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static long GetPeakJobMemory(KernelHandle job)
        {
            BoundedNative.ExtendedLimits limits = new BoundedNative.ExtendedLimits();
            IntPtr buffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(BoundedNative.ExtendedLimits)));
            try
            {
                uint returned;
                if (!BoundedNative.QueryInformationJobObject(job, 9, buffer,
                    (uint)Marshal.SizeOf(typeof(BoundedNative.ExtendedLimits)), out returned))
                    return 0;
                limits = (BoundedNative.ExtendedLimits)Marshal.PtrToStructure(buffer, typeof(BoundedNative.ExtendedLimits));
                return checked((long)limits.PeakJobMemoryUsed.ToUInt64());
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static void SampleRoot(KernelHandle process, BoundedProcessResult result)
        {
            BoundedNative.MemoryCounters counters = new BoundedNative.MemoryCounters();
            counters.cb = (uint)Marshal.SizeOf(typeof(BoundedNative.MemoryCounters));
            if (BoundedNative.GetProcessMemoryInfo(process, ref counters, counters.cb))
            {
                long value = checked((long)counters.PrivateUsage.ToUInt64());
                if (value > result.PeakRootPrivateBytes) result.PeakRootPrivateBytes = value;
            }
            uint handles;
            if (BoundedNative.GetProcessHandleCount(process, out handles) && handles > result.PeakRootHandles)
                result.PeakRootHandles = checked((int)handles);
        }

        private static Win32Exception Error(string operation)
        {
            int code = Marshal.GetLastWin32Error();
            return new Win32Exception(code, operation + " failed (Win32 " + code + ").");
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }

    internal static class BoundedNative
    {
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
        [DllImport("kernel32.dll")] internal static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool DuplicateHandle(
            IntPtr sourceProcess, IntPtr sourceHandle, IntPtr targetProcess, out IntPtr targetHandle,
            uint desiredAccess, bool inheritHandle, uint options);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool SetInformationJobObject(KernelHandle job, int info, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool QueryInformationJobObject(KernelHandle job, int info, IntPtr data, uint length, out uint returned);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool TerminateJobObject(KernelHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool IsProcessInJob(KernelHandle process, KernelHandle job, out bool result);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool CreateProcessW(
            string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
            bool inheritHandles, uint flags, IntPtr environment, string directory,
            ref StartupInfoEx startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(KernelHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetExitCodeProcess(KernelHandle process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetProcessTimes(KernelHandle process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetProcessHandleCount(KernelHandle process, out uint count);
        [DllImport("psapi.dll", SetLastError = true)] internal static extern bool GetProcessMemoryInfo(KernelHandle process, ref MemoryCounters counters, uint size);
    }
}
