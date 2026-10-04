from __future__ import annotations

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]/"skills/mql5-coding/scripts"
sys.path.insert(0, str(SCRIPTS))
from toolkit_common import InputError, digest
from toolkit_profiles import compare_profiles, native_profile

FIXTURES = Path(__file__).parent/"fixtures/profiles"


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mql5-profile-tests-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def profile(self, name="native-functions"):
        return native_profile(FIXTURES/(name+".csv"), FIXTURES/(name+"-conditions.json"))

    def test_genuine_measurements_and_indented_rows(self):
        report = self.profile()
        self.assertEqual(report["parsing"]["headers"], [])
        self.assertEqual(report["parsing"]["delimiter"], ";")
        self.assertEqual(len(report["entries"]), 4)
        self.assertEqual(report["hotspots"][0]["function"], "FixtureSeries")
        self.assertEqual(report["hotspots"][0]["measurements"]["self_cpu_samples"]["value"], "10716")
        self.assertEqual(report["entries"][1]["indentation"], 6)
        self.assertEqual(report["entries"][1]["reported_line"], 13)
        self.assertEqual(report["entries"][2]["measurements"]["self_cpu_percent"]["value"], "0.02")
        self.assertEqual(report["duplicates"], ["FixtureSeries"])
        self.assertIsNone(report["entries"][0]["source_file"])
        self.assertEqual(self.profile("native-functions-inlined")["entries"][0]["measurements"]["total_cpu_samples"]["value"], "9134")

    def test_matching_conditions_and_partial_mappings(self):
        a = self.profile()
        b = copy.deepcopy(a)
        result = compare_profiles(a, b)
        self.assertEqual(result["compatibility"]["status"], "comparable")
        self.assertEqual(result["matched_functions"], ["FixtureFold", "OnStart"])
        self.assertEqual(result["mapping_status"], "partial")
        self.assertEqual(result["uncertain"]["baseline"], ["FixtureSeries"])
        self.assertFalse(result["speed_improvement_established"])
        e = {"metrics": [{"metric": "OnStart.self_cpu_samples", "target": "difference", "maximum": "0"}]}
        self.assertEqual(compare_profiles(a, b, e)["expectations"]["status"], "pass")
        e["metrics"][0]["metric"] = "FixtureSeries.self_cpu_samples"
        self.assertEqual(compare_profiles(a, b, e)["expectations"]["status"], "not_evaluable")

    def test_incompatible_and_missing_conditions(self):
        self.assertEqual(compare_profiles(self.profile(), self.profile("native-functions-inlined"))["compatibility"]["status"], "incompatible")
        a = native_profile(FIXTURES/"native-functions.csv")
        self.assertEqual(compare_profiles(a, a)["compatibility"]["status"], "insufficient_evidence")
        a, b = self.profile(), self.profile()
        b["conditions"]["source_identity"] = "different-unit.mq5"
        result = compare_profiles(a, b)
        self.assertEqual(result["compatibility"]["status"], "incompatible")
        self.assertEqual(result["matched_functions"], [])
        self.assertEqual(result["unmatched"]["baseline"], ["FixtureFold", "OnStart"])
        self.assertEqual(result["unmatched"]["candidate"], ["FixtureFold", "OnStart"])

    def test_invalid_recorded_build_conditions(self):
        recorded = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        path = self.root/"conditions.json"
        for field, value in (("metaeditor_build", True), ("architecture", 64), ("architecture", 64.0), ("profiling_inlining", "unknown")):
            changed = copy.deepcopy(recorded)
            changed["build_conditions"][field] = value
            path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaises(InputError):
                native_profile(FIXTURES/"native-functions.csv", path)

    def test_elapsed_duration_requires_milliseconds(self):
        recorded = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        path = self.root/"conditions.json"
        recorded["elapsed_duration_milliseconds"] = "10.25"
        path.write_text(json.dumps(recorded), encoding="utf-8")
        report = native_profile(FIXTURES/"native-functions.csv", path)
        self.assertEqual(report["recorded_identity"]["elapsed_duration_milliseconds"]["unit"], "milliseconds")
        self.assertEqual(report["recorded_identity"]["elapsed_duration_milliseconds"]["value"], "10.25")
        recorded["elapsed_duration_milliseconds"] = "10.25%"
        path.write_text(json.dumps(recorded), encoding="utf-8")
        with self.assertRaises(InputError):
            native_profile(FIXTURES/"native-functions.csv", path)
        output = self.root/"invalid-elapsed-output"
        process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "profile", "read",
                                  "--input", str(FIXTURES/"native-functions.csv"), "--conditions", str(path),
                                  "--output", str(output)], capture_output=True)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(json.loads((output/"result.json").read_text())["status"], "failed")
        self.assertNotIn(b"Traceback", process.stderr)

    def test_equivalent_integer_and_string_builds_are_comparable(self):
        recorded = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        recorded["build_conditions"]["metaeditor_build"] = str(recorded["build_conditions"]["metaeditor_build"])
        path = self.root/"string-build.json"
        path.write_text(json.dumps(recorded), encoding="utf-8")
        candidate = native_profile(FIXTURES/"native-functions.csv", path)
        self.assertEqual(compare_profiles(self.profile(), candidate)["compatibility"]["status"], "comparable")
        self.assertIsInstance(candidate["recorded_identity"]["recorded_build_conditions"]["metaeditor_build"], str)
        self.assertIsInstance(self.profile()["recorded_identity"]["recorded_build_conditions"]["metaeditor_build"], int)

    def test_workload_json_types_and_numeric_equality(self):
        template = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        expectations = {"metrics": [{"metric": "OnStart.self_cpu_samples", "target": "candidate", "minimum": "0"}]}
        cases = ((True, 1, "incompatible"), (False, 0, "incompatible"), (1.5, "1.5", "incompatible"),
                 (1, "1", "incompatible"), (1, 1.0, "comparable"), (True, True, "comparable"))
        for index, (before, after, expected) in enumerate(cases):
            profiles = []
            for side, value in enumerate((before, after)):
                recorded = copy.deepcopy(template)
                recorded["workload"] = {"settings": [{"value": value}]}
                path = self.root/("workload-" + str(index) + "-" + str(side) + ".json")
                path.write_text(json.dumps(recorded), encoding="utf-8")
                profiles.append(native_profile(FIXTURES/"native-functions.csv", path))
            compared = compare_profiles(*profiles, expectations)
            with self.subTest(baseline=before, candidate=after):
                self.assertEqual(compared["compatibility"]["status"], expected)
                self.assertEqual(compared["expectations"]["status"], "pass" if expected == "comparable" else "not_evaluable")
                if expected == "incompatible":
                    kinds = compared["compatibility"]["differences"][0]["type_differences"]
                    self.assertEqual(kinds[0]["path"], ["workload", "settings", 0, "value"])
                    self.assertNotEqual(kinds[0]["baseline_type"], kinds[0]["candidate_type"])

    def test_decimal_condition_outputs_preserve_type_mismatch_evidence(self):
        template = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        paths = []
        for index, value in enumerate((1.5, "1.5")):
            recorded = copy.deepcopy(template)
            recorded["workload"] = {"value": value}
            recorded["elapsed_duration_milliseconds"] = 12.5
            path = self.root/("decimal-condition-" + str(index) + ".json")
            path.write_text(json.dumps(recorded), encoding="utf-8")
            paths.append(path)
        output = self.root/"decimal-condition-output"
        process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "profile", "compare",
                                  "--baseline", str(FIXTURES/"native-functions.csv"), "--candidate", str(FIXTURES/"native-functions.csv"),
                                  "--baseline-conditions", str(paths[0]), "--candidate-conditions", str(paths[1]), "--output", str(output)], capture_output=True)
        self.assertEqual(process.returncode, 3, process.stderr)
        self.assertNotIn(b"Traceback", process.stderr)
        recorded = json.loads((output/"result.json").read_text(encoding="utf-8"))
        difference = recorded["compatibility"]["differences"][0]
        self.assertEqual(difference["type_differences"], [{"path": ["workload", "value"], "baseline_type": "number", "candidate_type": "string"}])
        self.assertEqual(recorded["baseline"]["conditions"]["workload"]["value"], "1.5")
        self.assertEqual(recorded["baseline"]["recorded_identity"]["elapsed_duration_milliseconds"]["value"], "12.5")
        self.assertEqual(recorded["baseline"]["evidence_linkage"]["source"]["sha256"], digest(paths[0].read_bytes()))

    def test_cli_invalid_unicode_produces_complete_failure_evidence(self):
        template = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        workloads = ({"value": "\ud800"}, {"value": ["\udfff"]}, {"\ud800": "value"},
                     {"value": "\U0001f600\u00e9"})
        for index, workload in enumerate(workloads):
            path = self.root/("unicode-conditions-" + str(index) + ".json")
            path.write_text(json.dumps({**template, "workload": workload}), encoding="utf-8")
            original = path.read_bytes()
            output = self.root/("unicode-output-" + str(index))
            process = subprocess.run([sys.executable, "-B", str(SCRIPTS/"mql5_toolkit.py"), "profile", "read",
                                      "--input", str(FIXTURES/"native-functions.csv"), "--conditions", str(path),
                                      "--output", str(output)], capture_output=True)
            with self.subTest(workload=ascii(workload)):
                expected_code = 0 if index == 3 else 2
                self.assertEqual(process.returncode, expected_code, process.stderr)
                self.assertNotIn(b"Traceback", process.stderr)
                self.assertLess(len(process.stdout), 4096)
                recorded = json.loads((output/"result.json").read_text(encoding="utf-8"))
                self.assertEqual(recorded["exit_code"], expected_code)
                self.assertEqual(recorded["status"], "completed" if index == 3 else "failed")
                if index != 3:
                    self.assertEqual(recorded["issues"][0]["code"], "invalid_input_or_tooling")
                    self.assertEqual(recorded["issues"][0]["message"], "Invalid UTF-8 JSON")
                else:
                    self.assertEqual(recorded["conditions"]["workload"], workload)
                self.assertTrue((output/"summary.txt").is_file())
                self.assertEqual(path.read_bytes(), original)

    def test_hash_mismatch_and_explicit_evidence(self):
        conditions = json.loads((FIXTURES/"native-functions-conditions.json").read_text())
        conditions["profile_sha256"] = "0"*64
        path = self.root/"conditions.json"
        path.write_text(json.dumps(conditions), encoding="utf-8")
        report = native_profile(FIXTURES/"native-functions.csv", path)
        self.assertEqual(report["evidence_linkage"]["status"], "mismatch")
        self.assertIsNone(report["conditions"]["workload"])
        e = {"metrics": [{"metric": "OnStart.self_cpu_samples", "target": "candidate", "minimum": "0"}], "required_evidence": ["elapsed_duration"]}
        a = self.profile()
        self.assertEqual(compare_profiles(a, a, e)["expectations"]["status"], "not_evaluable")

    def test_conditions_source_fingerprints_consumed_bytes(self):
        original = (FIXTURES/"native-functions-conditions.json").read_bytes()
        path = self.root/"conditions.json"
        path.write_bytes(original)
        replacement = json.loads(original)
        replacement["workload"]["rounds"] = 9999
        original_read = Path.read_bytes
        replaced = []

        def read_then_replace(selected):
            data = original_read(selected)
            if selected == path and not replaced:
                selected.write_text(json.dumps(replacement), encoding="utf-8")
                replaced.append(True)
            return data

        with patch.object(Path, "read_bytes", read_then_replace):
            report = native_profile(FIXTURES/"native-functions.csv", path)
        self.assertTrue(replaced)
        self.assertEqual(report["conditions"]["workload"]["rounds"], 250)
        self.assertEqual(report["evidence_linkage"]["source"]["sha256"], digest(original))
        self.assertEqual(report["evidence_linkage"]["source"]["byte_length"], len(original))

    def test_unsupported_and_special_rows(self):
        cases = [b"function,count\nOnStart,20", "Function;Line;Total CPU;%;Self CPU;%\r\n".encode("utf-16"), "OnStart;16;1;105%;1;100%\r\n".encode("utf-16"), "OnStart;16;1.5;100%;1;100%\r\n".encode("utf-16")]
        path = self.root/"bad.csv"
        for data in cases:
            path.write_bytes(data)
            with self.assertRaises(InputError):
                native_profile(path)
        path.write_bytes("OnStart;16;0;0.00%;0;0.00%\r\n".encode("utf-16"))
        parsed = native_profile(path)
        self.assertEqual(parsed["entries"][0]["measurements"]["self_cpu_samples"]["value"], "0")

    def test_fixture_provenance(self):
        for root in (FIXTURES, Path(__file__).parent/"fixtures/reports"):
            provenance = json.loads((root/"provenance.json").read_text())
            for record in provenance["fixtures"]:
                extension = ".csv" if root == FIXTURES else ".htm"
                self.assertEqual(digest((root/(record["id"]+extension)).read_bytes()), record["sanitized_sha256"])


if __name__ == "__main__":
    unittest.main()
