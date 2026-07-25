using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Mql5Coding
{
    public sealed class CompilerProcessJob : IDisposable
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseShowWindow = 0x00000001;
        private const short SwHide = 0;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectBasicAccountingInformationClass = 1;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitFailed = 0xFFFFFFFF;
        private const uint ShareReadWrite = 0x00000003;
        private const uint ShareReadWriteDelete = 0x00000007;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public NativeFileTime CreationTime;
            public NativeFileTime LastAccessTime;
            public NativeFileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicAccounting
        {
            public long TotalUserTime;
            public long TotalKernelTime;
            public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount;
            public uint TotalProcesses;
            public uint ActiveProcesses;
            public uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeWaitHandle CreateJobObject(
            IntPtr jobAttributes,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(
            SafeWaitHandle job,
            int informationClass,
            ref JobObjectExtendedLimitInformation information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(
            SafeWaitHandle job,
            int informationClass,
            out JobObjectBasicAccounting information,
            uint informationLength,
            out uint returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle OpenPathHandle(
            string path,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(
            SafeWaitHandle job,
            SafeWaitHandle process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(SafeWaitHandle thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(
            SafeWaitHandle job,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(
            SafeWaitHandle process,
            uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(
            SafeWaitHandle handle,
            uint milliseconds);

        private SafeWaitHandle jobHandle;
        private SafeWaitHandle processHandle;
        private SafeWaitHandle threadHandle;

        private CompilerProcessJob(
            SafeWaitHandle job,
            SafeWaitHandle process,
            SafeWaitHandle thread,
            int processId)
        {
            jobHandle = job;
            processHandle = process;
            threadHandle = thread;
            ProcessId = processId;
        }

        public int ProcessId { get; private set; }

        public sealed class DirectoryIdentityLease : IDisposable
        {
            private SafeFileHandle handle;

            internal DirectoryIdentityLease(
                SafeFileHandle directoryHandle,
                string identity,
                string finalPath)
            {
                handle = directoryHandle;
                Identity = identity;
                FinalPath = finalPath;
            }

            public string Identity { get; private set; }

            public string FinalPath { get; private set; }

            public void Dispose()
            {
                if (handle != null)
                {
                    handle.Dispose();
                    handle = null;
                }
            }
        }

        private static string ReadFileIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "GetFileInformationByHandle failed.");

            return String.Format(
                "{0:X8}:{1:X8}{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }

        private static string ReadFinalPath(SafeFileHandle handle)
        {
            const int MaximumPathCharacters = 32768;
            StringBuilder path = new StringBuilder(MaximumPathCharacters);
            uint length = GetFinalPathNameByHandle(
                handle,
                path,
                unchecked((uint)path.Capacity),
                0);
            if (length == 0)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "GetFinalPathNameByHandle failed.");
            if (length >= path.Capacity)
                throw new InvalidOperationException(
                    "The resolved directory path exceeds the supported Windows path length.");

            string result = path.ToString();
            const string UncPrefix = @"\\?\UNC\";
            const string ExtendedPrefix = @"\\?\";
            if (result.StartsWith(UncPrefix, StringComparison.OrdinalIgnoreCase))
                return @"\\" + result.Substring(UncPrefix.Length);
            if (result.StartsWith(ExtendedPrefix, StringComparison.OrdinalIgnoreCase))
                return result.Substring(ExtendedPrefix.Length);
            return result;
        }

        public static string GetFileIdentity(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A file path is required.", "path");

            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                return ReadFileIdentity(stream.SafeFileHandle);
            }
        }

        public static DirectoryIdentityLease OpenDirectoryIdentityLease(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A directory path is required.", "path");

            SafeFileHandle handle = OpenPathHandle(
                path,
                0,
                ShareReadWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                if (handle != null)
                    handle.Dispose();
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Opening the directory identity lease failed.");
            }

            try
            {
                DirectoryIdentityLease lease = new DirectoryIdentityLease(
                    handle,
                    ReadFileIdentity(handle),
                    ReadFinalPath(handle));
                handle = null;
                return lease;
            }
            finally
            {
                if (handle != null)
                    handle.Dispose();
            }
        }

        public static string GetDirectoryIdentity(string path)
        {
            using (DirectoryIdentityLease lease = OpenDirectoryIdentityLease(path))
            {
                return lease.Identity;
            }
        }

        public static CompilerProcessJob Start(
            string applicationPath,
            string arguments,
            string currentDirectory)
        {
            SafeWaitHandle job = null;
            SafeWaitHandle process = null;
            SafeWaitHandle thread = null;
            CompilerProcessJob launch = null;
            bool processCreated = false;
            bool cleanupVerified = true;
            try
            {
                job = CreateJobObject(IntPtr.Zero, null);
                if (job == null || job.IsInvalid)
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateJobObject failed.");

                JobObjectExtendedLimitInformation limits =
                    new JobObjectExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags =
                    JobObjectLimitKillOnJobClose;
                if (!SetInformationJobObject(
                        job,
                        JobObjectExtendedLimitInformationClass,
                        ref limits,
                        unchecked((uint)Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation)))))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetInformationJobObject failed.");

                StartupInfo startup = new StartupInfo();
                startup.cb = unchecked((uint)Marshal.SizeOf(typeof(StartupInfo)));
                startup.dwFlags = StartfUseShowWindow;
                startup.wShowWindow = SwHide;
                ProcessInformation created;
                StringBuilder commandLine = new StringBuilder(
                    "\"" + applicationPath + "\" " + arguments);
                if (!CreateProcessW(
                        applicationPath,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        false,
                        CreateSuspended | CreateNoWindow,
                        IntPtr.Zero,
                        currentDirectory,
                        ref startup,
                        out created))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateProcessW failed.");

                processCreated = true;
                cleanupVerified = false;
                process = new SafeWaitHandle(created.hProcess, true);
                thread = new SafeWaitHandle(created.hThread, true);
                if (!AssignProcessToJobObject(job, process))
                {
                    int assignmentError = Marshal.GetLastWin32Error();
                    bool terminationRequested = TerminateProcess(process, 0xDEAD);
                    uint waitResult = WaitForSingleObject(process, 5000);
                    if (!terminationRequested || waitResult != WaitObject0)
                        throw new InvalidOperationException(
                            "AssignProcessToJobObject failed and termination of the suspended compiler process could not be verified.",
                            new Win32Exception(assignmentError));
                    cleanupVerified = true;
                    throw new Win32Exception(
                        assignmentError,
                        "AssignProcessToJobObject failed; the suspended compiler process was terminated.");
                }

                launch = new CompilerProcessJob(
                    job,
                    process,
                    thread,
                    unchecked((int)created.dwProcessId));
                job = null;
                process = null;
                thread = null;

                uint previousSuspendCount = ResumeThread(launch.threadHandle);
                if (previousSuspendCount == uint.MaxValue)
                {
                    int resumeError = Marshal.GetLastWin32Error();
                    try
                    {
                        launch.TerminateAndWaitForEmpty(5000);
                    }
                    catch (Exception cleanupError)
                    {
                        throw new InvalidOperationException(
                            "ResumeThread failed and termination of the suspended compiler process could not be verified.",
                            new AggregateException(
                                new Win32Exception(resumeError, "ResumeThread failed."),
                                cleanupError));
                    }
                    cleanupVerified = true;
                    throw new Win32Exception(
                        resumeError,
                        "ResumeThread failed; the suspended compiler process was terminated.");
                }

                CompilerProcessJob result = launch;
                launch = null;
                return result;
            }
            catch (Exception error)
            {
                error.Data["Mql5Coding.ProcessCreated"] = processCreated;
                error.Data["Mql5Coding.CleanupVerified"] =
                    !processCreated || cleanupVerified;
                throw;
            }
            finally
            {
                if (launch != null)
                    launch.Dispose();
                if (thread != null)
                    thread.Dispose();
                if (process != null)
                    process.Dispose();
                if (job != null)
                    job.Dispose();
            }
        }

        public bool IsEmpty()
        {
            if (jobHandle == null || jobHandle.IsInvalid || jobHandle.IsClosed)
                throw new InvalidOperationException("The compiler Job Object is unavailable.");

            JobObjectBasicAccounting accounting;
            uint returned;
            if (!QueryInformationJobObject(
                    jobHandle,
                    JobObjectBasicAccountingInformationClass,
                    out accounting,
                    unchecked((uint)Marshal.SizeOf(typeof(JobObjectBasicAccounting))),
                    out returned))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "QueryInformationJobObject failed.");
            return accounting.ActiveProcesses == 0;
        }

        public void WaitForEmpty(int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 0)
                throw new ArgumentOutOfRangeException("timeoutMilliseconds");

            Stopwatch stopwatch = Stopwatch.StartNew();
            while (true)
            {
                if (IsEmpty())
                    return;
                if (stopwatch.ElapsedMilliseconds >= timeoutMilliseconds)
                    throw new TimeoutException(
                        "The compiler Job Object did not become empty before the deadline.");
                Thread.Sleep(25);
            }
        }

        public void TerminateAndWaitForEmpty(int timeoutMilliseconds)
        {
            if (jobHandle == null || jobHandle.IsInvalid || jobHandle.IsClosed)
                throw new InvalidOperationException("The compiler Job Object is unavailable.");
            if (!TerminateJobObject(jobHandle, 0xDEAD))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "TerminateJobObject failed.");
            try
            {
                WaitForEmpty(timeoutMilliseconds);
            }
            catch (TimeoutException error)
            {
                throw new TimeoutException(
                    "The compiler Job Object did not become empty after termination.",
                    error);
            }
        }

        public void Dispose()
        {
            if (jobHandle != null)
            {
                jobHandle.Dispose();
                jobHandle = null;
            }
            if (threadHandle != null)
            {
                threadHandle.Dispose();
                threadHandle = null;
            }
            if (processHandle != null)
            {
                processHandle.Dispose();
                processHandle = null;
            }
        }
    }
}
