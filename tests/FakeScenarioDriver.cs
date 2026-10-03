using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
internal static class FakeScenarioDriver {
    private static string Hash(string path) {using(var sha=SHA256.Create()) using(var file=File.OpenRead(path)) return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();}
    private static string Q(string value) {return "\""+value.Replace("\\", "\\\\").Replace("\"", "\\\"")+"\"";}
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        string action=args[0], mode=args[1], source=args[2], output=args[3];
        string trace=Environment.GetEnvironmentVariable("MQL5_SCENARIO_TEST_TRACE");
        if(!String.IsNullOrEmpty(trace)) File.AppendAllText(trace,action+":"+mode+"\n");
        if(action=="Compile") {
            if(mode=="compiler-failure") return 1;
            string path=Path.Combine(Path.GetDirectoryName(source),"receipt-"+Guid.NewGuid().ToString("N")+".json");
            File.WriteAllText(path,"{\"schema_version\":1,\"status\":\"success\",\"exit_code\":0,\"source\":{\"path\":"+Q(source)+"}}",new UTF8Encoding(false));
            Console.WriteLine("MQL5_COMPILE_RECEIPT="+path);return 0;
        }
        Directory.CreateDirectory(output);
        if(mode=="missing-result") return 0;
        string fixture=Environment.GetEnvironmentVariable("MQL5_SCENARIO_TEST_REPORT");
        string report=Path.Combine(output,"native.htm");
        if(mode=="bad-report") File.WriteAllText(report,"<html>unsupported</html>");
        else File.Copy(fixture,report);
        string status=mode=="tester-failure"?"evidence_failed":mode=="timeout"?"timed_out":mode=="blocked"?"blocked":mode=="cleanup-failure"?"cleanup_failed":"engine_smoke_passed";
        bool started=mode!="blocked", empty=mode!="cleanup-failure";
        string reportHash=mode=="wrong-report-hash"?new String('0',64):Hash(report);
        string json="{\"schema_version\":2,\"status\":"+Q(status)+",\"inputs\":{\"symbol\":\"EURUSD\",\"period\":\"M1\",\"model\":0,\"execution_mode\":0,\"deposit\":100000,\"currency\":\"USD\",\"leverage\":100},\"binding\":{},\"artifacts\":{\"report\":{\"path\":"+Q(report)+",\"byte_length\":"+new FileInfo(report).Length+",\"sha256\":"+Q(reportHash)+"}},\"process\":{\"process_created\":"+(started?"true":"false")+",\"job_empty_verified\":"+(empty?"true":"false")+"},\"cleanup\":{\"errors\":[]}}";
        File.WriteAllText(Path.Combine(output,"smoke-result.json"),json,new UTF8Encoding(false));
        if(mode=="missing-report") File.Delete(report);
        return mode=="timeout"?3:mode=="blocked"?4:mode=="tester-failure"?1:mode=="cleanup-failure"?2:0;
    }
}
