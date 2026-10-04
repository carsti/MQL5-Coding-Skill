#!/usr/bin/env python3
"""Reusable MQL5 analysis CLI; all runtime dependencies are in the standard library."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from toolkit_common import InputError, absolute, load_expectations, publish, read_json, source
from toolkit_includes import compare_snapshots, inventory, selected_entrypoint, validated_profile
from toolkit_reports import compare_reports, native_report


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    families = result.add_subparsers(dest="family", required=True)
    for family, operations in (("report", ("read", "compare")), ("includes", ("inventory", "compare")), ("profile", ("read", "compare"))):
        commands = families.add_parser(family).add_subparsers(dest="command", required=True)
        for op in operations:
            command = commands.add_parser(op)
            command.add_argument("--output", required=True, help="New absolute output directory with existing parent")
            if op == "compare":
                command.add_argument("--baseline", required=True)
                command.add_argument("--candidate", required=True)
                if family != "includes":
                    command.add_argument("--expectations")
                if family == "report":
                    command.add_argument("--baseline-result")
                    command.add_argument("--candidate-result")
                if family == "profile":
                    command.add_argument("--baseline-conditions")
                    command.add_argument("--candidate-conditions")
            elif family == "includes":
                choice = command.add_mutually_exclusive_group(required=True)
                choice.add_argument("--project-profile")
                choice.add_argument("--root")
                command.add_argument("--entrypoint", action="append", default=[])
                command.add_argument("--include-root", action="append", default=[])
                command.add_argument("--powershell")
            else:
                command.add_argument("--input", required=True)
                command.add_argument("--tester-result" if family == "report" else "--conditions")
    return result


def optional(value: str | None) -> Path | None:
    return absolute(value, kind="file") if value else None


def execute(args) -> dict:
    expectations, expectation_source = None, None
    if args.family in {"report", "profile"} and args.command == "compare":
        expectation_path = optional(args.expectations)
        expectation_data = expectation_path.read_bytes() if expectation_path else None
        expectations = load_expectations(expectation_path, data=expectation_data)
        expectation_source = source(expectation_path, expectation_data) if expectation_path else None
    if args.family == "report":
        if args.command == "read":
            return native_report(absolute(args.input, kind="file"), optional(args.tester_result))
        baseline = native_report(absolute(args.baseline, kind="file"), optional(args.baseline_result))
        candidate = native_report(absolute(args.candidate, kind="file"), optional(args.candidate_result))
        result = compare_reports(baseline, candidate, expectations)
    elif args.family == "includes":
        if args.command == "compare":
            a, b = absolute(args.baseline, kind="file"), absolute(args.candidate, kind="file")
            a_data, b_data = a.read_bytes(), b.read_bytes()
            result = compare_snapshots(read_json(a, data=a_data), read_json(b, data=b_data))
            result["sources"] = [source(a, a_data), source(b, b_data)]
        else:
            profile_path = optional(args.project_profile)
            profile_data = None
            if profile_path:
                if args.entrypoint or args.include_root:
                    raise InputError("Profile mode uses saved entrypoints and include root without overrides")
                profile_data = profile_path.read_bytes()
                profile = validated_profile(profile_path, args.powershell)
                if profile_path.read_bytes() != profile_data:
                    raise InputError("Project profile changed during validation")
                root = absolute(profile["project_root"], kind="dir")
                entries = [selected_entrypoint(p) for p in profile["entrypoints"]]
                # Saved IncludePath is the compiler's MQL5 root; native angle
                # includes use its Include child. Preserve a missing or linked
                # child for inventory's unresolved/uncertain dependency checks.
                roots = [absolute(profile["include_path"], kind="dir") / "Include"] if profile["include_path"] else []
            else:
                root = absolute(args.root, kind="dir")
                entries = [selected_entrypoint(p) for p in args.entrypoint]
                roots = [absolute(p, kind="dir") for p in args.include_root]
            result = inventory(root, entries, roots, profile_path, profile_data=profile_data)
            if profile_path and profile_path.read_bytes() != profile_data:
                raise InputError("Project profile changed during inventory")
            return result
    else:
        from toolkit_profiles import native_profile, compare_profiles
        if args.command == "read":
            return native_profile(absolute(args.input, kind="file"), optional(args.conditions))
        baseline = native_profile(absolute(args.baseline, kind="file"), optional(args.baseline_conditions))
        candidate = native_profile(absolute(args.candidate, kind="file"), optional(args.candidate_conditions))
        result = compare_profiles(baseline, candidate, expectations)
    if expectation_source:
        result["expectation_source"] = expectation_source
    return result


def main(argv=None) -> int:
    # Pipes on Windows can inherit a legacy code page. Use the same UTF-8
    # encoding as the JSON/summary artifacts and the owned process reader.
    sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
    args = parser().parse_args(argv)
    try:
        output = absolute(args.output)
        # Exclusive creation prevents accidental overwrite, including two concurrent invocations.
        output.mkdir()
    except (InputError, OSError):
        print("Select a new absolute output directory with an existing parent", file=sys.stderr)
        return 2
    try:
        result = execute(args)
    except (InputError, OSError, UnicodeError, ValueError, KeyError, TypeError, RecursionError, subprocess.SubprocessError) as exc:
        result = {"schema_version": 1, "operation": args.family + " " + args.command, "status": "failed",
                  "issues": [{"code": "invalid_input_or_tooling", "message": str(exc) if isinstance(exc, InputError) else "Input processing failed; inspect the selected format, paths, and tooling"}]}
        if args.family in {"report", "profile"}:
            result["parsing"] = {"status": "failed"}
    return publish(output, result)


if __name__ == "__main__":
    sys.exit(main())
