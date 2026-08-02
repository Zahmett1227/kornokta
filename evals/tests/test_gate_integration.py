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


class TestAllThreeMeasuresAgree:
    """The three measures must reach the same verdict on the same input.

    They answer different questions, but they must not *contradict* each
    other: a reading the ordered comparison calls clean cannot be one the
    recall measure calls a total loss.
    """

    @staticmethod
    def _three(gold: str, reading: str):
        from evals.ocr_eval.critical_tokens import detect_critical_tokens
        from evals.ocr_eval.metrics import (
            added_critical_tokens,
            critical_token_error_rate,
            critical_token_mismatches,
        )

        gold_tokens = [t.text for t in detect_critical_tokens(gold)]
        return (
            critical_token_mismatches(gold, reading),
            critical_token_error_rate(gold_tokens, reading),
            added_critical_tokens(gold, reading),
        )

    @pytest.mark.parametrize(
        "gold,reading",
        [
            ("intravenöz verilir", "IV verilir"),
            ("kas içi uygulanır", "IM uygulanır"),
            ("ağızdan alınır", "PO alınır"),
            ("damar içine verilir", "IV verilir"),
            ("deri altına yapılır", "SC yapılır"),
            ("0,5 mg IM", "0,5 mg im"),
        ],
    )
    def test_route_synonyms_are_clean_in_all_three(self, gold, reading):
        """§10.5.1: every accepted spelling of one route is that route.

        The recall measure used to search for the gold *surface* textually, so
        it was the only one of the three that did not fold synonyms: a page
        saying 'damar içi', read correctly as 'IV', scored 1.0 missing while
        the other two called it clean. A correct reading would have been sent
        to quick_confirm, which is exactly what §24.2 is trying to avoid.
        """
        mismatches, missing, added = self._three(gold, reading)
        assert mismatches == []
        assert missing == 0.0
        assert added == []

    @pytest.mark.parametrize(
        "gold,reading",
        [
            ("IM uygulanır", "IV uygulanır"),
            ("intravenöz verilir", "kas içi verilir"),
            ("PO alınır", "SL alınır"),
            ("intratekal verilir", "intraartiküler verilir"),
        ],
    )
    def test_different_routes_are_still_caught(self, gold, reading):
        mismatches, missing, added = self._three(gold, reading)
        assert mismatches, "farklı yol uyuşmazlık üretmeli"
        assert missing > 0.0
        assert added

    def test_losing_one_of_two_routes_is_caught(self):
        # Folding must not let a surviving route stand in for a lost one.
        mismatches, missing, added = self._three("sabah IM, akşam IV", "sabah IM, akşam IM")
        assert mismatches
        assert missing > 0.0
