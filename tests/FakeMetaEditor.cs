using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class FakeMetaEditor
{
    private static string SourcePath(string[] args)
    {
        foreach (string arg in args)
        {
            const string prefix = "/compile:";
            if (arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                return Path.GetFullPath(arg.Substring(prefix.Length).Trim('"'));
        }
        throw new InvalidOperationException("Missing /compile argument.");
    }

    private static bool HasArgument(string[] args, string expected)
    {
        foreach (string arg in args)
        {
            if (String.Equals(arg, expected, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    public static int Main(string[] args)
    {
        string sourcePath = SourcePath(args);
        string logPath = Path.ChangeExtension(sourcePath, ".log");
        string artifactPath = Path.ChangeExtension(sourcePath, ".ex5");
        string mode = Environment.GetEnvironmentVariable("FAKE_METAEDITOR_MODE") ?? "success";
        string argumentsPath = Environment.GetEnvironmentVariable("FAKE_METAEDITOR_ARGS_PATH");
        if (!String.IsNullOrWhiteSpace(argumentsPath))
            File.WriteAllLines(argumentsPath, args, new UTF8Encoding(false));

        byte[] sourceBytes = File.ReadAllBytes(sourcePath);
        if (sourceBytes.Length == 0)
            throw new InvalidOperationException("Synthetic compiler received an empty source file.");

        if (mode == "exit_without_result")
            return 0;

        if (mode == "timeout" || mode == "timeout_detached")
        {
            var childInfo = new ProcessStartInfo
            {
                FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
                Arguments = "/d /c ping -n 60 127.0.0.1 > nul",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            Process child = Process.Start(childInfo);
            string childPidPath = Environment.GetEnvironmentVariable("FAKE_METAEDITOR_CHILD_PID_PATH");
            if (!String.IsNullOrWhiteSpace(childPidPath))
                File.WriteAllText(childPidPath, child.Id.ToString(), Encoding.ASCII);
            if (mode == "timeout_detached")
                return 0;
            Thread.Sleep(60000);
            return 0;
        }

        int errors = mode == "errors" ? 1 : 0;
        int warnings = mode == "warnings" ? 1 : 0;
        bool syntaxOnly = HasArgument(args, "/s");
        string result = String.Format(
            "Result: {0} errors, {1} warnings",
            errors,
            warnings);

        if (mode == "delayed_completion" && !syntaxOnly)
        {
            File.WriteAllBytes(artifactPath, Encoding.ASCII.GetBytes("partial ex5"));
            File.WriteAllText(logPath, result + Environment.NewLine, new UTF8Encoding(false));
            Thread.Sleep(750);
            File.WriteAllBytes(artifactPath, Encoding.ASCII.GetBytes("synthetic ex5 complete"));
            File.SetLastWriteTimeUtc(artifactPath, DateTime.UtcNow);
            return 0;
        }

        if (errors == 0 && !syntaxOnly && mode != "no_artifact" && mode != "stale_artifact")
        {
            File.WriteAllBytes(artifactPath, Encoding.ASCII.GetBytes("synthetic ex5"));
            File.SetLastWriteTimeUtc(artifactPath, DateTime.UtcNow);
        }

        File.WriteAllText(logPath, result + Environment.NewLine, new UTF8Encoding(false));
        return 0;
    }
}
