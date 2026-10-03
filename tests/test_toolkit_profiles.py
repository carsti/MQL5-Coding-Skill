from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

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
        for field, value in (("metaeditor_build", True), ("architecture", 64), ("profiling_inlining", "unknown")):
            changed = copy.deepcopy(recorded)
            changed["build_conditions"][field] = value
            path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaises(InputError):
                native_profile(FIXTURES/"native-functions.csv", path)

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
