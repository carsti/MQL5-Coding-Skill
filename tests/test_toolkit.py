from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "skills/mql5-coding/scripts"
sys.path.insert(0, str(SCRIPTS))
from toolkit_common import InputError, differences, load_expectations, number
from toolkit_reports import compare_reports, native_report
from toolkit_includes import compare_snapshots, directives, inventory

FIXTURES = Path(__file__).parent / "fixtures/reports"


class ToolkitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mql5-toolkit-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def report(self, name="mixed-trades", linked=True):
        return native_report(FIXTURES/(name+".htm"), FIXTURES/(name+"-result.json") if linked else None)

    def expectation(self, metric="net_profit", target="candidate", **bounds):
        value = {"schema_version": 1, "metrics": [{"metric": metric, "target": target, **bounds}]}
        path = self.root/"expectations.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return load_expectations(path)

    def test_genuine_native_statistics(self):
        # Independently checked directly in the retained native report cells.
        cases = {
            "no-trades": {"net_profit": "0.00", "trades": "0", "deals": "0", "gross_loss": "0.00"},
            "profitable-only": {"net_profit": "10.67", "trades": "6", "deals": "12", "gross_loss": "0.00", "profit_factor": "0.00", "equity_drawdown_maximal_amount": "14.71"},
            "mixed-trades": {"net_profit": "120.86", "gross_profit": "267.84", "gross_loss": "-146.98", "trades": "55", "deals": "110", "profit_factor": "1.82", "balance_drawdown_absolute": "4.43", "equity_drawdown_absolute": "10.37", "balance_drawdown_maximal_amount": "34.50", "equity_drawdown_maximal_percent": "0.04", "equity_drawdown_relative_amount": "44.24", "winning_trades": "30", "losing_trades": "25"},
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                report = self.report(name)
                self.assertEqual(report["evidence_linkage"]["status"], "hash_verified")
                for key, value in expected.items():
                    self.assertEqual(report["metrics"][key]["value"], value)
                    self.assertGreater(report["metrics"][key]["evidence"]["location"]["row"], 0)
                utf8 = native_report(FIXTURES/(name+"-utf8.htm"))
                self.assertEqual(report["metrics"], utf8["metrics"])
                self.assertEqual(report["conditions"]["effective_inputs"], utf8["conditions"]["effective_inputs"])

    def test_values_grouping_specials_and_zero(self):
        for raw, expected in [("1 234.50", "1234.50"), ("-12,345.01", "-12345.01"), ("1\u00a0234.00", "1234.00"), ("-0.01", "-0.01")]:
            self.assertEqual(number(raw)["value"], expected)
        for raw, state in [(None, "missing"), ("N/A", "undefined"), ("NaN", "special"), ("DBL_MAX", "special"), ("1.#INF", "special"), ("12,34", "unparseable"), ("12.34.56", "unparseable")]:
            self.assertEqual(number(raw)["state"], state)
        self.assertEqual(differences(number("0"), number("10"))["percentage_difference"]["reason"], "zero_baseline")
        delta = differences(number("-10"), number("-5"))
        self.assertEqual(delta["difference"]["value"], "5")
        self.assertEqual(delta["percentage_difference"]["value"], "50.0")

    def mutate_report(self, old, new):
        path = self.root/"mutated.htm"
        path.write_text((FIXTURES/"mixed-trades.htm").read_text(encoding="utf-16").replace(old, new), encoding="utf-8")
        return path

    def test_missing_special_and_pair_preservation(self):
        for original, replacement, metric, state in [("Gross Loss:", "Unknown Gross Loss:", "gross_loss", "missing"), ("<b>1.82</b>", "<b>NaN</b>", "profit_factor", "special"), ("<b>34.50 (0.03%)</b>", "<b>bad</b>", "balance_drawdown_maximal_amount", "unparseable")]:
            report = native_report(self.mutate_report(original, replacement))
            self.assertEqual(report["metrics"][metric]["state"], state)

    def test_unsupported_malformed_duplicate_layouts(self):
        for old, new in [("Settings</b>", "Einstellungen</b>"), ("</table>", ""), ("Gross Loss:", "Gross Profit:")]:
            with self.assertRaises(InputError):
                native_report(self.mutate_report(old, new))

    def test_linkage_does_not_invent_success(self):
        path = self.mutate_report("120.86", "119.86")
        report = native_report(path, FIXTURES/"mixed-trades-result.json")
        self.assertEqual(report["evidence_linkage"]["status"], "mismatch")
        self.assertIsNone(report["conditions"]["model"])
        self.assertFalse(report["recorded_run"]["verified_execution"])
        self.assertEqual(compare_reports(self.report(), report)["compatibility"]["status"], "insufficient_evidence")

    def test_comparison_statuses_artifact_and_supplemental(self):
        a = self.report()
        b = copy.deepcopy(a)
        b["artifact_identity"]["expert_sha256"] = "a"*64
        b["terminal"]["build"] = "9999"
        self.assertEqual(compare_reports(a, b)["compatibility"]["status"], "comparable")
        b["conditions"]["symbol"] = "EURUSD"
        self.assertEqual(compare_reports(a, b)["compatibility"]["status"], "incompatible")
        self.assertEqual(compare_reports(self.report(linked=False), self.report(linked=False))["compatibility"]["status"], "insufficient_evidence")
        self.assertEqual(a["conditions"]["reported_dates"], ["2025.01.12", "2026.04.18"])

    def test_expectation_pass_fail_missing_and_incompatible(self):
        a, b = self.report(), self.report()
        self.assertEqual(compare_reports(a, b, self.expectation(minimum="120", maximum="121"))["expectations"]["status"], "pass")
        self.assertEqual(compare_reports(a, b, self.expectation(minimum="121"))["expectations"]["status"], "fail")
        self.assertEqual(compare_reports(a, b, self.expectation("missing", minimum="0"))["expectations"]["status"], "not_evaluable")
        b["conditions"]["execution_mode"] = "100"
        self.assertEqual(compare_reports(a, b, self.expectation(minimum="0"))["expectations"]["status"], "not_evaluable")
        for content in ['{"schema_version":1,"metrics":[],"unknown":true}', '{"schema_version":1,"schema_version":1,"metrics":[]}', '{"schema_version":true,"metrics":[]}']:
            path = self.root/"invalid.json"
            path.write_text(content, encoding="utf-8")
            with self.assertRaises(InputError):
                load_expectations(path)
        for bound in ("1,000", "1 000", "5%", "NaN"):
            with self.assertRaises(InputError):
                self.expectation(minimum=bound)

    def test_explicit_evidence_requirements(self):
        a, b = self.report(), self.report()
        b["terminal"]["build"] = "9999"
        e = self.expectation(minimum="0")
        e["required_conditions"] = ["terminal_build"]
        self.assertEqual(compare_reports(a, b, e)["compatibility"]["status"], "incompatible")
        e.pop("required_conditions")
        e["required_evidence"] = ["preset_hash"]
        b["artifact_identity"]["preset_sha256"] = None
        self.assertEqual(compare_reports(a, b, e)["compatibility"]["status"], "insufficient_evidence")

    def project(self):
        root = self.root/"project"
        root.mkdir()
        external = self.root/"standard"
        external.mkdir()
        (root/"nested").mkdir()
        (root/"A.mq5").write_text('// #include "bad.mqh"\nstring s="#include \\"bad.mqh\\"";\n#include "nested/Child.mqh"\n#ifdef ENABLE\n#include <Shared.mqh>\n#endif\n', encoding="utf-8")
        (root/"B.mq5").write_text('#include <Shared.mqh>\n', encoding="utf-8")
        (root/"nested/Child.mqh").write_text('#include "../RootHeader.mqh"\n', encoding="utf-8")
        (root/"RootHeader.mqh").write_text('// root\n', encoding="utf-8")
        (external/"Shared.mqh").write_text('// external\n', encoding="utf-8")
        return root, external

    def test_include_main_root_rules_comments_strings_conditions(self):
        root, external = self.project()
        snap = inventory(root, [], [external])
        self.assertEqual(len(snap["entrypoints"]), 2)
        self.assertEqual(snap["unresolved"], [])
        shared = str((external/"Shared.mqh").resolve())
        self.assertEqual(len(snap["possible_consumers"][shared]), 2)
        self.assertEqual(len([x for x in snap["dependencies"] if x["conditional_context"]]), 1)
        self.assertNotIn("bad.mqh", str(snap["dependencies"]))
        self.assertEqual(directives('/*\n#include "bad"\n*/\n#include <x> // comment\n'), [(4, "include", "<x>")])

    def test_cycles_deleted_header_and_unknown_coverage(self):
        root, external = self.project()
        (external/"Shared.mqh").write_text('#include <Shared.mqh>\n', encoding="utf-8")
        a = inventory(root, [], [external])
        self.assertTrue(a["cycles"])
        (external/"Shared.mqh").unlink()
        (root/"orphan.mqh").write_text('// new unused source\n', encoding="utf-8")
        b = inventory(root, [root/"A.mq5"], [external])
        diff = compare_snapshots(a, b)
        deleted = [x for x in diff["differences"] if x["kind"] == "removed"][0]
        self.assertEqual(len(deleted["possible_affected_entrypoints"]), 2)
        self.assertTrue(b["unselected_entrypoints"])
        self.assertEqual(b["coverage"], "uncertain")
        self.assertTrue(any(x["kind"] == "added" for x in diff["differences"]))

    def test_nested_quoted_directory_and_reference_uncertainty(self):
        root, external = self.project()
        (root/"nested/Child.mqh").write_text('#include "Choice.mqh"\n', encoding="utf-8")
        local = root/"nested/Choice.mqh"
        local.write_text('// declaring-file header', encoding="utf-8")
        snap = inventory(root, [], [external])
        edge = [e for e in snap["dependencies"] if e["declaration"] == '"Choice.mqh"'][0]
        self.assertEqual(edge["target"], str(local))
        alternative = root/"Choice.mqh"
        alternative.write_text('// Reference main-source candidate', encoding="utf-8")
        snap = inventory(root, [], [external])
        edge = [e for e in snap["dependencies"] if e["declaration"] == '"Choice.mqh"'][0]
        self.assertEqual(edge["resolution"], "ambiguous")
        for path in (local, alternative):
            self.assertEqual(snap["possible_consumers"][str(path)], [str(root/"A.mq5")])
        self.assertEqual(snap["coverage"], "uncertain")

    def test_genuine_nested_include_fixture(self):
        root = Path(__file__).parent/"fixtures/includes"
        provenance = json.loads((root/"provenance.json").read_text())
        import hashlib
        for file in provenance["files"]:
            self.assertEqual(hashlib.sha256((root/file["path"]).read_bytes()).hexdigest(), file["sha256"])
        log = (root/"native-compile.log").read_text()
        self.assertIn('Nested\\Choice.mqh', log)
        self.assertEqual(provenance["tester_status"], "application_marker_passed")
        snap = inventory(root.resolve(), [], [])
        edge = [e for e in snap["dependencies"] if e["declaration"] == '"Choice.mqh"'][0]
        self.assertEqual(edge["resolution"], "ambiguous")
        self.assertEqual(len(edge["possible_targets"]), 2)

    def test_unsupported_macro_and_ambiguous_roots(self):
        root, external = self.project()
        (root/"A.mq5").write_text('#include HEADER\n#include <Shared.mqh>\n', encoding="utf-8")
        other = self.root/"other"
        other.mkdir()
        (other/"Shared.mqh").write_text('// collision', encoding="utf-8")
        snap = inventory(root, [], [external, other])
        self.assertEqual({x["resolution"] for x in snap["unresolved"]}, {"unsupported", "ambiguous"})

    def test_cli_exit_codes_and_no_overwrite(self):
        cli = SCRIPTS/"mql5_toolkit.py"
        def run(args, name):
            output = self.root/name
            proc = subprocess.run([sys.executable, "-B", str(cli), *args, "--output", str(output)], capture_output=True)
            self.assertLess(len(proc.stdout), 4096)
            return proc, output
        proc, out = run(["report", "read", "--input", str(FIXTURES/"mixed-trades.htm")], "read")
        self.assertEqual(proc.returncode, 0)
        old = (out/"result.json").read_bytes()
        repeated, _ = run(["report", "read", "--input", str(FIXTURES/"mixed-trades.htm")], "read")
        self.assertEqual(repeated.returncode, 2)
        self.assertEqual((out/"result.json").read_bytes(), old)
        comparison = ["report", "compare", "--baseline", str(FIXTURES/"mixed-trades.htm"), "--candidate", str(FIXTURES/"mixed-trades.htm")]
        self.assertEqual(run(comparison, "missing")[0].returncode, 4)
        comparison += ["--baseline-result", str(FIXTURES/"mixed-trades-result.json"), "--candidate-result", str(FIXTURES/"mixed-trades-result.json")]
        self.expectation(minimum="999")
        self.assertEqual(run(comparison + ["--expectations", str(self.root/"expectations.json")], "fail")[0].returncode, 1)
        candidate = self.mutate_report('>XAUUSD<', '>EURUSD<')
        self.assertEqual(run(["report", "compare", "--baseline", str(FIXTURES/"mixed-trades.htm"), "--candidate", str(candidate)], "incompatible")[0].returncode, 3)
        self.assertEqual(run(["report", "read", "--input", "relative.htm"], "invalid")[0].returncode, 2)


if __name__ == "__main__":
    unittest.main()
