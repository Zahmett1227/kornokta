"""The past exam bank's schema and the phone's Codable twin must not drift.

`tools/exam_bank/exam_bank.schema.json` is what the Mac pipeline validates every
package against; `ExamBankDocument.swift` is what the phone decodes it with
(docs/PLAN-cikmis-soru-bankasi.md §6, §12). A property added on one side only
is either silently dropped by the phone or makes every import fail; an enum
value added on one side only makes the whole bank undecodable (the Swift enums
decode strictly on purpose). This reads the Swift source as text, like
`test_swift_contract_sync.py`, so it runs without a Swift toolchain.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "tools" / "exam_bank" / "exam_bank.schema.json"
SWIFT_PATH = (
    REPO_ROOT / "ios" / "CizgiCore" / "Sources" / "CizgiCore" / "ExamBank" / "ExamBankDocument.swift"
)

# Swift struct ↔ the schema object it decodes.
STRUCTS = {
    "ExamBankDocument": lambda s: s,
    "ExamPaper": lambda s: s["$defs"]["paper"],
    "ExamPaperSource": lambda s: s["$defs"]["paper"]["properties"]["sources"]["items"],
    "ExamRegion": lambda s: s["$defs"]["region"],
    "ExamQuestion": lambda s: s["$defs"]["question"],
}

# Swift enum ↔ the schema property whose values it decodes.
ENUMS = {
    "ExamTest": lambda s: s["$defs"]["paper"]["properties"]["test"],
    "ExamPenalty": lambda s: s["$defs"]["paper"]["properties"]["penalty"],
    "ExamSourceKind": lambda s: s["$defs"]["paper"]["properties"]["sourceKind"],
    "ExamKeySource": lambda s: s["$defs"]["paper"]["properties"]["keySource"],
    "ExamSourceFamily": lambda s: s["$defs"]["paper"]["properties"]["sources"]["items"]["properties"]["family"],
    "ExamAnswerSource": lambda s: s["$defs"]["question"]["properties"]["answerSource"],
    "ExamQuestionStatus": lambda s: s["$defs"]["question"]["properties"]["status"],
    "ExamFigure": lambda s: s["$defs"]["question"]["properties"]["figure"],
    "ExamTextQuality": lambda s: s["$defs"]["question"]["properties"]["textQuality"],
    "ExamTextSource": lambda s: s["$defs"]["question"]["properties"]["textSource"],
}

_CASE_ITEM = re.compile(r'(\w+)\s*(?:=\s*"([^"]+)")?')


@pytest.fixture(scope="module")
def swift() -> str:
    return SWIFT_PATH.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def _body(source: str, kind: str, name: str) -> str:
    match = re.search(rf"^public {kind} {re.escape(name)}\b[^{{]*\{{(.*?)^\}}", source, re.S | re.M)
    assert match, f"ExamBankDocument.swift içinde `public {kind} {name}` bulunamadı"
    return match.group(1)


def swift_fields(source: str, name: str) -> dict[str, str]:
    """Stored `public let` properties of a struct → their Swift type."""
    fields = dict(re.findall(r"^    public let (\w+): ([^\n=]+?)\s*$", _body(source, "struct", name), re.M))
    assert fields, f"{name} için hiç alan okunamadı — regex bozulmuş olabilir"
    return fields


def swift_enum_values(source: str, name: str) -> list[str]:
    """Raw values in declaration order; several cases on one line allowed."""
    values = []
    for line in _body(source, "enum", name).splitlines():
        stripped = line.split("//")[0].strip()
        if not stripped.startswith("case "):
            continue
        for item in stripped[len("case "):].split(","):
            found = _CASE_ITEM.match(item.strip())
            if found:
                values.append(found.group(2) or found.group(1))
    assert values, f"{name} için hiç case okunamadı"
    return values


def _schema_values(prop: dict) -> list:
    if "enum" in prop:
        return prop["enum"]
    if "const" in prop:
        return [prop["const"]]
    raise AssertionError(f"enum değil: {prop}")


def _nullable(prop: dict) -> bool:
    kind = prop.get("type")
    if kind == "null" or (isinstance(kind, list) and "null" in kind):
        return True
    return None in prop.get("enum", [])


def test_parser_reads_the_swift_file(swift):
    """Guards the guard: an empty parse would make every check below vacuous."""
    assert len(swift_fields(swift, "ExamQuestion")) >= 18
    assert swift_enum_values(swift, "ExamSourceFamily") == ["F1", "F2", "F3", "F4", "F5", "F6"]
    assert "none" in swift_enum_values(swift, "ExamKeySource")


@pytest.mark.parametrize("name", sorted(STRUCTS))
def test_struct_fields_match_the_schema(swift, schema, name):
    target = STRUCTS[name](schema)
    fields = swift_fields(swift, name)
    properties = target["properties"]
    assert set(fields) - set(properties) == set(), f"{name}: Swift'te olup şemada olmayan alan"
    assert set(properties) - set(fields) == set(), f"{name}: şemada olup Swift'te olmayan alan"
    # Everything the schema requires must be present in every package, so the
    # Swift side decodes it as non-optional unless the value itself may be null.
    for key, swift_type in fields.items():
        optional = swift_type.endswith("?")
        assert optional == _nullable(properties[key]), (
            f"{name}.{key}: Swift `{swift_type}` ama şemada null "
            f"{'olabilir' if _nullable(properties[key]) else 'olamaz'}"
        )
    assert set(target.get("required", [])) == set(properties), f"{name}: şemada zorunlu olmayan alan var"


@pytest.mark.parametrize("name", sorted(ENUMS))
def test_enum_values_match_the_schema(swift, schema, name):
    canonical = [v for v in _schema_values(ENUMS[name](schema)) if v is not None]
    assert swift_enum_values(swift, name) == canonical


def test_osym_subjects_are_the_schema_enum_in_booklet_order(swift, schema):
    match = re.search(r"public static let osymSubjects = \[(.*?)\]", swift, re.S)
    assert match
    swift_list = re.findall(r'"([^"]+)"', match.group(1))
    canonical = [v for v in schema["$defs"]["question"]["properties"]["osymSubject"]["enum"] if v is not None]
    assert swift_list == canonical


def test_supported_schema_version_is_the_schemas(swift, schema):
    match = re.search(r"public static let supportedSchemaVersion = (\d+)", swift)
    assert match
    assert int(match.group(1)) == schema["properties"]["schemaVersion"]["const"]
