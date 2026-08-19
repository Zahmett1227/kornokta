"""The Swift enums and the canonical §14 schema must not drift apart.

`RiskFlag` and `CardType` in `ios/CizgiCore/.../Enums.swift` are the same facts
as `$defs.riskFlag` and `cards.items.type` in `llm_output.schema.json`. When a
value is added on one side and forgotten on the other, the app silently drops
the flag: `RiskFlag(rawValue:)` returns nil and `compactMap` discards it, so a
card that the model flagged as risky arrives looking clean.

These tests read the Swift source as text on purpose — they run in the existing
Python CI, with no Swift toolchain and no simulator, so the check is enforced on
every push rather than only when someone opens Xcode.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "backend" / "schemas" / "llm_output.schema.json"
ENUMS_PATH = (
    REPO_ROOT / "ios" / "CizgiCore" / "Sources" / "CizgiCore" / "Models" / "Enums.swift"
)

# `case foo` or `case foo = "foo_bar"`; the raw value wins when present.
_CASE = re.compile(r'^\s*case\s+(\w+)\s*(?:=\s*"([^"]+)")?\s*$')


def swift_enum_values(source: str, enum_name: str) -> list[str]:
    """Raw values of a Swift enum, in declaration order."""
    match = re.search(
        rf"^public enum {re.escape(enum_name)}\b[^{{]*\{{(.*?)^\}}",
        source,
        re.S | re.M,
    )
    assert match, f"Enums.swift içinde `public enum {enum_name}` bulunamadı"

    values = []
    for line in match.group(1).splitlines():
        found = _CASE.match(line)
        if found:
            values.append(found.group(2) or found.group(1))
    assert values, f"{enum_name} için hiç case okunamadı — regex bozulmuş olabilir"
    return values


@pytest.fixture(scope="module")
def swift_source() -> str:
    return ENUMS_PATH.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def test_parser_finds_the_enums(swift_source):
    """Guards the guard: a silently-empty parse would make every check vacuous."""
    assert len(swift_enum_values(swift_source, "RiskFlag")) > 5
    assert len(swift_enum_values(swift_source, "CardType")) > 2
    # Raw values are preferred over case names where they differ.
    assert "ocr_disagreement" in swift_enum_values(swift_source, "RiskFlag")
    assert "direct_recall" in swift_enum_values(swift_source, "CardType")
    assert len(swift_enum_values(swift_source, "MarkKind")) == 4


def test_risk_flags_match_the_schema(swift_source, schema):
    swift = swift_enum_values(swift_source, "RiskFlag")
    canonical = schema["$defs"]["riskFlag"]["enum"]

    assert set(swift) - set(canonical) == set(), "Swift'te olup şemada olmayan risk işareti"
    assert set(canonical) - set(swift) == set(), "Şemada olup Swift'te olmayan risk işareti"


def test_card_types_match_the_schema(swift_source, schema):
    swift = swift_enum_values(swift_source, "CardType")
    canonical = schema["properties"]["cards"]["items"]["properties"]["type"]["enum"]

    assert set(swift) - set(canonical) == set(), "Swift'te olup şemada olmayan kart tipi"
    assert set(canonical) - set(swift) == set(), "Şemada olup Swift'te olmayan kart tipi"


def test_mark_kinds_match_the_schema(swift_source, schema):
    """Schema v2.3's mark tiers, the fourth list living in three languages.

    Both readers speak it — the generator's own register and the independent
    auditor — so a tier that exists on one side and not the other cannot be
    merged into one coverage list on the phone: `MarkKind(rawValue:)` returns
    nil and the mark is silently dropped, which is precisely the failure the
    whole coverage layer exists to end.
    """
    swift = swift_enum_values(swift_source, "MarkKind")
    canonical = schema["properties"]["marks"]["items"]["properties"]["kind"]["enum"]

    assert set(swift) - set(canonical) == set(), "Swift'te olup şemada olmayan işaret kademesi"
    assert set(canonical) - set(swift) == set(), "Şemada olup Swift'te olmayan işaret kademesi"


def test_mark_kind_order_is_the_priority_ladder(swift_source, schema):
    """Order is meaning here, not presentation.

    Prompt rule 3 ranks handwriting above the symbol tier above underline above
    highlighter, and both the Swift side and the server sort uncovered marks by
    that order — so the most valuable thing the model skipped is the first row
    the owner sees. Declaration order *is* the contract; a reshuffle on either
    side silently reorders that list.
    """
    ladder = ["handwriting", "symbol", "underline", "highlight"]
    assert swift_enum_values(swift_source, "MarkKind") == ladder
    assert schema["properties"]["marks"]["items"]["properties"]["kind"]["enum"] == ladder


def test_raw_values_are_snake_case(swift_source):
    """The wire format is snake_case (§14); a stray camelCase raw value would
    decode to nil on the device without any error."""
    for enum_name in ("RiskFlag", "CardType", "ProcessingState", "SelectionType", "CardStatus", "MarkKind"):
        for value in swift_enum_values(swift_source, enum_name):
            assert value == value.lower(), f"{enum_name}: `{value}` snake_case değil"


def test_raw_values_are_unique_within_each_enum(swift_source):
    """Two cases sharing a raw value makes `init(rawValue:)` unreachable for one
    of them, which no compiler warning catches."""
    for enum_name in ("RiskFlag", "CardType", "ProcessingState", "SelectionType", "CardStatus", "MarkKind"):
        values = swift_enum_values(swift_source, enum_name)
        assert len(values) == len(set(values)), f"{enum_name} içinde tekrar eden ham değer"
