"""MetaEditor native function CSV: UTF-16LE BOM, semicolon, six cells, no header."""
from __future__ import annotations

import csv
import io
import re
from decimal import Decimal
from pathlib import Path

from toolkit_common import InputError, compatibility, differences, digest, evaluate, fields, number, read_json, source, version

BUILD_KEYS = {"metaeditor_build", "profiling_optimizations", "profiling_inlining", "architecture", "environment_id"}


def native_profile(path: Path, conditions_path: Path | None = None) -> dict:
    data = path.read_bytes()
    if len(data) > 16 * 1024 * 1024 or not data.startswith(b"\xff\xfe"):
        raise InputError("Expected native UTF-16LE BOM MetaEditor CSV under 16 MiB")
    try:
        rows = list(csv.reader(io.StringIO(data.decode("utf-16")), delimiter=";", strict=True))
    except (csv.Error, UnicodeError) as exc:
        raise InputError("Malformed native profiler CSV") from exc
    entries, issues = [], []
    for index, row in enumerate(rows, 1):
        if not row:
            continue
        if len(row) != 6 or not re.fullmatch(r" *[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*", row[0], flags=re.ASCII) or not re.fullmatch(r"\d+", row[1]):
            raise InputError("Unsupported profiler layout: expected six headerless function-view cells")
        values = {"total_cpu_samples": number(row[2], "samples"), "total_cpu_percent": number(row[3], "percent"),
                  "self_cpu_samples": number(row[4], "samples"), "self_cpu_percent": number(row[5], "percent")}
        for key, value in values.items():
            if value["state"] == "finite":
                numeric = Decimal(value["value"])
                if numeric < 0 or key.endswith("samples") and numeric != numeric.to_integral_value() or key.endswith("percent") and numeric > 100:
                    raise InputError("Profiler samples/percentages are outside their native ranges")
        if not row[3].endswith("%") or not row[5].endswith("%"):
            raise InputError("Unsupported profiler percentage representation")
        entries.append({"function": row[0].lstrip(" "), "indentation": len(row[0])-len(row[0].lstrip(" ")), "reported_line": int(row[1]), "source_file": None,
                        "measurements": values, "evidence": {"row": index, "cells": row}})
    if not entries:
        raise InputError("Profiler export has no measurements")
    linkage, conditions, identity = {"status": "not_supplied"}, {"workload": None, "build_conditions": None, "source_identity": None}, {}
    if conditions_path:
        recorded = read_json(conditions_path)
        fields(recorded, {"schema_version", "profile_sha256"}, {"workload", "build_conditions", "source_identity", "source_sha256", "elapsed_duration_milliseconds", "notes"})
        version(recorded)
        if not isinstance(recorded["profile_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", recorded["profile_sha256"]):
            raise InputError("Conditions need the recorded export hash")
        for name in ("workload", "build_conditions"):
            if name in recorded and not isinstance(recorded[name], dict):
                raise InputError("Profiling conditions must be objects")
        build = recorded.get("build_conditions") or {}
        for key in BUILD_KEYS - {"metaeditor_build"}:
            if key in build and (not isinstance(build[key], str) or not build[key].strip()):
                raise InputError("Build condition must be a nonempty string")
        for key in ("profiling_optimizations", "profiling_inlining"):
            if key in build and build[key] not in {"enabled", "disabled"}:
                raise InputError("Profiling switch must record enabled or disabled")
        if "metaeditor_build" in build and (type(build["metaeditor_build"]) not in {int, str} or not re.fullmatch(r"[1-9]\d*", str(build["metaeditor_build"]))):
            raise InputError("Invalid recorded MetaEditor build")
        if "source_sha256" in recorded and (not isinstance(recorded["source_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", recorded["source_sha256"])):
            raise InputError("Invalid source hash")
        if "elapsed_duration_milliseconds" in recorded:
            elapsed = number(str(recorded["elapsed_duration_milliseconds"]), "milliseconds")
            if elapsed["state"] != "finite" or Decimal(elapsed["value"]) < 0:
                raise InputError("Elapsed duration must be a nonnegative finite decimal")
            recorded["elapsed_duration_milliseconds"] = elapsed
        if "source_identity" in recorded and (not isinstance(recorded["source_identity"], str) or not recorded["source_identity"].strip()):
            raise InputError("Compilation-unit identity must be a nonempty string")
        if recorded["profile_sha256"] == digest(data):
            linkage = {"status": "hash_verified", "source": source(conditions_path)}
            conditions["workload"] = recorded.get("workload") or None
            build = recorded.get("build_conditions") or {}
            conditions["build_conditions"] = build if BUILD_KEYS <= build.keys() and all(build[k] is not None for k in BUILD_KEYS) else None
            conditions["source_identity"] = recorded.get("source_identity")
            identity["source_sha256"] = recorded.get("source_sha256")
            identity["elapsed_duration_milliseconds"] = recorded.get("elapsed_duration_milliseconds")
            identity["recorded_build_conditions"] = build
        else:
            linkage = {"status": "mismatch", "source": source(conditions_path)}
            issues.append({"code": "profile_conditions_hash_mismatch"})
    identities = {}
    for entry in entries:
        entry["compilation_unit"] = conditions["source_identity"]
        key = entry["function"]
        identities.setdefault(key, []).append(entry)
    duplicates = [key for key, rows in identities.items() if len(rows) > 1]
    if duplicates:
        issues.append({"code": "duplicate_function_identity", "functions": duplicates})
    hotspots = sorted(entries, key=lambda e: Decimal(e["measurements"]["self_cpu_samples"]["value"]) if e["measurements"]["self_cpu_samples"]["state"] == "finite" else Decimal("-1"), reverse=True)
    return {"schema_version": 1, "operation": "profile read", "status": "completed", "sources": [source(path, data)],
            "parsing": {"status": "success", "format": "metaeditor-function-csv-v1", "encoding": "utf-16le-bom", "delimiter": ";", "headers": [],
                        "columns": ["function", "line", "total_cpu_samples", "total_cpu_percent", "self_cpu_samples", "self_cpu_percent"]},
            "entries": entries, "hotspots": hotspots, "duplicates": duplicates, "conditions": conditions,
            "evidence_linkage": linkage, "recorded_identity": identity, "issues": issues,
            "limitations": ["Native CSV omits individual source-file identities and full signatures; source identity is a separately recorded compilation-unit context", "CPU columns are sampling counts and percentages, not call counts or durations", "Inlining can hide functions; duplicates and missing mappings remain uncertain", "Percent distributions alone do not establish overall speed improvement"]}


def compare_profiles(a: dict, b: dict, expectations: dict | None = None) -> dict:
    required = list(dict.fromkeys(["workload", "build_conditions", "source_identity"] + (expectations or {}).get("required_conditions", [])))
    if set(required) - {"workload", "build_conditions", "source_identity"}:
        raise InputError("Unknown profiling condition")
    compatible = compatibility(a["conditions"], b["conditions"], required)
    ambiguous = bool(a["duplicates"] or b["duplicates"])
    if (expectations or {}).get("require_successful_runs"):
        compatible["missing"].append("profiler_export_has_no_tester_run_status")
        if compatible["status"] == "comparable":
            compatible["status"] = "insufficient_evidence"
    evidence = (expectations or {}).get("required_evidence", [])
    if set(evidence) - {"source_hash", "linked_conditions", "elapsed_duration"}:
        raise InputError("Unknown required profiling evidence")
    for name in evidence:
        present = all(x["evidence_linkage"]["status"] == "hash_verified" if name == "linked_conditions" else x["recorded_identity"].get("source_sha256" if name == "source_hash" else "elapsed_duration_milliseconds") is not None for x in (a, b))
        if not present:
            compatible["missing"].append(name)
            if compatible["status"] == "comparable":
                compatible["status"] = "insufficient_evidence"
    groups = [{e["function"]: e for e in x["entries"] if e["function"] not in x["duplicates"]} for x in (a, b)]
    metrics = {}
    same_context = a["conditions"]["source_identity"] is not None and a["conditions"]["source_identity"] == b["conditions"]["source_identity"]
    matched = sorted(groups[0].keys() & groups[1].keys()) if same_context else []
    if not matched and compatible["status"] == "comparable":
        compatible["status"] = "insufficient_evidence"
        compatible["missing"].append("unambiguous_function_mapping")
    for function in matched:
        for measurement in groups[0][function]["measurements"]:
            metrics[function + "." + measurement] = differences(groups[0][function]["measurements"][measurement], groups[1][function]["measurements"][measurement])
    return {"schema_version": 1, "operation": "profile compare", "status": "completed", "sources": a["sources"] + b["sources"],
            "baseline": a, "candidate": b, "compatibility": compatible, "matched_functions": matched,
            "mapping_status": "uncertain_source_context" if not same_context else "partial" if ambiguous else "unique",
            "unmatched": {"baseline": sorted(groups[0].keys()-set(matched)), "candidate": sorted(groups[1].keys()-set(matched))},
            "uncertain": {"baseline": a["duplicates"], "candidate": b["duplicates"]}, "metrics": metrics,
            "expectations": evaluate(expectations, metrics, compatible["status"] == "comparable"), "issues": a["issues"] + b["issues"],
            "speed_improvement_established": False}
