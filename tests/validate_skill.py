from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPOSITORY_ROOT / "skills" / "mql5-coding"

EXPECTED_SKILL_FILES = {
    "SKILL.md",
    "agents/openai.yaml",
    "references/strategy-tester.md",
    "scripts/Compile-Mql5.ps1",
    "scripts/CompilationReceipt.ps1",
    "scripts/CompilerProcessJob.cs",
    "scripts/Invoke-Mt5TesterSmoke.ps1",
    "scripts/TesterEvidence.ps1",
    "scripts/TesterPathIntegrity.ps1",
    "scripts/TesterProcessJob.cs",
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
        try:
            resolved.relative_to(SKILL_ROOT.resolve())
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

    for markdown_path in [skill_path, reference_path, REPOSITORY_ROOT / "README.md"]:
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


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, TypeError, yaml.YAMLError) as error:
        print(f"SKILL_PACKAGE_INVALID: {error}", file=sys.stderr)
        raise SystemExit(1)
