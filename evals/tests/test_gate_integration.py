"""End-to-end check of the Faz 0 critical-token gate.

Each measure is unit-tested on its own elsewhere; this exercises them wired
together the way `docs/FAZ0-PLAN.md` prescribes — ordered comparison as the
gate, the two count-based measures as diagnostics — against a manifest entry
shaped like the real gold data.
"""

from __future__ import annotations

import pytest

from evals.ocr_eval.metrics import (
    added_critical_tokens,
    critical_token_error_rate,
    critical_token_mismatches,
)

# Shaped like one evals/gold-manifest.json entry.
GOLD_TRANSCRIPTION = "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir."
GOLD_TOKENS = ["0,3–0,5", "mg", "adrenalin"]


def run_gate(hypothesis: str) -> dict:
    """The gate as FAZ0-PLAN defines it: ordered comparison decides, the
    count-based measures say which direction the error went."""
    return {
        "mismatches": critical_token_mismatches(
            GOLD_TRANSCRIPTION, hypothesis, gold_tokens=GOLD_TOKENS
        ),
        "missing_rate": critical_token_error_rate(GOLD_TOKENS, hypothesis),
        "added": added_critical_tokens(GOLD_TRANSCRIPTION, hypothesis),
    }


def passes(result: dict) -> bool:
    return not result["mismatches"] and result["missing_rate"] == 0.0 and not result["added"]


class TestGatePassesCleanReadings:
    def test_exact_transcription(self):
        assert passes(run_gate(GOLD_TRANSCRIPTION))

    def test_case_and_spacing_variation(self):
        assert passes(run_gate("ANAFILAKSIDE ilk seçenek  0,3–0,5  mg IM ADRENALİNDİR."))


class TestGateRejectsMedicallyMeaningfulErrors:
    @pytest.mark.parametrize(
        "hypothesis, description",
        [
            ("Anafilakside ilk seçenek 0,3–0,5 mg IV adrenalindir.", "route changed"),
            ("Anafilakside ilk seçenek 3–5 mg IM adrenalindir.", "decimal lost"),
            ("Anafilakside ilk seçenek 0,3–0,5 g IM adrenalindir.", "unit changed"),
            ("Anafilakside ilk seçenek 0,3–0,5 mg IM noradrenalindir.", "drug changed"),
            ("Anafilakside ilk seçenek IM adrenalindir.", "dose lost"),
            ("Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalin değildir.", "negated"),
        ],
    )
    def test_error_is_caught_by_at_least_one_measure(self, hypothesis, description):
        result = run_gate(hypothesis)
        assert not passes(result), f"{description} slipped through the gate"

    def test_route_change_is_reported(self):
        # IM -> IV keeps every gold token and every number, so nothing but the
        # route class itself can catch it. The en dash is kept identical here
        # on purpose: an earlier version of this test used a hyphen and passed
        # on the dash difference rather than on the route.
        result = run_gate("Anafilakside ilk seçenek 0,3–0,5 mg IV adrenalindir.")
        assert result["mismatches"]

    def test_dash_variation_alone_is_still_caught(self):
        # Guard the case the flawed test was accidentally exercising.
        result = run_gate("Anafilakside ilk seçenek 0,3-0,5 mg IM adrenalindir.")
        assert not passes(result)

    def test_lost_dot_on_turkish_capital_i_is_an_error(self):
        # 'ADRENALİN' is the Turkish capitalisation and must pass; 'ADRENALIN'
        # with a dotless I is a different word, and §24.3 requires Turkish
        # characters to survive OCR.
        assert passes(run_gate("ANAFİLAKSİDE ilk seçenek 0,3–0,5 mg IM ADRENALİNDİR."))
        assert not passes(run_gate("ANAFİLAKSİDE ilk seçenek 0,3–0,5 mg IM ADRENALINDIR."))

    def test_direction_of_a_lost_dose_is_diagnosable(self):
        result = run_gate("Anafilakside ilk seçenek IM adrenalindir.")
        assert result["missing_rate"] > 0.0   # something the source had is gone
        assert not result["added"]            # and nothing was invented

    def test_direction_of_an_invented_value_is_diagnosable(self):
        result = run_gate("Anafilakside ilk seçenek 0,3–0,5 mg/kg IM adrenalindir.")
        assert result["added"]
