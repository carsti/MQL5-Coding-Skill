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
    public sealed class JobProcessLaunch : IDisposable
    {
        private const uint CreateSuspendedFlag = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint StartfUseShowWindow = 0x00000001;
        private const short SwHide = 0;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectBasicAccountingInformationClass = 1;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitFailed = 0xFFFFFFFF;
        private const uint FileListDirectory = 0x00000001;
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint ProcessQueryLimitedInformation = 0x00001000;
        private const uint ProcessNameNative = 0x00000001;
        private const uint ShareRead = 0x00000001;
        private const uint ShareReadWrite = 0x00000003;
        private const uint ShareReadWriteDelete = 0x00000007;
        private const uint DriveFixed = 3;
        private const int ErrorFileNotFound = 2;
        private const int ErrorPathNotFound = 3;
        private const int ErrorFileExists = 80;
        private const int ErrorAlreadyExists = 183;
        private const int ErrorMoreData = 234;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;

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

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProbeStartupInfo
        {
            public StartupInfo Startup;
            public IntPtr Attributes;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref SecurityAttributes attributes, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, UIntPtr size, IntPtr previous, IntPtr returned);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);

        [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProbeProcess(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, IntPtr environment, string directory, ref ProbeStartupInfo startup, out ProcessInformation process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(SafeWaitHandle process, out uint exitCode);

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public FileTime CreationTime;
            public FileTime LastAccessTime;
            public FileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
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

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "CreateDirectoryW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryPath(
            string path,
            IntPtr securityAttributes);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "GetDriveTypeW")]
        private static extern uint GetDriveType(string rootPathName);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "QueryDosDeviceW")]
        private static extern uint QueryDosDevice(
            string deviceName,
            StringBuilder targetPath,
            uint maximumCharacters);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "GetVolumeNameForVolumeMountPointW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeNameForVolumeMountPoint(
            string volumeMountPoint,
            StringBuilder volumeName,
            uint bufferLength);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "GetVolumePathNamesForVolumeNameW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumePathNamesForVolumeName(
            string volumeName,
            [Out] char[] volumePathNames,
            uint bufferLength,
            out uint returnLength);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "GetVolumeInformationW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeInformation(
            string rootPathName,
            StringBuilder volumeName,
            uint volumeNameSize,
            out uint volumeSerialNumber,
            out uint maximumComponentLength,
            out uint fileSystemFlags,
            StringBuilder fileSystemName,
            uint fileSystemNameSize);

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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeWaitHandle OpenProcess(
            uint desiredAccess,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
            uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(
            SafeWaitHandle process,
            uint flags,
            StringBuilder imagePath,
            ref uint size);

        private SafeWaitHandle jobHandle;
        private SafeWaitHandle processHandle;
        private SafeWaitHandle threadHandle;
        private bool resumed;

        private JobProcessLaunch(
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
        public StreamReader StandardOutput { get; private set; }
        public StreamReader StandardError { get; private set; }

        public sealed class ProbeOutput
        {
            public string Text { get; private set; }
            public bool LimitExceeded { get; private set; }
            internal ProbeOutput(string text, bool limitExceeded)
            {
                Text = text;
                LimitExceeded = limitExceeded;
            }
        }

        public static async System.Threading.Tasks.Task<ProbeOutput> ReadProbeOutputAsync(StreamReader reader, int maximumCharacters, bool captureText)
        {
            if (reader == null) throw new ArgumentNullException("reader");
            if (maximumCharacters < 1) throw new ArgumentOutOfRangeException("maximumCharacters");
            char[] buffer = new char[Math.Min(8192, maximumCharacters)];
            StringBuilder text = captureText ? new StringBuilder() : null;
            int received = 0;
            while (true)
            {
                int count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0) return new ProbeOutput(captureText ? text.ToString() : null, false);
                if (count > maximumCharacters - received) return new ProbeOutput(null, true);
                received += count;
                if (captureText) text.Append(buffer, 0, count);
            }
        }

        public bool WaitForExit(int timeoutMilliseconds)
        {
            uint result = WaitForSingleObject(processHandle, unchecked((uint)timeoutMilliseconds));
            if (result == WaitObject0) return true;
            if (result == 0x00000102) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Waiting for the probe process failed.");
        }

        public int ExitCode
        {
            get
            {
                uint code;
                if (!GetExitCodeProcess(processHandle, out code))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading the probe exit code failed.");
                return unchecked((int)code);
            }
        }

        public sealed class PathEntryLease : IDisposable
        {
            private SafeFileHandle handle;

            internal PathEntryLease(
                SafeFileHandle entryHandle,
                string path,
                string identity,
                bool isDirectory)
            {
                handle = entryHandle;
                Path = path;
                Identity = identity;
                IsDirectory = isDirectory;
            }

            public string Path { get; private set; }

            public string Identity { get; private set; }

            public bool IsDirectory { get; private set; }

            public void VerifyStillNonReparseDirectory()
            {
                if (handle == null || handle.IsInvalid || handle.IsClosed)
                    throw new InvalidOperationException(
                        "The directory path-integrity handle is unavailable.");
                if (!IsDirectory)
                    throw new InvalidOperationException(
                        "The path-integrity lease does not identify a directory.");

                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Reading live directory attributes failed: " + Path);
                if ((information.FileAttributes & FileAttributeDirectory) == 0 ||
                    (information.FileAttributes & FileAttributeReparsePoint) != 0)
                    throw new InvalidOperationException(
                        "A leased directory became a reparse point or changed type: " +
                        Path);
            }

            public void Dispose()
            {
                if (handle != null)
                {
                    handle.Dispose();
                    handle = null;
                }
            }
        }

        public static JobProcessLaunch CreateSuspended(
            string applicationPath,
            string configurationPath,
            string currentDirectory)
        {
            SafeWaitHandle job = null;
            SafeWaitHandle process = null;
            SafeWaitHandle thread = null;
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
                    "\"" + applicationPath + "\" /config:\"" + configurationPath + "\"");
                if (!CreateProcessW(
                        applicationPath,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        false,
                        CreateSuspendedFlag | CreateNoWindow,
                        IntPtr.Zero,
                        currentDirectory,
                        ref startup,
                        out created))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "CreateProcessW failed.");

                process = new SafeWaitHandle(created.hProcess, true);
                thread = new SafeWaitHandle(created.hThread, true);
                if (!AssignProcessToJobObject(job, process))
                {
                    int assignmentError = Marshal.GetLastWin32Error();
                    bool terminationRequested = TerminateProcess(process, 0xDEAD);
                    int terminationError = terminationRequested
                        ? 0
                        : Marshal.GetLastWin32Error();
                    uint waitResult = WaitForSingleObject(process, 5000);
                    int waitError = waitResult == WaitFailed
                        ? Marshal.GetLastWin32Error()
                        : 0;
                    bool terminationConfirmed = waitResult == WaitObject0;

                    Exception failure;
                    if (terminationConfirmed)
                    {
                        failure = new Win32Exception(
                            assignmentError,
                            "AssignProcessToJobObject failed; the suspended process was confirmed terminated before its primary thread ran.");
                    }
                    else
                    {
                        failure = new InvalidOperationException(
                            "AssignProcessToJobObject failed and termination of the suspended process could not be verified. " +
                            "TerminateProcess succeeded=" + terminationRequested +
                            ", termination error=" + terminationError +
                            ", wait result=0x" + waitResult.ToString("X8") +
                            ", wait error=" + waitError + ".",
                            new Win32Exception(
                                assignmentError,
                                "AssignProcessToJobObject failed."));
                    }

                    failure.Data["Mql5Coding.ProcessCreated"] = true;
                    failure.Data["Mql5Coding.ProcessId"] =
                        unchecked((int)created.dwProcessId);
                    failure.Data["Mql5Coding.SuspendedTerminationConfirmed"] =
                        terminationConfirmed;
                    failure.Data["Mql5Coding.TerminateProcessSucceeded"] =
                        terminationRequested;
                    failure.Data["Mql5Coding.TerminateProcessError"] =
                        terminationError;
                    failure.Data["Mql5Coding.WaitResult"] = waitResult;
                    failure.Data["Mql5Coding.WaitError"] = waitError;
                    throw failure;
                }

                JobProcessLaunch launch = new JobProcessLaunch(
                    job,
                    process,
                    thread,
                    unchecked((int)created.dwProcessId));
                job = null;
                process = null;
                thread = null;
                return launch;
            }
            finally
            {
                if (thread != null)
                    thread.Dispose();
                if (process != null)
                    process.Dispose();
                if (job != null)
                    job.Dispose();
            }
        }

        private static string QuoteProbeArgument(string value)
        {
            if (value.Length > 0 && value.IndexOf('"') < 0 && !System.Text.RegularExpressions.Regex.IsMatch(value, @"\s")) return value;
            StringBuilder quoted = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') { quoted.Append('\\', slashes * 2 + 1); quoted.Append('"'); }
                else { quoted.Append('\\', slashes); quoted.Append(character); }
                slashes = 0;
            }
            quoted.Append('\\', slashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        public static JobProcessLaunch CreateSuspendedProbe(string application, string[] arguments, string directory, System.Collections.IDictionary overrides)
        {
            SafeWaitHandle job = null, process = null, thread = null;
            SafeFileHandle inputRead = null, inputWrite = null, outputRead = null, outputWrite = null, errorRead = null, errorWrite = null;
            StreamReader output = null, error = null;
            IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero, environment = IntPtr.Zero;
            bool attributesInitialized = false;
            try
            {
                SecurityAttributes security = new SecurityAttributes();
                security.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                security.InheritHandle = true;
                if (!CreatePipe(out inputRead, out inputWrite, ref security, 0) ||
                    !CreatePipe(out outputRead, out outputWrite, ref security, 0) ||
                    !CreatePipe(out errorRead, out errorWrite, ref security, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Creating probe pipes failed.");
                inputWrite.Dispose(); inputWrite = null;
                if (!SetHandleInformation(outputRead, 1, 0) || !SetHandleInformation(errorRead, 1, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Configuring probe pipes failed.");
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                if (size == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Sizing probe attributes failed.");
                attributes = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Initializing probe attributes failed.");
                attributesInitialized = true;
                handles = Marshal.AllocHGlobal(3 * IntPtr.Size);
                Marshal.WriteIntPtr(handles, 0, inputRead.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, IntPtr.Size, outputWrite.DangerousGetHandle());
                Marshal.WriteIntPtr(handles, 2 * IntPtr.Size, errorWrite.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x00020002), handles, new UIntPtr(unchecked((uint)(3 * IntPtr.Size))), IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Restricting probe handle inheritance failed.");

                System.Collections.Generic.SortedDictionary<string, string> variables = new System.Collections.Generic.SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) variables[(string)entry.Key] = (string)entry.Value;
                foreach (System.Collections.DictionaryEntry entry in overrides)
                {
                    if (entry.Value == null) variables.Remove((string)entry.Key);
                    else variables[(string)entry.Key] = (string)entry.Value;
                }
                StringBuilder block = new StringBuilder();
                foreach (System.Collections.Generic.KeyValuePair<string, string> entry in variables) block.Append(entry.Key).Append('=').Append(entry.Value).Append('\0');
                block.Append('\0');
                environment = Marshal.StringToHGlobalUni(block.ToString());
                job = CreateJobObject(IntPtr.Zero, null);
                if (job == null || job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Creating the probe job failed.");
                JobObjectExtendedLimitInformation limits = new JobObjectExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformationClass, ref limits, unchecked((uint)Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation)))))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Configuring the probe job failed.");
                ProbeStartupInfo startup = new ProbeStartupInfo();
                startup.Startup.cb = unchecked((uint)Marshal.SizeOf(typeof(ProbeStartupInfo)));
                startup.Startup.dwFlags = StartfUseShowWindow | StartfUseStdHandles;
                startup.Startup.wShowWindow = SwHide;
                startup.Startup.hStdInput = inputRead.DangerousGetHandle();
                startup.Startup.hStdOutput = outputWrite.DangerousGetHandle();
                startup.Startup.hStdError = errorWrite.DangerousGetHandle();
                startup.Attributes = attributes;
                StringBuilder command = new StringBuilder(QuoteProbeArgument(application));
                foreach (string argument in arguments) command.Append(' ').Append(QuoteProbeArgument(argument));
                ProcessInformation created;
                if (!CreateProbeProcess(application, command, IntPtr.Zero, IntPtr.Zero, true, CreateSuspendedFlag | CreateNoWindow | CreateUnicodeEnvironment | ExtendedStartupInfoPresent, environment, directory, ref startup, out created))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Creating the suspended probe failed.");
                process = new SafeWaitHandle(created.hProcess, true);
                thread = new SafeWaitHandle(created.hThread, true);
                if (!AssignProcessToJobObject(job, process))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Assigning the suspended probe to its job failed.");
                output = new StreamReader(new FileStream(outputRead, FileAccess.Read), Encoding.UTF8, true);
                outputRead = null;
                error = new StreamReader(new FileStream(errorRead, FileAccess.Read), Encoding.UTF8, true);
                errorRead = null;
                JobProcessLaunch launch = new JobProcessLaunch(job, process, thread, unchecked((int)created.dwProcessId));
                launch.StandardOutput = output;
                launch.StandardError = error;
                job = null; process = null; thread = null; output = null; error = null;
                return launch;
            }
            finally
            {
                bool cleanupVerified = true;
                if (job != null) job.Dispose();
                if (process != null) { TerminateProcess(process, 0xDEAD); cleanupVerified = WaitForSingleObject(process, 5000) == WaitObject0; process.Dispose(); }
                if (thread != null) thread.Dispose();
                if (output != null) output.Dispose();
                if (error != null) error.Dispose();
                if (inputRead != null) inputRead.Dispose();
                if (inputWrite != null) inputWrite.Dispose();
                if (outputRead != null) outputRead.Dispose();
                if (outputWrite != null) outputWrite.Dispose();
                if (errorRead != null) errorRead.Dispose();
                if (errorWrite != null) errorWrite.Dispose();
                if (attributesInitialized) DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
                if (!cleanupVerified) throw new InvalidOperationException("Suspended probe cleanup could not be verified.");
            }
        }

        public void Resume()
        {
            if (resumed)
                throw new InvalidOperationException("The suspended process was already resumed.");
            uint previousSuspendCount = ResumeThread(threadHandle);
            if (previousSuspendCount == uint.MaxValue)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "ResumeThread failed.");
            resumed = true;
        }

        public static string GetFileIdentity(SafeFileHandle fileHandle)
        {
            if (fileHandle == null || fileHandle.IsInvalid || fileHandle.IsClosed)
                throw new InvalidOperationException("The file handle is unavailable.");

            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(fileHandle, out information))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "GetFileInformationByHandle failed.");

            ulong fileIndex =
                ((ulong)information.FileIndexHigh << 32) |
                (ulong)information.FileIndexLow;
            return information.VolumeSerialNumber.ToString("X8") +
                ":" + fileIndex.ToString("X16");
        }

        private static bool VolumePathListContainsRoot(
            string volumeName,
            string root)
        {
            uint requiredLength;
            char[] paths = new char[1024];
            while (!GetVolumePathNamesForVolumeName(
                volumeName,
                paths,
                unchecked((uint)paths.Length),
                out requiredLength))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorMoreData ||
                    requiredLength <= unchecked((uint)paths.Length) ||
                    requiredLength > 1048576)
                    throw new Win32Exception(
                        error,
                        "GetVolumePathNamesForVolumeName failed for " +
                        volumeName + ".");
                paths = new char[checked((int)requiredLength)];
            }

            int start = 0;
            while (start < paths.Length && paths[start] != '\0')
            {
                int end = start;
                while (end < paths.Length && paths[end] != '\0')
                    end++;
                string volumePath = new string(paths, start, end - start);
                if (String.Equals(
                    volumePath,
                    root,
                    StringComparison.OrdinalIgnoreCase))
                    return true;
                start = end + 1;
            }
            return false;
        }

        public static string GetFixedLocalVolumeIdentity(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A path is required.", "path");

            string fullPath = Path.GetFullPath(path);
            string root = Path.GetPathRoot(fullPath);
            if (String.IsNullOrWhiteSpace(root) ||
                root.Length != 3 ||
                !Char.IsLetter(root[0]) ||
                root[1] != ':' ||
                (root[2] != '\\' && root[2] != '/'))
                throw new InvalidOperationException(
                    "A drive-rooted path is required: " + fullPath);

            uint driveType = GetDriveType(root);
            if (driveType != DriveFixed)
                throw new InvalidOperationException(
                    "The path is not on a fixed local drive: " + fullPath);

            string deviceName = root.Substring(0, 2);
            StringBuilder mappingBuffer = new StringBuilder(32768);
            uint mappingLength = QueryDosDevice(
                deviceName,
                mappingBuffer,
                unchecked((uint)mappingBuffer.Capacity));
            if (mappingLength == 0)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "QueryDosDevice failed for " + deviceName + ".");

            string mapping = mappingBuffer.ToString();
            const string DirectVolumePrefix = @"\Device\HarddiskVolume";
            if (!mapping.StartsWith(
                    DirectVolumePrefix,
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    "Mapped, substituted, and redirected drive letters are not allowed: " +
                    deviceName + " -> " + mapping);

            string volumeSuffix = mapping.Substring(DirectVolumePrefix.Length);
            if (volumeSuffix.Length == 0)
                throw new InvalidOperationException(
                    "The drive letter does not map to a numbered local volume: " +
                    deviceName + " -> " + mapping);
            foreach (char value in volumeSuffix)
            {
                if (!Char.IsDigit(value))
                    throw new InvalidOperationException(
                        "The drive letter is not a direct local-volume mapping: " +
                        deviceName + " -> " + mapping);
            }

            StringBuilder volumeNameBuffer = new StringBuilder(1024);
            if (!GetVolumeNameForVolumeMountPoint(
                    root,
                    volumeNameBuffer,
                    unchecked((uint)volumeNameBuffer.Capacity)))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "GetVolumeNameForVolumeMountPoint failed for " + root + ".");

            string volumeName = volumeNameBuffer.ToString();
            if (!volumeName.StartsWith(
                    @"\\?\Volume{",
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    "The drive root did not resolve to a stable volume GUID: " +
                    root);
            if (!VolumePathListContainsRoot(volumeName, root))
                throw new InvalidOperationException(
                    "The drive letter is not registered for this volume by the " +
                    "Windows mount manager: " + root);

            uint volumeSerialNumber;
            uint maximumComponentLength;
            uint fileSystemFlags;
            StringBuilder displayName = new StringBuilder(261);
            StringBuilder fileSystemName = new StringBuilder(261);
            if (!GetVolumeInformation(
                    root,
                    displayName,
                    unchecked((uint)displayName.Capacity),
                    out volumeSerialNumber,
                    out maximumComponentLength,
                    out fileSystemFlags,
                    fileSystemName,
                    unchecked((uint)fileSystemName.Capacity)))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "GetVolumeInformation failed for " + root + ".");

            return volumeSerialNumber.ToString("X8") + "|" +
                volumeName.ToUpperInvariant() + "|" +
                mapping.ToUpperInvariant();
        }

        public static void VerifyPathEntryLeaseVolume(
            string path,
            PathEntryLease lease)
        {
            if (lease == null)
                throw new ArgumentNullException("lease");

            string volumeIdentity = GetFixedLocalVolumeIdentity(path);
            int separator = volumeIdentity.IndexOf('|');
            if (separator <= 0)
                throw new InvalidOperationException(
                    "The fixed-volume identity is malformed.");
            string expectedSerial = volumeIdentity.Substring(0, separator);
            string leaseIdentity = lease.Identity ?? String.Empty;
            int identitySeparator = leaseIdentity.IndexOf(':');
            string actualSerial = identitySeparator > 0
                ? leaseIdentity.Substring(0, identitySeparator)
                : String.Empty;
            if (!String.Equals(
                    expectedSerial,
                    actualSerial,
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    "The path-entry lease was opened on a different volume: " +
                    path);
        }

        private static PathEntryLease OpenNonReparsePathEntry(
            string path,
            bool requireDirectory,
            uint shareMode)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A path is required.", "path");

            uint flags = FileFlagOpenReparsePoint;
            if (requireDirectory)
                flags |= FileFlagBackupSemantics;

            SafeFileHandle handle = OpenPathHandle(
                path,
                requireDirectory ? FileListDirectory : GenericRead,
                shareMode,
                IntPtr.Zero,
                OpenExisting,
                flags,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                if (handle != null)
                    handle.Dispose();
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Opening a path-integrity lease failed: " + path);
            }

            try
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Reading path-integrity attributes failed: " + path);

                bool isDirectory =
                    (information.FileAttributes & FileAttributeDirectory) != 0;
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
                    throw new InvalidOperationException(
                        "Reparse-point path entries are not allowed: " + path);
                if (requireDirectory && !isDirectory)
                    throw new InvalidOperationException(
                        "A directory path component was expected: " + path);
                if (!requireDirectory && isDirectory)
                    throw new InvalidOperationException(
                        "A file path entry was expected: " + path);

                PathEntryLease lease = new PathEntryLease(
                    handle,
                    path,
                    GetFileIdentity(handle),
                    isDirectory);
                handle = null;
                return lease;
            }
            finally
            {
                if (handle != null)
                    handle.Dispose();
            }
        }

        public static PathEntryLease OpenDirectoryComponentLease(string path)
        {
            return OpenNonReparsePathEntry(path, true, ShareRead);
        }

        public static PathEntryLease OpenFileLeafLease(string path)
        {
            return OpenNonReparsePathEntry(path, false, ShareReadWrite);
        }

        public static PathEntryLease TryOpenFileLeafLease(string path)
        {
            try
            {
                return OpenNonReparsePathEntry(path, false, ShareReadWrite);
            }
            catch (Win32Exception exception)
            {
                if (exception.NativeErrorCode == ErrorFileNotFound ||
                    exception.NativeErrorCode == ErrorPathNotFound)
                    return null;
                throw;
            }
        }

        private static void VerifyNonReparseFile(
            SafeFileHandle handle,
            string path)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Reading output-file attributes failed: " + path);
            if ((information.FileAttributes & FileAttributeDirectory) != 0)
                throw new InvalidOperationException(
                    "An output file resolved to a directory: " + path);
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
                throw new InvalidOperationException(
                    "Output-file reparse points are not allowed: " + path);
        }

        public static PathEntryLease CreateMutableOutputFileLease(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A path is required.", "path");

            // Retain the exact no-follow creation handle. A zero-access reopen
            // does not reliably block rename/delete on Windows and reintroduces
            // output-provenance risk. GenericRead with read/write sharing lets
            // MT5 write the reserved file in place while denying replacement.
            SafeFileHandle handle = OpenPathHandle(
                path,
                GenericRead,
                ShareReadWrite,
                IntPtr.Zero,
                CreateNew,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (handle != null)
                    handle.Dispose();
                throw new Win32Exception(
                    error,
                    "Creating a mutable output reservation failed: " + path);
            }

            try
            {
                VerifyNonReparseFile(handle, path);
                PathEntryLease lease = new PathEntryLease(
                    handle,
                    path,
                    GetFileIdentity(handle),
                    false);
                handle = null;
                return lease;
            }
            finally
            {
                if (handle != null)
                    handle.Dispose();
            }
        }

        public static FileStream CreatePinnedOutputFileStream(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A path is required.", "path");

            SafeFileHandle handle = OpenPathHandle(
                path,
                GenericRead | GenericWrite,
                ShareRead,
                IntPtr.Zero,
                CreateNew,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (handle != null)
                    handle.Dispose();
                throw new Win32Exception(
                    error,
                    "Creating a pinned output file failed: " + path);
            }

            try
            {
                VerifyNonReparseFile(handle, path);
                FileStream stream = new FileStream(handle, FileAccess.ReadWrite);
                handle = null;
                return stream;
            }
            finally
            {
                if (handle != null)
                    handle.Dispose();
            }
        }

        public static bool TryCreateDirectory(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A path is required.", "path");
            if (CreateDirectoryPath(path, IntPtr.Zero))
                return true;

            int error = Marshal.GetLastWin32Error();
            if (error == ErrorFileExists || error == ErrorAlreadyExists)
                return false;
            throw new Win32Exception(
                error,
                "Creating a path-integrity directory failed: " + path);
        }

        public static string GetNonReparseGuardFileIdentity(string path)
        {
            using (PathEntryLease lease = OpenNonReparsePathEntry(
                path,
                false,
                ShareReadWriteDelete))
            {
                return lease.Identity;
            }
        }

        public static bool TryGetProcessImagePathOnFixedVolume(
            int processId,
            string fixedVolumePath,
            out string processImagePath)
        {
            processImagePath = null;
            if (processId <= 0)
                throw new ArgumentOutOfRangeException(
                    "processId",
                    "A positive process identifier is required.");
            if (String.IsNullOrWhiteSpace(fixedVolumePath))
                throw new ArgumentException(
                    "A fixed-volume path is required.",
                    "fixedVolumePath");

            string fullPath = Path.GetFullPath(fixedVolumePath);
            string root = Path.GetPathRoot(fullPath);
            string volumeIdentity = GetFixedLocalVolumeIdentity(fullPath);
            int mappingSeparator = volumeIdentity.LastIndexOf('|');
            if (mappingSeparator < 0 ||
                mappingSeparator == volumeIdentity.Length - 1)
                throw new InvalidOperationException(
                    "The fixed-volume identity is malformed.");

            string expectedDevicePrefix =
                volumeIdentity.Substring(mappingSeparator + 1);
            string nativeImagePath;
            SafeWaitHandle process = null;
            try
            {
                process = OpenProcess(
                    ProcessQueryLimitedInformation,
                    false,
                    unchecked((uint)processId));
                if (process == null || process.IsInvalid)
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "OpenProcess failed for PID " + processId + ".");

                uint capacity = 32768;
                StringBuilder imagePath = new StringBuilder((int)capacity);
                if (!QueryFullProcessImageName(
                        process,
                        ProcessNameNative,
                        imagePath,
                        ref capacity))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "QueryFullProcessImageName failed for PID " +
                        processId + ".");
                nativeImagePath = imagePath.ToString();
            }
            finally
            {
                if (process != null)
                    process.Dispose();
            }

            if (nativeImagePath.Length <= expectedDevicePrefix.Length ||
                !nativeImagePath.StartsWith(
                    expectedDevicePrefix,
                    StringComparison.OrdinalIgnoreCase) ||
                nativeImagePath[expectedDevicePrefix.Length] != '\\')
                return false;

            string relativePath =
                nativeImagePath.Substring(expectedDevicePrefix.Length + 1);
            if (String.IsNullOrWhiteSpace(relativePath) ||
                relativePath.IndexOf(':') >= 0)
                throw new InvalidOperationException(
                    "The native process-image path is malformed for PID " +
                    processId + ".");

            string translatedPath = Path.GetFullPath(
                Path.Combine(root, relativePath));
            if (!String.Equals(
                    Path.GetPathRoot(translatedPath),
                    root,
                    StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    "The native process-image path escaped its fixed volume.");

            string translatedVolumeIdentity =
                GetFixedLocalVolumeIdentity(translatedPath);
            if (!String.Equals(
                    translatedVolumeIdentity,
                    volumeIdentity,
                    StringComparison.Ordinal))
                throw new InvalidOperationException(
                    "The fixed-volume mapping changed during process-image inspection.");

            processImagePath = translatedPath;
            return true;
        }

        public string GetImagePath()
        {
            if (processHandle == null || processHandle.IsInvalid || processHandle.IsClosed)
                throw new InvalidOperationException("The process handle is unavailable.");

            uint capacity = 32768;
            StringBuilder imagePath = new StringBuilder((int)capacity);
            if (!QueryFullProcessImageName(
                    processHandle,
                    0,
                    imagePath,
                    ref capacity))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "QueryFullProcessImageName failed.");
            return imagePath.ToString();
        }

        public void TerminateAndWaitForEmpty(int timeoutMilliseconds)
        {
            if (jobHandle == null || jobHandle.IsInvalid || jobHandle.IsClosed)
                throw new InvalidOperationException("The process job handle is unavailable.");
            if (!TerminateJobObject(jobHandle, 0xDEAD))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "TerminateJobObject failed.");

            Stopwatch stopwatch = Stopwatch.StartNew();
            while (true)
            {
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
                if (accounting.ActiveProcesses == 0)
                    return;
                if (stopwatch.ElapsedMilliseconds >= timeoutMilliseconds)
                    throw new TimeoutException(
                        "The owned Windows Job Object did not become empty after termination.");
                Thread.Sleep(25);
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
            if (StandardOutput != null) { StandardOutput.Dispose(); StandardOutput = null; }
            if (StandardError != null) { StandardError.Dispose(); StandardError = null; }
        }
    }
}
