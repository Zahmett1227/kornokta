"""The Swift package ships a copy of the FSRS weights (same reasoning as
`test_marker_config_sync.py`): two copies of one set of numbers is exactly
the arrangement that has already gone wrong twice in this project, so the
copy is checked rather than trusted."""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SOURCE = REPO_ROOT / "evals" / "fsrs" / "weights.json"
SWIFT_COPY = (
    REPO_ROOT / "ios" / "CizgiCore" / "Sources" / "CizgiCore"
    / "Resources" / "fsrs-weights.json"
)


def test_the_swift_copy_exists():
    assert SWIFT_COPY.exists(), f"{SWIFT_COPY} yok. Kopyala: cp {SOURCE} {SWIFT_COPY}"


def test_the_two_copies_are_byte_identical():
    assert SWIFT_COPY.read_bytes() == SOURCE.read_bytes(), (
        "FSRS ağırlıkları ayrışmış.\n"
        f"Düzeltmek için: cp {SOURCE.relative_to(REPO_ROOT)} "
        f"{SWIFT_COPY.relative_to(REPO_ROOT)}"
    )


def test_the_copy_still_parses_and_has_21_weights():
    payload = json.loads(SWIFT_COPY.read_text(encoding="utf-8"))
    assert len(payload["weights"]) == 21
    assert 0 < payload["desiredRetention"] < 1
