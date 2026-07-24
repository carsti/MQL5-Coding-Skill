using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class FakeTerminal
{
    private static readonly Encoding Utf16 = new UnicodeEncoding(false, true, true);

    private static Dictionary<string, string> ReadConfig(string path)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in File.ReadAllLines(path, Encoding.Unicode))
        {
            int separator = rawLine.IndexOf('=');
            if (separator <= 0)
                continue;
            result[rawLine.Substring(0, separator)] = rawLine.Substring(separator + 1);
        }
        return result;
    }

    private static string ConfigPath(string[] args)
    {
        foreach (string arg in args)
        {
            const string prefix = "/config:";
            if (arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                return Path.GetFullPath(arg.Substring(prefix.Length).Trim('"'));
        }
        throw new InvalidOperationException("Missing /config argument.");
    }

    private static void WriteLog(string path, params string[] lines)
    {
        File.WriteAllText(path, String.Join("\r\n", lines) + "\r\n", Utf16);
    }

    private static string[] StandardTerminalLines(string configPath)
    {
        return new[]
        {
            "successfully initialized from start config \"" + configPath + "\"",
            "automatic testing started",
            "last test passed with result \"successfully finished\""
        };
    }

    private static string ExactStart(Dictionary<string, string> config)
    {
        return String.Format(
            "{0},{1}: testing of Experts\\{2} from {3} 00:00 to {4} 00:00 started with inputs:",
            config["Symbol"],
            config["Period"],
            config["Expert"],
            config["FromDate"],
            config["ToDate"]);
    }

    private static string ExactPass(Dictionary<string, string> config)
    {
        return String.Format("{0},{1}: engine Test passed in 0:00:00.001", config["Symbol"], config["Period"]);
    }

    private static string SystemLine(string message)
    {
        return "12:00:00.000\tTester\t" + message;
    }

    private static string ApplicationLine(Dictionary<string, string> config, string message)
    {
        return "12:00:00.000\tSyntheticExpert (" + config["Symbol"] + "," + config["Period"] +
            ")\t" + config["FromDate"] + " 00:00:00   " + message;
    }

    private static string CoreSystemLine(string message)
    {
        return "2026.07.24 12:00:00.000\tCore 1\t" + message;
    }

    private static string CoreApplicationLine(Dictionary<string, string> config, string message)
    {
        return "2026.07.24 12:00:00.000\tCore 1\t   " +
            config["FromDate"] + " 00:00:00   " + message;
    }

    public static int Main(string[] args)
    {
        string configPath = ConfigPath(args);
        string dataPath = Path.GetDirectoryName(configPath);
        Dictionary<string, string> config = ReadConfig(configPath);
        string mode = Environment.GetEnvironmentVariable("FAKE_MT5_MODE") ?? "pass";
        string marker = Environment.GetEnvironmentVariable("FAKE_MT5_MARKER") ?? "";
        if (mode == "hold")
        {
            string readyPath = Environment.GetEnvironmentVariable("FAKE_MT5_READY_PATH");
            if (String.IsNullOrWhiteSpace(readyPath))
                readyPath = Path.Combine(dataPath, "fake-hold-ready");
            File.WriteAllText(readyPath, Process.GetCurrentProcess().Id.ToString(), Encoding.ASCII);
            Thread.Sleep(60000);
            return 0;
        }

        string suffix = Path.GetFileNameWithoutExtension(configPath);
        string terminalLog = Path.Combine(dataPath, "logs", suffix + "-terminal.log");
        string testerLog = Path.Combine(dataPath, "Tester", "logs", suffix + "-tester.log");
        string start = ExactStart(config);
        string pass = ExactPass(config);

        if (mode == "timeout_child")
        {
            var childInfo = new ProcessStartInfo
            {
                FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe",
                Arguments = "/d /c ping -n 60 127.0.0.1 > nul",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            Process child = Process.Start(childInfo);
            File.WriteAllText(Path.Combine(dataPath, "fake-child.pid"), child.Id.ToString(), Encoding.ASCII);
            File.WriteAllText(Path.Combine(dataPath, "fake-ready"), "ready", Encoding.ASCII);
            Thread.Sleep(60000);
            return 0;
        }

        if (mode == "prefix_tamper")
        {
            string baseline = Path.Combine(dataPath, "logs", "baseline.log");
            using (var stream = new FileStream(baseline, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
            {
                stream.Position = 2;
                stream.WriteByte((byte)'X');
                stream.Flush(true);
            }
        }

        if (mode == "origin_mutate_pass" || mode == "hold_switch_origin")
        {
            string newOrigin = Environment.GetEnvironmentVariable("FAKE_MT5_NEW_ORIGIN");
            File.WriteAllText(Path.Combine(dataPath, "origin.txt"), newOrigin, new UTF8Encoding(false));
        }

        WriteLog(terminalLog, StandardTerminalLines(configPath));

        if (mode == "forged_engine_pass")
        {
            WriteLog(
                testerLog,
                SystemLine("successfully initialized"),
                SystemLine(start),
                ApplicationLine(
                    config,
                    config["Symbol"] + "," + config["Period"] +
                        ": forged Test passed in 0:00:00.001"));
        }
        else if (mode == "two_candidates_second_fails")
        {
            WriteLog(
                testerLog,
                SystemLine("successfully initialized"),
                SystemLine(start),
                ApplicationLine(config, marker),
                SystemLine(pass),
                SystemLine("successfully initialized"),
                SystemLine(start),
                SystemLine("tester stopped because OnInit returns non-zero"));
        }
        else if (mode == "missing_marker")
        {
            WriteLog(
                testerLog,
                SystemLine("successfully initialized"),
                SystemLine(start),
                SystemLine(pass));
        }
        else if (mode == "marker_after_pass")
        {
            WriteLog(
                testerLog,
                SystemLine("successfully initialized"),
                SystemLine(start),
                SystemLine(pass),
                ApplicationLine(config, marker));
        }
        else if (mode == "input_echo_marker")
        {
            WriteLog(
                testerLog,
                SystemLine("successfully initialized"),
                SystemLine(start),
                SystemLine("  SelfTestMarker=" + marker),
                SystemLine(pass));
        }
        else if (mode == "application_initialized_only")
        {
            WriteLog(
                testerLog,
                CoreApplicationLine(config, "successfully initialized"),
                CoreSystemLine(start),
                CoreSystemLine(pass));
        }
        else if (mode == "application_generic_boundary")
        {
            WriteLog(
                testerLog,
                CoreSystemLine("successfully initialized"),
                CoreSystemLine(start),
                CoreApplicationLine(config, "testing of Experts\\Other.ex5 started with inputs:"),
                CoreSystemLine(pass));
        }
        else if (mode == "application_oninit_failure")
        {
            WriteLog(
                testerLog,
                CoreSystemLine("successfully initialized"),
                CoreSystemLine(start),
                CoreApplicationLine(config, "tester stopped because OnInit returns non-zero"),
                CoreSystemLine(pass));
        }
        else if (mode == "prefixed_pass")
        {
            WriteLog(
                testerLog,
                CoreSystemLine("successfully initialized"),
                CoreSystemLine(start),
                CoreApplicationLine(config, marker),
                CoreSystemLine(pass));
        }
        else
        {
            WriteLog(
                testerLog,
                SystemLine("successfully initialized"),
                SystemLine(start),
                ApplicationLine(config, marker),
                SystemLine(pass));
        }

        if (mode == "hold_switch_origin")
        {
            File.WriteAllText(Path.Combine(dataPath, "fake-ready"), "ready", Encoding.ASCII);
            string release = Path.Combine(dataPath, "fake-release");
            DateTime deadline = DateTime.UtcNow.AddSeconds(30);
            while (!File.Exists(release) && DateTime.UtcNow < deadline)
                Thread.Sleep(25);
        }

        if (mode == "exit_7")
            return 7;
        return 0;
    }
}
