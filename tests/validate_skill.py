from __future__ import annotations

import re
import json
import sys
from pathlib import Path

import yaml


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPOSITORY_ROOT / "skills" / "mql5-coding"

EXPECTED_SKILL_FILES = {
    "version.json",
    "references/releases.md",
    "scripts/SkillRelease.ps1",
    "scripts/Update-Mql5Skill.ps1",
    "SKILL.md",
    "agents/openai.yaml",
    "references/strategy-tester.md",
    "references/mcp-contract.json",
    "references/environment-health.md",
    "references/project-profiles.md",
    "scripts/Mql5ProjectProfile.ps1",
    "scripts/New-Mql5ProjectProfile.ps1",
    "scripts/Invoke-Mql5Project.ps1",
    "scripts/Test-Mql5Environment.ps1",
    "scripts/Compile-Mql5.ps1",
    "scripts/CompilationReceipt.ps1",
    "scripts/BuildSourceSnapshot.ps1",
    "references/source-snapshots.md",
    "scripts/WindowsExecutableMetadata.ps1",
    "scripts/CompilerProcessJob.cs",
    "scripts/Invoke-Mt5TesterSmoke.ps1",
    "scripts/TesterEvidence.ps1",
    "scripts/TesterPathIntegrity.ps1",
    "scripts/TesterProcessJob.cs",
    "scripts/mql5_toolkit.py",
    "scripts/toolkit_common.py",
    "scripts/toolkit_reports.py",
    "scripts/toolkit_includes.py",
    "scripts/toolkit_profiles.py",
    "scripts/ToolkitSupport.ps1",
    "scripts/Read-Mql5Journal.ps1",
    "scripts/Invoke-Mql5ScenarioBatch.ps1",
    "references/toolkit.md",
    "references/compile.md",
    "references/focused-review.md",
    "references/performance.md",
    "references/refactoring.md",
    "assets/scenarios.template.json",
    "assets/comparison-expectations.template.json",
    "assets/Mql5Assertions.mqh",
    "assets/Mql5ToolkitSelfTest.mq5",
}


def fail(message: str) -> None:
    raise AssertionError(message)


def parse_frontmatter(text: str) -> dict:
    match = re.match(r"\A---\r?\n(.*?)\r?\n---\r?\n", text, re.DOTALL)
    if match is None:
        fail("SKILL.md must begin with YAML frontmatter.")
    result = yaml.safe_load(match.group(1))
    if not isinstance(result, dict):
        fail("SKILL.md frontmatter must be a mapping.")
    return result


def validate_relative_markdown_links(path: Path, text: str) -> None:
    for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
        if re.match(r"^(?:https?://|mailto:|#)", target):
            continue
        relative_target = target.split("#", 1)[0]
        if not relative_target:
            continue
        resolved = (path.parent / relative_target).resolve()
        allowed_root = REPOSITORY_ROOT if path == REPOSITORY_ROOT / "README.md" else SKILL_ROOT
        try:
            resolved.relative_to(allowed_root.resolve())
        except ValueError:
            fail(f"{path}: relative link escapes the skill package: {target}")
        if not resolved.is_file():
            fail(f"{path}: relative link target is missing: {target}")


def main() -> int:
    actual_files = {
        path.relative_to(SKILL_ROOT).as_posix()
        for path in SKILL_ROOT.rglob("*")
        if path.is_file()
    }
    if actual_files != EXPECTED_SKILL_FILES:
        fail(
            "Unexpected skill package files. "
            f"Expected {sorted(EXPECTED_SKILL_FILES)}, found {sorted(actual_files)}"
        )

    skill_path = SKILL_ROOT / "SKILL.md"
    skill_text = skill_path.read_text(encoding="utf-8")
    frontmatter = parse_frontmatter(skill_text)
    if set(frontmatter) != {"name", "description"}:
        fail("SKILL.md frontmatter must contain only name and description.")
    if frontmatter["name"] != "mql5-coding":
        fail("Skill name must be mql5-coding.")
    description = frontmatter["description"]
    if not isinstance(description, str) or "MQL5 CHM MCP" not in description:
        fail("Skill description must declare the MQL5 CHM MCP authority.")
    if "MQL4" not in description or "MetaTrader 4" not in description:
        fail("Skill description must preserve the MQL4/MT4 exclusion.")

    metadata_path = SKILL_ROOT / "agents" / "openai.yaml"
    metadata = yaml.safe_load(metadata_path.read_text(encoding="utf-8"))
    if metadata["interface"]["display_name"] != "MQL5 Coding":
        fail("agents/openai.yaml display_name must be MQL5 Coding.")
    if "$mql5-coding" not in metadata["interface"]["default_prompt"]:
        fail("agents/openai.yaml default_prompt must invoke $mql5-coding.")
    if metadata["policy"]["allow_implicit_invocation"] is not True:
        fail("Implicit invocation must remain enabled.")
    if metadata["dependencies"]["tools"] != [
        {
            "type": "mcp",
            "value": "mql5-chm",
            "description": "Installed MQL5 CHM server for primary API and language facts",
        }
    ]:
        fail("agents/openai.yaml must declare exactly the mql5-chm MCP dependency.")

    contract = json.loads((SKILL_ROOT / "references" / "mcp-contract.json").read_text(encoding="utf-8"))
    validate_mcp_contract(contract, metadata)

    required_skill_phrases = [
        "mql5_chm_status",
        "mql5_chm_search",
        "mql5_chm_read",
        "Not verified in the installed MQL5 CHM",
        "references/strategy-tester.md",
        "skills\\mql5-coding\\scripts\\Compile-Mql5.ps1",
    ]
    for phrase in required_skill_phrases:
        if phrase not in skill_text:
            fail(f"SKILL.md is missing required phrase: {phrase}")

    reference_path = SKILL_ROOT / "references" / "strategy-tester.md"
    reference_text = reference_path.read_text(encoding="utf-8")
    for phrase in [
        "-AcknowledgeSavedAccountRisk",
        "-ExpectedExpertSha256",
        "-CompilationReceiptPath",
        "-UseExpertDefaults",
        "MQL5_CODING_PASS:",
        "Windows Job Object",
        "Not verified in the installed MQL5 CHM",
        "engine_smoke_passed",
        "application_marker_passed",
        "security sandbox",
    ]:
        if phrase not in reference_text:
            fail(f"Strategy Tester reference is missing safeguard: {phrase}")

    version = json.loads((SKILL_ROOT / "version.json").read_text(encoding="utf-8"))
    if not isinstance(version, dict) or set(version) != {"schema_version", "version"} or type(version["schema_version"]) is not int or version["schema_version"] != 1 or not isinstance(version["version"], str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version["version"]):
        fail("Invalid skill release version.")

    for markdown_path in [*sorted(SKILL_ROOT.rglob("*.md")), REPOSITORY_ROOT / "README.md"]:
        text = markdown_path.read_text(encoding="utf-8")
        validate_relative_markdown_links(markdown_path, text)

    portable_files = [REPOSITORY_ROOT / "README.md"] + [
        SKILL_ROOT / relative_path for relative_path in sorted(EXPECTED_SKILL_FILES)
    ]
    for path in portable_files:
        text = path.read_text(encoding="utf-8-sig")
        if re.search(r"(?i)[A-Z]:[\\/]Users[\\/][^\\/]+", text):
            fail(f"{path}: contains a user-specific Windows path.")
        if "Shari" in text:
            fail(f"{path}: contains a user-specific name.")

    compiler_text = (SKILL_ROOT / "scripts" / "Compile-Mql5.ps1").read_text(
        encoding="utf-8-sig"
    )
    if ".mq4" in compiler_text.lower() or ".ex4" in compiler_text.lower():
        fail("Bundled compiler wrapper must remain MQL5-only.")

    print("SKILL_PACKAGE_VALID")
    return 0


def validate_mcp_contract(contract: dict, metadata: dict) -> None:
    if type(contract.get("schema_version")) is not int or contract["schema_version"] != 1:
        fail("Unsupported MCP consumer contract schema.")
    if set(contract) - {"schema_version", "server_name", "tools", "optional_tools"}:
        fail("Unknown MCP consumer contract fields.")
    declared = metadata["dependencies"]["tools"]
    if len(declared) != 1 or declared[0]["type"] != "mcp" or contract.get("server_name") != declared[0]["value"]:
        fail("MCP contract server_name does not match the skill dependency.")
    tools = contract.get("tools")
    if not isinstance(tools, dict) or set(tools) != {
        "mql5_chm_status", "mql5_chm_search", "mql5_chm_read", "mql5_chm_read_image"
    }:
        fail("MCP contract must cover the four required documentation tools.")
    optional = contract.get("optional_tools", {})
    if not isinstance(optional, dict) or set(optional) - {"mql5_chm_lookup_identifiers"}:
        fail("Unsupported optional documentation tools.")
    for name, tool in {**tools, **optional}.items():
        if not isinstance(tool, dict) or not isinstance(tool.get("required_arguments"), list) or not tool.get("outputs"):
            fail(f"Invalid MCP tool contract: {name}")
        arrays = tool.get("array_bounds", {})
        if not isinstance(arrays, dict):
            fail(f"Invalid MCP array bounds mapping: {name}")
        for field, bound in arrays.items():
            if not isinstance(bound, dict) or set(bound) != {"minimum", "maximum"} or any(type(bound[key]) is not int for key in bound) or not 0 <= bound["minimum"] <= bound["maximum"]:
                fail(f"Invalid MCP array bounds: {name}.{field}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, TypeError, ValueError, yaml.YAMLError) as error:
        print(f"SKILL_PACKAGE_INVALID: {error}", file=sys.stderr)
        raise SystemExit(1)
