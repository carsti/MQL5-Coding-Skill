"""Exercise CI cancellation policy and native-command failure propagation."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml


REPO = Path(__file__).resolve().parents[1]
WORKFLOW = REPO / ".github/workflows/ci.yml"


class Expression:
    """Evaluate the small boolean/context subset used by our concurrency policy."""

    TOKEN = re.compile(r"\s*(\|\||&&|==|[()]|'[^']*'|[A-Za-z_][A-Za-z0-9_.]*)")

    def __init__(self, source, context):
        self.tokens = []
        position = 0
        while position < len(source.rstrip()):
            match = self.TOKEN.match(source, position)
            if not match:
                raise ValueError(f"Unsupported policy expression: {source[position:]}")
            self.tokens.append(match.group(1))
            position = match.end()
        self.position = 0
        self.context = context

    def parse(self):
        result = self.binary(0)
        if self.position != len(self.tokens):
            raise ValueError("Unconsumed policy expression")
        return result

    def binary(self, level):
        if level == 3:
            token = self.tokens[self.position]
            self.position += 1
            if token == "(":
                result = self.binary(0)
                if self.tokens[self.position] != ")":
                    raise ValueError("Unbalanced policy expression")
                self.position += 1
                return result
            if token.startswith("'"):
                return token[1:-1]
            if token in ("true", "false", "null"):
                return {"true": True, "false": False, "null": None}[token]
            value = self.context
            for key in token.split("."):
                value = value.get(key) if isinstance(value, dict) else None
            return value
        operator = ("||", "&&", "==")[level]
        result = self.binary(level + 1)
        while self.position < len(self.tokens) and self.tokens[self.position] == operator:
            self.position += 1
            right = self.binary(level + 1)
            if operator == "||":
                result = result or right
            elif operator == "&&":
                result = result and right
            else:
                result = result == right
        return result


def evaluate(value, context):
    if not isinstance(value, str):
        return value
    match = re.fullmatch(r"\s*\$\{\{(.*?)\}\}\s*", value)
    if not match:
        raise ValueError("Expected an expression")
    return Expression(match.group(1), context).parse()


def policy(workflow, event, ref="refs/heads/main", run_id=1, pr=None):
    context = {"github": {"workflow": "Skill CI", "event_name": event,
                          "ref": ref, "run_id": run_id,
                          "event": {"pull_request": {"number": pr}}}}
    concurrency = workflow["concurrency"]
    group = re.sub(r"\$\{\{(.*?)\}\}",
                   lambda match: str(Expression(match.group(1), context).parse() or ""),
                   concurrency["group"]).lower()
    return group, bool(evaluate(concurrency["cancel-in-progress"], context))


class ConcurrencyPolicy(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))

    def test_dispatch_cannot_cancel_push_validation(self):
        push = policy(self.workflow, "push", run_id=10)
        dispatch = policy(self.workflow, "workflow_dispatch", run_id=11)
        self.assertNotEqual(push[0], dispatch[0])
        self.assertFalse(dispatch[1])

    def test_running_main_and_tag_proofs_are_preserved(self):
        for ref in ("refs/heads/main", "refs/tags/v1.2.1"):
            with self.subTest(ref=ref):
                self.assertFalse(policy(self.workflow, "push", ref)[1])
        self.assertNotEqual(policy(self.workflow, "push")[0],
                            policy(self.workflow, "push", "refs/tags/v1.2.1")[0])

    def test_manual_runs_have_independent_groups(self):
        first = policy(self.workflow, "workflow_dispatch", run_id=20)
        second = policy(self.workflow, "workflow_dispatch", run_id=21)
        self.assertNotEqual(first[0], second[0])
        self.assertFalse(first[1])
        self.assertFalse(second[1])

    def test_only_superseded_runs_of_the_same_pr_are_cancelled(self):
        first = policy(self.workflow, "pull_request", "refs/pull/4/merge", 30, 4)
        newer = policy(self.workflow, "pull_request", "refs/pull/4/merge", 31, 4)
        other = policy(self.workflow, "pull_request", "refs/pull/5/merge", 32, 5)
        self.assertEqual(first[0], newer[0])
        self.assertNotEqual(first[0], other[0])
        self.assertTrue(newer[1])


class WorkflowHardening(unittest.TestCase):
    """Every workflow pins actions to commits and never persists checkout credentials."""

    PINNED = re.compile(r"(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?)@(?P<sha>[0-9a-f]{40})")

    def steps(self):
        for path in sorted((REPO / ".github/workflows").glob("*.yml")):
            workflow = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
            for job in workflow["jobs"].values():
                for step in job.get("steps", []):
                    yield path.name, step

    def test_actions_are_pinned_to_one_commit_each(self):
        pins = {}
        for name, step in self.steps():
            uses = step.get("uses")
            if uses is None or uses.startswith("./"):
                continue
            match = self.PINNED.fullmatch(uses)
            self.assertIsNotNone(match, f"{name}: {uses} is not pinned to a full commit SHA")
            # Dependabot moves every use of an action together.
            self.assertEqual(pins.setdefault(match["action"], match["sha"]), match["sha"], f"{name}: {uses}")
        self.assertIn("actions/checkout", pins)

    def test_checkouts_never_persist_credentials(self):
        checkouts = [(name, step) for name, step in self.steps() if step.get("uses", "").startswith("actions/checkout@")]
        self.assertTrue(checkouts)
        for name, step in checkouts:
            self.assertEqual(step.get("with", {}).get("persist-credentials"), "false", name)
            self.assertNotIn("ssh-key", step.get("with", {}), name)


@unittest.skipUnless(os.name == "nt", "Native PowerShell workflow execution")
class TestCommandFailures(unittest.TestCase):
    def setUp(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = workflow["jobs"]["validate"]["steps"]
        self.block = next(step["run"] for step in steps
                          if "test_selection_workflows.py" in step.get("run", "")
                          and "test_native_integration.py" in step.get("run", ""))
        self.hosts = [Path(os.environ["ProgramFiles"]) / "PowerShell/7/pwsh.exe",
                      Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"]

    def run_block(self, host, selection_exit, native_exit, demo_exit=0):
        with tempfile.TemporaryDirectory(prefix="mql5-ci-exits-") as temporary:
            root = Path(temporary)
            witness = root / "calls.jsonl"
            double = root / "python_double.py"
            double.write_text(
                "import json,pathlib,sys\n"
                f"witness=pathlib.Path({str(witness)!r})\n"
                "with witness.open('a',encoding='utf-8') as stream: stream.write(json.dumps(sys.argv[1:])+'\\n')\n"
                f"raise SystemExit({selection_exit} if 'test_selection_workflows.py' in sys.argv else {demo_exit} if 'test_native_demo.py' in sys.argv else {native_exit})\n",
                encoding="utf-8")
            quote = lambda path: "'" + str(path).replace("'", "''") + "'"
            script = root / "step.ps1"
            script.write_text(
                "$ErrorActionPreference = 'Stop'\n"
                f"function python {{ & {quote(sys.executable)} {quote(double)} @args }}\n"
                + self.block
                + "\nif ((Test-Path -LiteralPath variable:\\LASTEXITCODE)) { exit $LASTEXITCODE }\n",
                encoding="utf-8")
            environment = dict(os.environ)
            if host.name.lower() == "powershell.exe":
                environment["PSModulePath"] = ";".join([
                    str(Path(os.environ["USERPROFILE"]) / "Documents/WindowsPowerShell/Modules"),
                    str(Path(os.environ["ProgramFiles"]) / "WindowsPowerShell/Modules"),
                    str(Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/Modules")])
            result = subprocess.run([str(host), "-NoLogo", "-NoProfile", "-NonInteractive",
                                     "-ExecutionPolicy", "Bypass", "-File", str(script)],
                                    capture_output=True, text=True, timeout=20, env=environment)
            calls = [json.loads(line) for line in witness.read_text(encoding="utf-8").splitlines()]
            return result, calls

    def test_failed_selection_stops_before_native_tests(self):
        for host in self.hosts:
            with self.subTest(host=host.name):
                self.assertTrue(host.is_file())
                result, calls = self.run_block(host, 7, 0)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 1)

    def test_failed_native_tests_fail_the_step(self):
        for host in self.hosts:
            with self.subTest(host=host.name):
                result, calls = self.run_block(host, 0, 9)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 2)

    def test_both_successful_suites_complete(self):
        for host in self.hosts:
            with self.subTest(host=host.name):
                result, calls = self.run_block(host, 0, 0)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 3)

    def test_failed_demo_tests_fail_the_step(self):
        for host in self.hosts:
            with self.subTest(host=host.name):
                result, calls = self.run_block(host, 0, 0, 6)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
