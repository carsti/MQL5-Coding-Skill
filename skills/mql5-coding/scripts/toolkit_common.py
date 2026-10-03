"""Standard-library evidence primitives. JSON never contains binary floats."""
from __future__ import annotations

import hashlib
import json
import re
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path


class InputError(ValueError):
    pass


def absolute(value: str | Path, *, kind: str | None = None) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise InputError("CLI paths must be absolute")
    path = path.resolve()
    if kind == "file" and not path.is_file():
        raise InputError("Selected input file is unavailable")
    if kind == "dir" and not path.is_dir():
        raise InputError("Selected directory is unavailable")
    return path


def config_path(value: str, base: Path) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise InputError("Configuration path must be a nonempty string")
    path = Path(value)
    if path.drive and not path.is_absolute() or path.root and not path.is_absolute():
        raise InputError("Drive-relative and root-relative paths are unsupported")
    return (path if path.is_absolute() else base / path).resolve()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source(path: Path, data: bytes | None = None) -> dict:
    data = path.read_bytes() if data is None else data
    return {"path": str(path), "byte_length": len(data), "sha256": digest(data)}


def object_keys(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise InputError("Duplicate JSON key")
        result[key] = value
    return result


def read_json(path: Path, limit: int = 32 * 1024 * 1024, *, data: bytes | None = None) -> dict:
    data = path.read_bytes() if data is None else data
    if len(data) > limit:
        raise InputError("JSON exceeds the supported size limit")
    try:
        value = json.loads(data.decode("utf-8-sig"), object_pairs_hook=object_keys,
                           parse_float=Decimal,
                           parse_constant=lambda s: (_ for _ in ()).throw(InputError("Nonstandard JSON number")))
    except (UnicodeError, json.JSONDecodeError, InvalidOperation) as exc:
        raise InputError("Invalid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise InputError("JSON root must be an object")
    return value


def fields(value: dict, required: set, optional: set = frozenset()) -> None:
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - optional:
        raise InputError("Missing or unsupported configuration fields")


def version(value: dict) -> None:
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise InputError("Unsupported schema version")


def decimal_text(value: Decimal) -> str:
    return format(value, "f")


def canonical_decimal(value: str) -> str:
    # Formatting and trimming preserve every input digit; Decimal.normalize()
    # would first round to the caller's active arithmetic context.
    decimal = Decimal(value)
    if not decimal:
        return "0"
    text = decimal_text(decimal)
    return text.rstrip("0").rstrip(".") if "." in text else text


def number(raw: str | None, unit: str | None = None) -> dict:
    if raw is None:
        return {"state": "missing", "value": None, "unit": unit, "raw": None}
    text = raw.strip().replace("\u2212", "-").replace("\u00a0", " ").replace("\u202f", " ")
    if text.endswith("%"):
        if unit is not None and unit != "percent":
            return {"state": "unparseable", "value": None, "unit": unit, "raw": raw,
                    "reported_unit": "percent", "reason": "unexpected_percentage_unit"}
        unit = "percent"
        text = text[:-1].strip()
    lowered = text.lower()
    if lowered in {"", "n/a", "na", "undefined", "--", "-"}:
        return {"state": "undefined", "value": None, "unit": unit, "raw": raw}
    if lowered in {"nan", "+nan", "-nan", "inf", "+inf", "-inf", "infinity", "+infinity", "-infinity", "1.#inf", "-1.#inf", "1.#qnan", "dbl_max"}:
        return {"state": "special", "value": None, "unit": unit, "raw": raw, "special": lowered}
    # English report: decimal dot, thousands in triples separated by comma/space.
    valid = re.fullmatch(r"[+-]?(?:\d+|\d{1,3}(?:[ ,]\d{3})+)(?:\.\d+)?(?:[eE][+-]?\d+)?", text)
    if valid and len(text) <= 128:
        try:
            value = Decimal(text.replace(" ", "").replace(",", ""))
            if value.is_finite() and abs(value.adjusted()) <= 500:
                return {"state": "finite", "value": decimal_text(value), "unit": unit, "raw": raw}
        except InvalidOperation:
            pass
    return {"state": "unparseable", "value": None, "unit": unit, "raw": raw}


def differences(baseline: dict, candidate: dict) -> dict:
    result = {"baseline": baseline, "candidate": candidate, "difference": {"state": "undefined", "value": None},
              "percentage_difference": {"state": "undefined", "value": None, "unit": "percent"}}
    if baseline.get("state") == candidate.get("state") == "finite" and baseline.get("unit") == candidate.get("unit"):
        with localcontext() as ctx:
            ctx.prec = 50
            b, c = Decimal(baseline["value"]), Decimal(candidate["value"])
            result["difference"] = {"state": "finite", "value": decimal_text(c-b), "unit": candidate.get("unit")}
            result["absolute_difference"] = {"state": "finite", "value": decimal_text(abs(c-b)), "unit": candidate.get("unit")}
            if b:
                result["percentage_difference"]["state"] = "finite"
                result["percentage_difference"]["value"] = decimal_text((c-b)/abs(b)*100)
            else:
                result["percentage_difference"]["reason"] = "zero_baseline"
    else:
        result["difference"]["reason"] = "missing_special_or_different_units"
    return result


def load_expectations(path: Path | None, *, data: bytes | None = None) -> dict | None:
    if path is None:
        return None
    value = read_json(path, data=data)
    fields(value, {"schema_version", "metrics"}, {"required_conditions", "require_successful_runs", "required_evidence"})
    version(value)
    for key in ("required_conditions", "required_evidence"):
        if key in value and (not isinstance(value[key], list) or any(not isinstance(x, str) for x in value[key]) or len(set(value[key])) != len(value[key])):
            raise InputError("Evidence requirements must be unique strings")
    if type(value.get("require_successful_runs", False)) is not bool:
        raise InputError("require_successful_runs must be boolean")
    if not isinstance(value["metrics"], list) or not value["metrics"]:
        raise InputError("Expectations require one or more bounds")
    for item in value["metrics"]:
        fields(item, {"metric", "target"}, {"minimum", "maximum"})
        if not isinstance(item["metric"], str) or item["target"] not in {"candidate", "difference", "percentage_difference"}:
            raise InputError("Unsupported expectation target")
        if "minimum" not in item and "maximum" not in item:
            raise InputError("Expectation requires a bound")
        for key in ("minimum", "maximum"):
            if key in item and (not isinstance(item[key], str) or not re.fullmatch(r"[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", item[key]) or number(item[key])["state"] != "finite"):
                raise InputError("Expectation bounds must be finite decimal strings")
        if "minimum" in item and "maximum" in item and Decimal(item["minimum"]) > Decimal(item["maximum"]):
            raise InputError("Minimum exceeds maximum")
    return value


def evaluate(expectations: dict | None, metrics: dict, ready: bool) -> dict:
    if expectations is None:
        return {"status": "not_requested", "checks": []}
    checks = []
    for bound in expectations["metrics"]:
        measurement = metrics.get(bound["metric"], {}).get(bound["target"], {})
        status = "not_evaluable"
        if ready and measurement.get("state") == "finite":
            value = Decimal(measurement["value"])
            passed = ("minimum" not in bound or value >= Decimal(bound["minimum"])) and ("maximum" not in bound or value <= Decimal(bound["maximum"]))
            status = "pass" if passed else "fail"
        checks.append({"bound": bound, "measurement": measurement, "status": status})
    status = "fail" if any(c["status"] == "fail" for c in checks) else "not_evaluable" if any(c["status"] == "not_evaluable" for c in checks) else "pass"
    return {"status": status, "checks": checks}


def condition_kind(value) -> str:
    if type(value) in {int, Decimal}:
        return "number"
    for kind, classes in (("string", str), ("boolean", bool), ("array", list), ("object", dict)):
        if isinstance(value, classes):
            return kind
    if value is None:
        return "null"
    raise InputError("Unsupported comparison condition type")


def equal_conditions(a, b, type_differences: list, path: tuple) -> bool:
    before, after = condition_kind(a), condition_kind(b)
    if before != after:
        type_differences.append({"path": list(path), "baseline_type": before, "candidate_type": after})
        return False
    if before == "object":
        equal = a.keys() == b.keys()
        for key in sorted(a.keys() & b.keys()):
            if not equal_conditions(a[key], b[key], type_differences, path + (key,)):
                equal = False
        return equal
    if before == "array":
        equal = len(a) == len(b)
        for index, (left, right) in enumerate(zip(a, b)):
            if not equal_conditions(left, right, type_differences, path + (index,)):
                equal = False
        return equal
    return a == b


def compatibility(a: dict, b: dict, required: list[str]) -> dict:
    missing, changed = [], []
    for key in required:
        if a.get(key) is None or b.get(key) is None:
            missing.append(key)
        else:
            type_differences = []
            if not equal_conditions(a[key], b[key], type_differences, (key,)):
                difference = {"condition": key, "baseline": a[key], "candidate": b[key]}
                if type_differences:
                    difference["type_differences"] = type_differences
                changed.append(difference)
    status = "incompatible" if changed else "insufficient_evidence" if missing else "comparable"
    return {"status": status, "required": required, "missing": missing, "differences": changed}


def exit_code(result: dict) -> int:
    if result.get("status") == "failed":
        return 2
    if result.get("compatibility", {}).get("status") == "incompatible":
        return 3
    if result.get("compatibility", {}).get("status") == "insufficient_evidence" or result.get("expectations", {}).get("status") == "not_evaluable":
        return 4
    if result.get("expectations", {}).get("status") == "fail":
        return 1
    return 0


def json_decimal(value) -> str:
    if isinstance(value, Decimal) and value.is_finite():
        return str(value)
    raise TypeError("Unsupported JSON output value")


def publish(output: Path, result: dict) -> int:
    # The caller has atomically reserved a new directory before any work.
    code = exit_code(result)
    result["exit_code"] = code
    with (output / "result.json").open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False, default=json_decimal)
        stream.write("\n")
    lines = [result["operation"], "Status: " + result["status"]]
    for key in ("parsing", "evidence_linkage", "compatibility", "expectations"):
        if key in result:
            lines.append(key + ": " + str(result[key].get("status")))
    for key in ("metrics", "files", "entries", "hotspots", "differences", "issues"):
        if key in result:
            lines.append(key + ": " + str(len(result[key])))
    lines.extend(["Exit code: " + str(code), "Evidence: " + str(output / "result.json")])
    summary = "\n".join(lines) + "\n"
    (output / "summary.txt").write_text(summary, encoding="utf-8")
    print(summary, end="")
    return code
