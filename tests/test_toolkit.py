from __future__ import annotations

import copy
import errno
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "skills/mql5-coding/scripts"
sys.path.insert(0, str(SCRIPTS))
from toolkit_common import InputError, differences, digest, load_expectations, number, read_json
from toolkit_reports import compare_reports, native_report
from toolkit_includes import compare_snapshots, directives, inventory, selected_entrypoint
from mql5_toolkit import execute, parser as cli_parser

FIXTURES = Path(__file__).parent / "fixtures/reports"


class ToolkitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mql5-toolkit-")
        # Windows CI may return an 8.3 alias for TEMP. Evidence paths are
        # canonical, so fixture expectations and injected I/O failures must use
        # the same physical directory rather than an unresolved alias.
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def report(self, name="mixed-trades", linked=True):
        return native_report(FIXTURES/(name+".htm"), FIXTURES/(name+"-result.json") if linked else None)

    def expectation(self, metric="net_profit", target="candidate", **bounds):
        value = {"schema_version": 1, "metrics": [{"metric": metric, "target": target, **bounds}]}
        path = self.root/"expectations.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return load_expectations(path)

    def test_json_rejects_unpaired_surrogates_in_keys_and_nested_values(self):
        path = self.root/"unicode.json"
        for value in ({"value": "\ud800"}, {"value": ["\udfff"]}, {"\ud800": "value"},
                      {"value": {"nested": ["\ud800text\udfff"]}}):
            data = json.dumps(value).encode("utf-8")
            path.write_bytes(data)
            with self.subTest(value=ascii(value)):
                with self.assertRaisesRegex(InputError, "Invalid UTF-8 JSON"):
                    read_json(path)
                with self.assertRaises(InputError):
                    read_json(path, data=data)

    def test_json_preserves_valid_literal_and_escaped_unicode(self):
        path = self.root/"valid-unicode.json"
        expected = {"\U0001f600": {"text": ["\u00e9", "\U0001f600", "\\ud800"]}}
        for escaped in (False, True):
            path.write_text(json.dumps(expected, ensure_ascii=escaped), encoding="utf-8")
            with self.subTest(escaped=escaped):
                self.assertEqual(read_json(path), expected)

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

    def input_cell_report(self, token, markup, name, encoding="utf-8", linked=False):
        html = (FIXTURES/"mixed-trades-utf8.htm").read_text(encoding="utf-8")
        old = "<b>" + token + "</b>"
        self.assertEqual(html.count(old), 1)
        path = self.root/(name + ".htm")
        path.write_bytes(html.replace(old, markup, 1).encode(encoding))
        if not linked:
            return path, None
        run = json.loads((FIXTURES/"mixed-trades-result.json").read_text(encoding="utf-8"))
        data = path.read_bytes()
        run["artifacts"]["report"].update(path=str(path), sha256=digest(data), byte_length=len(data))
        run["fixture_notes"] = "Synthetic input-cell mutation; no tester was executed."
        run_path = self.root/(name + "-result.json")
        run_path.write_text(json.dumps(run), encoding="utf-8")
        return path, run_path

    def test_report_preserves_first_and_continuation_input_whitespace(self):
        values = (("<b>Caption=alpha </b>", "Caption=alpha "),
                  ("<b>Caption=alpha\t</b>", "Caption=alpha\t"),
                  ("<b>Caption=alpha\n</b>", "Caption=alpha\n"),
                  ("<b>Caption=alpha&#32;</b>", "Caption=alpha "),
                  ("<b>Caption=alpha&nbsp;</b>", "Caption=alpha\u00a0"),
                  ("<b>Caption=alpha<br></b>", "Caption=alpha\n"),
                  ("<b>Caption= alpha</b>", "Caption= alpha"))
        for encoding in ("utf-8", "utf-16"):
            for token, index in (("Info Panel=", 0), ("ForceChartSettings=true", 1)):
                for case, (markup, expected) in enumerate(values):
                    with self.subTest(encoding=encoding, row=index, value=ascii(expected)):
                        path, _ = self.input_cell_report(token, markup, f"input-{encoding}-{index}-{case}", encoding)
                        report = native_report(path)
                        self.assertEqual(report["conditions"]["effective_inputs"][index], expected)
                        self.assertEqual(report["metrics"]["net_profit"]["value"], "120.86")
                        self.assertEqual(report["sources"][0]["sha256"], digest(path.read_bytes()))
                        if index == 0:
                            self.assertEqual(report["configuration_evidence"]["Inputs"]["raw"], expected)

    def test_report_preserves_input_text_outside_or_across_bold_spans(self):
        cases = ("Caption=alpha ",
                 "<b>Caption=</b>alpha ",
                 "<b>Caption=</b><b>alpha </b>",
                 "<b></b>Caption=alpha ")
        for encoding in ("utf-8", "utf-16"):
            for case, markup in enumerate(cases):
                with self.subTest(encoding=encoding, markup=markup):
                    path, _ = self.input_cell_report("Info Panel=", markup, f"input-markup-{encoding}-{case}", encoding)
                    report = native_report(path)
                    self.assertEqual(report["conditions"]["effective_inputs"][0], "Caption=alpha ")
                    self.assertEqual(report["configuration_evidence"]["Inputs"]["raw"], "Caption=alpha ")

    def test_cli_comparison_distinguishes_input_whitespace_from_cell_padding(self):
        self.expectation(minimum="0")
        cases = (("space", "<b>Caption=alpha </b>", 3),
                 ("tab", "<b>Caption=alpha\t</b>", 3),
                 ("entity", "<b>Caption=alpha&#32;</b>", 3),
                 ("padding", " \t<b>Caption=alpha</b>\n ", 0))
        for encoding in ("utf-8", "utf-16"):
            for token, index in (("Info Panel=", 0), ("ForceChartSettings=true", 1)):
                baseline, baseline_run = self.input_cell_report(token, "<b>Caption=alpha</b>",
                    f"input-baseline-{encoding}-{index}", encoding, linked=True)
                for case, markup, expected_code in cases:
                    with self.subTest(encoding=encoding, row=index, case=case):
                        name = f"input-candidate-{encoding}-{index}-{case}"
                        candidate, candidate_run = self.input_cell_report(token, markup, name, encoding, linked=True)
                        output = self.root/(name+"-output")
                        process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"),
                            "report", "compare", "--baseline", str(baseline), "--candidate", str(candidate),
                            "--baseline-result", str(baseline_run), "--candidate-result", str(candidate_run),
                            "--expectations", str(self.root/"expectations.json"), "--output", str(output)],
                            capture_output=True)
                        self.assertEqual(process.returncode, expected_code, process.stderr)
                        self.assertNotIn(b"Traceback", process.stderr)
                        result = json.loads((output/"result.json").read_text(encoding="utf-8"))
                        self.assertEqual(result["exit_code"], expected_code)
                        self.assertEqual(result["compatibility"]["status"], "comparable" if expected_code == 0 else "incompatible")
                        self.assertEqual(result["expectations"]["status"], "pass" if expected_code == 0 else "not_evaluable")
                        self.assertEqual(result["metrics"]["net_profit"]["difference"]["value"], "0.00")
                        self.assertTrue((output/"summary.txt").is_file())
                        for recorded in (result["baseline"], result["candidate"]):
                            self.assertEqual(recorded["evidence_linkage"]["status"], "hash_verified")
                        if expected_code == 3:
                            changed = result["compatibility"]["differences"]
                            self.assertEqual([d["condition"] for d in changed], ["effective_inputs"])
                            self.assertNotEqual(changed[0]["baseline"][index], changed[0]["candidate"][index])

    def test_report_build_header_ignores_settings_and_footer_values(self):
        html = (FIXTURES/"mixed-trades-utf8.htm").read_text(encoding="utf-8")
        self.assertEqual(self.report()["terminal"]["build"], "6235")
        mutations = [
            ("Info Panel=", "Info Panel=My Label (Build 9001)"),
            ("ForceChartSettings=true", "Caption=Chart Label (Build 9001)"),
            ("FixtureMixedTrades", "FixtureMixedTrades (Build 9001)"),
            ("</table>", '<tr><td>Later note (Build 9001)</td></tr></table>'),
        ]
        for encoding in ("utf-8", "utf-16"):
            for index, (old, new) in enumerate(mutations):
                with self.subTest(encoding=encoding, field=old):
                    self.assertIn(old, html)
                    path = self.root/(f"build-in-value-{index}-{encoding}.htm")
                    path.write_text(html.replace(old, new, 1), encoding=encoding)
                    report = native_report(path)
                    self.assertEqual(report["terminal"]["build"], "6235")
                    self.assertEqual(report["terminal"]["report_header"], "Fixture-Server (Build 6235)")
                    self.assertEqual(report["metrics"]["net_profit"]["value"], "120.86")
                    self.assertEqual(report["sources"][0]["sha256"], digest(path.read_bytes()))
                    if index < 2:
                        self.assertIn(new, report["conditions"]["effective_inputs"])
                    elif index == 2:
                        self.assertEqual(report["configuration_evidence"]["Expert"]["raw"], new)
            duplicate = self.root/("duplicate-build-header-" + encoding + ".htm")
            duplicate.write_text(html.replace("Fixture-Server (Build 6235)",
                                              'Fixture-Server (Build 6235)</b><br></div></td></tr><tr><td><b>Second-Server (Build 7000)', 1), encoding=encoding)
            with self.assertRaisesRegex(InputError, "Ambiguous terminal build header"):
                native_report(duplicate)

    def test_input_build_text_cannot_supply_missing_terminal_evidence(self):
        html = (FIXTURES/"mixed-trades-utf8.htm").read_text(encoding="utf-8")
        html = html.replace("Fixture-Server (Build 6235)", "Fixture-Server", 1)
        html = html.replace("Info Panel=", "Info Panel=My Label (Build 9001)", 1)
        expectations = self.expectation(minimum="0")
        expectations["required_conditions"] = ["terminal_build"]
        for encoding in ("utf-8", "utf-16"):
            with self.subTest(encoding=encoding):
                path = self.root/("missing-header-" + encoding + ".htm")
                path.write_text(html, encoding=encoding)
                run = json.loads((FIXTURES/"mixed-trades-result.json").read_text(encoding="utf-8"))
                run["artifacts"]["report"].update(sha256=digest(path.read_bytes()), byte_length=path.stat().st_size)
                run_path = self.root/("missing-header-" + encoding + ".json")
                run_path.write_text(json.dumps(run), encoding="utf-8")
                report = native_report(path, run_path)
                self.assertIsNone(report["terminal"]["build"])
                self.assertIsNone(report["terminal"]["report_header"])
                self.assertIn("Info Panel=My Label (Build 9001)", report["conditions"]["effective_inputs"])
                compared = compare_reports(report, report, expectations)
                self.assertEqual(compared["compatibility"]["status"], "insufficient_evidence")
                self.assertIn("terminal_build", compared["compatibility"]["missing"])
                self.assertEqual(compared["expectations"]["status"], "not_evaluable")

    def test_missing_special_and_pair_preservation(self):
        for original, replacement, metric, state in [("Gross Loss:", "Unknown Gross Loss:", "gross_loss", "missing"), ("<b>1.82</b>", "<b>NaN</b>", "profit_factor", "special"), ("<b>34.50 (0.03%)</b>", "<b>bad</b>", "balance_drawdown_maximal_amount", "unparseable")]:
            report = native_report(self.mutate_report(original, replacement))
            self.assertEqual(report["metrics"][metric]["state"], state)

    def test_percentage_cannot_satisfy_money_ratio_or_count_expectations(self):
        baseline = self.report()
        for index, (cell, metric, unit) in enumerate([("120.86", "net_profit", "USD"),
                                                     ("1.82", "profit_factor", "ratio"),
                                                     ("110", "deals", "count")]):
            with self.subTest(metric=metric):
                path = self.mutate_report(f"<b>{cell}</b>", f"<b>{cell}%</b>")
                run = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
                run["artifacts"]["report"].update(sha256=digest(path.read_bytes()), byte_length=path.stat().st_size)
                run_path = self.root/"candidate-run.json"
                run_path.write_text(json.dumps(run), encoding="utf-8")
                candidate = native_report(path, run_path)
                self.assertEqual(candidate["evidence_linkage"]["status"], "hash_verified")
                value = candidate["metrics"][metric]
                self.assertEqual(value["state"], "unparseable")
                self.assertEqual(value["raw"], cell+"%")
                self.assertEqual(value["unit"], unit)
                self.assertEqual(value["reported_unit"], "percent")
                self.assertIsNone(value["value"])
                expectations = self.expectation(metric, minimum="0")
                comparison = compare_reports(baseline, candidate, expectations)
                self.assertEqual(comparison["compatibility"]["status"], "comparable")
                self.assertEqual(comparison["expectations"]["status"], "not_evaluable")
                output = self.root/f"unit-output-{index}"
                process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "report", "compare",
                                          "--baseline", str(FIXTURES/"mixed-trades.htm"), "--candidate", str(path),
                                          "--baseline-result", str(FIXTURES/"mixed-trades-result.json"),
                                          "--candidate-result", str(run_path), "--expectations", str(self.root/"expectations.json"),
                                          "--output", str(output)], capture_output=True)
                self.assertEqual(process.returncode, 4)
                self.assertEqual(json.loads((output/"result.json").read_text())["expectations"]["status"], "not_evaluable")
                self.assertNotIn(b"Traceback", process.stderr)

    def test_percentage_deposit_does_not_establish_test_conditions(self):
        path = self.mutate_report("<b>100 000.00</b>", "<b>100 000.00%</b>")
        run = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
        run["artifacts"]["report"].update(sha256=digest(path.read_bytes()), byte_length=path.stat().st_size)
        run_path = self.root/"candidate-run.json"
        run_path.write_text(json.dumps(run), encoding="utf-8")
        report = native_report(path, run_path)
        self.assertIsNone(report["conditions"]["deposit"])
        self.assertEqual(report["configuration_evidence"]["Initial Deposit"]["raw"], "100 000.00%")
        self.assertEqual(compare_reports(self.report(), report)["compatibility"]["status"], "insufficient_evidence")

    def test_count_measurements_require_nonnegative_integers(self):
        for raw in ('-1', '-1 234', '-1e2', '1.5', '1,234.5', '1e-3', '0.0000000000000000000001'):
            with self.subTest(raw=raw):
                measurement = number(raw, 'count')
                self.assertEqual(measurement['state'], 'unparseable')
                self.assertEqual(measurement['reason'], 'invalid_count')
                self.assertEqual(measurement['raw'], raw)
                self.assertEqual(measurement['unit'], 'count')
                self.assertIsNone(measurement['value'])
        for raw, value in [('0', '0'), ('-0.00', '-0.00'), ('1.00', '1.00'), ('1e2', '100'), ('1,234', '1234')]:
            self.assertEqual(number(raw, 'count')['value'], value)
        for raw, state in [(None, 'missing'), ('N/A', 'undefined'), ('NaN', 'special'), ('1.5%', 'unparseable')]:
            self.assertEqual(number(raw, 'count')['state'], state)
        for unit in (None, 'USD', 'ratio'):
            self.assertEqual(number('-1.5', unit)['state'], 'finite')

    def count_candidate(self, label, raw, encoding, name):
        html = (FIXTURES/'mixed-trades.htm').read_text(encoding='utf-16')
        pattern = '(' + re.escape(label) + r':</td>\s*<td[^>]*><b>)([^<]*)(</b>)'
        def replacement(match):
            _, separator, suffix = match[2].partition('(')
            return match[1] + raw + (' (' + suffix if separator else '') + match[3]
        changed, count = re.subn(pattern, replacement, html, count=1)
        self.assertEqual(count, 1)
        path = self.root/(name+'.htm')
        data = changed.encode(encoding)
        path.write_bytes(data)
        run = json.loads((FIXTURES/'mixed-trades-result.json').read_text(encoding='utf-8'))
        run['artifacts']['report'].update(sha256=digest(data), byte_length=len(data))
        run['fixture_derivation'] = 'Synthetic invalid/valid count mutation; not a tester execution'
        run_path = self.root/(name+'.json')
        run_path.write_text(json.dumps(run), encoding='utf-8')
        return path, run_path, native_report(path, run_path)

    def test_native_report_counts_cannot_evaluate_invalid_statistics(self):
        baseline = self.report()
        fields = [('Total Trades', 'trades'), ('Total Deals', 'deals'), ('Bars', 'bars'), ('Ticks', 'ticks'),
                  ('Symbols', 'symbols'), ('Profit Trades (% of total)', 'winning_trades'),
                  ('Loss Trades (% of total)', 'losing_trades'), ('Short Trades (won %)', 'short_trades'),
                  ('Long Trades (won %)', 'long_trades')]
        for encoding in ('utf-8', 'utf-16'):
            for label, metric in fields:
                for raw in ('1.5', '-1'):
                    with self.subTest(encoding=encoding, metric=metric, raw=raw):
                        path, _, report = self.count_candidate(label, raw, encoding, 'count-case')
                        value = report['metrics'][metric]
                        self.assertEqual(value['state'], 'unparseable')
                        self.assertEqual(value['reason'], 'invalid_count')
                        self.assertEqual(value['raw'], raw)
                        self.assertEqual(value['unit'], 'count')
                        self.assertGreater(value['evidence']['location']['row'], 0)
                        self.assertEqual(report['evidence_linkage']['status'], 'hash_verified')
                        expected = {'metrics': [{'metric': metric, 'target': 'candidate', 'minimum': '0'}]}
                        result = compare_reports(baseline, report, expected)
                        self.assertEqual(result['compatibility']['status'], 'comparable')
                        self.assertEqual(result['expectations']['status'], 'not_evaluable')
                        self.assertEqual(result['metrics'][metric]['difference']['state'], 'undefined')
                        if metric in ('bars', 'ticks', 'symbols'):
                            expected['required_conditions'] = [metric]
                            result = compare_reports(baseline, report, expected)
                            self.assertEqual(result['compatibility']['status'], 'insufficient_evidence')
                            self.assertIn(metric, result['compatibility']['missing'])
                        if metric+'_percent' in report['metrics']:
                            self.assertEqual(report['metrics'][metric+'_percent']['value'], baseline['metrics'][metric+'_percent']['value'])
                        self.assertEqual(report['sources'][0]['sha256'], digest(path.read_bytes()))
                        self.assertEqual(report['metrics']['net_profit']['value'], '120.86')
                        self.assertEqual(report['metrics']['gross_loss']['value'], '-146.98')

    def test_report_count_cli_expectations_and_evidence(self):
        cases = [('Total Trades', 'trades', '1.5', 4), ('Total Deals', 'deals', '-1', 4),
                 ('Ticks', 'ticks', '123.25', 4), ('Total Trades', 'trades', '56.00', 0)]
        for encoding in ('utf-8', 'utf-16'):
            for index, (label, metric, raw, code) in enumerate(cases):
                with self.subTest(encoding=encoding, metric=metric, raw=raw):
                    name = 'count-cli-'+encoding+'-'+str(index)
                    path, run_path, _ = self.count_candidate(label, raw, encoding, name)
                    self.expectation(metric, minimum='0')
                    originals = {p: p.read_bytes() for p in (path, run_path, self.root/'expectations.json')}
                    output = self.root/(name+'-output')
                    process = subprocess.run([sys.executable, '-B', str(SCRIPTS/'mql5_toolkit.py'), 'report', 'compare',
                        '--baseline', str(FIXTURES/'mixed-trades.htm'), '--baseline-result', str(FIXTURES/'mixed-trades-result.json'),
                        '--candidate', str(path), '--candidate-result', str(run_path),
                        '--expectations', str(self.root/'expectations.json'), '--output', str(output)], capture_output=True)
                    self.assertEqual(process.returncode, code, process.stderr)
                    self.assertNotIn(b'Traceback', process.stderr)
                    self.assertLess(len(process.stdout), 4096)
                    result = json.loads((output/'result.json').read_text(encoding='utf-8'))
                    self.assertEqual(result['status'], 'completed')
                    self.assertEqual(result['exit_code'], code)
                    self.assertEqual(result['compatibility']['status'], 'comparable')
                    self.assertEqual(result['expectations']['status'], 'pass' if code == 0 else 'not_evaluable')
                    measurement = result['metrics'][metric]['candidate']
                    self.assertEqual(measurement['state'], 'finite' if code == 0 else 'unparseable')
                    self.assertEqual(measurement['raw'], raw)
                    self.assertEqual(result['sources'][1]['sha256'], digest(originals[path]))
                    self.assertTrue((output/'summary.txt').is_file())
                    for selected, data in originals.items():
                        self.assertEqual(selected.read_bytes(), data)

    def test_unsupported_malformed_duplicate_layouts(self):
        for old, new in [("Settings</b>", "Einstellungen</b>"), ("</table>", ""), ("Gross Loss:", "Gross Profit:")]:
            with self.assertRaises(InputError):
                native_report(self.mutate_report(old, new))

    def test_report_rejects_crossed_and_unmatched_table_elements(self):
        original = (FIXTURES/"mixed-trades.htm").read_text(encoding="utf-16")
        table_end = original.index("</table>")
        for element in ("</td>", "</tr>"):
            start = original.rfind(element, 0, table_end)
            crossed = original[:start] + "</table>" + original[start:table_end] + original[table_end+8:]
            path = self.root/("crossed-" + element[2:-1] + ".htm")
            path.write_text(crossed, encoding="utf-8")
            with self.subTest(element=element), self.assertRaisesRegex(InputError, "Malformed table"):
                native_report(path)
        for old, new in (("</td>", "</th>"), ("</td>", "</td></td>"), ("</tr>", "</tr></tr>")):
            path = self.root/"unmatched-table.htm"
            path.write_text(original.replace(old, new, 1), encoding="utf-8")
            with self.subTest(replacement=new), self.assertRaisesRegex(InputError, "Malformed table"):
                native_report(path)

    def test_deposit_conditions_preserve_exact_decimal_identity(self):
        original = (FIXTURES/"mixed-trades.htm").read_text(encoding="utf-16")
        template = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
        amounts = ["100000.00000000000000000000000001", "100000.00000000000000000000000002"]
        reports = []
        for index, amount in enumerate(amounts):
            path = self.root/("deposit-" + str(index) + ".htm")
            text = original.replace("<b>100 000.00</b>", "<b>" + amount + "</b>")
            self.assertNotEqual(text, original)
            path.write_text(text, encoding="utf-8")
            linked = copy.deepcopy(template)
            linked["inputs"]["deposit"] = amount
            linked["artifacts"]["report"].update(sha256=digest(path.read_bytes()), byte_length=path.stat().st_size)
            run_path = self.root/("deposit-" + str(index) + ".json")
            run_path.write_text(json.dumps(linked), encoding="utf-8")
            report = native_report(path, run_path)
            self.assertEqual(report["conditions"]["deposit"], amount)
            self.assertFalse(report["issues"])
            reports.append(report)
        self.assertEqual(compare_reports(*reports)["compatibility"]["status"], "incompatible")
        linked["inputs"]["deposit"] = amounts[0]
        run_path.write_text(json.dumps(linked), encoding="utf-8")
        conflicted = native_report(path, run_path)
        self.assertTrue(any(i["code"] == "requested_reported_condition_difference" and i["condition"] == "deposit" for i in conflicted["issues"]))
        equivalent = copy.deepcopy(template)
        equivalent["inputs"]["deposit"] = "100000.0000"
        run_path.write_text(json.dumps(equivalent), encoding="utf-8")
        equivalent_report = native_report(FIXTURES/"mixed-trades.htm", run_path)
        self.assertEqual(compare_reports(self.report(), equivalent_report)["compatibility"]["status"], "comparable")

    def test_linkage_does_not_invent_success(self):
        path = self.mutate_report("120.86", "119.86")
        report = native_report(path, FIXTURES/"mixed-trades-result.json")
        self.assertEqual(report["evidence_linkage"]["status"], "mismatch")
        self.assertIsNone(report["conditions"]["model"])
        self.assertFalse(report["recorded_run"]["verified_execution"])
        self.assertEqual(compare_reports(self.report(), report)["compatibility"]["status"], "insufficient_evidence")

    def test_random_execution_mode_is_retained_for_native_reports(self):
        # Recorded settings are derived for import testing; these fixtures do
        # not establish a new tester run or its random-delay behavior.
        for name in ("no-trades", "profitable-only", "mixed-trades"):
            with self.subTest(fixture=name):
                run = json.loads((FIXTURES/(name+"-result.json")).read_text(encoding="utf-8"))
                run["inputs"]["execution_mode"] = -1
                path = self.root/(name+"-random-mode.json")
                path.write_text(json.dumps(run), encoding="utf-8")
                report = native_report(FIXTURES/(name+".htm"), path)
                self.assertEqual(report["conditions"]["execution_mode"], "-1")
                self.assertEqual(report["recorded_run"]["requested_settings"]["execution_mode"], -1)
                self.assertEqual(report["evidence_linkage"]["status"], "hash_verified")
                self.assertEqual(report["metrics"], self.report(name)["metrics"])
                self.assertFalse(report["recorded_run"]["verified_execution"])
                self.assertEqual(report["recorded_run"]["source"]["sha256"], digest(path.read_bytes()))

    def test_cli_random_execution_mode_comparisons_and_invalid_values(self):
        original = json.loads((FIXTURES/"mixed-trades-result.json").read_text(encoding="utf-8"))
        expectations = self.root/"execution-mode-expectations.json"
        expectations.write_text(json.dumps({"schema_version": 1, "metrics": [
            {"metric": "net_profit", "target": "candidate", "minimum": "120", "maximum": "121"}]}), encoding="utf-8")
        runs = []
        for mode in (-1, 0, 100):
            path = self.root/("execution-mode-"+str(mode)+".json")
            path.write_text(json.dumps({**original, "inputs": {**original["inputs"], "execution_mode": mode}}), encoding="utf-8")
            runs.append(path)
        for index, (candidate, code) in enumerate(((runs[0], 0), (runs[1], 3), (runs[2], 3))):
            output = self.root/("execution-comparison-"+str(index))
            process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "report", "compare",
                                      "--baseline", str(FIXTURES/"mixed-trades.htm"), "--candidate", str(FIXTURES/"mixed-trades.htm"),
                                      "--baseline-result", str(runs[0]), "--candidate-result", str(candidate),
                                      "--expectations", str(expectations), "--output", str(output)], capture_output=True)
            with self.subTest(candidate=candidate.name):
                self.assertEqual(process.returncode, code, process.stderr)
                compared = json.loads((output/"result.json").read_text(encoding="utf-8"))
                self.assertEqual(compared["compatibility"]["status"], "comparable" if code == 0 else "incompatible")
                self.assertEqual(compared["expectations"]["status"], "pass" if code == 0 else "not_evaluable")
                self.assertEqual(compared["metrics"]["net_profit"]["difference"]["value"], "0.00")
                if code:
                    self.assertEqual([item["condition"] for item in compared["compatibility"]["differences"]], ["execution_mode"])
        for index, mode in enumerate((-2, True, -1.0, "-1")):
            path = self.root/("invalid-execution-mode-"+str(index)+".json")
            path.write_text(json.dumps({**original, "inputs": {**original["inputs"], "execution_mode": mode}}), encoding="utf-8")
            original_bytes = path.read_bytes()
            output = self.root/("invalid-execution-output-"+str(index))
            process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "report", "read",
                                      "--input", str(FIXTURES/"mixed-trades.htm"), "--tester-result", str(path),
                                      "--output", str(output)], capture_output=True)
            with self.subTest(invalid_mode=mode):
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertNotIn(b"Traceback", process.stderr)
                self.assertEqual(json.loads((output/"result.json").read_text(encoding="utf-8"))["status"], "failed")
                self.assertTrue((output/"summary.txt").is_file())
                self.assertEqual(path.read_bytes(), original_bytes)

    def test_random_execution_mode_keeps_run_status_and_linkage_separate(self):
        original = json.loads((FIXTURES/"mixed-trades-result.json").read_text(encoding="utf-8"))
        original["inputs"]["execution_mode"] = -1
        original["status"] = "evidence_failed"
        path = self.root/"failed-random-mode-run.json"
        path.write_text(json.dumps(original), encoding="utf-8")
        report = native_report(FIXTURES/"mixed-trades.htm", path)
        self.assertEqual(report["evidence_linkage"]["status"], "hash_verified")
        self.assertEqual(report["recorded_run"]["status"], "evidence_failed")
        self.assertFalse(report["recorded_run"]["successful_status_recorded"])
        self.assertFalse(report["recorded_run"]["verified_execution"])
        expectations = self.expectation(minimum="0")
        expectations["require_successful_runs"] = True
        self.assertEqual(compare_reports(report, report, expectations)["expectations"]["status"], "not_evaluable")
        original["artifacts"]["report"]["sha256"] = "0"*64
        path.write_text(json.dumps(original), encoding="utf-8")
        mismatched = native_report(FIXTURES/"mixed-trades.htm", path)
        self.assertEqual(mismatched["evidence_linkage"]["status"], "mismatch")
        self.assertIsNone(mismatched["conditions"]["execution_mode"])
        self.assertEqual(compare_reports(report, mismatched)["compatibility"]["status"], "insufficient_evidence")

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

    def test_decimal_json_numbers_cannot_satisfy_string_fields(self):
        for key, value in (("minimum", 1.5), ("metric", 1.5)):
            document = {"schema_version": 1, "metrics": [{"metric": "net_profit", "target": "candidate", "minimum": "0"}]}
            document["metrics"][0][key] = value
            path = self.root/("numeric-" + key + ".json")
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.subTest(field=key), self.assertRaises(InputError):
                load_expectations(path)
        original = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
        for key in ("symbol", "period", "currency", "from_date", "to_date"):
            document = copy.deepcopy(original)
            document["inputs"][key] = 1.5
            path = self.root/("numeric-" + key + ".json")
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.subTest(field=key), self.assertRaises(InputError):
                native_report(FIXTURES/"mixed-trades.htm", path)

    def test_decimal_json_deposit_is_supported_and_published_exactly(self):
        path = self.mutate_report("<b>100 000.00</b>", "<b>100 000.125</b>")
        document = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
        document["inputs"]["deposit"] = 100000.125
        document["artifacts"]["report"].update(sha256=digest(path.read_bytes()), byte_length=path.stat().st_size)
        run_path = self.root/"decimal-deposit.json"
        run_path.write_text(json.dumps(document), encoding="utf-8")
        report = native_report(path, run_path)
        self.assertEqual(report["conditions"]["deposit"], "100000.125")
        self.assertFalse(report["issues"])
        output = self.root/"decimal-deposit-output"
        process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "report", "read",
                                  "--input", str(path), "--tester-result", str(run_path), "--output", str(output)], capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        recorded = json.loads((output/"result.json").read_text(encoding="utf-8"))
        self.assertEqual(recorded["recorded_run"]["requested_settings"]["deposit"], "100000.125")
        self.assertEqual(recorded["recorded_run"]["source"]["sha256"], digest(run_path.read_bytes()))

    def test_supplemental_numeric_conditions_ignore_equivalent_formatting(self):
        baseline = self.report()
        raw = baseline["metrics"]["history_quality"]["raw"]
        value = baseline["metrics"]["history_quality"]["value"]
        expectations = self.expectation(minimum="0")
        expectations["required_conditions"] = ["history_quality"]
        for suffix, expected in ((".00%", "comparable"), (".01%", "incompatible")):
            path = self.mutate_report("<b>" + raw + "</b>", "<b>" + value + suffix + "</b>")
            document = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
            document["artifacts"]["report"].update(sha256=digest(path.read_bytes()), byte_length=path.stat().st_size)
            run_path = self.root/"quality-run.json"
            run_path.write_text(json.dumps(document), encoding="utf-8")
            candidate = native_report(path, run_path)
            self.assertEqual(candidate["metrics"]["history_quality"]["raw"], value + suffix)
            compared = compare_reports(baseline, candidate, expectations)
            self.assertEqual(compared["compatibility"]["status"], expected)
            self.assertEqual(compared["expectations"]["status"], "pass" if expected == "comparable" else "not_evaluable")

    def test_invalid_recorded_run_fields_fail_without_tracebacks(self):
        original = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
        changes = [
            ("artifacts", []), ("inputs", []), ("binding", []),
            ("artifacts.report", []), ("artifacts.preset", []),
            ("binding.terminal_image", []), ("inputs.compilation_receipt", []),
            ("inputs.deposit", "bad"), ("inputs.deposit", "NaN"), ("inputs.deposit", "100000%"),
            ("inputs.expected_expert_sha256", "not-a-hash"),
            ("inputs.compilation_receipt.source_sha256", "not-a-hash"),
            ("artifacts.preset.sha256", "not-a-hash"),
            ("binding.terminal_image.sha256", "not-a-hash"),
        ]
        for index, (key, value) in enumerate(changes):
            with self.subTest(field=key, value=value):
                run = copy.deepcopy(original)
                target = run
                parts = key.split(".")
                for part in parts[:-1]:
                    target = target[part]
                target[parts[-1]] = value
                path = self.root/f"invalid-run-{index}.json"
                path.write_text(json.dumps(run), encoding="utf-8")
                with self.assertRaises(InputError):
                    native_report(FIXTURES/"mixed-trades.htm", path)
                out = self.root/f"invalid-run-output-{index}"
                process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"),
                                          "report", "read", "--input", str(FIXTURES/"mixed-trades.htm"),
                                          "--tester-result", str(path), "--output", str(out)], capture_output=True)
                self.assertEqual(process.returncode, 2)
                self.assertNotIn(b"Traceback", process.stderr)
                self.assertEqual(json.loads((out/"result.json").read_text())["status"], "failed")

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

    def test_json_sources_fingerprint_consumed_bytes(self):
        for operation in ("report", "expectations", "snapshot"):
            with self.subTest(operation=operation):
                changing = self.root/(operation+".json")
                if operation == "report":
                    document = json.loads((FIXTURES/"mixed-trades-result.json").read_text())
                    replacement = copy.deepcopy(document)
                    replacement["inputs"]["deposit"] = 200000
                    invoke = lambda: native_report(FIXTURES/"mixed-trades.htm", changing)
                    selected_source = lambda result: result["recorded_run"]["source"]
                elif operation == "expectations":
                    document = {"schema_version": 1, "metrics": [{"metric": "net_profit", "target": "candidate", "minimum": "0"}]}
                    replacement = copy.deepcopy(document)
                    replacement["metrics"][0]["minimum"] = "9999"
                    args = cli_parser().parse_args(["report", "compare", "--baseline", str(FIXTURES/"mixed-trades.htm"),
                                                   "--candidate", str(FIXTURES/"mixed-trades.htm"),
                                                   "--baseline-result", str(FIXTURES/"mixed-trades-result.json"),
                                                   "--candidate-result", str(FIXTURES/"mixed-trades-result.json"),
                                                   "--expectations", str(changing), "--output", str(self.root/"unused")])
                    invoke = lambda: execute(args)
                    selected_source = lambda result: result["expectation_source"]
                else:
                    root, external = self.project()
                    document = inventory(root, [], [external])
                    replacement = copy.deepcopy(document)
                    replacement["coverage"] = "uncertain"
                    candidate = self.root/"candidate-snapshot.json"
                    candidate.write_text(json.dumps(document), encoding="utf-8")
                    args = cli_parser().parse_args(["includes", "compare", "--baseline", str(changing),
                                                   "--candidate", str(candidate), "--output", str(self.root/"unused")])
                    invoke = lambda: execute(args)
                    selected_source = lambda result: result["sources"][0]
                original_bytes = json.dumps(document).encode("utf-8")
                changing.write_bytes(original_bytes)
                original_read = Path.read_bytes
                replaced = []

                def read_then_replace(path):
                    data = original_read(path)
                    if path == changing and not replaced:
                        path.write_text(json.dumps(replacement), encoding="utf-8")
                        replaced.append(True)
                    return data

                with patch.object(Path, "read_bytes", read_then_replace):
                    result = invoke()
                self.assertTrue(replaced)
                if operation == "report":
                    self.assertEqual(result["recorded_run"]["requested_settings"]["deposit"], 100000)
                elif operation == "expectations":
                    self.assertEqual(result["expectations"]["status"], "pass")
                else:
                    self.assertEqual(result["coverage"]["baseline"], document["coverage"])
                self.assertEqual(selected_source(result)["sha256"], digest(original_bytes))
                self.assertEqual(selected_source(result)["byte_length"], len(original_bytes))

    def test_profile_inventory_uses_compiler_root_standard_directory(self):
        fixture = Path(__file__).parent/'fixtures/angle-include-filename'
        copied = self.root/'profile-standard-directory'
        shutil.copytree(fixture, copied)
        root, mql5 = copied/'Project', copied/'MQL5'
        standard, entry = mql5/'Include', root/'Probe.mq5'
        for name in ("Owner's.mqh", 'Shared.mqh'):
            (mql5/name).write_text('// wrong-root decoy, not a standard header\n', encoding='utf-8')
        profile = self.root/'standard-profile.json'
        profile.write_text('{}', encoding='utf-8')
        validated = {'project_root': str(root), 'entrypoints': [str(entry)], 'include_path': str(mql5)}
        args = cli_parser().parse_args(['includes', 'inventory', '--project-profile', str(profile),
                                       '--output', str(self.root/'unused')])
        with patch('mql5_toolkit.validated_profile', return_value=validated):
            before = execute(args)
            self.assertEqual(before['include_roots'], [str(standard)])
            self.assertEqual(before['coverage'], 'selected_entrypoints_scanned')
            self.assertEqual(before['files'], inventory(root, [entry], [standard])['files'])
            for name in ("Owner's.mqh", 'Shared.mqh'):
                self.assertEqual(before['possible_consumers'][str(standard/name)], [str(entry)])
                self.assertNotIn(str(mql5/name), before['possible_consumers'])
            shared = standard/'Shared.mqh'
            shared.write_text('// independently specified shared-header change\n', encoding='utf-8')
            changed = execute(args)
            impact = compare_snapshots(before, changed)
            self.assertEqual([(item['path'], item['kind']) for item in impact['differences']], [(str(shared), 'changed')])
            self.assertEqual(impact['possible_affected_entrypoints'], [str(entry)])
            shared.unlink()
            removed = compare_snapshots(changed, execute(args))
            self.assertEqual([(item['path'], item['kind']) for item in removed['differences']], [(str(shared), 'removed')])
            self.assertEqual(removed['possible_affected_entrypoints'], [str(entry)])
            self.assertTrue(removed['differences'][0]['consumer_coverage_unknown'])

    def test_profile_missing_standard_directory_retains_known_sources(self):
        root, mql5 = self.root/'project', self.root/'MQL5'
        root.mkdir()
        mql5.mkdir()
        entry, local = root/'Probe.mq5', root/'Local.mqh'
        entry.write_text('#include "Local.mqh"\n#include <Missing.mqh>\n', encoding='utf-8')
        local.write_text('// known local header\n', encoding='utf-8')
        (mql5/'Missing.mqh').write_text('// cannot supply a native standard include\n', encoding='utf-8')
        profile = self.root/'missing-standard-profile.json'
        profile.write_text('{}', encoding='utf-8')
        validated = {'project_root': str(root), 'entrypoints': [str(entry)], 'include_path': str(mql5)}
        args = cli_parser().parse_args(['includes', 'inventory', '--project-profile', str(profile),
                                       '--output', str(self.root/'unused')])
        with patch('mql5_toolkit.validated_profile', return_value=validated):
            snapshot = execute(args)
            self.assertEqual(snapshot['coverage'], 'uncertain')
            self.assertEqual(snapshot['possible_consumers'][str(local)], [str(entry)])
            self.assertEqual([(edge['declaration'], edge['resolution']) for edge in snapshot['unresolved']],
                             [('<Missing.mqh>', 'unresolved')])
            self.assertEqual(snapshot['unresolved'][0]['searched_roots'], [str(mql5/'Include')])
            self.assertNotIn(str(mql5/'Missing.mqh'), snapshot['possible_consumers'])
            entry.write_text('#include "Local.mqh"\n', encoding='utf-8')
            self.assertEqual(execute(args)['coverage'], 'selected_entrypoints_scanned')
            validated['include_path'] = None
            self.assertEqual(execute(args)['include_roots'], [])

    def test_include_profile_changes_stop_inventory(self):
        root, external = self.project()
        profile = self.root/"profile.json"
        validated = {"project_root": str(root), "entrypoints": [str(root/"A.mq5")], "include_path": str(external)}
        args = cli_parser().parse_args(["includes", "inventory", "--project-profile", str(profile),
                                       "--output", str(self.root/"unused")])
        for stage in ("validation", "inventory"):
            with self.subTest(stage=stage):
                profile.write_text("{}", encoding="utf-8")

                def validate_then_change(*unused):
                    if stage == "validation":
                        profile.write_text('{"changed":true}', encoding="utf-8")
                    return validated

                def inventory_then_change(*args, **kwargs):
                    result = inventory(*args, **kwargs)
                    if stage == "inventory":
                        profile.write_text('{"changed":true}', encoding="utf-8")
                    return result

                with patch("mql5_toolkit.validated_profile", validate_then_change), patch("mql5_toolkit.inventory", inventory_then_change):
                    with self.assertRaisesRegex(InputError, "Project profile changed"):
                        execute(args)

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

    def test_include_directives_supported_physical_line_endings(self):
        lines = [
            '// comment before includes',
            "#include <Owner's.mqh>",
            'string quoted = "#include <Hidden.mqh>";',
            '/* multi-line comment',
            '#include "Hidden.mqh"',
            '*/',
            '#ifdef ENABLED',
            '#include "Shared.mqh"',
            '#endif',
            '#include <Last.mqh> // trailing comment',
        ]
        expected = [(2, 'include', "<Owner's.mqh>"), (7, 'ifdef', 'ENABLED'),
                    (8, 'include', '"Shared.mqh"'), (9, 'endif', ''),
                    (10, 'include', '<Last.mqh>')]
        for name, endings in (("LF", ("\n",)), ("CRLF", ("\r\n",)),
                              ("CR", ("\r",)), ("mixed", ("\r", "\n", "\r\n"))):
            with self.subTest(line_endings=name):
                text = ''.join(line + endings[i % len(endings)] for i, line in enumerate(lines))
                self.assertEqual(directives(text), expected)
                self.assertEqual(directives('/* incomplete' + endings[0]),
                                 [(2, 'unsupported', 'unterminated comment')])

    def test_unicode_text_keeps_physical_directive_lines(self):
        for separator in ('\u0085', '\u2028', '\u2029', '\u0085\u2028\u2029'):
            for ending in ('\n', '\r\n', '\r'):
                with self.subTest(separator=ascii(separator), ending=ascii(ending)):
                    header = 'Header' + separator + 'Name.mqh'
                    lines = ['string title="A' + separator + 'B";', '#include "' + header + '"',
                             '#ifdef ENABLED', '#include <' + header + '>', '#endif']
                    self.assertEqual(directives(ending.join(lines) + ending),
                                     [(2, 'include', '"' + header + '"'), (3, 'ifdef', 'ENABLED'),
                                      (4, 'include', '<' + header + '>'), (5, 'endif', '')])

    def test_unicode_header_shared_consumers_and_snapshots(self):
        header_name = 'Header\u0085\u2028\u2029Name.mqh'
        for index, ending in enumerate(('\n', '\r\n', '\r')):
            for encoding in ('utf-8-sig', 'utf-16'):
                with self.subTest(encoding=encoding, ending=ascii(ending)):
                    root = self.root / ('unicode-' + str(index) + '-' + encoding)
                    root.mkdir()
                    entries = [root/'A.mq5', root/'B.mq5']
                    code = ending.join(['#property strict', 'string label="A\u0085B\u2028C\u2029D";',
                                        '#include "' + header_name + '"', '#include "Shared.mqh"', ''])
                    entries[0].write_bytes(code.encode(encoding))
                    entries[1].write_bytes(('#include "' + header_name + '"' + ending).encode(encoding))
                    header, shared = root/header_name, root/'Shared.mqh'
                    header.write_bytes(('int HeaderValue(void) { return 7; }' + ending).encode(encoding))
                    shared.write_bytes(('int SharedValue(void) { return 2; }' + ending).encode(encoding))
                    originals = {p: p.read_bytes() for p in (*entries, header, shared)}
                    before = inventory(root, entries, [])
                    self.assertEqual(before['coverage'], 'selected_entrypoints_scanned')
                    self.assertEqual(before['unresolved'], [])
                    self.assertEqual(before['possible_consumers'].get(str(header)), sorted(map(str, entries)))
                    self.assertEqual([(e['line'], e['target']) for e in before['dependencies'] if e['source'] == str(entries[0])],
                                     [(3, str(header)), (4, str(shared))])
                    for path, data in originals.items():
                        self.assertEqual(path.read_bytes(), data)
                        self.assertEqual(next(f['sha256'] for f in before['files'] if f['path'] == str(path)), digest(data))
                    header.write_bytes(('int HeaderValue(void) { return 8; }' + ending).encode(encoding))
                    changed = inventory(root, entries, [])
                    impact = compare_snapshots(before, changed)
                    self.assertEqual([(d['path'], d['kind']) for d in impact['differences']], [(str(header), 'changed')])
                    self.assertEqual(impact['possible_affected_entrypoints'], sorted(map(str, entries)))
                    header.unlink()
                    removed = compare_snapshots(changed, inventory(root, entries, []))
                    self.assertEqual([(d['path'], d['kind']) for d in removed['differences']], [(str(header), 'removed')])
                    self.assertEqual(removed['possible_affected_entrypoints'], sorted(map(str, entries)))
                    self.assertTrue(removed['differences'][0]['consumer_coverage_unknown'])

    def test_genuine_unicode_include_separator_fixture(self):
        fixture = (Path(__file__).parent/'fixtures/unicode-include-separators').resolve()
        provenance = json.loads((fixture/'provenance.json').read_text(encoding='utf-8'))
        self.assertEqual(provenance['separator_codepoints'], ['U+0085', 'U+2028', 'U+2029'])
        self.assertEqual(len(provenance['variants']), 2)
        for variant in provenance['variants']:
            with self.subTest(encoding=variant['source_encoding']):
                folder = fixture/variant['directory']
                for record in variant['files']:
                    data = (folder/record['path']).read_bytes()
                    self.assertEqual((len(data), digest(data)), (record['byte_length'], record['sha256']))
                log = (folder/'native-compile.log').read_bytes()
                self.assertEqual(digest(log), variant['sanitized_log_sha256'])
                self.assertIn(b'Result: 0 errors, 0 warnings', log)
                self.assertEqual((variant['compilation_status'], variant['exit_code'], variant['errors'], variant['warnings']),
                                 ('success', 0, 0, 0))
                self.assertFalse(variant['syntax_only'])
                entry = folder/'Probe.mq5'
                snapshot = inventory(folder, [entry], [])
                self.assertEqual(snapshot['coverage'], 'selected_entrypoints_scanned')
                self.assertEqual(snapshot['unresolved'], [])
                self.assertEqual([e['line'] for e in snapshot['dependencies']], variant['expected_include_lines'])
                self.assertEqual([e['target'] for e in snapshot['dependencies']],
                                 [str(folder/path) for path in variant['expected_include_paths']])
                for name in variant['expected_include_paths']:
                    self.assertEqual(snapshot['possible_consumers'].get(str(folder/name)), [str(entry)])

    def test_cr_sources_keep_shared_header_consumers(self):
        for name, endings in (("lf", ("\n",)), ("crlf", ("\r\n",)),
                              ("cr", ("\r",)), ("mixed", ("\r", "\n", "\r\n"))):
            for encoding in ('utf-8', 'utf-16'):
                with self.subTest(line_endings=name, encoding=encoding):
                    root = self.root / (name + '-' + encoding)
                    root.mkdir()
                    shared, leaf = root/'Shared.mqh', root/'Leaf.mqh'
                    entries = [root/'A.mq5', root/'B.mq5']
                    logical = ['// comment', '#ifdef ENABLED', '#include "Shared.mqh"', '#endif']
                    data = ''.join(line + endings[i % len(endings)] for i, line in enumerate(logical)).encode(encoding)
                    for entry in entries:
                        entry.write_bytes(data)
                    shared.write_bytes(('// shared comment' + endings[0] + '#include "Leaf.mqh"' + endings[-1]).encode(encoding))
                    leaf.write_text('// original independently specified header\n', encoding='utf-8')
                    consumers = sorted(map(str, entries))
                    before = inventory(root, entries, [])
                    self.assertEqual(before['coverage'], 'selected_entrypoints_scanned')
                    self.assertEqual(before['possible_consumers'].get(str(leaf)), consumers)
                    for edge in before['dependencies']:
                        if edge['source'] in consumers:
                            self.assertEqual((edge['line'], edge['conditional_context'], edge['active_dependency']),
                                             (3, ['#ifdef ENABLED'], 'unknown'))
                    for entry in entries:
                        record = next(f for f in before['files'] if f['path'] == str(entry))
                        self.assertEqual(record['sha256'], digest(data))
                        self.assertEqual(entry.read_bytes(), data)
                    leaf.write_text('// changed independently specified header\n', encoding='utf-8')
                    changed = inventory(root, entries, [])
                    impact = compare_snapshots(before, changed)
                    self.assertEqual(impact['possible_affected_entrypoints'], consumers)
                    self.assertEqual([(f['path'], f['kind']) for f in impact['differences']], [(str(leaf), 'changed')])
                    leaf.unlink()
                    removed = compare_snapshots(changed, inventory(root, entries, []))
                    self.assertEqual(removed['possible_affected_entrypoints'], consumers)
                    self.assertEqual([(f['path'], f['kind']) for f in removed['differences']], [(str(leaf), 'removed')])
                    self.assertTrue(removed['differences'][0]['consumer_coverage_unknown'])

    def test_genuine_carriage_return_include_fixture(self):
        fixture = (Path(__file__).parent/'fixtures/carriage-return-includes').resolve()
        provenance = json.loads((fixture/'provenance.json').read_text(encoding='utf-8'))
        self.assertEqual(len(provenance['variants']), 2)
        for variant in provenance['variants']:
            with self.subTest(encoding=variant['source_encoding']):
                folder = fixture/variant['directory']
                for record in variant['files']:
                    data = (folder/record['path']).read_bytes()
                    self.assertEqual((len(data), digest(data)), (record['byte_length'], record['sha256']))
                log = (folder/'native-compile.log').read_bytes()
                self.assertEqual(digest(log), variant['sanitized_log_sha256'])
                self.assertEqual((variant['compilation_status'], variant['exit_code'], variant['errors'], variant['warnings']),
                                 ('success', 0, 0, 0))
                self.assertFalse(variant['syntax_only'])
                self.assertIn(b'including <fixture-root>\\First.mqh', log)
                self.assertIn(b'including <fixture-root>\\Shared.mqh', log)
                self.assertIn(b'Result: 0 errors, 0 warnings', log)
                entry = folder/'Probe.mq5'
                raw = entry.read_bytes()
                decoded = raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8')
                self.assertIn('\r', decoded)
                self.assertNotIn('\n', decoded)
                snapshot = inventory(folder, [entry], [])
                self.assertEqual(snapshot['coverage'], 'selected_entrypoints_scanned')
                self.assertEqual(snapshot['unresolved'], [])
                self.assertEqual([(e['line'], e['declaration']) for e in snapshot['dependencies']],
                                 [(2, '"First.mqh"'), (4, '"Shared.mqh"')])
                self.assertEqual(snapshot['possible_consumers'].get(str(folder/'Shared.mqh')), [str(entry)])
                source_record = next(f for f in snapshot['files'] if f['path'] == str(entry))
                self.assertEqual(source_record['sha256'], digest(raw))

    def test_angle_include_filename_keeps_following_directives(self):
        for prefix in ("#include ", "# include ", "/* leading */ #include /* before filename */ "):
            with self.subTest(prefix=prefix):
                text = '\n'.join([
                    'string text = "#include <decoy.mqh>";',
                    "ushort letter='<';",
                    'bool comparison=1<2;',
                    '/* #include <comment.mqh> */',
                    prefix + "<Owner's.mqh> // trailing comment",
                    '#ifdef ENABLE',
                    '#include "Local.mqh" /* trailing comment */',
                    '#endif',
                    '#include <Shared.mqh>',
                ])
                self.assertEqual(directives(text), [
                    (5, 'include', "<Owner's.mqh>"), (6, 'ifdef', 'ENABLE'),
                    (7, 'include', '"Local.mqh"'), (8, 'endif', ''),
                    (9, 'include', '<Shared.mqh>'),
                ])
        # An incomplete header name stays unsupported without consuming the
        # following directive as part of a fictitious character literal.
        self.assertEqual(directives("#include <Owner's.mqh\n#include <Shared.mqh>\n"),
                         [(1, 'include', "<Owner's.mqh"), (2, 'include', '<Shared.mqh>')])

    def test_genuine_angle_include_filename_fixture(self):
        fixture = (Path(__file__).parent/'fixtures/angle-include-filename').resolve()
        provenance = json.loads((fixture/'provenance.json').read_text(encoding='utf-8'))
        for file in provenance['files']:
            self.assertEqual(digest((fixture/file['path']).read_bytes()), file['sha256'])
        log = (fixture/'native-compile.log').read_bytes()
        self.assertEqual(digest(log), provenance['sanitized_log_sha256'])
        self.assertEqual((provenance['compilation_status'], provenance['errors'], provenance['warnings']),
                         ('success', 0, 0))
        self.assertIn(b"including <fixture-root>\\MQL5\\Include\\Owner's.mqh", log)
        self.assertIn(b'including <fixture-root>\\MQL5\\Include\\Shared.mqh', log)
        self.assertIn(b'Result: 0 errors, 0 warnings', log)
        entry = fixture/'Project/Probe.mq5'
        snapshot = inventory(entry.parent, [entry], [fixture/'MQL5/Include'])
        self.assertEqual(snapshot['coverage'], 'selected_entrypoints_scanned')
        self.assertEqual(snapshot['unresolved'], [])
        self.assertEqual([item['declaration'] for item in snapshot['dependencies']],
                         ["<Owner's.mqh>", '<Shared.mqh>'])
        for name in ("Owner's.mqh", 'Shared.mqh'):
            self.assertEqual(snapshot['possible_consumers'][str(fixture/'MQL5/Include'/name)], [str(entry)])

    def test_angle_filename_retains_changed_and_deleted_shared_consumers(self):
        fixture = Path(__file__).parent/'fixtures/angle-include-filename'
        copied = self.root/'angle-includes'
        shutil.copytree(fixture, copied)
        root, standard = copied/'Project', copied/'MQL5/Include'
        entry = root/'Probe.mq5'
        second = root/'Second.mq5'
        second.write_bytes(entry.read_bytes())
        shared, leaf = standard/'Shared.mqh', standard/'Leaf.mqh'
        shared.write_text('#include <Leaf.mqh>\nint SharedProbe(void) { return 2; }\n', encoding='utf-8')
        leaf.write_text('// independently specified first leaf version\n', encoding='utf-8')
        output = self.root/'angle-inventory-cli'
        process = subprocess.run([sys.executable, '-B', str(SCRIPTS/'mql5_toolkit.py'), 'includes', 'inventory',
                                  '--root', str(root), '--include-root', str(standard), '--output', str(output)],
                                 capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        before = json.loads((output/'result.json').read_text(encoding='utf-8'))
        consumers = sorted([str(entry), str(second)])
        self.assertEqual(before['possible_consumers'].get(str(leaf)), consumers)
        leaf.write_text('// independently specified changed leaf version\n', encoding='utf-8')
        changed = inventory(root, [], [standard])
        difference = compare_snapshots(before, changed)
        self.assertEqual([(item['path'], item['kind']) for item in difference['differences']], [(str(leaf), 'changed')])
        self.assertEqual(difference['possible_affected_entrypoints'], consumers)
        self.assertFalse(difference['differences'][0]['consumer_coverage_unknown'])
        leaf.unlink()
        deleted = inventory(root, [], [standard])
        difference = compare_snapshots(changed, deleted)
        self.assertEqual([(item['path'], item['kind']) for item in difference['differences']], [(str(leaf), 'removed')])
        self.assertEqual(difference['possible_affected_entrypoints'], consumers)
        self.assertTrue(difference['differences'][0]['consumer_coverage_unknown'])
        self.assertEqual(deleted['coverage'], 'uncertain')
        self.assertTrue(all(item['declaration'] == '<Leaf.mqh>' for item in deleted['unresolved']))

    @unittest.skipUnless(os.name == "nt", "Windows case-insensitive filename selection")
    def test_entrypoint_case_aliases_do_not_invent_source_changes(self):
        for index, filename in enumerate(("CaseEA.mq5", "Case\u00c9A.mq5")):
            with self.subTest(filename=filename):
                root = self.root/("case-project-" + str(index))
                root.mkdir()
                entry = root/filename
                header = root/"Shared.mqh"
                entry.write_text('#include "Shared.mqh"\nvoid OnTick() {}\n', encoding="utf-8")
                header.write_text('// initial independently recorded header\n', encoding="utf-8")
                alias = entry.with_name(filename.swapcase())
                self.assertTrue(alias.samefile(entry))
                baseline = inventory(root, [], [])
                output = self.root/("case-cli-" + str(index))
                process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "includes", "inventory",
                                          "--root", str(root), "--entrypoint", str(alias), "--output", str(output)], capture_output=True)
                self.assertEqual(process.returncode, 0, process.stderr)
                candidate = json.loads((output/"result.json").read_text(encoding="utf-8"))
                self.assertEqual(candidate["entrypoints"], [str(entry)])
                self.assertEqual(candidate["unselected_entrypoints"], [])
                self.assertEqual(candidate["coverage"], "selected_entrypoints_scanned")
                self.assertEqual(candidate["files"], baseline["files"])
                self.assertEqual(candidate["possible_consumers"], baseline["possible_consumers"])
                self.assertEqual(compare_snapshots(baseline, candidate)["differences"], [])
                header.write_text('// separately specified changed header\n', encoding="utf-8")
                changed = inventory(root, [selected_entrypoint(alias)], [])
                impact = compare_snapshots(candidate, changed)
                self.assertEqual([item["path"] for item in impact["differences"]], [str(header)])
                self.assertEqual(impact["possible_affected_entrypoints"], [str(entry)])
                self.assertFalse(impact["differences"][0]["consumer_coverage_unknown"])

    @unittest.skipUnless(os.name == "nt", "Windows case-insensitive filename selection")
    def test_entrypoint_case_alias_does_not_use_an_extra_source_slot(self):
        root = self.root/"case-budget-project"
        root.mkdir()
        entry = root/"CaseEA.mq5"
        entry.write_text('#include "Shared.mqh"\n', encoding="utf-8")
        (root/"Shared.mqh").write_text('// included project header\n', encoding="utf-8")
        alias = entry.with_name("caseea.mq5")
        self.assertTrue(alias.samefile(entry))
        # The two existing sources fill this controlled budget. Another spelling
        # of the same entrypoint must reuse that source's identity.
        with patch("toolkit_includes.MAX_SOURCE_FILES", 2):
            snapshot = inventory(root, [selected_entrypoint(alias)], [])
        self.assertEqual(len(snapshot["files"]), 2)
        self.assertEqual(snapshot["coverage"], "selected_entrypoints_scanned")

    def test_shared_source_changes_cannot_mix_dependency_versions(self):
        root, external = self.project()
        shared = external/"Shared.mqh"
        late = external/"Late.mqh"
        late.write_text('// independently shared dependency\n', encoding="utf-8")
        original_read = Path.read_bytes
        replaced = []

        def read_then_change(path):
            data = original_read(path)
            if path == shared and not replaced:
                shared.write_text('#include <Late.mqh>\n', encoding="utf-8")
                replaced.append(True)
            return data

        with patch.object(Path, "read_bytes", read_then_change):
            with self.assertRaisesRegex(InputError, "Source changed during inventory"):
                inventory(root, [], [external])
        self.assertTrue(replaced)
        # A fresh inventory has both consumers of the independently specified
        # dependency rather than mixing the old and new Shared.mqh declarations.
        stable = inventory(root, [], [external])
        self.assertEqual(stable["possible_consumers"][str(late)], [str(root/"A.mq5"), str(root/"B.mq5")])

    def test_source_limit_includes_the_last_external_header(self):
        root, external = self.root/"bounded-project", self.root/"bounded-standard"
        root.mkdir(); external.mkdir()
        (root/"Main.mq5").write_text('#include <External.mqh>\n', encoding="utf-8")
        (root/"Unused.mqh").write_text('// inventoried project source\n', encoding="utf-8")
        (external/"External.mqh").write_text('// reachable external source\n', encoding="utf-8")
        # The two project files already fill this controlled budget. The final
        # external header must not add a third source beyond that same limit.
        with patch("toolkit_includes.MAX_SOURCE_FILES", 2):
            with self.assertRaisesRegex(InputError, "bounded depth or file count"):
                inventory(root, [], [external])

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

    def test_invalid_include_snapshots_do_not_invent_consumers(self):
        root, external = self.project()
        valid = inventory(root, [], [external])
        key = str(root/"A.mq5")
        for value in ("EA.mq5", [42], [""]):
            bad = copy.deepcopy(valid)
            bad["possible_consumers"][key] = value
            with self.assertRaises(InputError):
                compare_snapshots(valid, bad)
        for field, value in (("sha256", "invalid"), ("byte_length", True), ("path", None)):
            bad = copy.deepcopy(valid)
            bad["files"][0][field] = value
            with self.assertRaises(InputError):
                compare_snapshots(valid, bad)
        bad = copy.deepcopy(valid)
        bad.pop("coverage")
        with self.assertRaises(InputError):
            compare_snapshots(valid, bad)

    def test_unreadable_subtrees_leave_consumer_coverage_uncertain(self):
        project = self.root/"scan-project"
        project.mkdir()
        entry = project/"Main.mq5"
        entry.write_text('void OnTick() {}', encoding="utf-8")
        hidden = project/"unreadable"
        failure = PermissionError(errno.EACCES, "Controlled scan failure", str(hidden))

        def interrupted_walk(root, *, followlinks=False, onerror=None):
            if onerror is not None:
                onerror(failure)
            yield str(root), [], ["Main.mq5"]

        with patch("toolkit_includes.os.walk", interrupted_walk):
            snapshot = inventory(project, [], [])
        self.assertEqual(snapshot["coverage"], "uncertain")
        self.assertEqual(snapshot["issues"], [{"code": "directory_scan_failed", "path": str(hidden), "errno": errno.EACCES}])
        self.assertEqual(snapshot["entrypoints"], [str(entry)])
        entry.write_text('void OnTick() { Print("changed"); }', encoding="utf-8")
        compared = compare_snapshots(snapshot, inventory(project, [], []))
        self.assertEqual(compared["possible_affected_entrypoints"], [str(entry)])
        self.assertTrue(compared["differences"][0]["consumer_coverage_unknown"])

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
        for folder in (external, other):
            self.assertEqual(snap["possible_consumers"][str(folder/"Shared.mqh")],
                             [str(root/"A.mq5"), str(root/"B.mq5")])
        before = snap
        (other/"Shared.mqh").write_text('#include <Leaf.mqh>\n', encoding="utf-8")
        (other/"Leaf.mqh").write_text("// nested candidate", encoding="utf-8")
        after = inventory(root, [], [external, other])
        diff = compare_snapshots(before, after)
        self.assertEqual([d["kind"] for d in diff["differences"]], ["added", "changed"])
        self.assertEqual(diff["possible_affected_entrypoints"], [str(root/"A.mq5"), str(root/"B.mq5")])
        self.assertTrue(all(d["consumer_coverage_unknown"] for d in diff["differences"]))

    def test_linked_include_paths_are_disclosed_without_traversal(self):
        root, external = self.project()
        alias = root/"linked"
        if os.name == "nt":
            quote = lambda p: "'" + str(p).replace("'", "''") + "'"
            process = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                                      "New-Item -ItemType Junction -Path " + quote(alias) +
                                      " -Target " + quote(external) + " | Out-Null"], capture_output=True)
            self.assertEqual(process.returncode, 0, process.stderr)
        else:
            alias.symlink_to(external, target_is_directory=True)
        (root/"A.mq5").write_text('#include "linked/Shared.mqh"\n', encoding="utf-8")
        snapshot = inventory(root, [root/"A.mq5"], [])
        self.assertEqual(snapshot["coverage"], "uncertain")
        self.assertNotIn(str(external/"Shared.mqh"), {f["path"] for f in snapshot["files"]})
        edge = snapshot["dependencies"][0]
        self.assertEqual(edge["resolution"], "linked_source_uncertainty")
        self.assertEqual(edge["linked_candidates"][0]["path"], str(alias/"Shared.mqh"))
        self.assertTrue(any(i["code"] == "linked_source_uncertainty" for i in snapshot["issues"]))

    def test_linked_entrypoints_are_not_resolved_before_inspection(self):
        root, external = self.project()
        target = external/"Outside.mq5"
        target.write_text('#include "Shared.mqh"\n', encoding="utf-8")
        alias = root/"Linked.mq5"
        try:
            alias.symlink_to(target)
        except OSError as exc:
            self.skipTest("File symlinks unavailable: " + str(exc))
        snap = inventory(root, [], [external])
        self.assertIn(str(alias), snap["entrypoints"])
        self.assertTrue(any(i["code"] == "linked_source_uncertainty" and i["path"] == str(alias) for i in snap["issues"]))
        self.assertNotIn(str(target), {f["path"] for f in snap["files"]})
        output = self.root/"linked-entry-cli"
        proc = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "includes", "inventory",
                               "--root", str(root), "--entrypoint", str(alias), "--output", str(output)], capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        read = json.loads((output/"result.json").read_text())
        self.assertEqual(read["entrypoints"], [str(alias)])
        self.assertEqual(read["coverage"], "uncertain")

    def test_cli_output_io_failures_are_tooling_failures(self):
        # The public exit-code contract classifies failed evidence writes as 2,
        # including failures after parsing succeeded or after a partial write.
        shim = """
from pathlib import Path
import errno
import sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
from mql5_toolkit import main
target = Path(sys.argv[3]) / sys.argv[4]
original_open = Path.open
class FullDiskStream:
    def __init__(self, stream):
        self.stream = stream
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.stream.close()
    def write(self, value):
        self.stream.write(value[:1])
        raise OSError(errno.ENOSPC, "simulated full evidence volume")
def failing_open(path, *args, **kwargs):
    if path != target:
        return original_open(path, *args, **kwargs)
    if sys.argv[5] == "permission":
        raise PermissionError(errno.EACCES, "simulated denied evidence write")
    return FullDiskStream(original_open(path, *args, **kwargs))
with patch.object(Path, "open", failing_open):
    sys.exit(main(["report", "read", "--input", sys.argv[2], "--output", sys.argv[3]]))
"""
        fixture = FIXTURES/"mixed-trades.htm"
        original = fixture.read_bytes()
        for artifact in ("result.json", "summary.txt"):
            for failure in ("permission", "full_disk"):
                with self.subTest(artifact=artifact, failure=failure):
                    output = self.root/(artifact + "-" + failure)
                    proc = subprocess.run([sys.executable, "-B", "-c", shim, str(SCRIPTS),
                                           str(fixture), str(output), artifact, failure], capture_output=True)
                    self.assertEqual(proc.returncode, 2, proc.stderr)
                    self.assertNotIn(b"Traceback", proc.stderr)
                    self.assertIn(b"incomplete", proc.stderr)
                    self.assertLess(len(proc.stderr), 256)
                    self.assertEqual(proc.stdout, b"")
                    self.assertTrue(output.is_dir())
                    self.assertEqual(fixture.read_bytes(), original)
                    if failure == "full_disk":
                        self.assertEqual(len((output/artifact).read_bytes()), 1)
                    else:
                        self.assertFalse((output/artifact).exists())
                    if artifact == "summary.txt":
                        recorded = json.loads((output/"result.json").read_text(encoding="utf-8"))
                        self.assertEqual(recorded["parsing"]["status"], "success")
                        self.assertEqual(recorded["metrics"]["net_profit"]["value"], "120.86")

    def test_cli_unicode_output_under_a_legacy_pipe_encoding(self):
        output = self.root/"analysis-\u7ed3\u679c"
        env = {**os.environ, "PYTHONIOENCODING": "ascii"}
        process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "report", "read",
                                  "--input", str(FIXTURES/"mixed-trades.htm"), "--output", str(output)],
                                 capture_output=True, env=env)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertNotIn(b"Traceback", process.stderr)
        self.assertIn(str(output), process.stdout.decode("utf-8"))
        self.assertEqual(process.stdout.decode("utf-8").splitlines(), (output/"summary.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(json.loads((output/"result.json").read_text())["exit_code"], 0)

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
