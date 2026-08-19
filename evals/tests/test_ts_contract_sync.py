"""The TypeScript enums and the canonical §14 schema must not drift apart.

Sibling check to `test_swift_contract_sync.py`: Faz 3 added a third copy of
`RiskFlag`/`CardType` (`backend/schemas/llmOutputTypes.ts`), on top of the
schema itself and the Swift enums. This project has already been bitten twice
by "one behaviour, two places, only one updated" (docs/ADR-001) before this
third copy existed; the guard has to exist before the drift does, not after.

Reads the TypeScript source as text on purpose, same reason as the Swift
check: it runs in the existing Python CI with no Node toolchain required.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "backend" / "schemas" / "llm_output.schema.json"
TYPES_PATH = REPO_ROOT / "backend" / "schemas" / "llmOutputTypes.ts"


def ts_const_array(source: str, name: str) -> list[str]:
    """String literals of `export const <name> = [...] as const;`, in order."""
    match = re.search(
        rf"export const {re.escape(name)} = \[(.*?)\] as const;",
        source,
        re.S,
    )
    assert match, f"llmOutputTypes.ts içinde `export const {name}` bulunamadı"
    return re.findall(r'"([^"]+)"', match.group(1))


@pytest.fixture(scope="module")
def ts_source() -> str:
    return TYPES_PATH.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def test_parser_finds_the_arrays(ts_source):
    """Guards the guard: a silently-empty parse would make every check vacuous."""
    assert len(ts_const_array(ts_source, "RISK_FLAGS")) > 5
    assert len(ts_const_array(ts_source, "CARD_TYPES")) > 2
    assert "ocr_disagreement" in ts_const_array(ts_source, "RISK_FLAGS")
    assert "direct_recall" in ts_const_array(ts_source, "CARD_TYPES")
    assert ts_const_array(ts_source, "MARK_KINDS") == ["handwriting", "symbol", "underline", "highlight"]


def test_mark_kinds_match_the_schema(ts_source, schema):
    """Schema v2.3's mark tiers (docs/PLAN-kapsama-sozlesmesi.md).

    `MARK_KINDS` is not decoration: `providers/coverage.ts` ranks uncovered
    marks by its order and the Gemini auditor's response schema is built from
    it, so a tier here that the canonical schema does not know is a value the
    generator can never emit — and one the auditor emits and `sanitizeMarks`
    then drops.
    """
    ts = ts_const_array(ts_source, "MARK_KINDS")
    canonical = schema["properties"]["marks"]["items"]["properties"]["kind"]["enum"]

    assert set(ts) - set(canonical) == set(), "TS'te olup şemada olmayan işaret kademesi"
    assert set(canonical) - set(ts) == set(), "Şemada olup TS'te olmayan işaret kademesi"
    # Order is the priority ladder of prompt rule 3, shared with the Swift enum.
    assert ts == canonical


def test_risk_flags_match_the_schema(ts_source, schema):
    ts = ts_const_array(ts_source, "RISK_FLAGS")
    canonical = schema["$defs"]["riskFlag"]["enum"]

    assert set(ts) - set(canonical) == set(), "TS'te olup şemada olmayan risk işareti"
    assert set(canonical) - set(ts) == set(), "Şemada olup TS'te olmayan risk işareti"


def test_card_types_match_the_schema(ts_source, schema):
    ts = ts_const_array(ts_source, "CARD_TYPES")
    canonical = schema["properties"]["cards"]["items"]["properties"]["type"]["enum"]

    assert set(ts) - set(canonical) == set(), "TS'te olup şemada olmayan kart tipi"
    assert set(canonical) - set(ts) == set(), "Şemada olup TS'te olmayan kart tipi"


def test_values_are_unique_within_each_array(ts_source):
    for name in ("RISK_FLAGS", "CARD_TYPES"):
        values = ts_const_array(ts_source, name)
        assert len(values) == len(set(values)), f"{name} içinde tekrar eden değer"
