"""Fixed-scope A/B processing measurements; no claim about whole-agent speed/tokens."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from decimal import Decimal
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO/"skills/mql5-coding/scripts"
FIXTURES = REPO/"tests/fixtures/reports"

REPORT_BASELINE = r'''
import sys,re,json,html
from pathlib import Path
from decimal import Decimal
def read(path):
 text=Path(path).read_text(encoding="utf-16")
 cells=[html.unescape(re.sub(r"<[^>]+>","",c)).strip() for c in re.findall(r"<td\b[^>]*>(.*?)</td>",text,re.S)]
 values={cells[i][:-1]:cells[i+1] for i in range(len(cells)-1) if cells[i].endswith(":" )}
 return values
a,b=read(sys.argv[1]),read(sys.argv[2])
labels={"net_profit":"Total Net Profit","gross_profit":"Gross Profit","gross_loss":"Gross Loss","trades":"Total Trades","deals":"Total Deals"}
delta={k:str(Decimal(b[v])-Decimal(a[v])) for k,v in labels.items()}
delta["compatibility"]="incompatible" if any(a[k]!=b[k] for k in ("Symbol","Period","Inputs")) else "unknown"
out=Path(sys.argv[3]);out.mkdir();(out/"result.json").write_text(json.dumps(delta));print(json.dumps(delta))
'''
INCLUDE_BASELINE = r'''
import sys,re,json,hashlib
from pathlib import Path
root=Path(sys.argv[1]);before=json.loads(Path(sys.argv[2]).read_text())
changed=[p for p,h in before.items() if not Path(p).is_file() or hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h]
affected=[]
for entry in sorted(root.glob("*.mq5")):
 refs=re.findall(r'^\s*#include "([^"]+)"',entry.read_text(),re.M)
 if any(str((entry.parent/r).resolve()) in changed for r in refs): affected.append(str(entry.resolve()))
out=Path(sys.argv[3]);out.mkdir();value={"possible_affected_entrypoints":affected};(out/"result.json").write_text(json.dumps(value));print(json.dumps(value))
'''
JOURNAL_BASELINE = r'''
param([string]$Run,[string]$Scripts,[string]$Output)
. (Join-Path $Scripts 'TesterEvidence.ps1')
$r=Get-Content -LiteralPath $Run -Raw -Encoding UTF8 | ConvertFrom-Json
$s=$r.evidence.terminal_journal.segments[0]
$bytes=[IO.File]::ReadAllBytes($s.path)
$range=New-Object byte[] $s.byte_length
[Array]::Copy($bytes,$s.source_offset,$range,0,$s.byte_length)
$sha=[Security.Cryptography.SHA256]::Create()
try {$actual=([BitConverter]::ToString($sha.ComputeHash($range))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
if ($actual -cne $s.sha256) {throw 'Hash mismatch'}
$groups=@{}
foreach($line in ([Text.Encoding]::Unicode.GetString($range) -split "`r`n")) {
 if(-not $line) {continue}
 $cols=$line -split "`t",5
 $message=Protect-JournalLine -Line $cols[4]
 $message=[regex]::Replace($message,'MQL5_CODING_PASS:[0-9a-fA-F]{32,64}(?::[^\s]*)?','<APPLICATION_MARKER>')
 if(-not $groups.ContainsKey($message)) {$groups[$message]=0};$groups[$message]++
}
[IO.Directory]::CreateDirectory($Output)|Out-Null
$value=@{counts=@($groups.Values|Sort-Object)}
$value|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $Output 'result.json') -Encoding UTF8
$value|ConvertTo-Json -Compress
'''


def timed(command: list, output: Path, code_lines: int) -> tuple[dict, dict]:
    start = time.perf_counter()
    proc = subprocess.run(command, capture_output=True, timeout=120)
    duration = time.perf_counter()-start
    result = json.loads((output/"result.json").read_text(encoding="utf-8-sig"))
    measurement = {"commands": 1, "retries": 0, "elapsed_seconds": str(Decimal(str(duration))),
                   "console_bytes": len(proc.stdout)+len(proc.stderr), "artifact_bytes": sum(p.stat().st_size for p in output.rglob("*") if p.is_file()),
                   "processing_code_lines": code_lines, "exit_code": proc.returncode,
                   "token_usage": None, "token_usage_reason": "Not exposed by this local subprocess measurement"}
    return result, measurement


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--powershell", type=Path, required=True)
    args = parser.parse_args()
    if not args.output.is_absolute() or args.output.exists() or not args.powershell.is_absolute():
        parser.error("Use new absolute output and absolute PowerShell paths")
    args.output.mkdir()
    out = args.output
    cases = []
    baseline = out/"report-baseline.py"
    baseline.write_text(REPORT_BASELINE, encoding="utf-8")
    a, b = FIXTURES/"profitable-only.htm", FIXTURES/"mixed-trades.htm"
    raw, without = timed([sys.executable,"-B",str(baseline),str(a),str(b),str(out/"report-without")], out/"report-without", len(REPORT_BASELINE.splitlines()))
    processed, with_helper = timed([sys.executable,"-B",str(SCRIPTS/"mql5_toolkit.py"),"report","compare","--baseline",str(a),"--candidate",str(b),"--baseline-result",str(FIXTURES/"profitable-only-result.json"),"--candidate-result",str(FIXTURES/"mixed-trades-result.json"),"--output",str(out/"report-with")], out/"report-with", 0)
    expected = {"net_profit":"110.19","gross_profit":"257.17","gross_loss":"-146.98","trades":"49","deals":"98","compatibility":"incompatible"}
    selected = {k:processed["metrics"][k]["difference"]["value"] for k in expected if k != "compatibility"}
    selected["compatibility"] = processed["compatibility"]["status"]
    cases.append({"id":"report-comparison","scope":"Five native metric differences and known configuration incompatibility", "correctness":raw==expected and selected==expected,"without_helper":without,"with_helper":with_helper})

    project = out/"project"
    project.mkdir()
    for name in ("A.mq5","B.mq5"):
        (project/name).write_text('#include "Shared.mqh"\nvoid OnTick() {}\n', encoding="utf-8")
    shared = project/"Shared.mqh"
    shared.write_text('// shared calculations\n', encoding="utf-8")
    hashes = {str(p.resolve()):hashlib.sha256(p.read_bytes()).hexdigest() for p in project.iterdir()}
    snapshot = out/"raw-snapshot.json"
    snapshot.write_text(json.dumps(hashes), encoding="utf-8")
    before, first = timed([sys.executable,"-B",str(SCRIPTS/"mql5_toolkit.py"),"includes","inventory","--root",str(project),"--output",str(out/"inventory-before")], out/"inventory-before", 0)
    shared.unlink()
    after, second = timed([sys.executable,"-B",str(SCRIPTS/"mql5_toolkit.py"),"includes","inventory","--root",str(project),"--output",str(out/"inventory-after")], out/"inventory-after", 0)
    baseline = out/"includes-baseline.py"
    baseline.write_text(INCLUDE_BASELINE, encoding="utf-8")
    raw, without = timed([sys.executable,"-B",str(baseline),str(project),str(snapshot),str(out/"includes-without")], out/"includes-without", len(INCLUDE_BASELINE.splitlines()))
    processed, with_helper = timed([sys.executable,"-B",str(SCRIPTS/"mql5_toolkit.py"),"includes","compare","--baseline",str(out/"inventory-before/result.json"),"--candidate",str(out/"inventory-after/result.json"),"--output",str(out/"includes-with")], out/"includes-with", 0)
    expected = [str((project/n).resolve()) for n in ("A.mq5","B.mq5")]
    cases.append({"id":"include-impact","scope":"Deleted shared literal header with two known consumers", "correctness":raw["possible_affected_entrypoints"]==expected and processed["possible_affected_entrypoints"]==expected,
                  "without_helper":without,"with_helper":with_helper,"snapshot_preparation":{"helper_commands":2,"measurements":[first,second],"baseline_preparation":"One hash snapshot saved by the evaluator"}})

    journal = out/"journal.log"
    prefix = 'prefix\r\n'
    messages = ['AA\t0\t10:00:01.000\tFixture\trepeated message','BB\t0\t10:00:02.000\tFixture\trepeated message','CC\t0\t10:00:03.000\tFixture\tMQL5_CODING_PASS:'+"a"*32+':fixture']
    segment = ('\r\n'.join(messages)+'\r\n').encode('utf-16le')
    journal.write_bytes(b'\xff\xfe'+prefix.encode('utf-16le')+segment)
    run = {"schema_version":2,"status":"engine_smoke_passed","evidence":{"terminal_journal":{"appended_byte_length":len(segment),"limit_exceeded":False,"segments":[{"path":str(journal),"source_offset":2+len(prefix.encode('utf-16le')),"byte_length":len(segment),"sha256":hashlib.sha256(segment).hexdigest()}],"excerpts":[]},"tester_journal":{"appended_byte_length":0,"limit_exceeded":False,"segments":[],"excerpts":[]}}}
    run_path = out/"run.json"
    run_path.write_text(json.dumps(run), encoding="utf-8")
    baseline = out/"journal-baseline.ps1"
    baseline.write_text(JOURNAL_BASELINE, encoding="utf-8")
    host = [str(args.powershell),"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File"]
    raw, without = timed(host+[str(baseline),"-Run",str(run_path),"-Scripts",str(SCRIPTS),"-Output",str(out/"journal-without")], out/"journal-without", len(JOURNAL_BASELINE.splitlines()))
    processed, with_helper = timed(host+[str(SCRIPTS/"Read-Mql5Journal.ps1"),"-TesterResultPath",str(run_path),"-OutputDirectory",str(out/"journal-with")], out/"journal-with", 0)
    cases.append({"id":"journal-grouping","scope":"Verified bounded segment, repeated messages, and redacted application marker", "correctness":raw["counts"]==[1,2] and sorted(g["count"] for g in processed["groups"])==[1,2] and 'MQL5_CODING_PASS' not in json.dumps(processed),"without_helper":without,"with_helper":with_helper})
    result = {"schema_version":1,"operation":"fixed_scope_toolkit_evaluation","status":"passed" if all(c["correctness"] for c in cases) else "failed","cases":cases,
              "limitations":["Fixed-scope scripted measurements, not whole-agent task or token savings", "The helper retains broader evidence than baseline scripts; compare artifact volume in that context", "Preparation costs are disclosed separately", "Maintenance effort is represented by retained processing code, not measured long-term labor", "Single runs do not establish a general time improvement"]}
    (out/"evaluation.json").write_text(json.dumps(result, indent=2)+"\n", encoding="utf-8")
    print(result["status"]+": "+str(len(cases))+" fixed-scope evaluations; see "+str(out/"evaluation.json"))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
