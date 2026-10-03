"""Possible include edges, not a replacement MQL5 preprocessor."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

from toolkit_common import InputError, absolute, digest, read_json, source, version


def selected_entrypoint(value: str | Path) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise InputError("CLI paths must be absolute")
    # Explicit directory selections may be canonicalized, but preserve a source
    # leaf link so inventory can disclose it without reading its target.
    path = absolute(path.parent, kind="dir") / path.name
    if not path.is_file():
        raise InputError("Selected input file is unavailable")
    return path


def linked_component(path: Path) -> Path | None:
    # Inspect from the root down; never inspect a leaf through a linked parent.
    for component in reversed([path, *path.parents]):
        if component.is_symlink() or component.is_junction():
            return component
    return None


def validated_profile(path: Path, shell: str | None) -> dict:
    host = shell or shutil.which("pwsh") or shutil.which("powershell.exe")
    if not host:
        raise InputError("Install PowerShell or pass --powershell with its absolute path to reuse the profile validator")
    if shell:
        absolute(shell, kind="file")
    runner = Path(__file__).with_name("Invoke-Mql5Project.ps1")
    quote = lambda p: "'" + str(p).replace("'", "''") + "'"
    command = "[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); & " + quote(runner) + " -ProfilePath " + quote(path) + " -Action Validate; exit $LASTEXITCODE"
    result = subprocess.run([host, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command], capture_output=True, timeout=30)
    if result.returncode or len(result.stdout) > 1024 * 1024:
        raise InputError("Existing project profile validator rejected the selection")
    import json
    try:
        return json.loads(result.stdout.decode("utf-8-sig"))
    except (ValueError, UnicodeError) as exc:
        raise InputError("Profile validator output is unavailable") from exc


def directives(text: str) -> list[tuple[int, str, str]]:
    # Replace comments with whitespace while retaining newlines and quoted text.
    # A parallel mask records only '#' outside both comments and strings.
    cleaned, markers = list(text), set()
    state, escape, i = "code", False, 0
    while i < len(text):
        c, nxt = text[i], text[i+1:i+2]
        if state == "line":
            if c == "\n":
                state = "code"
            else:
                cleaned[i] = " "
        elif state == "block":
            if c != "\n":
                cleaned[i] = " "
            if c == "*" and nxt == "/":
                cleaned[i+1] = " "
                i += 1
                state = "code"
        elif state in {"double", "single"}:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == ('"' if state == "double" else "'"):
                state = "code"
        elif c == "/" and nxt in {"/", "*"}:
            cleaned[i] = cleaned[i+1] = " "
            state = "line" if nxt == "/" else "block"
            i += 1
        elif c in {'"', "'"}:
            state = "double" if c == '"' else "single"
        elif c == "#":
            markers.add(i)
        i += 1
    result, offset = [], 0
    for line_number, line in enumerate("".join(cleaned).splitlines(keepends=True), 1):
        match = re.match(r"\s*#\s*([A-Za-z_]\w*)\b(.*)", line.rstrip("\r\n"))
        if match and offset + line.index("#") in markers:
            result.append((line_number, match.group(1), match.group(2).strip()))
        offset += len(line)
    if state == "block":
        result.append((text.count("\n")+1, "unsupported", "unterminated comment"))
    return result


def source_text(data: bytes) -> str:
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16")
    return data.decode("utf-8-sig")


def inventory(root: Path, entrypoints: list[Path], include_roots: list[Path], profile: Path | None = None) -> dict:
    known, all_sources, issues = [], [], []
    inspected = 0
    for folder, dirs, files in os.walk(root, followlinks=False):
        kept = []
        for name in dirs:
            selected = Path(folder) / name
            if selected.is_symlink() or selected.is_junction():
                issues.append({"code": "linked_directory_not_scanned", "path": str(selected)})
            elif name not in {".git", "__pycache__", ".venv"}:
                kept.append(name)
        dirs[:] = kept
        inspected += len(files)
        if inspected > 50000:
            raise InputError("Project inventory exceeds 50000 files; select a narrower root")
        known.extend(str(Path(folder)/name) for name in files if name.lower().endswith(".mq5"))
        all_sources.extend(Path(folder)/name for name in files if Path(name).suffix.lower() in {".mq5", ".mqh"})
    if not entrypoints:
        entrypoints = [Path(p) for p in sorted(known)]
    if not entrypoints:
        raise InputError("No MQ5 entrypoints were selected or discovered")
    if len(entrypoints) != len(set(entrypoints)):
        raise InputError("Duplicate entrypoints")
    for entry in entrypoints:
        if entry.suffix.lower() != ".mq5" or not entry.is_file():
            raise InputError("Entrypoints must be existing MQ5 files")
        if not entry.is_relative_to(root):
            raise InputError("Entrypoint is outside the selected project root")
    files, edges, cycles, consumers = {}, [], [], {}
    if len(all_sources) > 10000:
        raise InputError("Source inventory exceeds 10000 files")
    for path in all_sources:
        if path.is_symlink():
            issues.append({"code": "linked_source_uncertainty", "path": str(path)})
            continue
        if path.stat().st_size > 8 * 1024 * 1024:
            raise InputError("Source exceeds 8 MiB")
        files[str(path.resolve())] = source(path.resolve())
    for entry in entrypoints:
        seen, stack = set(), []

        def visit(path: Path):
            identity = str(path)
            consumers.setdefault(identity, set()).add(str(entry))
            if identity in stack:
                cycles.append({"entrypoint": str(entry), "paths": stack[stack.index(identity):] + [identity]})
                return
            if identity in seen:
                return
            seen.add(identity)
            stack.append(identity)
            if len(stack) > 128 or len(files) > 10000:
                raise InputError("Include graph exceeds bounded depth or file count")
            link = linked_component(path)
            if link is not None:
                issues.append({"code": "linked_source_uncertainty", "path": identity, "linked_component": str(link)})
                stack.pop()
                return
            data = path.read_bytes()
            if len(data) > 8 * 1024 * 1024:
                raise InputError("Source exceeds 8 MiB")
            files[identity] = source(path, data)
            try:
                declared = directives(source_text(data))
            except UnicodeError:
                issues.append({"code": "unsupported_source_encoding", "path": identity})
                stack.pop()
                return
            conditions = []
            for line, directive, value in declared:
                if directive in {"ifdef", "ifndef", "if"}:
                    conditions.append(f"#{directive} {value}")
                elif directive in {"else", "elif"}:
                    if conditions:
                        conditions[-1] += f"; #{directive} {value}"
                    else:
                        issues.append({"code": "unbalanced_conditional", "path": identity, "line": line})
                elif directive == "endif":
                    if conditions:
                        conditions.pop()
                    else:
                        issues.append({"code": "unbalanced_conditional", "path": identity, "line": line})
                elif directive == "include":
                    literal = re.fullmatch(r'"([^"\r\n]+)"|<([^>\r\n]+)>', value)
                    edge = {"entrypoint": str(entry), "source": identity, "line": line, "declaration": value,
                            "conditional_context": list(conditions), "resolution": "unsupported", "target": None,
                            "active_dependency": "unknown"}
                    if literal:
                        form = "quoted" if literal.group(1) is not None else "angle"
                        name = literal.group(1) or literal.group(2)
                        name = name.replace("\\", os.sep).replace("/", os.sep)
                        edge["form"] = form
                        # AlgoBook 2.9.1 and the native nested-header fixture use
                        # the file containing this directive. The Reference's
                        # main-source wording can conflict: retain that candidate
                        # conservatively when it is a different existing file.
                        roots = list(dict.fromkeys([path.parent, entry.parent])) if form == "quoted" else include_roots
                        edge["searched_roots"] = [str(p) for p in roots]
                        if Path(name).is_absolute() or Path(name).drive:
                            edge["resolution"] = "unsupported_absolute_include"
                        else:
                            matches, links = [], []
                            for base in roots:
                                candidate = base/name
                                link = linked_component(candidate)
                                if link is not None:
                                    record = {"path": str(candidate), "linked_component": str(link)}
                                    links.append(record)
                                    issues.append({"code": "linked_source_uncertainty", **record})
                                    consumers.setdefault(str(candidate), set()).add(str(entry))
                                elif candidate.is_file():
                                    matches.append(candidate.resolve())
                            matches = list(dict.fromkeys(matches))
                            edge["resolution"] = "possible" if len(matches) == 1 else "ambiguous" if matches else "unresolved"
                            if links:
                                edge["linked_candidates"] = links
                                edge["resolution"] = "ambiguous" if matches else "linked_source_uncertainty"
                            if form == "quoted":
                                edge["quoted_rule"] = "declaring_file_directory"
                                declaring = path.parent/name
                                edge["declaring_file_candidate"] = str(declaring if linked_component(declaring) else declaring.resolve())
                                if matches and not links and not declaring.is_file():
                                    edge["resolution"] = "uncertain_reference_main_only"
                            if len(matches) == 1 and not links:
                                edge["target"] = str(matches[0])
                            if len(matches) > 1 or links and matches:
                                edge["possible_targets"] = [str(p) for p in matches] + [p["path"] for p in links]
                            for candidate in matches:
                                visit(candidate)
                    edges.append(edge)
                elif directive == "unsupported":
                    issues.append({"code": "unsupported_construct", "path": identity, "line": line})
            if conditions:
                issues.append({"code": "unclosed_conditional", "path": identity})
            stack.pop()

        visit(entry)
    unselected = sorted(set(known)-{str(p) for p in entrypoints})
    unresolved = [x for x in edges if x["resolution"] != "possible"]
    coverage = "uncertain" if issues or unresolved or unselected else "selected_entrypoints_scanned"
    return {"schema_version": 1, "operation": "includes inventory", "status": "completed", "project_root": str(root),
            "profile": source(profile) if profile else None, "include_roots": [str(p) for p in include_roots],
            "entrypoints": [str(p) for p in entrypoints], "known_entrypoints": sorted(known), "unselected_entrypoints": unselected,
            "files": [files[k] for k in sorted(files)], "dependencies": edges, "unresolved": unresolved, "cycles": cycles,
            "possible_consumers": {k: sorted(v) for k, v in sorted(consumers.items())}, "coverage": coverage, "issues": issues,
            "limitations": ["Literal includes only; conditional branches remain possible dependencies", "Quoted includes use the declaring-file directory; conflicting main-source candidates remain uncertain due to Reference/AlgoBook wording", "Angle includes use explicitly selected standard roots", "Cycles are observations, not compilation errors", "Snapshot is not proof of exact compiler consumption or runtime dependencies", "Unselected entrypoints and unsupported constructs leave consumer coverage unknown"]}


def compare_snapshots(a: dict, b: dict) -> dict:
    for snapshot in (a, b):
        version(snapshot)
        if snapshot.get("operation") != "includes inventory" or snapshot.get("status") != "completed" or not isinstance(snapshot.get("files"), list) or not isinstance(snapshot.get("possible_consumers"), dict):
            raise InputError("Expected completed include snapshots")
        if snapshot.get("coverage") not in {"selected_entrypoints_scanned", "uncertain"} or not isinstance(snapshot.get("project_root"), str) or not Path(snapshot["project_root"]).is_absolute():
            raise InputError("Snapshot root and consumer coverage are required")
        for record in snapshot["files"]:
            if not isinstance(record, dict) or not isinstance(record.get("path"), str) or not Path(record["path"]).is_absolute() or not isinstance(record.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) or type(record.get("byte_length")) is not int or record["byte_length"] < 0:
                raise InputError("Invalid snapshot file identity")
        for path, entries in snapshot["possible_consumers"].items():
            if not isinstance(path, str) or not Path(path).is_absolute() or not isinstance(entries, list) or any(not isinstance(p, str) or not Path(p).is_absolute() for p in entries):
                raise InputError("Snapshot consumers must be arrays of absolute entrypoint paths")
    mappings = [{x["path"]: x for x in s["files"]} for s in (a, b)]
    if any(len(m) != len(s["files"]) for m, s in zip(mappings, (a, b))):
        raise InputError("Duplicate snapshot file identities")
    before, after = mappings
    changes = []
    for key in sorted(before.keys() | after.keys()):
        kind = "added" if key not in before else "removed" if key not in after else "changed" if before[key]["sha256"] != after[key]["sha256"] else None
        if kind:
            affected = sorted(set(a["possible_consumers"].get(key, [])) | set(b["possible_consumers"].get(key, [])))
            changes.append({"path": key, "kind": kind, "baseline": before.get(key), "candidate": after.get(key), "possible_affected_entrypoints": affected,
                            "consumer_coverage_unknown": not affected or a.get("coverage") == "uncertain" or b.get("coverage") == "uncertain"})
    return {"schema_version": 1, "operation": "includes compare", "status": "completed", "differences": changes,
            "possible_affected_entrypoints": sorted({p for c in changes for p in c["possible_affected_entrypoints"]}),
            "coverage": {"baseline": a.get("coverage"), "candidate": b.get("coverage"), "same_root": a.get("project_root") == b.get("project_root")},
            "issues": [] if a.get("project_root") == b.get("project_root") else [{"code": "different_roots", "message": "Paths are exact identities; moved files are reported as removed/added"}],
            "limitations": a.get("limitations", [])}
