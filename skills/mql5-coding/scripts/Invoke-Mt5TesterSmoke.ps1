#Requires -Version 5.1

param(
    $ExpertPath,
    $ExpectedExpertSha256,
    $Symbol,
    $Period,
    $FromDate,
    $ToDate,
    $Model,
    $SetPath,
    [switch]$UseExpertDefaults,
    $TerminalPath,
    $TerminalDataPath,
    $OutputDirectory,
    $TimeoutSeconds = '300',
    $MaxJournalAppendBytes = '16777216',
    $Deposit,
    $Currency,
    $Leverage,
    $ExecutionMode,

    [string[]]$ExpectedLogMarker = @(),
    $ExpectedLogMarkerFile,

    [switch]$AcknowledgeSavedAccountRisk,

    [switch]$Execute,

    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixedLocalVolumeIdentities = @{}

$nativeTypeLoadError = $null
try {
    if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {
        Add-Type -TypeDefinition @'
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
        }
    }
}
'@
    }
}
catch {
    $nativeTypeLoadError = $_.Exception.Message
}

function ConvertTo-Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-Hex -Bytes $algorithm.ComputeHash($Bytes)
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    return Get-BytesSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-SafeIniValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 260
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1f\x7f=]') {
        throw "$Name contains unsupported characters or exceeds $MaximumLength characters."
    }
}

function ConvertTo-NormalizedDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not [string]::IsNullOrWhiteSpace($root) -and
        $full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]@('\', '/'))
    }
    return $full
}

function Test-IsAbsoluteLocalDrivePath {
    param([Parameter(Mandatory)][string]$Path)

    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        $Path -cmatch '\A[A-Za-z]:[\\/]'
    )
}

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )
    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "$Name must be an absolute path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $null = Open-NonReparseFileLeaf `
        -Path $full `
        -Tracker $Tracker `
        -LeasesByPath $LeasesByPath
    return $full
}

function Assert-StableFixedLocalVolumePath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    try {
        $identity = [Mql5Coding.JobProcessLaunch]::GetFixedLocalVolumeIdentity(
            $full
        )
    }
    catch {
        throw "BLOCKED: Security-sensitive paths must use a direct fixed local volume: $full. $($_.Exception.Message)"
    }

    $rootKey = ([IO.Path]::GetPathRoot($full)).ToUpperInvariant()
    if ($script:fixedLocalVolumeIdentities.ContainsKey($rootKey)) {
        if ([string]$script:fixedLocalVolumeIdentities[$rootKey] -cne
            [string]$identity) {
            throw "BLOCKED: The local-volume mapping changed during tester validation: $rootKey"
        }
    }
    else {
        $script:fixedLocalVolumeIdentities[$rootKey] = $identity
    }
}

function Open-NonReparseDirectoryChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive directories must use absolute local-drive paths: $Path"
    }
    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    if ($full -cnotmatch '\A[A-Za-z]:\\') {
        throw "BLOCKED: UNC, device, and drive-relative paths are not supported for security-sensitive tester paths: $full"
    }
    Assert-StableFixedLocalVolumePath -Path $full

    $root = [IO.Path]::GetPathRoot($full)
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add($root)
    $current = $root
    $relative = $full.Substring($root.Length)
    foreach ($component in @($relative -split '[\\/]' | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            })) {
        $current = Join-Path $current $component
        $candidates.Add((ConvertTo-NormalizedDirectoryPath -Path $current))
    }

    foreach ($candidate in $candidates) {
        Assert-StableFixedLocalVolumePath -Path $candidate
        $key = (ConvertTo-NormalizedDirectoryPath -Path $candidate).ToUpperInvariant()
        if ($LeasesByPath.ContainsKey($key)) {
            $existingLease = $LeasesByPath[$key]
            try {
                [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                    $candidate,
                    $existingLease
                )
            }
            catch {
                throw "BLOCKED: Directory volume binding changed for '$candidate': $($_.Exception.Message)"
            }
            continue
        }
        $lease = $null
        try {
            $lease = [Mql5Coding.JobProcessLaunch]::OpenDirectoryComponentLease(
                $candidate
            )
            Assert-StableFixedLocalVolumePath -Path $candidate
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $candidate,
                $lease
            )
        }
        catch {
            if ($null -ne $lease) {
                $lease.Dispose()
            }
            throw "BLOCKED: Unsafe or unleaseable directory path component '$candidate': $($_.Exception.Message)"
        }
        $LeasesByPath[$key] = $lease
        $Tracker.Add($lease)
    }
    Assert-StableFixedLocalVolumePath -Path $full
    return $LeasesByPath[$full.ToUpperInvariant()]
}

function Open-NonReparseFileLeaf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive files must use absolute local-drive paths: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath

    $key = $full.ToUpperInvariant()
    if ($LeasesByPath.ContainsKey($key)) {
        $existingLease = $LeasesByPath[$key]
        Assert-StableFixedLocalVolumePath -Path $full
        try {
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $full,
                $existingLease
            )
        }
        catch {
            throw "BLOCKED: File volume binding changed for '$full': $($_.Exception.Message)"
        }
        return $existingLease
    }
    $lease = $null
    try {
        $lease = [Mql5Coding.JobProcessLaunch]::OpenFileLeafLease($full)
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
            $full,
            $lease
        )
    }
    catch {
        if ($null -ne $lease) {
            $lease.Dispose()
        }
        throw "BLOCKED: Unsafe or unleaseable file path '$full': $($_.Exception.Message)"
    }
    $LeasesByPath[$key] = $lease
    $Tracker.Add($lease)
    return $lease
}

function Try-OpenNonReparseFileLeaf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive files must use absolute local-drive paths: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath

    $key = $full.ToUpperInvariant()
    if ($LeasesByPath.ContainsKey($key)) {
        $existingLease = $LeasesByPath[$key]
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
            $full,
            $existingLease
        )
        return $existingLease
    }

    $lease = $null
    try {
        $lease = [Mql5Coding.JobProcessLaunch]::TryOpenFileLeafLease($full)
        if ($null -eq $lease) {
            return $null
        }
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
            $full,
            $lease
        )
    }
    catch {
        if ($null -ne $lease) {
            $lease.Dispose()
        }
        throw "BLOCKED: Unsafe or unleaseable file path '$full': $($_.Exception.Message)"
    }
    $LeasesByPath[$key] = $lease
    $Tracker.Add($lease)
    return $lease
}

function Open-OrCreateNonReparseDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive directories must use absolute local-drive paths: $Path"
    }
    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "BLOCKED: A non-root directory path is required: $full"
    }
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath
    $created = [Mql5Coding.JobProcessLaunch]::TryCreateDirectory($full)
    $lease = Open-NonReparseDirectoryChain -Path $full -Tracker $Tracker -LeasesByPath $LeasesByPath
    return [pscustomobject]@{
        created = [bool]$created
        lease = $lease
        path = $full
    }
}

function Open-NewMutableOutputFileReservation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Mutable output reservations must use absolute local-drive paths: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath

    $key = $full.ToUpperInvariant()
    if ($LeasesByPath.ContainsKey($key)) {
        throw "A mutable output reservation already exists: $full"
    }

    $lease = $null
    try {
        $lease = [Mql5Coding.JobProcessLaunch]::CreateMutableOutputFileLease($full)
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume($full, $lease)
    }
    catch {
        if ($null -ne $lease) {
            $lease.Dispose()
        }
        throw "BLOCKED: Could not reserve a stable mutable output file '$full': $($_.Exception.Message)"
    }

    $LeasesByPath[$key] = $lease
    $Tracker.Add($lease)
    return $lease
}

function Open-DirectoryMutationGuard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$DirectoryLease,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$GuardsByPath,
        [Parameter(Mandatory)][string]$RunId
    )

    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    $key = $full.ToUpperInvariant()
    if ($GuardsByPath.ContainsKey($key)) {
        return $GuardsByPath[$key]
    }
    if (-not [bool]$DirectoryLease.IsDirectory -or
        -not ([IO.Path]::GetFullPath([string]$DirectoryLease.Path)).Equals(
            $full,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "BLOCKED: A matching directory lease is required before creating a mutation guard: $full"
    }

    $guardLeaf = '.mcg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    $guardPath = Join-Path $full $guardLeaf
    if ($guardPath.Length -gt 259) {
        throw "BLOCKED: The directory mutation-guard path exceeds 259 characters: $guardPath"
    }

    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $guardPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
        $bytes = [Text.Encoding]::UTF8.GetBytes($RunId)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)

        $DirectoryLease.VerifyStillNonReparseDirectory()
        $handleIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $stream.SafeFileHandle
        )
        $pathIdentity = [Mql5Coding.JobProcessLaunch]::GetNonReparseGuardFileIdentity(
            $guardPath
        )
        if ([string]$handleIdentity -cne [string]$pathIdentity) {
            throw 'The directory mutation guard did not remain bound to its leased directory.'
        }
        $DirectoryLease.VerifyStillNonReparseDirectory()

        $record = [pscustomobject][ordered]@{
            directory_path = $full
            path = $guardPath
            file_identity = $handleIdentity
            stream = $stream
        }
        $GuardsByPath[$key] = $record
        $Tracker.Add($record)
        return $record
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw "BLOCKED: Could not pin a nonempty leased directory '$full': $($_.Exception.Message)"
    }
}

function Assert-ExpectedApplicationMarker {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$SourceName
    )

    if ($Marker -cnotmatch '\AMQL5_CODING_PASS:[0-9A-Fa-f]{32,64}(?::[A-Za-z0-9_.-]{1,64})?\z') {
        throw (
            "$SourceName must use the case-sensitive pass protocol " +
            "'MQL5_CODING_PASS:<32-64 hex nonce>[:optional-label]'."
        )
    }
}

function ConvertFrom-TerminalOriginText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $origin = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($origin) -or
        $origin -match '[\r\n]' -or
        -not (Test-IsAbsoluteLocalDrivePath -Path $origin)) {
        throw "Terminal origin file must contain exactly one absolute install-directory path: $SourcePath"
    }
    return [IO.Path]::GetFullPath($origin)
}

function Read-TerminalOrigin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Lease
    )

    $full = [IO.Path]::GetFullPath($Path)
    if ($null -eq $Lease -or [bool]$Lease.IsDirectory -or
        -not ([IO.Path]::GetFullPath([string]$Lease.Path)).Equals(
            $full,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "A matching no-follow file lease is required before reading terminal origin: $full"
    }

    $stream = [IO.File]::Open(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $streamIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $stream.SafeFileHandle
        )
        if ([string]$streamIdentity -cne [string]$Lease.Identity) {
            throw "Terminal origin path changed while its file lease was held: $full"
        }
        if ([long]$stream.Length -le 0 -or [long]$stream.Length -gt 32768) {
            throw "Terminal origin file must contain 1-32768 bytes: $full"
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $reader = New-Object IO.StreamReader(
            $stream,
            $strictUtf8,
            $true,
            1024,
            $true
        )
        try {
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        return ConvertFrom-TerminalOriginText -Text $text -SourcePath $full
    }
    finally {
        $stream.Dispose()
    }
}

function Resolve-TerminalBinding {
    param(
        [string]$RequestedTerminalPath,
        [string]$RequestedDataPath,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $terminal = $null
    $data = $null

    if (-not [string]::IsNullOrWhiteSpace($RequestedTerminalPath)) {
        $terminal = Resolve-ExistingFile -Path $RequestedTerminalPath -Name 'TerminalPath' -Tracker $Tracker -LeasesByPath $LeasesByPath
        if ([IO.Path]::GetFileName($terminal) -ine 'terminal64.exe') {
            throw "TerminalPath must identify terminal64.exe: $terminal"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedDataPath)) {
        if (-not (Test-IsAbsoluteLocalDrivePath -Path $RequestedDataPath)) {
            throw 'TerminalDataPath must be an absolute path.'
        }
        $data = ConvertTo-NormalizedDirectoryPath -Path $RequestedDataPath
        $null = Open-NonReparseDirectoryChain -Path $data -Tracker $Tracker -LeasesByPath $LeasesByPath
    }

    $terminalDataRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MetaQuotes\Terminal'
    if ($null -eq $data) {
        $null = Open-NonReparseDirectoryChain -Path $terminalDataRoot -Tracker $Tracker -LeasesByPath $LeasesByPath
        $matches = New-Object 'System.Collections.Generic.List[object]'
        foreach ($directory in Get-ChildItem -LiteralPath $terminalDataRoot -Directory) {
            $candidateData = [IO.Path]::GetFullPath($directory.FullName)
            $null = Open-NonReparseDirectoryChain -Path $candidateData -Tracker $Tracker -LeasesByPath $LeasesByPath
            $originPath = Join-Path $candidateData 'origin.txt'
            $originLease = Try-OpenNonReparseFileLeaf -Path $originPath -Tracker $Tracker -LeasesByPath $LeasesByPath
            if ($null -eq $originLease) {
                continue
            }
            try {
                $origin = Read-TerminalOrigin -Path $originPath -Lease $originLease
            }
            catch {
                continue
            }

            if ($null -eq $terminal) {
                $candidateTerminal = [IO.Path]::GetFullPath(
                    (Join-Path $origin 'terminal64.exe')
                )
                $candidateTerminalLease = Try-OpenNonReparseFileLeaf -Path $candidateTerminal -Tracker $Tracker -LeasesByPath $LeasesByPath
                if ($null -eq $candidateTerminalLease) {
                    continue
                }
                $matches.Add([pscustomobject]@{
                    data = $candidateData
                    terminal = $candidateTerminal
                })
            }
            else {
                $terminalInstall = [IO.Path]::GetFullPath(
                    (Split-Path -Parent $terminal)
                ).TrimEnd('\', '/')
                if ($origin.TrimEnd('\', '/').Equals(
                        $terminalInstall,
                        [StringComparison]::OrdinalIgnoreCase
                    )) {
                    $matches.Add([pscustomobject]@{
                        data = $candidateData
                        terminal = $terminal
                    })
                }
            }
        }

        if ($matches.Count -eq 0) {
            throw 'No terminal data directory with a matching origin.txt was found.'
        }
        if ($matches.Count -gt 1) {
            $candidatePaths = @($matches | ForEach-Object { $_.data })
            throw "Terminal data discovery is ambiguous: $($candidatePaths -join '; ')"
        }
        $data = [IO.Path]::GetFullPath([string]$matches[0].data)
        if ($null -eq $terminal) {
            $terminal = [IO.Path]::GetFullPath([string]$matches[0].terminal)
        }
    }

    $dataLease = Open-NonReparseDirectoryChain -Path $data -Tracker $Tracker -LeasesByPath $LeasesByPath
    $originPath = Join-Path $data 'origin.txt'
    $originFileLease = Open-NonReparseFileLeaf -Path $originPath -Tracker $Tracker -LeasesByPath $LeasesByPath
    $origin = Read-TerminalOrigin -Path $originPath -Lease $originFileLease
    if ($null -eq $terminal) {
        $terminal = Resolve-ExistingFile -Path (Join-Path $origin 'terminal64.exe') -Name 'terminal64.exe from origin.txt' -Tracker $Tracker -LeasesByPath $LeasesByPath
    }
    else {
        $null = Open-NonReparseFileLeaf -Path $terminal -Tracker $Tracker -LeasesByPath $LeasesByPath
    }

    $terminalInstall = [IO.Path]::GetFullPath(
        (Split-Path -Parent $terminal)
    ).TrimEnd('\', '/')
    if (-not $origin.TrimEnd('\', '/').Equals(
            $terminalInstall,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "TerminalDataPath belongs to '$origin', not to '$terminal'."
    }

    foreach ($requiredDirectory in @(
            (Join-Path $data 'MQL5'),
            (Join-Path $data 'Tester'),
            (Join-Path $data 'logs')
        )) {
        $null = Open-NonReparseDirectoryChain -Path $requiredDirectory -Tracker $Tracker -LeasesByPath $LeasesByPath
    }

    return [pscustomobject][ordered]@{
        terminal_path = [IO.Path]::GetFullPath($terminal)
        terminal_data_path = [IO.Path]::GetFullPath($data)
    }
}

function Get-FileIdentityFromPath {
    param([Parameter(Mandatory)][string]$Path)

    $temporaryLeases = New-Object 'System.Collections.Generic.List[object]'
    $temporaryLeasesByPath = @{}
    try {
        $lease = Open-NonReparseFileLeaf -Path $Path -Tracker $temporaryLeases -LeasesByPath $temporaryLeasesByPath
        return [string]$lease.Identity
    }
    finally {
        for ($index = $temporaryLeases.Count - 1; $index -ge 0; $index--) {
            $temporaryLeases[$index].Dispose()
        }
    }
}

function Get-NativeProcessImageObservation {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedVolumePath
    )

    [string]$translatedPath = ''
    try {
        $onExpectedVolume = [Mql5Coding.JobProcessLaunch]::TryGetProcessImagePathOnFixedVolume(
                $ProcessId,
                $ExpectedVolumePath,
                [ref]$translatedPath
            )
    }
    catch {
        return [pscustomobject][ordered]@{
            query_succeeded = $false
            on_expected_volume = $false
            identity_resolved = $false
            executable_path = $null
            file_identity = $null
            error = $_.Exception.Message
        }
    }

    if (-not $onExpectedVolume) {
        return [pscustomobject][ordered]@{
            query_succeeded = $true
            on_expected_volume = $false
            identity_resolved = $false
            executable_path = $null
            file_identity = $null
            error = $null
        }
    }

    try {
        $identity = Get-FileIdentityFromPath -Path $translatedPath
        return [pscustomobject][ordered]@{
            query_succeeded = $true
            on_expected_volume = $true
            identity_resolved = $true
            executable_path = [IO.Path]::GetFullPath($translatedPath)
            file_identity = [string]$identity
            error = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            query_succeeded = $true
            on_expected_volume = $true
            identity_resolved = $false
            executable_path = [IO.Path]::GetFullPath($translatedPath)
            file_identity = $null
            error = $_.Exception.Message
        }
    }
}

function Open-TerminalImageReadLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker
    )

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ([long]$stream.Length -le 0) {
            throw "Terminal executable is empty: $Path"
        }

        $record = [pscustomobject][ordered]@{
            kind = 'terminal executable'
            destination_path = [IO.Path]::GetFullPath($Path)
            byte_length = [long]$stream.Length
            sha256 = Get-StreamSha256 -Stream $stream
            file_identity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            )
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $stream
        })
        $stream = $null
        return $record
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Wait-ForNoMatchingTerminalProcesses {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedFileIdentity,
        [Parameter(Mandatory)]$VerifiedOwnedProcessIdentity,
        [ValidateRange(0, 60000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(0, 1000)][int]$PollMilliseconds = 100
    )

    if (
        $null -eq $VerifiedOwnedProcessIdentity.creation_utc_ticks -or
        $null -eq $VerifiedOwnedProcessIdentity.session_id -or
        [string]$VerifiedOwnedProcessIdentity.executable_file_identity -cne
            $ExpectedFileIdentity
    ) {
        throw 'Cannot retry post-exit process discovery without the verified owned process identity.'
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        # Inspection failures remain immediate blockers. Only an exact row for
        # the already verified owned process is eligible for bounded settling.
        $matches = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath $ExecutablePath `
                -ExpectedFileIdentity $ExpectedFileIdentity `
                -SettlingOwnedIdentity $VerifiedOwnedProcessIdentity
        )
        if ($matches.Count -eq 0) {
            return @()
        }

        $foreignMatch = @(
            $matches | Where-Object {
                if ([bool]$_.identity_unresolved) {
                    return (
                        [int]$_.process_id -ne
                            [int]$VerifiedOwnedProcessIdentity.process_id
                    )
                }
                return (
                    [int]$_.process_id -ne
                        [int]$VerifiedOwnedProcessIdentity.process_id -or
                    $null -eq $_.creation_utc_ticks -or
                    [long]$_.creation_utc_ticks -ne
                        [long]$VerifiedOwnedProcessIdentity.creation_utc_ticks -or
                    $null -eq $_.session_id -or
                    [int]$_.session_id -ne
                        [int]$VerifiedOwnedProcessIdentity.session_id -or
                    [string]$_.executable_file_identity -cne
                        [string]$VerifiedOwnedProcessIdentity.executable_file_identity
                )
            }
        )
        if ($foreignMatch.Count -gt 0) {
            return $matches
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            return $matches
        }
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
}

function Get-MatchingTerminalProcesses {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedFileIdentity,
        $TrustedSuspendedIdentity,
        $SettlingOwnedIdentity
    )
    if (
        $null -ne $TrustedSuspendedIdentity -and
        $null -ne $SettlingOwnedIdentity
    ) {
        throw 'Process discovery cannot use suspended and settling identities together.'
    }

    $wanted = [IO.Path]::GetFullPath($ExecutablePath)
    $wantedLeaf = [IO.Path]::GetFileName($wanted)
    $suspendedVerifiedPath = $null
    if ($null -ne $TrustedSuspendedIdentity) {
        $suspendedVerifiedPath = [IO.Path]::GetFullPath(
            [string]$TrustedSuspendedIdentity.executable_path
        )
        if (
            [IO.Path]::GetFileName($suspendedVerifiedPath) -ine $wantedLeaf -or
            [string]$TrustedSuspendedIdentity.executable_file_identity -cne
                $ExpectedFileIdentity
        ) {
            throw 'The trusted suspended process identity does not match the selected terminal image.'
        }
    }
    $settlingVerifiedPath = $null
    if ($null -ne $SettlingOwnedIdentity) {
        $settlingVerifiedPath = [IO.Path]::GetFullPath(
            [string]$SettlingOwnedIdentity.executable_path
        )
        if (
            [IO.Path]::GetFileName($settlingVerifiedPath) -ine $wantedLeaf -or
            [string]$SettlingOwnedIdentity.executable_file_identity -cne
                $ExpectedFileIdentity
        ) {
            throw 'The settling process identity does not match the selected terminal image.'
        }
    }

    $matchingProcesses = New-Object 'System.Collections.Generic.List[object]'
    $unknown = New-Object 'System.Collections.Generic.List[int]'

    try {
        # Enumerate all process images so a hard-link, junction, symlink, or
        # short-path alias cannot evade the selected executable's file identity.
        $processes = @(Get-CimInstance -ClassName Win32_Process)
    }
    catch {
        throw "BLOCKED: Cannot safely inspect running process images: $($_.Exception.Message)"
    }

    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        $processName = [string]$process.Name
        $processNameAvailable = -not [string]::IsNullOrWhiteSpace($processName)
        $sameLeafName = (
            $processNameAvailable -and
            $processName.Equals(
                $wantedLeaf,
                [StringComparison]::OrdinalIgnoreCase
            )
        )

        $creationTicks = $null
        try {
            if ($process.CreationDate -is [datetime]) {
                $creationTicks = [long]$process.CreationDate.ToUniversalTime().Ticks
            }
        }
        catch {
            $creationTicks = $null
        }
        $sessionId = $null
        try {
            $observedSessionId = $process.SessionId
            if ($null -ne $observedSessionId) {
                $sessionId = [int]$observedSessionId
            }
        }
        catch {
            $sessionId = $null
        }

        # The live suspended PID and image were already verified through owned
        # native handles. CIM may hide fields until that process is resumed.
        $suspendedProcessIdMatch = (
            $null -ne $TrustedSuspendedIdentity -and
            $processId -eq [int]$TrustedSuspendedIdentity.process_id
        )
        $suspendedIdentityCompatible = (
            $suspendedProcessIdMatch -and
            (
                -not $processNameAvailable -or
                $sameLeafName
            )
        )
        $suspendedMatchRecord = if ($suspendedIdentityCompatible) {
            [pscustomobject][ordered]@{
                process_id = $processId
                parent_process_id = [int]$process.ParentProcessId
                creation_utc_ticks = if ($null -ne $creationTicks) {
                    $creationTicks
                }
                else {
                    [long]$TrustedSuspendedIdentity.creation_utc_ticks
                }
                session_id = if ($null -ne $sessionId) {
                    $sessionId
                }
                else {
                    [int]$TrustedSuspendedIdentity.session_id
                }
                creation_cim_observed = [bool]($null -ne $creationTicks)
                session_cim_observed = [bool]($null -ne $sessionId)
                executable_path = $suspendedVerifiedPath
                executable_file_identity = $ExpectedFileIdentity
                identity_match = $true
                path_match = $true
                identity_unresolved = $false
            }
        }
        else {
            $null
        }

        # After verified Job Object emptiness, an owned row can briefly outlive
        # readable CIM fields. Missing fields may settle; positive mismatches may not.
        $settlingProcessIdMatch = (
            $null -ne $SettlingOwnedIdentity -and
            $processId -eq [int]$SettlingOwnedIdentity.process_id
        )
        $settlingIdentityCompatible = (
            $settlingProcessIdMatch -and
            (
                -not $processNameAvailable -or
                $sameLeafName
            ) -and
            (
                $null -eq $creationTicks -or
                -not [bool]$SettlingOwnedIdentity.creation_cim_observed -or
                $creationTicks -eq [long]$SettlingOwnedIdentity.creation_utc_ticks
            ) -and
            (
                $null -eq $sessionId -or
                -not [bool]$SettlingOwnedIdentity.session_cim_observed -or
                $sessionId -eq [int]$SettlingOwnedIdentity.session_id
            )
        )
        $settlingIdentityComplete = (
            $settlingIdentityCompatible -and
            [bool]$SettlingOwnedIdentity.creation_cim_observed -and
            [bool]$SettlingOwnedIdentity.session_cim_observed -and
            $null -ne $creationTicks -and
            $null -ne $sessionId
        )
        $settlingMatchRecord = if ($settlingIdentityCompatible) {
            [pscustomobject][ordered]@{
                process_id = $processId
                parent_process_id = [int]$process.ParentProcessId
                creation_utc_ticks = $creationTicks
                session_id = $sessionId
                creation_cim_observed = [bool]$SettlingOwnedIdentity.creation_cim_observed
                session_cim_observed = [bool]$SettlingOwnedIdentity.session_cim_observed
                executable_path = $settlingVerifiedPath
                executable_file_identity = $ExpectedFileIdentity
                identity_match = $false
                path_match = $false
                identity_unresolved = $true
            }
        }
        else {
            $null
        }

        try {
            $path = [string]$process.ExecutablePath
        }
        catch {
            $path = ''
        }

        $reportedCandidate = $null
        $reportedIdentityError = $null
        $candidate = $null
        $candidateIdentity = $null
        $identityResolved = $false
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try {
                $reportedCandidate = [IO.Path]::GetFullPath($path)
                $candidate = $reportedCandidate
                $candidateIdentity = Get-FileIdentityFromPath -Path $reportedCandidate
                $identityResolved = $true
            }
            catch {
                $reportedIdentityError = $_.Exception.Message
            }
        }

        $nativeObservation = $null
        if (-not $identityResolved) {
            $nativeObservation = Get-NativeProcessImageObservation `
                -ProcessId $processId `
                -ExpectedVolumePath $wanted
            if ([bool]$nativeObservation.identity_resolved) {
                $candidate = [IO.Path]::GetFullPath(
                    [string]$nativeObservation.executable_path
                )
                $candidateIdentity = [string]$nativeObservation.file_identity
                $identityResolved = $true
            }
        }

        if (-not $identityResolved) {
            $nativeVolumeContradiction = (
                $null -ne $nativeObservation -and
                [bool]$nativeObservation.query_succeeded -and
                -not [bool]$nativeObservation.on_expected_volume
            )
            $nativeReparseRejected = (
                $null -ne $nativeObservation -and
                [bool]$nativeObservation.query_succeeded -and
                [bool]$nativeObservation.on_expected_volume -and
                -not [bool]$nativeObservation.identity_resolved -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$nativeObservation.error
                ) -and
                [string]$nativeObservation.error -match
                    '(?i)\breparse(?:-point)?\b'
            )
            if ([string]::IsNullOrWhiteSpace($path)) {
                if (
                    $null -ne $suspendedMatchRecord -and
                    -not $nativeVolumeContradiction
                ) {
                    $matchingProcesses.Add($suspendedMatchRecord)
                }
                elseif (
                    $null -ne $settlingMatchRecord -and
                    -not $nativeVolumeContradiction
                ) {
                    $matchingProcesses.Add($settlingMatchRecord)
                }
                elseif (
                    -not $nativeVolumeContradiction -and
                    (
                        $sameLeafName -or
                        $suspendedProcessIdMatch -or
                        $settlingProcessIdMatch -or
                        $nativeReparseRejected
                    )
                ) {
                    $unknown.Add($processId)
                }
                continue
            }

            $pathMatches = (
                $null -ne $reportedCandidate -and
                $reportedCandidate.Equals(
                    $wanted,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )
            $suspendedKnownPath = (
                $null -eq $reportedCandidate -or
                $pathMatches -or
                (
                    $null -ne $suspendedVerifiedPath -and
                    $reportedCandidate.Equals(
                        $suspendedVerifiedPath,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                )
            )
            $settlingKnownPath = (
                $null -eq $reportedCandidate -or
                $pathMatches -or
                (
                    $null -ne $settlingVerifiedPath -and
                    $reportedCandidate.Equals(
                        $settlingVerifiedPath,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                )
            )
            $reportedReparseRejected = (
                -not [string]::IsNullOrWhiteSpace($reportedIdentityError) -and
                $reportedIdentityError -match '(?i)\breparse(?:-point)?\b'
            )
            $sameVolumeReparseUnresolved = (
                $nativeReparseRejected -or
                (
                    $reportedReparseRejected -and
                    (
                        $null -eq $nativeObservation -or
                        -not [bool]$nativeObservation.query_succeeded -or
                        [bool]$nativeObservation.on_expected_volume
                    )
                )
            )
            if (
                $null -ne $suspendedMatchRecord -and
                $suspendedKnownPath -and
                -not $nativeVolumeContradiction
            ) {
                $matchingProcesses.Add($suspendedMatchRecord)
            }
            elseif (
                $null -ne $settlingMatchRecord -and
                $settlingKnownPath -and
                -not $nativeVolumeContradiction
            ) {
                $matchingProcesses.Add($settlingMatchRecord)
            }
            elseif (
                -not $nativeVolumeContradiction -and
                (
                    $sameLeafName -or
                    $pathMatches -or
                    $suspendedProcessIdMatch -or
                    $settlingProcessIdMatch -or
                    $sameVolumeReparseUnresolved
                )
            ) {
                $unknown.Add($processId)
            }
            continue
        }

        $pathMatch = (
            $candidate.Equals(
                $wanted,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            (
                $null -ne $reportedCandidate -and
                $reportedCandidate.Equals(
                    $wanted,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )
        )
        $identityMatch = $candidateIdentity.Equals(
            $ExpectedFileIdentity,
            [StringComparison]::Ordinal
        )
        if ($suspendedProcessIdMatch) {
            if (
                $identityMatch -and
                $null -ne $suspendedMatchRecord
            ) {
                $matchingProcesses.Add($suspendedMatchRecord)
            }
            else {
                $unknown.Add($processId)
            }
        }
        elseif ($settlingProcessIdMatch) {
            if (
                -not $identityMatch -or
                $null -eq $settlingMatchRecord
            ) {
                $unknown.Add($processId)
            }
            elseif (-not $settlingIdentityComplete) {
                $matchingProcesses.Add($settlingMatchRecord)
            }
            else {
                $matchingProcesses.Add([pscustomobject][ordered]@{
                    process_id = $processId
                    parent_process_id = [int]$process.ParentProcessId
                    creation_utc_ticks = $creationTicks
                    session_id = $sessionId
                    creation_cim_observed = $true
                    session_cim_observed = $true
                    executable_path = $candidate
                    executable_file_identity = $candidateIdentity
                    identity_match = $true
                    path_match = [bool]$pathMatch
                    identity_unresolved = $false
                })
            }
        }
        elseif ($pathMatch -or $identityMatch) {
            $matchingProcesses.Add([pscustomobject][ordered]@{
                process_id = $processId
                parent_process_id = [int]$process.ParentProcessId
                creation_utc_ticks = $creationTicks
                session_id = $sessionId
                creation_cim_observed = [bool]($null -ne $creationTicks)
                session_cim_observed = [bool]($null -ne $sessionId)
                executable_path = $candidate
                executable_file_identity = $candidateIdentity
                identity_match = [bool]$identityMatch
                path_match = [bool]$pathMatch
                identity_unresolved = $false
            })
        }
    }

    if ($unknown.Count -gt 0) {
        throw "BLOCKED: Running terminal64.exe process identity is unreadable for PID(s) $($unknown -join ', '); refusing an unsafe launch."
    }
    return $matchingProcesses.ToArray()
}

function Open-DataDirectoryLock {
    param(
        [Parameter(Mandatory)][string]$TerminalDataPath,
        [Parameter(Mandatory)][string]$RunId
    )
    # Keep the lock inside the bound data directory. Textual path hashes can be
    # bypassed by reaching the same directory through a junction or symlink.
    $lockPath = Join-Path $TerminalDataPath '.mql5-coding-smoke.data-lock'
    try {
        $stream = New-Object IO.FileStream(
            $lockPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
    }
    catch [IO.IOException] {
        throw (
            'BLOCKED: Another MQL5 Coding smoke run owns the terminal data lock, ' +
            "or a stale lock remains after an abnormal shutdown. Do not remove it unless no matching run is active: $lockPath"
        )
    }

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($RunId)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return [pscustomobject]@{ path = $lockPath; stream = $stream }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Open-NewOutputDirectoryClaim {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$DirectoryLease,
        [Parameter(Mandatory)]$IntegrityTracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    if ($null -eq $DirectoryLease -or
        -not [bool]$DirectoryLease.IsDirectory -or
        -not (ConvertTo-NormalizedDirectoryPath -Path ([string]$DirectoryLease.Path)).Equals(
            $full,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "OutputDirectory must have a matching live directory lease before it is claimed: $full"
    }
    $DirectoryLease.VerifyStillNonReparseDirectory()
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "OutputDirectory must be created and path-lease validated before it is claimed: $full"
    }
    if (@(Get-ChildItem -LiteralPath $full -Force).Count -ne 0) {
        throw "OutputDirectory was populated before exclusive ownership was established: $full"
    }

    $claimPath = Join-Path $full '.mql5-coding-smoke.claim'
    $ownerPath = Join-Path $full '.mql5-coding-smoke.owner'
    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $claimPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
        $entries = @(Get-ChildItem -LiteralPath $full -Force)
        if ($entries.Count -ne 1 -or
            -not ([IO.Path]::GetFullPath($entries[0].FullName)).Equals(
                [IO.Path]::GetFullPath($claimPath),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "OutputDirectory was populated before exclusive ownership was established: $full"
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($RunId)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $DirectoryLease.VerifyStillNonReparseDirectory()
        $claimHandleIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $stream.SafeFileHandle
        )
        $claimPathIdentity = [Mql5Coding.JobProcessLaunch]::GetNonReparseGuardFileIdentity(
            $claimPath
        )
        if ([string]$claimHandleIdentity -cne [string]$claimPathIdentity) {
            throw 'The output-directory claim did not remain bound to its leased directory.'
        }
        $DirectoryLease.VerifyStillNonReparseDirectory()

        $ownerText = $RunId + "\`n"
        $ownerRecord = Open-NewTextArtifactReadLock -Text $ownerText -Path $ownerPath -Encoding (New-Object Text.UTF8Encoding($false)) -Kind 'output owner' -Tracker $IntegrityTracker -PathEntryLeases $PathEntryLeases -LeasesByPath $LeasesByPath
        return [pscustomobject]@{
            path = $claimPath
            stream = $stream
            owner_path = $ownerPath
            owner_sha256 = $ownerRecord.sha256
            owner_record = $ownerRecord
            file_identity = $claimHandleIdentity
        }
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw "OutputDirectory could not be claimed exclusively: $full. $($_.Exception.Message)"
    }
}

function Copy-NewHashBoundFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $sourceLease = Open-NonReparseFileLeaf -Path $Source -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $parent = Split-Path -Parent $Destination
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $input = $null
    $output = $null
    $record = $null
    try {
        $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($input.SafeFileHandle) -cne
            [string]$sourceLease.Identity) {
            throw "$Kind source path changed before staging: $Source"
        }
        $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $record = [pscustomobject][ordered]@{
            kind = $Kind
            source_path = $Source
            destination_path = $Destination
            byte_length = [long]0
            sha256 = $null
            verified = $false
        }
        $Tracker.Add($record)
        $input.CopyTo($output)
        $output.Flush($true)

        $destinationLease = Open-NonReparseFileLeaf -Path $Destination -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($output.SafeFileHandle) -cne
            [string]$destinationLease.Identity) {
            throw "$Kind staging path changed while its lease was established: $Destination"
        }

        $sourceLength = [long]$input.Length
        $destinationLength = [long]$output.Length
        $sourceHash = Get-StreamSha256 -Stream $input
        $destinationHash = Get-StreamSha256 -Stream $output
        if ($sourceLength -ne $destinationLength -or
            $sourceHash -cne $destinationHash) {
            throw "$Kind staging hash mismatch: $Destination"
        }

        $record.byte_length = $destinationLength
        $record.sha256 = $destinationHash
        $record.verified = $true
        return $record
    }
    finally {
        if ($null -ne $output) {
            $output.Dispose()
        }
        if ($null -ne $input) {
            $input.Dispose()
        }
    }
}

function Copy-NewVerifiedOutputArtifact {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$SourceLease,
        [Parameter(Mandatory)]$Tracker
    )

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $input = $null
    $output = $null
    try {
        $input = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($input.SafeFileHandle) -cne [string]$SourceLease.Identity) {
            throw "$Kind source identity changed before output publication: $sourcePath"
        }

        $output = [Mql5Coding.JobProcessLaunch]::CreatePinnedOutputFileStream($destinationPath)
        $input.CopyTo($output)
        $output.Flush($true)
        $sourceHash = Get-StreamSha256 -Stream $input
        $destinationHash = Get-StreamSha256 -Stream $output
        if ([long]$input.Length -ne [long]$output.Length -or $sourceHash -cne $destinationHash) {
            throw "$Kind output copy failed exact byte verification: $destinationPath"
        }

        $record = [pscustomobject][ordered]@{
            kind = $Kind
            source_path = $sourcePath
            destination_path = $destinationPath
            byte_length = [long]$output.Length
            sha256 = $destinationHash
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $output
        })
        $output = $null
        return $record
    }
    finally {
        if ($null -ne $output) {
            $output.Dispose()
        }
        if ($null -ne $input) {
            $input.Dispose()
        }
    }
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-Hex -Bytes $algorithm.ComputeHash($Stream)
    }
    finally {
        $algorithm.Dispose()
        $Stream.Position = 0
    }
}

function Open-NewTextArtifactReadLock {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Text.Encoding]$Encoding,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $creationStream = $null
    try {
        $creationStream = [Mql5Coding.JobProcessLaunch]::CreatePinnedOutputFileStream(
            $full
        )
        $preamble = $Encoding.GetPreamble()
        if ($preamble.Length -gt 0) {
            $creationStream.Write($preamble, 0, $preamble.Length)
        }
        $bytes = $Encoding.GetBytes($Text)
        if ($bytes.Length -gt 0) {
            $creationStream.Write($bytes, 0, $bytes.Length)
        }
        $creationStream.Flush($true)

        # Correlate the exact no-follow creation handle with a retained no-follow
        # leaf lease while the creation handle is still open. Keeping that same
        # stream removes the close-to-reopen replacement window.
        $lease = Open-NonReparseFileLeaf -Path $full -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
        $creationIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $creationStream.SafeFileHandle
        )
        if ([string]$creationIdentity -cne [string]$lease.Identity) {
            throw "$Kind creation handle did not remain bound to its no-follow leaf lease: $full"
        }
        $expectedLength = [long]$creationStream.Length
        $expectedHash = Get-StreamSha256 -Stream $creationStream

        $record = [pscustomobject][ordered]@{
            kind = $Kind
            destination_path = $full
            byte_length = $expectedLength
            sha256 = $expectedHash
            file_identity = $creationIdentity
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $creationStream
        })
        $creationStream = $null
        return $record
    }
    finally {
        if ($null -ne $creationStream) {
            $creationStream.Dispose()
        }
    }
}

function Open-TerminalOriginReadLock {
    param(
        [Parameter(Mandatory)][string]$TerminalDataPath,
        [Parameter(Mandatory)][string]$TerminalPath,
        [Parameter(Mandatory)]$Tracker
    )

    $originPath = Join-Path $TerminalDataPath 'origin.txt'
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $originPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ([long]$stream.Length -le 0 -or [long]$stream.Length -gt 32768) {
            throw "Terminal origin file must contain 1-32768 bytes: $originPath"
        }

        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $reader = New-Object IO.StreamReader($stream, $strictUtf8, $true, 1024, $true)
        try {
            $originText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        $origin = ConvertFrom-TerminalOriginText -Text $originText -SourcePath $originPath
        $terminalInstall = [IO.Path]::GetFullPath((Split-Path -Parent $TerminalPath)).TrimEnd('\', '/')
        if (-not $origin.TrimEnd('\', '/').Equals(
                $terminalInstall,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Terminal data origin changed or does not belong to '$TerminalPath': $originPath"
        }

        $stream.Position = 0
        $record = [pscustomobject][ordered]@{
            kind = 'terminal origin binding'
            destination_path = $originPath
            install_path = $origin
            byte_length = [long]$stream.Length
            sha256 = Get-StreamSha256 -Stream $stream
            file_identity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            )
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $stream
        })
        $stream = $null
        return $record
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Open-StagingReadLocks {
    param(
        [Parameter(Mandatory)]$Records,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    foreach ($record in $Records) {
        if ($null -eq $record.PSObject.Properties['verified'] -or -not [bool]$record.verified) {
            throw "Cannot lock an unverified $($record.kind) staging copy: $($record.destination_path)"
        }
        $path = [IO.Path]::GetFullPath([string]$record.destination_path)
        $lease = Open-NonReparseFileLeaf -Path $path -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
        $stream = [IO.File]::Open(
            $path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($stream.SafeFileHandle) -cne
                [string]$lease.Identity) {
                throw "$($record.kind) path changed while its read lock was established: $path"
            }
            $entry = [pscustomobject][ordered]@{
                record = $record
                stream = $stream
            }
            $Tracker.Add($entry)
            $stream = $null
            $hash = Get-StreamSha256 -Stream $entry.stream
            if ([long]$entry.stream.Length -ne [long]$record.byte_length -or
                $hash -cne [string]$record.sha256) {
                throw "$($record.kind) staging bytes changed before the read lock was established: $path"
            }
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
}

function Open-VerifiedArtifactReadLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $full = [IO.Path]::GetFullPath($Path)
    $lease = Open-NonReparseFileLeaf -Path $full -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $stream = [IO.File]::Open(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($stream.SafeFileHandle) -cne
            [string]$lease.Identity) {
            throw "$Kind path changed while its read lock was established: $full"
        }
        $record = [pscustomobject][ordered]@{
            kind = $Kind
            destination_path = $full
            byte_length = [long]$stream.Length
            sha256 = Get-StreamSha256 -Stream $stream
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $stream
        })
        $stream = $null
        return $record
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-PinnedStagingIntegrityFailures {
    param([Parameter(Mandatory)]$Locks)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Locks) {
        $record = $entry.record
        $stream = $entry.stream
        try {
            $hash = Get-StreamSha256 -Stream $stream
            if ([long]$stream.Length -ne [long]$record.byte_length -or $hash -cne [string]$record.sha256) {
                $failures.Add("$($record.kind) staging bytes changed while its read lock was held: $($record.destination_path)")
            }
        }
        catch {
            $failures.Add("Could not verify locked $($record.kind) staging bytes '$($record.destination_path)': $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}

function Get-StreamPrefixSha256 {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Length
    )

    if ($Length -lt 0 -or $Length -gt [long]$Stream.Length) {
        throw "Cannot hash $Length bytes from a stream of length $($Stream.Length)."
    }
    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 1048576
    $remaining = $Length
    try {
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $Stream.Read($buffer, 0, $requested)
            if ($read -le 0) {
                throw "Stream ended before the requested $Length-byte prefix could be hashed."
            }
            $null = $algorithm.TransformBlock($buffer, 0, $read, $buffer, 0)
            $remaining -= $read
        }
        $empty = New-Object byte[] 0
        $null = $algorithm.TransformFinalBlock($empty, 0, 0)
        return ConvertTo-Hex -Bytes $algorithm.Hash
    }
    finally {
        $algorithm.Dispose()
        $Stream.Position = 0
    }
}

function Get-JournalSnapshot {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [Parameter(Mandatory)]$StreamTracker,
        [hashtable]$Existing = @{}
    )
    $snapshot = @{}
    $null = Open-NonReparseDirectoryChain -Path $RootPath -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    foreach ($file in Get-ChildItem -LiteralPath $RootPath -File -Filter '*.log') {
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        $key = $fullPath.ToLowerInvariant()
        $stream = $null
        $lease = $null
        $newStream = $false
        if ($Existing.ContainsKey($key)) {
            $stream = $Existing[$key].stream
            $lease = $Existing[$key].path_entry_lease
        }
        else {
            $lease = Open-NonReparseFileLeaf -Path $fullPath -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
            $stream = [IO.File]::Open(
                $fullPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite
            )
            $newStream = $true
        }

        try {
            $streamIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            )
            if ($streamIdentity -cne [string]$lease.Identity) {
                throw "Journal path changed while its read lease was acquired: $fullPath"
            }
            $byteLength = [long]$stream.Length
            $prefixHash = Get-StreamPrefixSha256 -Stream $stream -Length $byteLength
            if ($newStream) {
                $StreamTracker.Add($stream)
                $newStream = $false
            }
        }
        finally {
            if ($newStream -and $null -ne $stream) {
                $stream.Dispose()
            }
        }
        $snapshot[$key] = [pscustomobject]@{
            path = $fullPath
            byte_length = $byteLength
            prefix_sha256 = $prefixHash
            file_identity = $streamIdentity
            path_entry_lease = $lease
            stream = $stream
        }
    }
    return $snapshot
}

function Read-ExactBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Length
    )
    $bytes = New-Object byte[] $Length
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $null = $stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $readTotal = 0
        while ($readTotal -lt $Length) {
            $read = $stream.Read($bytes, $readTotal, $Length - $readTotal)
            if ($read -le 0) {
                throw "Journal ended while reading appended bytes: $Path"
            }
            $readTotal += $read
        }
    }
    finally {
        $stream.Dispose()
    }
    return $bytes
}

function Read-ExactBytesFromStream {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Length,
        [Parameter(Mandatory)][string]$Path
    )

    $bytes = New-Object byte[] $Length
    $null = $Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $readTotal = 0
    while ($readTotal -lt $Length) {
        $read = $Stream.Read($bytes, $readTotal, $Length - $readTotal)
        if ($read -le 0) {
            throw "Journal ended while reading appended bytes: $Path"
        }
        $readTotal += $read
    }
    return $bytes
}

function Read-JournalDelta {
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][int]$MaximumBytes,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [Parameter(Mandatory)]$StreamTracker
    )
    $after = Get-JournalSnapshot -RootPath $RootPath -PathEntryLeases $PathEntryLeases -LeasesByPath $LeasesByPath -StreamTracker $StreamTracker -Existing $Before
    $plans = New-Object 'System.Collections.Generic.List[object]'
    $total = [long]0

    foreach ($beforeKey in $Before.Keys) {
        if (-not $after.ContainsKey($beforeKey)) {
            throw "$LogicalName journal disappeared during the run: $($Before[$beforeKey].path)"
        }
    }

    foreach ($entry in @($after.Values | Sort-Object path)) {
        $key = ([string]$entry.path).ToLowerInvariant()
        $offset = [long]0
        $beforePrefixHash = $null
        if ($Before.ContainsKey($key)) {
            $offset = [long]$Before[$key].byte_length
            $beforePrefixHash = [string]$Before[$key].prefix_sha256
        }
        if ([long]$entry.byte_length -lt $offset) {
            throw "$LogicalName journal was truncated during the run: $($entry.path)"
        }
        $length = [long]$entry.byte_length - $offset
        if ($length -le 0) {
            if ($offset -gt 0 -and [string]$entry.prefix_sha256 -cne $beforePrefixHash) {
                throw "$LogicalName journal bytes were replaced or modified during the run: $($entry.path)"
            }
            continue
        }
        $total += $length
        $plans.Add([pscustomobject]@{
            path = $entry.path
            offset = $offset
            byte_length = $length
            before_prefix_sha256 = $beforePrefixHash
            after_byte_length = [long]$entry.byte_length
            after_sha256 = [string]$entry.prefix_sha256
            file_identity = [string]$entry.file_identity
            stream = $entry.stream
        })
    }

    if ($total -gt $MaximumBytes) {
        return [pscustomobject][ordered]@{
            logical_name = $LogicalName
            root_path = $RootPath
            appended_byte_length = $total
            limit_exceeded = $true
            records = @()
            text = ''
        }
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $textParts = New-Object 'System.Collections.Generic.List[string]'
    $unicode = New-Object Text.UnicodeEncoding($false, $true, $true)
    foreach ($plan in $plans) {
        if ([long]$plan.byte_length -gt [int]::MaxValue) {
            throw "$LogicalName appended segment is too large to inspect safely: $($plan.path)"
        }
        $stream = $plan.stream
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            ) -cne [string]$plan.file_identity) {
            throw "$LogicalName journal file identity changed after its post-run snapshot: $($plan.path)"
        }
        if ([long]$stream.Length -ne [long]$plan.after_byte_length) {
            throw "$LogicalName journal changed after its post-run snapshot: $($plan.path)"
        }
        $afterHash = Get-StreamPrefixSha256 -Stream $stream -Length ([long]$plan.after_byte_length)
        if ($afterHash -cne [string]$plan.after_sha256) {
            throw "$LogicalName journal bytes changed after its post-run snapshot: $($plan.path)"
        }
        if ([long]$plan.offset -gt 0) {
            $prefixHash = Get-StreamPrefixSha256 -Stream $stream -Length ([long]$plan.offset)
            if ($prefixHash -cne [string]$plan.before_prefix_sha256) {
                throw "$LogicalName journal prefix was replaced or modified during the run: $($plan.path)"
            }
        }
        $bytes = Read-ExactBytesFromStream `
            -Stream $stream `
            -Offset ([long]$plan.offset) `
            -Length ([int]$plan.byte_length) `
            -Path ([string]$plan.path)
        $start = 0
        if ([long]$plan.offset -eq 0 -and $bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) {
            $start = 2
        }
        if ((($bytes.Length - $start) % 2) -ne 0) {
            throw "$LogicalName appended UTF-16LE journal segment has an odd byte length: $($plan.path)"
        }
        $decoded = $unicode.GetString($bytes, $start, $bytes.Length - $start)
        $textParts.Add($decoded)

        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ConvertTo-Hex -Bytes $algorithm.ComputeHash($bytes)
        }
        finally {
            $algorithm.Dispose()
        }
        $records.Add([pscustomobject][ordered]@{
            path = [string]$plan.path
            source_offset = [long]$plan.offset
            byte_length = [long]$plan.byte_length
            sha256 = $hash
        })
    }

    return [pscustomobject][ordered]@{
        logical_name = $LogicalName
        root_path = $RootPath
        appended_byte_length = $total
        limit_exceeded = $false
        records = $records.ToArray()
        text = ($textParts -join "`r`n")
    }
}

function Test-ContainsText {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Needle,
        [switch]$CaseSensitive
    )
    $comparison = if ($CaseSensitive) {
        [StringComparison]::Ordinal
    }
    else {
        [StringComparison]::OrdinalIgnoreCase
    }
    return $Text.IndexOf($Needle, $comparison) -ge 0
}

function Get-TextIndex {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Needle,
        [int]$StartIndex = 0,
        [switch]$CaseSensitive
    )

    if ($StartIndex -lt 0 -or $StartIndex -gt $Text.Length) {
        return -1
    }
    $comparison = if ($CaseSensitive) {
        [StringComparison]::Ordinal
    }
    else {
        [StringComparison]::OrdinalIgnoreCase
    }
    return $Text.IndexOf($Needle, $StartIndex, $comparison)
}

function Protect-JournalLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [string[]]$SensitiveValues = @()
    )
    $redacted = $Line
    $secretLabelPattern =
        '(?:' +
            '(?:[A-Za-z0-9]+[._-])*' +
                '(?:password|passwd|pwd|token|secret|authorization|auth|' +
                    'access[._-]+token|refresh[._-]+token|api[._-]+key|' +
                    'client[._-]+secret)' +
                '(?:[._-][A-Za-z0-9]+)*' +
            '|' +
            '(?-i:[A-Za-z0-9]*(?:[Pp]assword|[Pp]asswd|[Pp]wd|[Tt]oken|' +
                '[Ss]ecret|[Aa]uthorization|[Aa]uth|[Aa]pi[Kk]ey)' +
                '(?:[A-Z][A-Za-z0-9]*)*)' +
            '|' +
            'access[ \t]+token|refresh[ \t]+token|api[ \t]+key|' +
                'client[ \t]+secret' +
        ')'
    $secretLabelClosingQuotePattern = '(?:\\*["''])?'
    $orderedSensitiveValues = @(
        $SensitiveValues |
            Where-Object { -not [string]::IsNullOrEmpty($_) } |
            Sort-Object { $_.Length } -Descending
    )
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $redacted = [regex]::Replace(
            $redacted,
            [regex]::Escape($env:USERPROFILE),
            '<USERPROFILE>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $redacted = [regex]::Replace($redacted, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])', '<IP>')
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b(account|login)\s*[:=]?\s*[0-9]{5,}\b',
        '$1 <REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b(balance|equity|profit)\s+[-+]?[0-9]+(?:\.[0-9]+)?',
        '$1 <REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b(community|username|user)\s*[:=]\s*\S+',
        '$1=<REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9]+[._-])*' +
            '(?:authorization|auth)\b\s*[:=].*$',
        '<SECRET>=<REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+',
        'Bearer <REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)(?<![A-Za-z0-9_.-])(?:' +
            $secretLabelPattern +
            $secretLabelClosingQuotePattern +
            '\s*[:=]\s*[^\r\n]*' +
            '|--?' +
            $secretLabelPattern +
            '(?:\s+|\s*[:=]\s*)[^\r\n]*' +
        ')',
        '<SECRET>=<REDACTED>'
    )
    $bareSecretPattern =
        '(?i)(?<![A-Za-z0-9_.-])' +
            $secretLabelPattern +
            $secretLabelClosingQuotePattern +
            '\s+(?<bareSecretValue>[^\r\n]+)'
    $knownBareSecretDiagnosticPattern =
        '(?i)^(?:is\s+)?(?:authentication\s+failed|refresh\s+failed|not\s+configured|' +
            'missing|required|invalid|expired|rejected|failed|failure|denied|disabled|' +
            'enabled|unavailable|empty|absent)$'
    $redacted = [regex]::Replace(
        $redacted,
        $bareSecretPattern,
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $normalizedValue = [regex]::Replace(
                $match.Groups['bareSecretValue'].Value.Trim(),
                '\s+',
                ' '
            )
            if ($normalizedValue -match $knownBareSecretDiagnosticPattern) {
                return $match.Value
            }
            return '<SECRET>=<REDACTED>'
        }
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        '<EMAIL>'
    )
    $redacted = [regex]::Replace($redacted, '(?<![A-Za-z0-9])[0-9]{7,}(?![A-Za-z0-9])', '<NUMBER>')
    foreach ($sensitiveValue in $orderedSensitiveValues) {
        $redacted = $redacted.Replace($sensitiveValue, '')
    }
    foreach ($sensitiveValue in $orderedSensitiveValues) {
        if ($redacted.Contains($sensitiveValue)) {
            return ''
        }
    }
    return $redacted
}

function Select-JournalEvidence {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string[]]$Patterns,
        [string[]]$SensitiveValues = @()
    )
    $selected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $matched = $false
        foreach ($pattern in $Patterns) {
            if ($line -match $pattern) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            $safe = Protect-JournalLine -Line $line -SensitiveValues $SensitiveValues
            if (-not [string]::IsNullOrWhiteSpace($safe) -and -not $selected.Contains($safe)) {
                $selected.Add($safe)
            }
        }
        if ($selected.Count -ge 60) {
            break
        }
    }
    return $selected.ToArray()
}

function Get-SpawnedProcessIdentity {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExecutableFileIdentity
    )

    try {
        $creationUtcTicks = [long]$Process.StartTime.ToUniversalTime().Ticks
        $sessionId = [int]$Process.SessionId
    }
    catch {
        throw "Cannot capture the spawned process identity for PID $($Process.Id): $($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        process_id = [int]$Process.Id
        parent_process_id = [int]$PID
        creation_utc_ticks = $creationUtcTicks
        session_id = $sessionId
        executable_path = [IO.Path]::GetFullPath($ExecutablePath)
        executable_file_identity = $ExecutableFileIdentity
    }
}

function Write-NewTextFile {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Text.Encoding]$Encoding
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $preamble = $Encoding.GetPreamble()
        if ($preamble.Length -gt 0) {
            $stream.Write($preamble, 0, $preamble.Length)
        }
        $bytes = $Encoding.GetBytes($Text)
        if ($bytes.Length -gt 0) {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $json = $Value | ConvertTo-Json -Depth 12
    $utf8 = New-Object Text.UTF8Encoding($false)
    Write-NewTextFile -Text ($json + "`n") -Path $Path -Encoding $utf8
}

$runId = '{0}-{1}' -f ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0, 12))
$startedUtc = [datetimeoffset]::UtcNow
$errors = New-Object 'System.Collections.Generic.List[string]'
$warnings = New-Object 'System.Collections.Generic.List[string]'
$cleanupRemoved = New-Object 'System.Collections.Generic.List[string]'
$cleanupPreserved = New-Object 'System.Collections.Generic.List[string]'
$cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
$hashBoundStaging = New-Object 'System.Collections.Generic.List[object]'
$outputArtifactIntegrityRecords = New-Object 'System.Collections.Generic.List[object]'
$stagingReadLocks = New-Object 'System.Collections.Generic.List[object]'
$pathEntryLeases = New-Object 'System.Collections.Generic.List[object]'
$leasedPathEntries = @{}
$directoryMutationGuards = New-Object 'System.Collections.Generic.List[object]'
$guardedDirectories = @{}
$journalReadStreams = New-Object 'System.Collections.Generic.List[object]'
$generatedOwnedPaths = New-Object 'System.Collections.Generic.List[string]'
$createdDirectories = New-Object 'System.Collections.Generic.List[string]'
$lock = $null
$outputClaim = $null
$process = $null
$jobLaunch = $null
$ownedProcessTreeTerminationVerified = $true
$stagingReadLocksReleased = $true
$stagingReadLockAcquisitionCompleted = $false
$unsafePostLaunchIsolation = $false
$outputCreated = $false
$resultPath = $null
$resultWritten = $false
$exitCode = 2

$result = [ordered]@{
    schema_version = 2
    run_id = $runId
    status = 'preparing'
    primary_status_before_cleanup = $null
    started_utc = $startedUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'")
    ended_utc = $null
    duration_milliseconds = 0
    preflight_only = [bool]$PreflightOnly
    execute_requested = [bool]$Execute
    inputs = [ordered]@{
        expert_path = $ExpertPath
        expected_expert_sha256 = if ([string]::IsNullOrWhiteSpace($ExpectedExpertSha256)) { $null } else { $ExpectedExpertSha256 }
        set_path = if ([string]::IsNullOrWhiteSpace($SetPath)) { $null } else { $SetPath }
        use_expert_defaults = [bool]$UseExpertDefaults
        symbol = $Symbol
        period = $Period
        from_date = $FromDate
        to_date = $ToDate
        model = $Model
        deposit = $Deposit
        currency = $Currency
        leverage = $Leverage
        execution_mode = $ExecutionMode
        timeout_seconds = $TimeoutSeconds
        max_journal_append_bytes = $MaxJournalAppendBytes
        expected_log_marker_count = @($ExpectedLogMarker).Count
        expected_log_marker_file = if ([string]::IsNullOrWhiteSpace($ExpectedLogMarkerFile)) { $null } else { $ExpectedLogMarkerFile }
        expected_log_marker_file_sha256 = $null
        expected_log_marker_sha256 = @()
        expected_log_marker_aggregate_sha256 = $null
    }
    binding = $null
    safety = [ordered]@{
        strategy_tester_requested = [bool]$Execute
        saved_account_risk_acknowledged = [bool]$AcknowledgeSavedAccountRisk
        saved_terminal_state_isolation_verified = $false
        optimization = $false
        visual_mode = $false
        use_local_agents = $true
        use_remote_agents = $false
        use_cloud_agents = $false
        live_trading_disabled_in_startup_config = $true
        startup_config_effects_chm_verified = $false
        strict_offline_terminal = $false
        process_job_containment = $true
        staging_read_locks = $true
        output_artifact_read_locks = $true
        non_reparse_path_chain_leases = $true
        local_drive_paths_required = $true
        direct_fixed_volume_mapping_required = $true
        mount_manager_drive_registration_required = $true
        path_handle_volume_correlation = $true
        directory_data_write_sharing_denied = $true
        directory_mutation_guards = $true
        terminal_process_checks_point_in_time = $true
        execution_staging_auto_cleanup = $false
        preflight_staging_auto_cleanup = $false
        untrusted_code_sandbox = $false
        notice = 'The generated startup file requests local-only testing, disabled live trading, and terminal shutdown, but the effects of those startup keys are not verified in the installed MQL5 CHM. MT5 may initialize its saved broker account before the Strategy Tester starts. This runner does not attach the EA to a chart or call a live-order API, but it is not a security sandbox for untrusted EX5 code. The terminal is created suspended, assigned to a kill-on-close Windows Job Object, and resumed only after identity checks. Terminal-process discovery is point-in-time and cannot prevent a separately launched terminal from starting and exiting between checks.'
    }
    artifacts = [ordered]@{}
    process = [ordered]@{
        execution_attempted = $false
        process_created = $false
        process_id = $null
        resumed = $false
        suspended_launch_cleanup = $null
        exit_code = $null
        timed_out = $false
        job_containment_established = $false
        job_empty_verified = $false
        post_start_identity_verified = $false
        identity_source = $null
        post_exit_no_matching_terminal = $false
        post_exit_no_potential_descendants = $false
        potential_descendant_process_ids = @()
    }
    evidence = [ordered]@{}
    errors = $errors
    warnings = $warnings
    cleanup = [ordered]@{
        execution_staging_preserved = $false
        preflight_staging_preserved = $false
        removed = $cleanupRemoved
        preserved = $cleanupPreserved
        errors = $cleanupErrors
    }
}

try {
    if ($null -ne $nativeTypeLoadError) {
        throw "Native process helper could not be loaded: $nativeTypeLoadError"
    }
    if ($args.Count -gt 0) {
        throw "Unrecognized command-line argument count: $($args.Count)."
    }
    if ([bool]$Execute -eq [bool]$PreflightOnly) {
        throw 'Select exactly one mode: -Execute for a real tester run, or -PreflightOnly for validation without launching MT5.'
    }
    $hasSetPath = -not [string]::IsNullOrWhiteSpace([string]$SetPath)
    if ($hasSetPath -eq [bool]$UseExpertDefaults) {
        throw 'Select exactly one EA input source: -SetPath for an explicit .set preset, or -UseExpertDefaults after explicitly accepting the compiled EA defaults.'
    }
    if ([bool]$Execute -and -not [bool]$AcknowledgeSavedAccountRisk) {
        throw '-Execute requires -AcknowledgeSavedAccountRisk after the user explicitly confirms that MT5 may initialize its saved broker account and terminal state.'
    }
    if ([bool]$PreflightOnly -and [bool]$AcknowledgeSavedAccountRisk) {
        throw '-AcknowledgeSavedAccountRisk is valid only with -Execute.'
    }

    foreach ($required in @(
            [pscustomobject]@{ name = 'ExpertPath'; value = $ExpertPath },
            [pscustomobject]@{ name = 'Symbol'; value = $Symbol },
            [pscustomobject]@{ name = 'Period'; value = $Period },
            [pscustomobject]@{ name = 'FromDate'; value = $FromDate },
            [pscustomobject]@{ name = 'ToDate'; value = $ToDate },
            [pscustomobject]@{ name = 'Model'; value = $Model },
            [pscustomobject]@{ name = 'Deposit'; value = $Deposit },
            [pscustomobject]@{ name = 'Currency'; value = $Currency },
            [pscustomobject]@{ name = 'Leverage'; value = $Leverage },
            [pscustomobject]@{ name = 'ExecutionMode'; value = $ExecutionMode },
            [pscustomobject]@{ name = 'OutputDirectory'; value = $OutputDirectory }
        )) {
        if ($null -eq $required.value -or [string]::IsNullOrWhiteSpace([string]$required.value)) {
            throw "$($required.name) is required."
        }
    }

    $modelValue = 0
    if (-not [int]::TryParse([string]$Model, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$modelValue) -or
        $modelValue -lt 0 -or $modelValue -gt 4) {
        throw 'Model must be an integer from 0 through 4.'
    }
    $timeoutValue = 0
    if (-not [int]::TryParse([string]$TimeoutSeconds, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$timeoutValue) -or
        $timeoutValue -lt 10 -or $timeoutValue -gt 86400) {
        throw 'TimeoutSeconds must be an integer from 10 through 86400.'
    }
    $journalLimitValue = 0
    if (-not [int]::TryParse([string]$MaxJournalAppendBytes, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$journalLimitValue) -or
        $journalLimitValue -lt 1048576 -or $journalLimitValue -gt 268435456) {
        throw 'MaxJournalAppendBytes must be an integer from 1048576 through 268435456.'
    }
    $depositText = [string]$Deposit
    $depositValue = [decimal]::Zero
    if ($depositText -cnotmatch '\A[0-9]+(?:\.[0-9]+)?\z' -or
        -not [decimal]::TryParse($depositText, [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$depositValue) -or
        $depositValue -lt 1 -or $depositValue -gt 1000000000) {
        throw "Deposit must use invariant digits with an optional '.' fractional part and be from 1 through 1000000000."
    }
    $leverageValue = 0
    if (-not [int]::TryParse([string]$Leverage, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$leverageValue) -or
        $leverageValue -lt 1 -or $leverageValue -gt 5000) {
        throw 'Leverage must be an integer from 1 through 5000.'
    }
    $executionModeValue = 0
    if (-not [int]::TryParse([string]$ExecutionMode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$executionModeValue) -or
        $executionModeValue -lt -1 -or $executionModeValue -gt 10000) {
        throw 'ExecutionMode must be an integer from -1 through 10000.'
    }
    Assert-SafeIniValue -Value ([string]$Currency) -Name 'Currency' -MaximumLength 8
    if ([string]$Currency -cnotmatch '\A[A-Z]{3,8}\z') {
        throw 'Currency must contain 3-8 uppercase letters.'
    }

    $Model = $modelValue
    $TimeoutSeconds = $timeoutValue
    $MaxJournalAppendBytes = $journalLimitValue
    $Deposit = $depositValue
    $Leverage = $leverageValue
    $ExecutionMode = $executionModeValue
    $Currency = [string]$Currency
    $result.inputs.model = $Model
    $result.inputs.deposit = $Deposit
    $result.inputs.currency = $Currency
    $result.inputs.leverage = $Leverage
    $result.inputs.execution_mode = $ExecutionMode
    $result.inputs.timeout_seconds = $TimeoutSeconds
    $result.inputs.max_journal_append_bytes = $MaxJournalAppendBytes

    $expectedExpertHash = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExpertSha256)) {
        if ([string]$ExpectedExpertSha256 -cnotmatch '\A[0-9A-Fa-f]{64}\z') {
            throw 'ExpectedExpertSha256 must contain exactly 64 hexadecimal characters.'
        }
        $expectedExpertHash = ([string]$ExpectedExpertSha256).ToLowerInvariant()
        $result.inputs.expected_expert_sha256 = $expectedExpertHash
    }

    Assert-SafeIniValue -Value $Symbol -Name 'Symbol' -MaximumLength 64
    if ($Symbol -match '[\\/]') {
        throw 'Symbol cannot contain a path separator.'
    }
    Assert-SafeIniValue -Value $Period -Name 'Period' -MaximumLength 16
    if ($Period -cnotmatch '\A[A-Za-z0-9_]+\z') {
        throw 'Period must contain only letters, numbers, or underscores.'
    }

    $from = [datetime]::MinValue
    $to = [datetime]::MinValue
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [datetime]::TryParseExact($FromDate, 'yyyy.MM.dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$from)) {
        throw "FromDate is not a valid date: $FromDate"
    }
    if (-not [datetime]::TryParseExact($ToDate, 'yyyy.MM.dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$to)) {
        throw "ToDate is not a valid date: $ToDate"
    }
    if ($to -le $from) {
        throw 'ToDate must be later than FromDate.'
    }

    $markers = New-Object 'System.Collections.Generic.List[string]'
    foreach ($marker in @($ExpectedLogMarker)) {
        Assert-ExpectedApplicationMarker -Marker $marker -SourceName 'Each ExpectedLogMarker'
        if (-not $markers.Contains($marker)) {
            $markers.Add($marker)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLogMarkerFile)) {
        $markerFile = Resolve-ExistingFile -Path $ExpectedLogMarkerFile -Name 'ExpectedLogMarkerFile' -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
        $markerFileStream = [IO.File]::Open(
            $markerFile,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            if ($markerFileStream.Length -gt 65536) {
                throw 'ExpectedLogMarkerFile cannot exceed 65536 bytes.'
            }
            $markerFileBytes = New-Object byte[] ([int]$markerFileStream.Length)
            $markerFileBytesRead = 0
            while ($markerFileBytesRead -lt $markerFileBytes.Length) {
                $read = $markerFileStream.Read(
                    $markerFileBytes,
                    $markerFileBytesRead,
                    $markerFileBytes.Length - $markerFileBytesRead
                )
                if ($read -le 0) {
                    throw 'ExpectedLogMarkerFile ended before its declared byte length was read.'
                }
                $markerFileBytesRead += $read
            }
        }
        finally {
            $markerFileStream.Dispose()
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $markerFileOffset = 0
        if ($markerFileBytes.Length -ge 3 -and
            $markerFileBytes[0] -eq 0xef -and
            $markerFileBytes[1] -eq 0xbb -and
            $markerFileBytes[2] -eq 0xbf) {
            $markerFileOffset = 3
        }
        $markerFileText = $strictUtf8.GetString(
            $markerFileBytes,
            $markerFileOffset,
            $markerFileBytes.Length - $markerFileOffset
        )
        foreach ($marker in ($markerFileText -split '\r\n|\n|\r')) {
            if ([string]::IsNullOrWhiteSpace($marker)) {
                continue
            }
            Assert-ExpectedApplicationMarker `
                -Marker $marker `
                -SourceName 'Each non-empty ExpectedLogMarkerFile line'
            if (-not $markers.Contains($marker)) {
                $markers.Add($marker)
            }
        }
        if ($markers.Count -eq 0) {
            throw 'ExpectedLogMarkerFile contains no non-empty markers.'
        }
        $result.inputs.expected_log_marker_file = $markerFile
        $result.inputs.expected_log_marker_file_sha256 = Get-BytesSha256 -Bytes $markerFileBytes
    }
    if ($markers.Count -gt 64) {
        throw 'No more than 64 unique expected log markers are allowed.'
    }
    $markerCharacterCount = 0
    foreach ($marker in $markers) {
        $markerCharacterCount += $marker.Length
    }
    if ($markerCharacterCount -gt 8192) {
        throw 'Expected log markers cannot exceed 8192 aggregate characters.'
    }
    $markerHashes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($marker in $markers) {
        $markerHashes.Add((Get-TextSha256 -Text $marker))
    }
    $result.inputs.expected_log_marker_count = $markers.Count
    $result.inputs.expected_log_marker_sha256 = $markerHashes.ToArray()
    if ($markerHashes.Count -gt 0) {
        $aggregateMaterial = "mql5-coding-markers-v1`n" + (@($markerHashes | Sort-Object) -join "`n")
        $result.inputs.expected_log_marker_aggregate_sha256 = Get-TextSha256 -Text $aggregateMaterial
    }

    $expert = Resolve-ExistingFile -Path $ExpertPath -Name 'ExpertPath' -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    if ([IO.Path]::GetExtension($expert) -ine '.ex5') {
        throw "ExpertPath must identify a compiled .ex5 file: $expert"
    }
    if ((Get-Item -LiteralPath $expert).Length -le 0) {
        throw "ExpertPath is empty: $expert"
    }

    $preset = $null
    $presetInfo = $null
    $presetHash = $null
    if (-not [string]::IsNullOrWhiteSpace($SetPath)) {
        $preset = Resolve-ExistingFile -Path $SetPath -Name 'SetPath' -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
        if ([IO.Path]::GetExtension($preset) -ine '.set') {
            throw "SetPath must identify a .set file: $preset"
        }
        $presetInfo = Get-Item -LiteralPath $preset
        $presetHash = Get-FileSha256 -Path $preset
    }

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $OutputDirectory)) {
        throw 'OutputDirectory must be an absolute path.'
    }
    $output = ConvertTo-NormalizedDirectoryPath -Path $OutputDirectory
    $outputParent = Split-Path -Parent $output
    $outputParentLease = Open-NonReparseDirectoryChain `
        -Path $outputParent `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    $null = Open-DirectoryMutationGuard `
        -Path $outputParent `
        -DirectoryLease $outputParentLease `
        -Tracker $directoryMutationGuards `
        -GuardsByPath $guardedDirectories `
        -RunId $runId
    $outputCreation = Open-OrCreateNonReparseDirectory `
        -Path $output `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    if (-not [bool]$outputCreation.created) {
        throw "OutputDirectory must not already exist: $output"
    }
    $outputCreated = $true
    $outputDirectoryLease = $outputCreation.lease
    $outputClaim = Open-NewOutputDirectoryClaim -Path $output -RunId $runId -DirectoryLease $outputDirectoryLease -IntegrityTracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    $resultPath = Join-Path $output 'smoke-result.json'

    $binding = Resolve-TerminalBinding -RequestedTerminalPath $TerminalPath -RequestedDataPath $TerminalDataPath -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    $terminal = [string]$binding.terminal_path
    $data = [string]$binding.terminal_data_path
    $mql5 = Join-Path $data 'MQL5'
    $expertsRoot = Join-Path $mql5 'Experts'
    $profilesRoot = Join-Path $mql5 'Profiles\Tester'
    $terminalLogRoot = Join-Path $data 'logs'
    $testerLogRoot = Join-Path $data 'Tester\logs'
    $terminalPathLease = Open-NonReparseFileLeaf -Path $terminal -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    $mutationGuardDirectories = @(
        $expertsRoot,
        $profilesRoot,
        $terminalLogRoot,
        $testerLogRoot
    )
    foreach ($requiredDirectory in @($data, $mql5) + $mutationGuardDirectories) {
        $requiredDirectoryLease = Open-NonReparseDirectoryChain `
            -Path $requiredDirectory `
            -Tracker $pathEntryLeases `
            -LeasesByPath $leasedPathEntries
        if ($mutationGuardDirectories -icontains $requiredDirectory) {
            $null = Open-DirectoryMutationGuard `
                -Path $requiredDirectory `
                -DirectoryLease $requiredDirectoryLease `
                -Tracker $directoryMutationGuards `
                -GuardsByPath $guardedDirectories `
                -RunId $runId
        }
    }
    $originPathLease = Open-NonReparseFileLeaf -Path (Join-Path $data 'origin.txt') -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries

    $result.binding = [ordered]@{
        terminal_path = $terminal
        terminal_data_path = $data
        output_directory = $output
        terminal_image = $null
        terminal_origin = $null
    }

    $lock = Open-DataDirectoryLock -TerminalDataPath $data -RunId $runId
    $stagingReadLocksReleased = $false
    $terminalImageRecord = Open-TerminalImageReadLock -Path $terminal -Tracker $stagingReadLocks
    if ($terminalImageRecord.file_identity -cne [string]$terminalPathLease.Identity) {
        throw 'Terminal executable identity changed while its path-chain lease was established.'
    }
    $result.binding.terminal_image = [ordered]@{
        path = $terminalImageRecord.destination_path
        byte_length = [long]$terminalImageRecord.byte_length
        sha256 = $terminalImageRecord.sha256
        file_identity = $terminalImageRecord.file_identity
        read_lock_acquired = $true
    }
    $originRecord = Open-TerminalOriginReadLock `
        -TerminalDataPath $data `
        -TerminalPath $terminal `
        -Tracker $stagingReadLocks
    if ($originRecord.file_identity -cne [string]$originPathLease.Identity) {
        throw 'Terminal origin identity changed while its path-chain lease was established.'
    }
    $result.binding.terminal_origin = [ordered]@{
        path = $originRecord.destination_path
        install_path = $originRecord.install_path
        byte_length = [long]$originRecord.byte_length
        sha256 = $originRecord.sha256
        read_lock_acquired = $true
    }
    $conflicts = @(Get-MatchingTerminalProcesses -ExecutablePath $terminal -ExpectedFileIdentity $terminalImageRecord.file_identity)
    if ($conflicts.Count -gt 0) {
        $pids = @($conflicts | ForEach-Object { $_.process_id })
        throw "BLOCKED: The bound MT5 terminal is already running (PID(s) $($pids -join ', ')). Close it before an isolated smoke run; the runner will not stop it."
    }

    $expertHash = Get-FileSha256 -Path $expert
    if ($null -ne $expectedExpertHash -and $expertHash -cne $expectedExpertHash) {
        throw "ExpertPath SHA-256 does not match ExpectedExpertSha256: $expert"
    }
    $expertInfo = Get-Item -LiteralPath $expert
    $expertLeaf = [IO.Path]::GetFileName($expert)
    Assert-SafeIniValue -Value $expertLeaf -Name 'Expert file name' -MaximumLength 128
    $expertStageRoot = Join-Path $expertsRoot 'CodexSmoke'
    $expertStageDirectory = Join-Path $expertStageRoot $runId
    $expertStage = Join-Path $expertStageDirectory $expertLeaf
    $expertRelative = "CodexSmoke\$runId\$expertLeaf"
    Assert-SafeIniValue -Value $expertRelative -Name 'Expert relative path' -MaximumLength 220

    $presetLeaf = $null
    $presetStage = $null
    if ($null -ne $preset) {
        $presetLeaf = "CodexSmoke-$runId.set"
        $presetStage = Join-Path $profilesRoot $presetLeaf
    }

    $configStage = Join-Path $data "CodexSmoke-$runId.ini"
    $reportLeaf = "CodexSmokeReport-$runId.htm"
    $reportStage = Join-Path $data $reportLeaf
    $reportCompanionStages = @(
        foreach ($suffix in @('.png', '-hst.png', '-mfemae.png', '-holding.png')) {
            Join-Path $data ("CodexSmokeReport-$runId$suffix")
        }
    )
    $allMt5StagePaths = @($expertStage, $configStage, $reportStage) + @($reportCompanionStages)
    if ($null -ne $presetStage) {
        $allMt5StagePaths += $presetStage
    }
    foreach ($path in $allMt5StagePaths) {
        if ($path.Length -gt 259) {
            throw "Owned MT5 staging path exceeds 259 characters: $path"
        }
    }

    $configLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @(
            '[Common]',
            'NewsEnable=0',
            'CertInstall=0',
            '',
            '[Experts]',
            'AllowLiveTrading=0',
            'AllowDllImport=0',
            'Enabled=0',
            'Account=0',
            'Profile=0',
            '',
            '[Tester]',
            "Expert=$($expertRelative.Replace('/', '\'))"
        )) {
        $configLines.Add($line)
    }
    if ($null -ne $presetLeaf) {
        $configLines.Add("ExpertParameters=$presetLeaf")
    }
    foreach ($line in @(
            "Symbol=$Symbol",
            "Period=$Period",
            "Model=$Model",
            "ExecutionMode=$ExecutionMode",
            'Optimization=0',
            'OptimizationCriterion=0',
            "FromDate=$FromDate",
            "ToDate=$ToDate",
            'ForwardMode=0',
            "Report=$reportLeaf",
            'ReplaceReport=1',
            'ShutdownTerminal=1',
            ('Deposit=' + $Deposit.ToString([Globalization.CultureInfo]::InvariantCulture)),
            "Currency=$Currency",
            "Leverage=$Leverage",
            'ProfitInPips=0',
            'UseLocal=1',
            'UseRemote=0',
            'UseCloud=0',
            'Visual=0',
            ''
        )) {
        $configLines.Add($line)
    }
    if ($null -eq $presetLeaf) {
        $configLines.Add('[TesterInputs]')
        $configLines.Add('')
    }
    $configContent = ($configLines -join "`r`n")
    $canonicalConfig = Join-Path $output 'tester-start.ini'
    $utf16 = New-Object Text.UnicodeEncoding($false, $true)
    $canonicalConfigRecord = Open-NewTextArtifactReadLock -Text $configContent -Path $canonicalConfig -Encoding $utf16 -Kind 'canonical startup config' -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    $canonicalConfigHash = $canonicalConfigRecord.sha256

    $result.artifacts = [ordered]@{
        output_owner = [ordered]@{
            path = $outputClaim.owner_path
            byte_length = [long]$outputClaim.owner_record.byte_length
            sha256 = $outputClaim.owner_sha256
        }
        expert = [ordered]@{
            source_path = $expert
            relative_tester_path = $expertRelative.Replace('/', '\')
            byte_length = [long]$expertInfo.Length
            sha256 = $expertHash
            staged_copy_required = $true
            staged_copy = $null
            executed_copy = $null
        }
        preset = if ($null -eq $preset) {
            $null
        }
        else {
            [ordered]@{
                source_path = $preset
                byte_length = [long]$presetInfo.Length
                sha256 = $presetHash
                staged_copy = $null
                executed_copy = $null
            }
        }
        canonical_config = [ordered]@{
            path = $canonicalConfig
            byte_length = [long]$canonicalConfigRecord.byte_length
            sha256 = $canonicalConfigHash
            encoding = 'utf-16le-bom'
            newline = 'crlf'
            staged_copy = $null
            executed_copy = $null
        }
        report = $null
        staging_integrity = [ordered]@{
            read_locks_acquired = $false
            prelaunch_verified = $false
            postrun_verified = $null
        }
    }
    $expertStageRootCreation = Open-OrCreateNonReparseDirectory `
        -Path $expertStageRoot `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    if ([bool]$expertStageRootCreation.created) {
        $createdDirectories.Add($expertStageRoot)
    }
    $expertStageRootLease = $expertStageRootCreation.lease
    $null = Open-DirectoryMutationGuard `
        -Path $expertStageRoot `
        -DirectoryLease $expertStageRootLease `
        -Tracker $directoryMutationGuards `
        -GuardsByPath $guardedDirectories `
        -RunId $runId
    $expertStageDirectory = Split-Path -Parent $expertStage
    $expertStageDirectoryCreation = Open-OrCreateNonReparseDirectory `
        -Path $expertStageDirectory `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    if (-not [bool]$expertStageDirectoryCreation.created) {
        throw "Refusing to reuse an existing run staging directory: $expertStageDirectory"
    }
    $createdDirectories.Add($expertStageDirectory)
    $expertStageDirectoryLease = $expertStageDirectoryCreation.lease
    $null = Open-DirectoryMutationGuard `
        -Path $expertStageDirectory `
        -DirectoryLease $expertStageDirectoryLease `
        -Tracker $directoryMutationGuards `
        -GuardsByPath $guardedDirectories `
        -RunId $runId
    $stageRecord = Copy-NewHashBoundFile -Source $expert -Destination $expertStage -Kind 'expert' -Tracker $hashBoundStaging -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    if ($stageRecord.sha256 -cne $expertHash -or [long]$stageRecord.byte_length -ne [long]$expertInfo.Length) {
        throw 'Expert source bytes changed while the hash-bound staging copy was prepared.'
    }
    $result.artifacts.expert.staged_copy = [ordered]@{
        path = $stageRecord.destination_path
        byte_length = [long]$stageRecord.byte_length
        sha256 = $stageRecord.sha256
    }
    if ($Execute) {
        $result.artifacts.expert.executed_copy = $result.artifacts.expert.staged_copy
    }
    if ($null -ne $presetStage) {
        $presetRecord = Copy-NewHashBoundFile -Source $preset -Destination $presetStage -Kind 'preset' -Tracker $hashBoundStaging -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
        if ($presetRecord.sha256 -cne $presetHash -or [long]$presetRecord.byte_length -ne [long]$presetInfo.Length) {
            throw 'Preset source bytes changed while the hash-bound staging copy was prepared.'
        }
        $result.artifacts.preset.staged_copy = [ordered]@{
            path = $presetRecord.destination_path
            byte_length = [long]$presetRecord.byte_length
            sha256 = $presetRecord.sha256
        }
        if ($Execute) {
            $result.artifacts.preset.executed_copy = $result.artifacts.preset.staged_copy
        }
    }
    $configRecord = Copy-NewHashBoundFile -Source $canonicalConfig -Destination $configStage -Kind 'startup config' -Tracker $hashBoundStaging -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    if ($configRecord.sha256 -cne $canonicalConfigHash -or [long]$configRecord.byte_length -ne [long]$canonicalConfigRecord.byte_length) {
        throw 'Canonical startup config bytes changed while the staging copy was prepared.'
    }
    $result.artifacts.canonical_config.staged_copy = [ordered]@{
        path = $configRecord.destination_path
        byte_length = [long]$configRecord.byte_length
        sha256 = $configRecord.sha256
    }
    if ($Execute) {
        $result.artifacts.canonical_config.executed_copy = $result.artifacts.canonical_config.staged_copy
    }

    foreach ($generatedPath in @($reportStage) + @($reportCompanionStages)) {
        if ([bool]$Execute) {
            $null = Open-NewMutableOutputFileReservation `
                -Path $generatedPath `
                -Tracker $pathEntryLeases `
                -LeasesByPath $leasedPathEntries
            $generatedOwnedPaths.Add($generatedPath)
        }
        else {
            $existingGeneratedLease = Try-OpenNonReparseFileLeaf `
                -Path $generatedPath `
                -Tracker $pathEntryLeases `
                -LeasesByPath $leasedPathEntries
            if ($null -ne $existingGeneratedLease) {
                throw "Refusing to reuse an existing generated report path: $generatedPath"
            }
        }
    }

    $stagingReadLocksReleased = $false
    $integrityRecordsToLock = @($hashBoundStaging.ToArray())
    Open-StagingReadLocks -Records $integrityRecordsToLock -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    $stagingReadLockAcquisitionCompleted = $true
    $result.artifacts.staging_integrity.read_locks_acquired = $true
    $prelaunchIntegrityFailures = @(Get-PinnedStagingIntegrityFailures -Locks $stagingReadLocks)
    if ($prelaunchIntegrityFailures.Count -gt 0) {
        throw "Staged input integrity failed before launch: $($prelaunchIntegrityFailures -join ' ')"
    }
    $result.artifacts.staging_integrity.prelaunch_verified = $true

    $beforeTerminal = Get-JournalSnapshot -RootPath $terminalLogRoot -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams
    $beforeTester = Get-JournalSnapshot -RootPath $testerLogRoot -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams

    if ($PreflightOnly) {
        $preflightFinalConflicts = @(Get-MatchingTerminalProcesses -ExecutablePath $terminal -ExpectedFileIdentity $terminalImageRecord.file_identity)
        if ($preflightFinalConflicts.Count -gt 0) {
            $pids = @($preflightFinalConflicts | ForEach-Object { $_.process_id })
            throw "BLOCKED: The bound MT5 terminal started during preflight (PID(s) $($pids -join ', ')); preflight readiness is no longer valid."
        }
        $result.status = 'preflight_passed'
        $warnings.Add('PreflightOnly was used: staging paths, bytes, journal readability, and process-isolation preconditions were verified at the final check, but no MT5 process was started by the runner and no Strategy Tester behavior was validated.')
        $exitCode = 0
    }
    else {
        $conflicts = @(Get-MatchingTerminalProcesses -ExecutablePath $terminal -ExpectedFileIdentity $terminalImageRecord.file_identity)
        if ($conflicts.Count -gt 0) {
            $pids = @($conflicts | ForEach-Object { $_.process_id })
            throw "BLOCKED: The bound MT5 terminal started during preflight (PID(s) $($pids -join ', ')); refusing to continue."
        }

        $result.process.execution_attempted = $true
        $jobLaunch = [Mql5Coding.JobProcessLaunch]::CreateSuspended(
            $terminal,
            $configStage,
            (Split-Path -Parent $terminal)
        )
        $ownedProcessTreeTerminationVerified = $false
        $result.process.process_created = $true
        $result.process.process_id = [int]$jobLaunch.ProcessId
        $result.process.job_containment_established = $true
        $process = [Diagnostics.Process]::GetProcessById([int]$jobLaunch.ProcessId)
        $spawnedImagePath = [IO.Path]::GetFullPath($jobLaunch.GetImagePath())
        $spawnedImageFileIdentity = Get-FileIdentityFromPath -Path $spawnedImagePath
        if ($spawnedImageFileIdentity -cne [string]$terminalImageRecord.file_identity) {
            throw (
                "BLOCKED: Suspended PID $($process.Id) did not map to the pinned " +
                'terminal executable file identity.'
            )
        }
        $spawnedProcessIdentity = Get-SpawnedProcessIdentity `
            -Process $process `
            -ExecutablePath $spawnedImagePath `
            -ExecutableFileIdentity $spawnedImageFileIdentity

        $postStartMatches = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath $terminal `
                -ExpectedFileIdentity $terminalImageRecord.file_identity `
                -TrustedSuspendedIdentity $spawnedProcessIdentity
        )
        $ownedMatches = @($postStartMatches | Where-Object { [int]$_.process_id -eq [int]$process.Id })
        if ($postStartMatches.Count -ne 1 -or $ownedMatches.Count -ne 1) {
            $observed = @($postStartMatches | ForEach-Object { $_.process_id })
            throw "BLOCKED: Suspended terminal identity was not exactly the owned PID $($process.Id); observed PID(s): $($observed -join ', ')."
        }
        if (
            $null -eq $ownedMatches[0].creation_utc_ticks -or
            $null -eq $ownedMatches[0].session_id
        ) {
            throw "BLOCKED: Creation time or session was unavailable for the owned suspended terminal PID $($process.Id)."
        }
        $result.process.post_start_identity_verified = $true
        $result.process.identity_source = 'pinned_file_identity_and_suspended_cim_cross_check'

        $jobLaunch.Resume()
        $result.process.resumed = $true

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            $result.process.timed_out = $true
            $ownedProcessTreeTerminationVerified = $false
            $jobLaunch.TerminateAndWaitForEmpty(5000)
            $ownedProcessTreeTerminationVerified = $true
        }
        else {
            $result.process.exit_code = [int]$process.ExitCode
            $ownedProcessTreeTerminationVerified = $false
            $jobLaunch.TerminateAndWaitForEmpty(5000)
            $ownedProcessTreeTerminationVerified = $true
        }
        $result.process.job_empty_verified = $true
        $result.process.post_exit_no_potential_descendants = $true
        if ($process.HasExited) {
            $result.process.exit_code = [int]$process.ExitCode
        }

        # Win32_Process can briefly retain a terminated row after the owned Job Object is empty.
        # Retry only at this post-containment boundary; prelaunch isolation checks remain immediate.
        $postExitMatches = @(
            Wait-ForNoMatchingTerminalProcesses `
                -ExecutablePath $terminal `
                -ExpectedFileIdentity $terminalImageRecord.file_identity `
                -VerifiedOwnedProcessIdentity $ownedMatches[0] `
                -TimeoutMilliseconds 5000 `
                -PollMilliseconds 100
        )
        if ($postExitMatches.Count -gt 0) {
            $remaining = @($postExitMatches | ForEach-Object { $_.process_id })
            throw "BLOCKED: Bound terminal PID(s) $($remaining -join ', ') remained after the owned process ended. The runner will not stop them."
        }
        $result.process.post_exit_no_matching_terminal = $true

        $postrunIntegrityFailures = @(Get-PinnedStagingIntegrityFailures -Locks $stagingReadLocks)
        $postrunIntegrityValid = $postrunIntegrityFailures.Count -eq 0
        $result.artifacts.staging_integrity.postrun_verified = $postrunIntegrityValid
        foreach ($failure in $postrunIntegrityFailures) {
            $errors.Add($failure)
        }

        $terminalDelta = Read-JournalDelta -Before $beforeTerminal -RootPath $terminalLogRoot -LogicalName 'terminal' -MaximumBytes $MaxJournalAppendBytes -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams
        $testerDelta = Read-JournalDelta -Before $beforeTester -RootPath $testerLogRoot -LogicalName 'tester' -MaximumBytes $MaxJournalAppendBytes -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams

        $terminalText = [string]$terminalDelta.text
        $testerText = [string]$testerDelta.text
        $configLaunchNeedle = "successfully initialized from start config `"$configStage`""
        $configIndex = Get-TextIndex -Text $terminalText -Needle $configLaunchNeedle
        $genericConfigLaunchNeedle = 'successfully initialized from start config'
        $nextConfigIndex = if ($configIndex -ge 0) {
            Get-TextIndex `
                -Text $terminalText `
                -Needle $genericConfigLaunchNeedle `
                -StartIndex ($configIndex + $configLaunchNeedle.Length)
        }
        else {
            -1
        }
        $terminalWindowEnd = if ($nextConfigIndex -ge 0) {
            $nextConfigIndex
        }
        else {
            $terminalText.Length
        }
        $automaticStartedIndex = if ($configIndex -ge 0) {
            $foundAutomaticStart = Get-TextIndex `
                -Text $terminalText `
                -Needle 'automatic testing started' `
                -StartIndex ($configIndex + $configLaunchNeedle.Length)
            if ($foundAutomaticStart -ge 0 -and $foundAutomaticStart -lt $terminalWindowEnd) {
                $foundAutomaticStart
            }
            else {
                -1
            }
        }
        else {
            -1
        }
        $terminalSuccessNeedle = 'last test passed with result "successfully finished"'
        $terminalSucceededIndex = if ($automaticStartedIndex -ge 0) {
            $foundTerminalSuccess = Get-TextIndex `
                -Text $terminalText `
                -Needle $terminalSuccessNeedle `
                -StartIndex ($automaticStartedIndex + 'automatic testing started'.Length)
            if ($foundTerminalSuccess -ge 0 -and $foundTerminalSuccess -lt $terminalWindowEnd) {
                $foundTerminalSuccess
            }
            else {
                -1
            }
        }
        else {
            -1
        }
        $configCorrelated = $configIndex -ge 0
        $automaticStarted = $automaticStartedIndex -ge 0
        $terminalSucceeded = $terminalSucceededIndex -ge 0
        $terminalSequenceOrdered = (
            $configIndex -ge 0 -and
            $automaticStartedIndex -gt $configIndex -and
            $terminalSucceededIndex -gt $automaticStartedIndex
        )
        # The installed CHM does not define journal syntax. Accept only the
        # sample-backed system layouts below and fail closed on unknown layouts.
        $testerSystemHeaderPattern = (
            '(?:' +
                '(?:\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tTester\t)' +
                '|(?:[A-Z]{2}\t\d+\t\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
                '|(?:\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
            ')'
        )
        $testerApplicationHeaderPattern = (
            '(?:' +
                '(?:\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\t' +
                    '(?![Tt][Ee][Ss][Tt][Ee][Rr]\t)[^\r\n\t]+\t)' +
                '|(?:[A-Z]{2}\t\d+\t\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
                '|(?:\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
            ')'
        )
        $simulatedTimePattern = (
            '\d{4}\.\d{2}\.\d{2} ' +
            '\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?[ ]+'
        )
        $testerApplicationLinePrefix = (
            '(?m)^' +
            $testerApplicationHeaderPattern +
            '[ ]*' +
            $simulatedTimePattern
        )
        $testerSystemMessagePrefix = (
            '(?m)^' +
            $testerSystemHeaderPattern +
            '(?![ ]*' + $simulatedTimePattern + ')' +
            '[ ]*'
        )

        $testStartNeedle = (
            $Symbol + ',' + $Period + ': testing of Experts\' +
            $expertRelative.Replace('/', '\') +
            ' from ' + $FromDate + ' 00:00 to ' + $ToDate + ' 00:00'
        )
        $testStartRecord = $testStartNeedle + ' started with inputs:'
        $testStartPattern = (
            $testerSystemMessagePrefix +
            [regex]::Escape($testStartRecord) +
            '[ ]*\r?$'
        )
        $testStartRegex = New-Object Text.RegularExpressions.Regex(
            $testStartPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $testPassedPattern = (
            $testerSystemMessagePrefix +
            [regex]::Escape("$Symbol,$Period") +
            ':[^\r\n]*Test passed in \d+:\d{2}:\d{2}(?:\.\d+)?[^\r\n]*\r?$'
        )
        $testPassedRegex = New-Object Text.RegularExpressions.Regex(
            $testPassedPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $testerInitializedNeedle = 'successfully initialized'
        $testerInitializedPattern = (
            $testerSystemMessagePrefix +
            '(?![^=\r\n]+=[^\r\n]*' +
                [regex]::Escape($testerInitializedNeedle) + ')' +
            '[^\r\n]*' + [regex]::Escape($testerInitializedNeedle) +
            '[^\r\n]*\r?$'
        )
        $testerInitializedRegex = New-Object Text.RegularExpressions.Regex(
            $testerInitializedPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $genericTestStartSignal = 'testing of Experts\'
        $genericTestStartPattern = (
            $testerSystemMessagePrefix +
            '(?![^=\r\n]+=[^\r\n]*' +
                [regex]::Escape($genericTestStartSignal) + ')' +
            '[^,\r\n]+,[^:\r\n]+:[ ]*testing of Experts\\[^\r\n]+ ' +
            'from \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} ' +
            'to \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} ' +
            'started with inputs:[ ]*\r?$'
        )
        $genericTestStartRegex = New-Object Text.RegularExpressions.Regex(
            $genericTestStartPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $onInitFailureNeedle = 'tester stopped because OnInit returns non-zero'
        $onInitFailurePattern = (
            $testerSystemMessagePrefix +
            '(?![^=\r\n]+=[^\r\n]*' +
                [regex]::Escape($onInitFailureNeedle) + ')' +
            '[^\r\n]*' + [regex]::Escape($onInitFailureNeedle) +
            '[^\r\n]*\r?$'
        )
        $onInitFailureRegex = New-Object Text.RegularExpressions.Regex(
            $onInitFailurePattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $testerInitializedMatches = $testerInitializedRegex.Matches($testerText)
        $genericTestStartMatches = $genericTestStartRegex.Matches($testerText)
        $testCandidates = New-Object 'System.Collections.Generic.List[object]'
        $candidateSearchIndex = 0
        while ($candidateSearchIndex -lt $testerText.Length) {
            $candidateStartMatch = $testStartRegex.Match($testerText, $candidateSearchIndex)
            if (-not $candidateStartMatch.Success) {
                break
            }
            $candidateStart = [int]$candidateStartMatch.Index
            $candidateEnd = $candidateStart + [int]$candidateStartMatch.Length
            $previousGenericStart = -1
            foreach ($genericStartMatch in $genericTestStartMatches) {
                if ([int]$genericStartMatch.Index -ge $candidateStart) {
                    break
                }
                $previousGenericStart = [int]$genericStartMatch.Index
            }
            $candidateInitialized = -1
            foreach ($initializedMatch in $testerInitializedMatches) {
                if ([int]$initializedMatch.Index -ge $candidateStart) {
                    break
                }
                $candidateInitialized = [int]$initializedMatch.Index
            }
            $initializationInWindow = (
                $candidateInitialized -ge 0 -and
                ($previousGenericStart -lt 0 -or $candidateInitialized -gt $previousGenericStart)
            )
            $nextGenericStart = -1
            foreach ($genericStartMatch in $genericTestStartMatches) {
                if ([int]$genericStartMatch.Index -ge $candidateEnd) {
                    $nextGenericStart = [int]$genericStartMatch.Index
                    break
                }
            }
            $candidateWindowEnd = if ($nextGenericStart -ge 0) {
                $nextGenericStart
            }
            else {
                $testerText.Length
            }
            $candidatePassMatch = $testPassedRegex.Match($testerText, $candidateEnd)
            $candidatePassIndex = if (
                $candidatePassMatch.Success -and
                [int]$candidatePassMatch.Index -lt $candidateWindowEnd
            ) {
                [int]$candidatePassMatch.Index
            }
            else {
                -1
            }
            $candidateOnInitMatch = $onInitFailureRegex.Match($testerText, $candidateEnd)
            $candidateOnInitFailure = if ($candidateOnInitMatch.Success) {
                [int]$candidateOnInitMatch.Index
            }
            else {
                -1
            }
            $onInitFailureInWindow = (
                $candidateOnInitFailure -ge 0 -and
                $candidateOnInitFailure -lt $candidateWindowEnd
            )
            $candidateMarkerIndices = New-Object 'System.Collections.Generic.List[int]'
            $allCandidateMarkersMatched = $true
            foreach ($candidateMarker in $markers) {
                $candidateMarkerPattern = (
                    $testerApplicationLinePrefix +
                    [regex]::Escape($candidateMarker) +
                    '[ ]*\r?$'
                )
                $candidateMarkerRegex = New-Object Text.RegularExpressions.Regex(
                    $candidateMarkerPattern,
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant
                )
                $candidateMarkerMatch = $candidateMarkerRegex.Match(
                    $testerText,
                    $candidateEnd
                )
                $candidateMarkerIndex = if ($candidateMarkerMatch.Success) {
                    [int]$candidateMarkerMatch.Index
                }
                else {
                    -1
                }
                $candidateMarkerEnd = if ($candidateMarkerMatch.Success) {
                    [int]$candidateMarkerMatch.Index + [int]$candidateMarkerMatch.Length
                }
                else {
                    -1
                }
                $candidateMarkerMatched = (
                    $candidateMarkerIndex -ge 0 -and
                    $candidateMarkerEnd -le $candidatePassIndex -and
                    $candidateMarkerEnd -le $candidateWindowEnd
                )
                if (-not $candidateMarkerMatched) {
                    $allCandidateMarkersMatched = $false
                    $candidateMarkerIndices.Add(-1)
                }
                else {
                    $candidateMarkerIndices.Add([int]$candidateMarkerIndex)
                }
            }
            $sequenceValid = (
                $initializationInWindow -and
                $candidatePassIndex -gt $candidateStart
            )
            $testCandidates.Add([pscustomobject][ordered]@{
                start_index = [int]$candidateStart
                end_index = [int]$candidateEnd
                window_end_index = [int]$candidateWindowEnd
                initialized_index = [int]$candidateInitialized
                pass_index = [int]$candidatePassIndex
                on_init_failed = [bool]$onInitFailureInWindow
                sequence_valid = [bool]$sequenceValid
                core_valid = [bool]($sequenceValid -and -not $onInitFailureInWindow)
                all_markers_matched = [bool]$allCandidateMarkersMatched
                marker_indices = $candidateMarkerIndices.ToArray()
            })
            $candidateSearchIndex = $candidateStart + 1
        }

        $selectedCandidate = if ($testCandidates.Count -eq 1) {
            $testCandidates[0]
        }
        else {
            $null
        }

        $expertCorrelated = $testCandidates.Count -eq 1
        $initializedIndex = if ($null -ne $selectedCandidate) {
            [int]$selectedCandidate.initialized_index
        }
        else {
            -1
        }
        $testStartIndex = if ($null -ne $selectedCandidate) {
            [int]$selectedCandidate.start_index
        }
        else {
            -1
        }
        $testPassedIndex = if ($null -ne $selectedCandidate) {
            [int]$selectedCandidate.pass_index
        }
        else {
            -1
        }
        $initialized = $initializedIndex -ge 0
        $testPassed = $testPassedIndex -ge 0
        $testerSequenceOrdered = (
            $null -ne $selectedCandidate -and
            [bool]$selectedCandidate.sequence_valid
        )
        $onInitFailed = if ($null -ne $selectedCandidate) {
            [bool]$selectedCandidate.on_init_failed
        }
        else {
            $onInitFailureRegex.IsMatch($testerText)
        }

        $markerEvidence = New-Object 'System.Collections.Generic.List[object]'
        $missingMarkerHashes = New-Object 'System.Collections.Generic.List[string]'
        for ($markerIndex = 0; $markerIndex -lt $markers.Count; $markerIndex++) {
            $markerHash = $markerHashes[$markerIndex]
            $markerMatched = (
                $null -ne $selectedCandidate -and
                $markerIndex -lt @($selectedCandidate.marker_indices).Count -and
                [int]$selectedCandidate.marker_indices[$markerIndex] -ge 0
            )
            $markerEvidence.Add([pscustomobject][ordered]@{
                sha256 = $markerHash
                matched = $markerMatched
            })
            if (-not $markerMatched) {
                $missingMarkerHashes.Add($markerHash)
            }
        }

        $terminalEvidence = Select-JournalEvidence -Text $terminalText -Patterns @(
            'successfully initialized from start config',
            'Terminal\s+launched with',
            'automatic testing started',
            'last test passed with result',
            'Terminal\s+exit with code'
        ) -SensitiveValues $markers.ToArray()
        $testerEvidence = Select-JournalEvidence -Text $testerText -Patterns @(
            'testing of Experts\\',
            'successfully initialized',
            'Test passed in ',
            'OnInit returns non-zero',
            '(?i)\b(error|failed|cannot load|stopped because)\b'
        ) -SensitiveValues $markers.ToArray()

        $result.evidence = [ordered]@{
            terminal_journal = [ordered]@{
                appended_byte_length = [long]$terminalDelta.appended_byte_length
                limit_exceeded = [bool]$terminalDelta.limit_exceeded
                segments = @($terminalDelta.records)
                excerpts = $terminalEvidence
            }
            tester_journal = [ordered]@{
                appended_byte_length = [long]$testerDelta.appended_byte_length
                limit_exceeded = [bool]$testerDelta.limit_exceeded
                segments = @($testerDelta.records)
                excerpts = $testerEvidence
            }
            expected_markers = [ordered]@{
                aggregate_sha256 = $result.inputs.expected_log_marker_aggregate_sha256
                entries = $markerEvidence.ToArray()
                missing_sha256 = $missingMarkerHashes.ToArray()
            }
            checks = [ordered]@{
                exact_config_launch = $configCorrelated
                automatic_testing_started = $automaticStarted
                terminal_evidence_ordered = $terminalSequenceOrdered
                exact_expert_symbol_period_dates = $expertCorrelated
                exact_test_candidate_count = $testCandidates.Count
                exact_test_window_selected = ($null -ne $selectedCandidate)
                tester_initialized = $initialized
                tester_engine_passed = $testPassed
                tester_evidence_ordered = $testerSequenceOrdered
                terminal_result_successfully_finished = $terminalSucceeded
                on_init_failure_absent = (-not $onInitFailed)
                expected_markers_supplied = ($markers.Count -gt 0)
                expected_markers_matched = ($markers.Count -gt 0 -and $missingMarkerHashes.Count -eq 0)
                missing_marker_count = $missingMarkerHashes.Count
                staged_inputs_unchanged = $postrunIntegrityValid
            }
        }

        $reportStageLease = Try-OpenNonReparseFileLeaf -Path $reportStage -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
        if ($null -ne $reportStageLease) {
            $reportSourceRecord = Open-VerifiedArtifactReadLock -Path $reportStage -Kind 'generated report source' -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
            if ([long]$reportSourceRecord.byte_length -gt 0) {
                $finalReport = Join-Path $output $reportLeaf
                $finalReportRecord = Copy-NewVerifiedOutputArtifact `
                    -Source $reportStage `
                    -Destination $finalReport `
                    -Kind 'output report' `
                    -SourceLease $reportStageLease `
                    -Tracker $stagingReadLocks
                $reportCompanions = New-Object 'System.Collections.Generic.List[object]'
                foreach ($companionStage in $reportCompanionStages) {
                    $companionStageLease = Try-OpenNonReparseFileLeaf -Path $companionStage -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
                    if ($null -eq $companionStageLease) {
                        continue
                    }
                    $companionSourceRecord = Open-VerifiedArtifactReadLock -Path $companionStage -Kind 'generated report companion source' -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
                    if ([long]$companionSourceRecord.byte_length -le 0) {
                        continue
                    }
                    $companionFinal = Join-Path $output ([IO.Path]::GetFileName($companionStage))
                    $companionRecord = Copy-NewVerifiedOutputArtifact `
                        -Source $companionStage `
                        -Destination $companionFinal `
                        -Kind 'output report companion' `
                        -SourceLease $companionStageLease `
                        -Tracker $stagingReadLocks
                    $reportCompanions.Add([pscustomobject][ordered]@{
                        path = $companionFinal
                        byte_length = [long]$companionRecord.byte_length
                        sha256 = $companionRecord.sha256
                    })
                }
                $result.artifacts.report = [ordered]@{
                    path = $finalReport
                    byte_length = [long]$finalReportRecord.byte_length
                    sha256 = $finalReportRecord.sha256
                    companions = $reportCompanions.ToArray()
                    required_for_pass = $false
                }
            }
            else {
                $warnings.Add('MT5 created an empty report; journal evidence remains authoritative for this smoke result.')
            }
        }
        else {
            $warnings.Add('MT5 did not create a report; report existence is optional and was not used as a pass condition.')
        }

        $journalLimitExceeded = [bool]$terminalDelta.limit_exceeded -or [bool]$testerDelta.limit_exceeded
        if ([bool]$terminalDelta.limit_exceeded) {
            $errors.Add("Terminal journal append exceeded the $MaxJournalAppendBytes-byte inspection limit.")
        }
        if ([bool]$testerDelta.limit_exceeded) {
            $errors.Add("Tester journal append exceeded the $MaxJournalAppendBytes-byte inspection limit.")
        }
        if ([bool]$result.process.timed_out) {
            $errors.Add("Strategy Tester exceeded the $TimeoutSeconds-second timeout.")
        }

        if (-not $postrunIntegrityValid -or $journalLimitExceeded) {
            $result.status = 'tooling_error'
            $exitCode = 2
        }
        elseif ([bool]$result.process.timed_out) {
            $result.status = 'timed_out'
            $exitCode = 3
        }
        else {
            if ($null -eq $result.process.exit_code -or [int]$result.process.exit_code -ne 0) {
                $errors.Add("Spawned MT5 process did not exit cleanly (exit code $($result.process.exit_code)).")
            }
            if (-not $configCorrelated) {
                $errors.Add('Terminal journal did not correlate the exact staged startup config.')
            }
            if (-not $automaticStarted) {
                $errors.Add('Terminal journal did not show automatic testing started.')
            }
            if (-not $terminalSequenceOrdered) {
                $errors.Add('Terminal journal did not show staged-config initialization, automatic test start, and successful finish in that order.')
            }
            if ($testCandidates.Count -gt 1) {
                $errors.Add(
                    "Tester journal contained $($testCandidates.Count) exact test candidates; evidence is ambiguous."
                )
            }
            elseif (-not $expertCorrelated) {
                $errors.Add('Tester journal did not correlate the exact expert, symbol, period, and dates.')
            }
            if (-not $initialized) {
                $errors.Add('Tester journal did not show successful agent initialization.')
            }
            if (-not $testPassed) {
                $errors.Add('Tester journal did not show a correlated engine Test passed result.')
            }
            if (-not $testerSequenceOrdered) {
                $errors.Add('Tester journal did not show initialization, the exact test start, and the correlated engine pass in that order.')
            }
            if (-not $terminalSucceeded) {
                $errors.Add('Terminal journal result was not exactly "successfully finished".')
            }
            if ($onInitFailed) {
                $errors.Add('Tester stopped because OnInit returned a non-zero code.')
            }
            if ($missingMarkerHashes.Count -gt 0) {
                $errors.Add("$($missingMarkerHashes.Count) caller-supplied expected log marker(s) were not found.")
            }

            if ($errors.Count -eq 0) {
                if ($markers.Count -gt 0) {
                    $result.status = 'application_marker_passed'
                }
                else {
                    $result.status = 'engine_smoke_passed'
                    $warnings.Add('No expected application marker was supplied. This proves only correlated Strategy Tester engine completion, not strategy correctness or full-date execution.')
                }
                $exitCode = 0
            }
            else {
                $result.status = 'tester_failed'
                $exitCode = 1
            }
        }
    }
}
catch {
    $launchFailure = $_.Exception
    while ($null -ne $launchFailure) {
        if ($launchFailure.Data.Contains('Mql5Coding.ProcessCreated')) {
            $result.process.process_created = [bool]$launchFailure.Data['Mql5Coding.ProcessCreated']
            $result.process.process_id = [int]$launchFailure.Data['Mql5Coding.ProcessId']
            $suspendedTerminationConfirmed = [bool]$launchFailure.Data['Mql5Coding.SuspendedTerminationConfirmed']
            $result.process.suspended_launch_cleanup = [ordered]@{
                termination_confirmed = $suspendedTerminationConfirmed
                terminate_process_succeeded = [bool]$launchFailure.Data['Mql5Coding.TerminateProcessSucceeded']
                terminate_process_error = [int]$launchFailure.Data['Mql5Coding.TerminateProcessError']
                wait_result = [long]$launchFailure.Data['Mql5Coding.WaitResult']
                wait_error = [int]$launchFailure.Data['Mql5Coding.WaitError']
            }
            $ownedProcessTreeTerminationVerified = $suspendedTerminationConfirmed
            if (-not $suspendedTerminationConfirmed) {
                $unsafePostLaunchIsolation = $true
            }
            break
        }
        $launchFailure = $launchFailure.InnerException
    }

    $message = $_.Exception.Message
    $isBlockedMessage = $message.StartsWith('BLOCKED:', [StringComparison]::Ordinal)
    if ($isBlockedMessage -and -not [bool]$result.process.execution_attempted) {
        $result.status = 'blocked'
        $errors.Add($message.Substring('BLOCKED:'.Length).Trim())
        $exitCode = 4
    }
    else {
        $result.status = 'tooling_error'
        if ($isBlockedMessage) {
            $unsafePostLaunchIsolation = $true
            $errors.Add(
                'Post-launch isolation failure: ' +
                $message.Substring('BLOCKED:'.Length).Trim()
            )
        }
        else {
            $errors.Add($message)
        }
        $exitCode = 2
    }
}
finally {
    if ($null -ne $jobLaunch) {
        try {
            if (-not $ownedProcessTreeTerminationVerified) {
                $jobLaunch.TerminateAndWaitForEmpty(5000)
                $ownedProcessTreeTerminationVerified = $true
                $result.process.job_empty_verified = $true
                $result.process.post_exit_no_potential_descendants = $true
            }
        }
        catch {
            $ownedProcessTreeTerminationVerified = $false
            $cleanupErrors.Add("Could not empty the owned Windows Job Object: $($_.Exception.Message)")
        }
    }

    if ($null -ne $process) {
        try {
            $process.Dispose()
        }
        catch {
            $cleanupErrors.Add("Could not dispose the terminal process handle: $($_.Exception.Message)")
        }
    }
    if ($null -ne $jobLaunch) {
        try {
            $jobLaunch.Dispose()
        }
        catch {
            $cleanupErrors.Add("Could not dispose the Windows Job Object handles: $($_.Exception.Message)")
        }
    }

    if ($stagingReadLocks.Count -gt 0) {
        if ([bool]$Execute) {
            $finalIntegrityFailures = @(Get-PinnedStagingIntegrityFailures -Locks $stagingReadLocks)
            if ($finalIntegrityFailures.Count -gt 0) {
                if ($null -ne $result.artifacts -and
                    $null -ne $result.artifacts.PSObject.Properties['staging_integrity']) {
                    $result.artifacts.staging_integrity.postrun_verified = $false
                }
                foreach ($failure in $finalIntegrityFailures) {
                    $cleanupErrors.Add("Final artifact integrity verification failed: $failure")
                }
            }
        }
        $lockReleaseFailed = $false
        for ($index = $stagingReadLocks.Count - 1; $index -ge 0; $index--) {
            try {
                $stagingReadLocks[$index].stream.Dispose()
            }
            catch {
                $lockReleaseFailed = $true
                $cleanupErrors.Add(
                    "Could not release the $($stagingReadLocks[$index].record.kind) integrity read lock: $($_.Exception.Message)"
                )
            }
        }
        $stagingReadLocksReleased = $stagingReadLockAcquisitionCompleted -and -not $lockReleaseFailed
    }

    for ($index = $journalReadStreams.Count - 1; $index -ge 0; $index--) {
        try {
            $journalReadStreams[$index].Dispose()
        }
        catch {
            $cleanupErrors.Add(
                "Could not release a pinned journal read stream: $($_.Exception.Message)"
            )
        }
    }


    $stagingArtifactsExist = (
        $hashBoundStaging.Count -gt 0 -or
        $generatedOwnedPaths.Count -gt 0 -or
        $createdDirectories.Count -gt 0
    )
    $executionStagingPreservationRequired = [bool]$Execute -and $stagingArtifactsExist
    $preflightStagingPreservationRequired = [bool]$PreflightOnly -and $stagingArtifactsExist
    $result.cleanup.execution_staging_preserved = $executionStagingPreservationRequired
    $result.cleanup.preflight_staging_preserved = $preflightStagingPreservationRequired
    $conservativeExecutionPreservation = (
        $executionStagingPreservationRequired -and
        $ownedProcessTreeTerminationVerified -and
        $stagingReadLocksReleased -and
        -not $unsafePostLaunchIsolation
    )
    $conservativePreflightPreservation = (
        $preflightStagingPreservationRequired -and
        $stagingReadLocksReleased -and
        -not [bool]$result.process.execution_attempted
    )
    $preservationReason = if ($conservativeExecutionPreservation) {
        'execution staging is retained because automatic pathname deletion is disabled'
    }
    elseif ($conservativePreflightPreservation) {
        'preflight staging is retained because automatic pathname deletion is disabled'
    }
    else {
        'process isolation or staging-lock release was not verified'
    }
    foreach ($record in $hashBoundStaging) {
        $path = [string]$record.destination_path
        $cleanupPreserved.Add("$($record.kind): $preservationReason; preserved: $path")
    }
    foreach ($path in $generatedOwnedPaths) {
        try {
            $generatedLease = Try-OpenNonReparseFileLeaf `
                -Path $path `
                -Tracker $pathEntryLeases `
                -LeasesByPath $leasedPathEntries
            if ($null -ne $generatedLease) {
                $cleanupPreserved.Add("generated report artifact: $preservationReason; preserved: $path")
            }
        }
        catch {
            $cleanupErrors.Add("Could not safely inspect generated report artifact '$path': $($_.Exception.Message)")
        }
    }
    foreach ($directory in $createdDirectories) {
        $cleanupPreserved.Add("staging directory: $preservationReason; preserved: $directory")
    }
    if ($stagingArtifactsExist -and ($conservativeExecutionPreservation -or $conservativePreflightPreservation)) {
        $warnings.Add(
            'Staging was preserved because automatic deletion by pathname is disabled to avoid deleting a replaced file. Remove the recorded unique paths only after independently verifying their identities and that no related process remains.'
        )
    }
    elseif ($stagingArtifactsExist) {
        $cleanupErrors.Add('Staging was preserved because process isolation or staging-lock release could not be verified.')
    }

    if ($null -ne $lock) {
        try {
            $lock.stream.Dispose()
        }
        catch {
            $cleanupErrors.Add("Could not release the terminal data lock: $($_.Exception.Message)")
        }
    }


    if ($cleanupErrors.Count -gt 0) {
        if ($result.status -ne 'tooling_error') {
            $result.primary_status_before_cleanup = $result.status
        }
        $result.status = 'tooling_error'
        $errors.Add('Owned staging cleanup failed; inspect cleanup.errors. Any primary outcome is recorded in primary_status_before_cleanup.')
        $exitCode = 2
    }

    $endedUtc = [datetimeoffset]::UtcNow
    $result.ended_utc = $endedUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'")
    $result.duration_milliseconds = [long]($endedUtc - $startedUtc).TotalMilliseconds

    if ($outputCreated -and $null -ne $resultPath) {
        try {
            Assert-StableFixedLocalVolumePath -Path $output
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $output,
                $outputDirectoryLease
            )
            $outputDirectoryLease.VerifyStillNonReparseDirectory()
            Write-JsonFile -Value $result -Path $resultPath
            $resultWritten = $true
        }
        catch {
            [Console]::Error.WriteLine(
                (Protect-JournalLine -Line "Could not write smoke result '$resultPath': $($_.Exception.Message)")
            )
            $exitCode = 2
        }
    }
    elseif ($errors.Count -gt 0) {
        [Console]::Error.WriteLine(
            (Protect-JournalLine -Line "MQL5 tester smoke $($result.status): $($errors[$errors.Count - 1])")
        )
    }

    $postResultReleaseErrors = New-Object 'System.Collections.Generic.List[string]'
    for ($index = $directoryMutationGuards.Count - 1; $index -ge 0; $index--) {
        try {
            $directoryMutationGuards[$index].stream.Dispose()
        }
        catch {
            $postResultReleaseErrors.Add(
                "Could not release the directory mutation guard '$($directoryMutationGuards[$index].path)': $($_.Exception.Message)"
            )
        }
    }
    if ($null -ne $outputClaim) {
        try {
            $outputClaim.stream.Dispose()
        }
        catch {
            $postResultReleaseErrors.Add(
                "Could not release the output-directory claim '$($outputClaim.path)': $($_.Exception.Message)"
            )
        }
    }
    if ($postResultReleaseErrors.Count -gt 0) {
        if (-not $resultWritten) {
            $exitCode = 2
        }
        foreach ($releaseError in $postResultReleaseErrors) {
            [Console]::Error.WriteLine(
                (Protect-JournalLine -Line "MQL5 tester smoke warning: $releaseError")
            )
        }
    }

    $pathLeaseReleaseError = $null
    for ($index = $pathEntryLeases.Count - 1; $index -ge 0; $index--) {
        try {
            $pathEntryLeases[$index].Dispose()
        }
        catch {
            if ($null -eq $pathLeaseReleaseError) {
                $pathLeaseReleaseError = $_.Exception.Message
            }
        }
    }
    if ($null -ne $pathLeaseReleaseError) {
        [Console]::Error.WriteLine(
            (Protect-JournalLine -Line (
                    'MQL5 tester smoke warning: could not release a ' +
                    "path-integrity lease: $pathLeaseReleaseError"
                ))
        )
    }

}

if ($resultWritten) {
    Write-Output $resultPath
}
exit $exitCode
