from __future__ import annotations

import copy
import json
from pathlib import Path
import unittest

import yaml
from validate_skill import validate_mcp_contract


class McpContractTests(unittest.TestCase):
    def setUp(self) -> None:
        root = Path(__file__).resolve().parents[1] / "skills" / "mql5-coding"
        self.contract = json.loads((root / "references" / "mcp-contract.json").read_text(encoding="utf-8"))
        self.metadata = yaml.safe_load((root / "agents" / "openai.yaml").read_text(encoding="utf-8"))

    def test_current_contract_matches_dependency(self) -> None:
        validate_mcp_contract(self.contract, self.metadata)

    def test_wrong_or_missing_dependency_is_rejected(self) -> None:
        for dependency in [[], [{"type": "mcp", "value": "wrong-server"}], [{"type": "app", "value": "mql5-chm"}]]:
            metadata = copy.deepcopy(self.metadata)
            metadata["dependencies"]["tools"] = dependency
            with self.assertRaises(AssertionError):
                validate_mcp_contract(self.contract, metadata)

    def test_optional_batch_contract_preserves_older_servers_and_rejects_invalid_bounds(self) -> None:
        older = copy.deepcopy(self.contract)
        del older["optional_tools"]
        validate_mcp_contract(older, self.metadata)
        for mutation in ["name", "empty-output", "boolean-bound", "inverted-bound"]:
            contract = copy.deepcopy(self.contract)
            batch = contract["optional_tools"]["mql5_chm_lookup_identifiers"]
            if mutation == "name":
                contract["optional_tools"] = {"unknown_tool": batch}
            elif mutation == "empty-output":
                batch["outputs"] = {}
            else:
                batch["array_bounds"]["identifiers"]["minimum"] = True if mutation == "boolean-bound" else 17
            with self.assertRaises(AssertionError):
                validate_mcp_contract(contract, self.metadata)

    def test_removed_tool_or_missing_commitments_is_rejected(self) -> None:
        for mutation in ["removed-tool", "empty-output", "unknown-version", "boolean-version"]:
            contract = copy.deepcopy(self.contract)
            if mutation == "removed-tool":
                del contract["tools"]["mql5_chm_read"]
            elif mutation == "empty-output":
                contract["tools"]["mql5_chm_status"]["outputs"] = {}
            else:
                contract["schema_version"] = True if mutation == "boolean-version" else 99
            with self.assertRaises(AssertionError):
                validate_mcp_contract(contract, self.metadata)

    def test_ci_uses_actual_peer_and_preserves_release_triggers(self) -> None:
        root = Path(__file__).resolve().parents[1]
        # BaseLoader preserves the Actions key 'on' rather than YAML 1.1 boolean coercion.
        workflow = yaml.load((root / ".github/workflows/skill-compatibility.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertEqual(workflow["on"]["workflow_call"]["secrets"]["MQL5_PEER_READ_KEY"]["required"], "true")
        pair = workflow["jobs"]["pair"]
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", pair["if"])
        checkouts = [step for step in pair["steps"] if step.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 2)
        for checkout in checkouts:
            self.assertEqual(checkout["with"]["persist-credentials"], "false")
        self.assertEqual(checkouts[1]["with"]["repository"], "${{ github.repository_owner }}/MQL5-CHM-MCP")
        self.assertEqual(checkouts[1]["with"]["ssh-key"], "${{ secrets.MQL5_PEER_READ_KEY }}")
        runs = "\n".join(step.get("run", "") for step in pair["steps"])
        self.assertIn("npm run build:candidate", runs)
        self.assertIn("--skill-root skill/skills/mql5-coding", runs)
        self.assertIn("--require-hashes -r skill/.github/requirements-ci.txt", runs)
        ci = yaml.load((root / ".github/workflows/ci.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        self.assertEqual(ci["jobs"]["compatibility"]["uses"], "./.github/workflows/skill-compatibility.yml")
        self.assertEqual(ci["jobs"]["compatibility"]["secrets"], "inherit")
        self.assertIn("v*", ci["on"]["push"]["tags"])


if __name__ == "__main__":
    unittest.main()
