"""The Swift package ships a copy of the marker-detection thresholds.

Two copies of one set of numbers is exactly the arrangement that has already
gone wrong twice in this project, so the copy is checked rather than trusted.
Calibrating against the gold set will change these values, and a calibration
that reached only the eval side would leave the phone detecting with the old
thresholds while the report claimed the new ones.
"""

from __future__ import annotations

import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SOURCE = REPO_ROOT / "evals" / "spikes" / "marker_detection" / "config.json"
SWIFT_COPY = (
    REPO_ROOT / "ios" / "CizgiCore" / "Sources" / "CizgiCore"
    / "Resources" / "marker-detection-config.json"
)


def test_the_swift_copy_exists():
    assert SWIFT_COPY.exists(), (
        f"{SWIFT_COPY} yok. Kopyala: cp {SOURCE} {SWIFT_COPY}"
    )


def test_the_two_copies_are_byte_identical():
    assert SWIFT_COPY.read_bytes() == SOURCE.read_bytes(), (
        "İşaret algılama eşikleri ayrışmış.\n"
        f"Düzeltmek için: cp {SOURCE.relative_to(REPO_ROOT)} "
        f"{SWIFT_COPY.relative_to(REPO_ROOT)}"
    )


def test_the_copy_still_parses_and_carries_every_section():
    payload = json.loads(SWIFT_COPY.read_text(encoding="utf-8"))
    for section in ("confidenceWeights", "decisionThresholds", "highlight", "underline"):
        assert section in payload, f"{section} eksik"


def test_the_confidence_weights_sum_to_one():
    """A weight set that does not sum to 1 makes `selectionConfidence`
    incomparable with the thresholds beside it (§9.3)."""
    weights = json.loads(SOURCE.read_text(encoding="utf-8"))["confidenceWeights"]
    assert abs(sum(weights.values()) - 1.0) < 1e-9, weights
