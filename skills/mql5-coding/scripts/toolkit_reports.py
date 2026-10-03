"""Bounded structural reader for the English native MT5 Settings/Results layout."""
from __future__ import annotations

import re
from decimal import Decimal
from html.parser import HTMLParser
from pathlib import Path

from toolkit_common import InputError, canonical_decimal, compatibility, differences, digest, evaluate, number, read_json, source

CORE_CONDITIONS = ["symbol", "period", "reported_dates", "model", "deposit", "currency", "leverage", "execution_mode", "effective_inputs"]
SUCCESS = {"engine_smoke_passed", "application_marker_passed"}
LABELS = {
    "Total Net Profit": ("net_profit", "currency"), "Gross Profit": ("gross_profit", "currency"),
    "Gross Loss": ("gross_loss", "currency"), "Profit Factor": ("profit_factor", "ratio"),
    "Expected Payoff": ("expected_payoff", "currency"), "Total Trades": ("trades", "count"),
    "Total Deals": ("deals", "count"), "Recovery Factor": ("recovery_factor", "ratio"),
    "Sharpe Ratio": ("sharpe_ratio", "ratio"), "History Quality": ("history_quality", "percent"),
    "Bars": ("bars", "count"), "Ticks": ("ticks", "count"), "Symbols": ("symbols", "count"),
}
for axis in ("Balance", "Equity"):
    for kind in ("Absolute", "Maximal", "Relative"):
        LABELS[f"{axis} Drawdown {kind}"] = (f"{axis.lower()}_drawdown_{kind.lower()}", "currency")
PAIRS = {"Profit Trades (% of total)": "winning_trades", "Loss Trades (% of total)": "losing_trades",
         "Short Trades (won %)": "short_trades", "Long Trades (won %)": "long_trades"}


def recorded_object(value, name: str) -> dict:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise InputError("Tester-result " + name + " must be an object or null")
    return value


def recorded_hash(value, name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise InputError("Invalid tester-result " + name + " SHA-256")
    return value.lower()


def recorded_settings(run: dict) -> tuple[dict, dict, dict, dict]:
    artifacts = recorded_object(run.get("artifacts"), "artifacts")
    report = recorded_object(artifacts.get("report"), "artifacts.report")
    preset = recorded_object(artifacts.get("preset"), "artifacts.preset")
    settings = recorded_object(run.get("inputs"), "inputs")
    receipt = recorded_object(settings.get("compilation_receipt"), "inputs.compilation_receipt")
    binding = recorded_object(run.get("binding"), "binding")
    image = recorded_object(binding.get("terminal_image"), "binding.terminal_image")
    hashes = {
        "expert_sha256": recorded_hash(settings.get("expected_expert_sha256"), "EX5"),
        "source_sha256": recorded_hash(receipt.get("source_sha256"), "source"),
        "preset_sha256": recorded_hash(preset.get("sha256"), "preset"),
    }
    report_hash = recorded_hash(report.get("sha256"), "report")
    image_hash = recorded_hash(image.get("sha256"), "terminal")
    length = report.get("byte_length")
    if length is not None and (type(length) is not int or length < 0):
        raise InputError("Tester-result report byte_length must be a nonnegative integer")
    for key in ("model", "execution_mode", "leverage"):
        value = settings.get(key)
        if value is not None and (type(value) is not int or value < 0):
            raise InputError("Tester-result " + key + " must be a nonnegative integer")
    for key in ("symbol", "period", "currency", "from_date", "to_date"):
        value = settings.get(key)
        if value is not None and (not isinstance(value, str) or not value.strip()):
            raise InputError("Tester-result " + key + " must be a nonempty string")
    deposit = settings.get("deposit")
    if deposit is not None and (type(deposit) not in {int, Decimal, str} or number(str(deposit), "currency")["state"] != "finite"):
        raise InputError("Tester-result deposit must be a finite currency amount")
    return settings, report, hashes, {"report_hash": report_hash, "image_hash": image_hash}


class Tables(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows, self.row, self.cell = [], None, None
        self.cell_tag = None
        self.table = 0
        self.depth = 0
        self.row_index = 0
        self.title = []
        self.in_title = False
        self.generator = None
        self.bad = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "title":
            self.in_title = True
        if tag == "meta" and attrs.get("name", "").lower() == "generator":
            self.generator = attrs.get("content", "")
        if tag == "table":
            self.depth += 1
            if self.depth > 1:
                self.bad = True
            self.table += 1
            self.row_index = 0
        if tag == "tr":
            if not self.depth or self.row is not None:
                self.bad = True
            if self.depth:
                self.row_index += 1
                self.row = {"table": self.table, "row": self.row_index, "source_line": self.getpos()[0], "cells": []}
        if tag in {"td", "th"}:
            if self.row is None or self.cell is not None:
                self.bad = True
            if self.row is not None:
                self.cell, self.cell_tag = [], tag
        if tag == "br" and self.cell is not None:
            self.cell.append("\n")

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag in {"td", "th"}:
            if self.cell is None or self.row is None or tag != self.cell_tag:
                self.bad = True
            if self.cell is not None and self.row is not None:
                self.row["cells"].append("".join(self.cell).strip())
            self.cell, self.cell_tag = None, None
        if tag == "tr":
            if self.row is None or self.cell is not None:
                self.bad = True
            if self.row is not None:
                self.rows.append(self.row)
            self.row, self.cell, self.cell_tag = None, None, None
        if tag == "table":
            if self.row is not None or self.cell is not None:
                self.bad = True
            self.depth -= 1
            if self.depth < 0:
                self.bad = True

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)
        if self.in_title:
            self.title.append(data)


def decoded(data: bytes) -> tuple[str, str]:
    try:
        if data.startswith(b"\xff\xfe"):
            return data.decode("utf-16"), "utf-16le-bom"
        if data.startswith(b"\xfe\xff"):
            raise InputError("UTF-16BE is unsupported")
        text = data.decode("utf-8-sig")
        if "\x00" in text:
            raise InputError("UTF-16 requires a little-endian BOM")
        return text, "utf-8-bom" if data.startswith(b"\xef\xbb\xbf") else "utf-8"
    except UnicodeError as exc:
        raise InputError("Unsupported report encoding") from exc


def native_report(path: Path, result_path: Path | None = None) -> dict:
    data = path.read_bytes()
    if len(data) > 64 * 1024 * 1024:
        raise InputError("Report exceeds 64 MiB")
    text, encoding = decoded(data)
    parser = Tables()
    parser.feed(text)
    parser.close()
    if parser.bad or parser.depth or parser.row is not None or parser.cell is not None:
        raise InputError("Malformed table structure")
    headings = {c for r in parser.rows for c in r["cells"] if len(r["cells"]) == 1}
    if "Strategy Tester Report" not in "".join(parser.title) or parser.generator != "strategy tester" or not {"Settings", "Results"} <= headings:
        raise InputError("Unsupported report layout or language; expected English MT5 Settings/Results")
    records, inputs, issues = {}, [], []
    section, input_mode = None, False
    for row in parser.rows:
        cells = row["cells"]
        if len(cells) == 1 and cells[0] in {"Settings", "Results", "Orders", "Deals"}:
            section, input_mode = cells[0], False
            continue
        if section not in {"Settings", "Results"}:
            continue
        if input_mode and len(cells) == 2 and not cells[0] and cells[1]:
            inputs.append(cells[1])
            continue
        for idx, label in enumerate(cells[:-1]):
            if not label.endswith(":"):
                continue
            key = label[:-1]
            if key in records:
                raise InputError("Duplicate native statistic or configuration label: " + key)
            record = {"label": label, "raw": cells[idx+1], "location": {k: row[k] for k in ("table", "row", "source_line")}}
            record["location"]["label_cell"] = idx + 1
            record["location"]["value_cell"] = idx + 2
            records[key] = record
            input_mode = key == "Inputs"
            if input_mode and record["raw"]:
                inputs.append(record["raw"])
    if not {"Expert", "Symbol", "Period"} & records.keys() or not LABELS.keys() & records.keys():
        raise InputError("Unsupported report contents")
    raw = lambda key: records.get(key, {}).get("raw")
    currency = raw("Currency") or None
    metrics = {}
    for label, (key, unit) in LABELS.items():
        unit = currency if unit == "currency" and currency else unit
        value = raw(label)
        record = records.get(label)
        if "Drawdown" in label and not label.endswith("Absolute"):
            match = re.fullmatch(r"(.+?)\s*\((.+?)\)", value or "")
            first, second = (match.group(1), match.group(2)) if match else (None, None)
            if label.endswith("Relative"):
                first, second = second, first
            metrics[key + "_amount"] = {**number(first, unit), "evidence": record}
            metrics[key + "_percent"] = {**number(second, "percent"), "evidence": record}
            if value is not None and not match:
                metrics[key + "_amount"] = {**number(value, unit), "state": "unparseable", "value": None, "evidence": record}
                issues.append({"code": "unparseable_drawdown_pair", "label": label})
        else:
            metrics[key] = {**number(value, unit), "evidence": record}
    for label, key in PAIRS.items():
        match = re.fullmatch(r"(.+?)\s*\((.+?)\)", raw(label) or "")
        metrics[key] = {**number(match.group(1) if match else raw(label), "count"), "evidence": records.get(label)}
        metrics[key + "_percent"] = {**number(match.group(2) if match else None, "percent"), "evidence": records.get(label)}
    period = re.fullmatch(r"(.+?)\s*\((\d{4}\.\d{2}\.\d{2})\s*-\s*(\d{4}\.\d{2}\.\d{2})\)", raw("Period") or "")
    deposit = number(raw("Initial Deposit"), currency or "currency")
    leverage = re.fullmatch(r"1:(\d+)", raw("Leverage") or "")
    conditions = {"symbol": raw("Symbol") or None, "period": period.group(1) if period else None,
                  "reported_dates": [period.group(2), period.group(3)] if period else None,
                  "model": None, "deposit": canonical_decimal(deposit["value"]) if deposit["state"] == "finite" else None,
                  "currency": currency, "leverage": leverage.group(1) if leverage else None,
                  "execution_mode": None, "effective_inputs": inputs if "Inputs" in records else None}
    linkage = {"status": "not_supplied"}
    build_headers = [(row, cell, re.fullmatch(r"(.+) \(Build (\d+)\)", cell)) for row in parser.rows for cell in row["cells"]]
    build_headers = [(row, cell, match) for row, cell, match in build_headers if match]
    if len(build_headers) > 1:
        raise InputError("Ambiguous terminal build header")
    terminal = {"build": build_headers[0][2].group(2) if build_headers else None,
                "report_header": build_headers[0][1] if build_headers else None}
    recorded_run, artifacts = None, {}
    if result_path:
        run_data = result_path.read_bytes()
        run = read_json(result_path, data=run_data)
        if type(run.get("schema_version")) is not int or run["schema_version"] != 2 or not isinstance(run.get("status"), str):
            raise InputError("Unsupported tester-result schema")
        settings, recorded_report, recorded_artifacts, verified_fields = recorded_settings(run)
        recorded_run = {"status": run["status"], "run_id": run.get("run_id"), "source": source(result_path, run_data),
                        "successful_status_recorded": run["status"] in SUCCESS, "verified_execution": False}
        if verified_fields["report_hash"] != digest(data) or recorded_report.get("byte_length") != len(data):
            linkage = {"status": "mismatch", "recorded_report": recorded_report}
            issues.append({"code": "report_hash_or_length_mismatch", "message": "Run settings are not associated with this report"})
        else:
            linkage = {"status": "hash_verified", "recorded_report": recorded_report}
            conditions["model"] = str(settings["model"]) if type(settings.get("model")) is int else None
            conditions["execution_mode"] = str(settings["execution_mode"]) if type(settings.get("execution_mode")) is int else None
            # Requested dates are retained independently; never replace reported coverage.
            recorded_run["requested_settings"] = {k: settings.get(k) for k in ("symbol", "period", "from_date", "to_date", "model", "deposit", "currency", "leverage", "execution_mode")}
            for key in ("symbol", "period", "currency", "leverage", "deposit"):
                requested = settings.get(key)
                if requested is None or conditions[key] is None:
                    continue
                requested = canonical_decimal(number(str(requested), "currency")["value"]) if key == "deposit" else str(requested)
                if requested != conditions[key]:
                    issues.append({"code": "requested_reported_condition_difference", "condition": key, "requested": requested, "reported": conditions[key]})
            artifacts = recorded_artifacts
            terminal["image_sha256"] = verified_fields["image_hash"]
    return {"schema_version": 1, "operation": "report read", "status": "completed", "sources": [source(path, data)],
            "parsing": {"status": "success", "format": "mt5-english-settings-results-v1", "encoding": encoding},
            "evidence_linkage": linkage, "recorded_run": recorded_run, "conditions": conditions, "configuration_evidence": records,
            "metrics": metrics, "artifact_identity": artifacts, "terminal": terminal,
            "data_quality": {k: metrics[k] for k in ("history_quality", "bars", "ticks", "symbols")}, "issues": issues,
            "limitations": ["Statistics are native report values, not recalculated", "Report parsing and a recorded run status do not verify execution", "Headline statistics do not establish identical trading behavior", "Missing terminal build and requested/reported date differences remain evidence gaps"]}


def compare_reports(a: dict, b: dict, expectations: dict | None = None) -> dict:
    required = list(dict.fromkeys(CORE_CONDITIONS + (expectations or {}).get("required_conditions", [])))
    allowed = set(CORE_CONDITIONS) | {"terminal_image_sha256", "terminal_build", "history_quality", "bars", "ticks", "symbols"}
    if set(required) - allowed:
        raise InputError("Unknown report comparison condition")
    conditions = []
    for report in (a, b):
        values = dict(report["conditions"])
        values.update(terminal_image_sha256=report["terminal"].get("image_sha256"), terminal_build=report["terminal"].get("build"))
        values.update({k: canonical_decimal(v["value"]) if v["state"] == "finite" else None for k, v in report["data_quality"].items()})
        conditions.append(values)
    compatible = compatibility(*conditions, required)
    linkage_ok = all(x["evidence_linkage"]["status"] != "mismatch" for x in (a, b))
    gaps = []
    if not linkage_ok:
        gaps.append("report_run_linkage")
    if any(i["code"] == "requested_reported_condition_difference" for x in (a, b) for i in x["issues"]):
        gaps.append("conflicting_recorded_conditions")
    requested = (expectations or {}).get("required_evidence", [])
    if set(requested) - {"linked_run", "source_hash", "expert_hash", "preset_hash"}:
        raise InputError("Unknown required report evidence")
    for name in requested:
        for report in (a, b):
            present = report["evidence_linkage"]["status"] == "hash_verified" if name == "linked_run" else report["artifact_identity"].get({"source_hash": "source_sha256", "expert_hash": "expert_sha256", "preset_hash": "preset_sha256"}[name])
            if not present:
                gaps.append(name)
    if (expectations or {}).get("require_successful_runs") and not all(x["recorded_run"] and x["recorded_run"]["successful_status_recorded"] and x["evidence_linkage"]["status"] == "hash_verified" for x in (a, b)):
        gaps.append("successful_recorded_runs")
    compatible["missing"].extend(sorted(set(gaps)))
    if compatible["status"] == "comparable" and gaps:
        compatible["status"] = "insufficient_evidence"
    metrics = {key: differences(a["metrics"].get(key, number(None)), b["metrics"].get(key, number(None))) for key in sorted(a["metrics"].keys() | b["metrics"].keys())}
    return {"schema_version": 1, "operation": "report compare", "status": "completed", "sources": a["sources"] + b["sources"],
            "baseline": a, "candidate": b, "compatibility": compatible, "metrics": metrics,
            "expectations": evaluate(expectations, metrics, compatible["status"] == "comparable"),
            "artifact_identity_changes": {k: {"baseline": a["artifact_identity"].get(k), "candidate": b["artifact_identity"].get(k)} for k in a["artifact_identity"].keys() | b["artifact_identity"].keys() if a["artifact_identity"].get(k) != b["artifact_identity"].get(k)},
            "supplemental_differences": {"terminal": {"baseline": a["terminal"], "candidate": b["terminal"]}, "data_quality": {"baseline": a["data_quality"], "candidate": b["data_quality"]}},
            "issues": a["issues"] + b["issues"]}
