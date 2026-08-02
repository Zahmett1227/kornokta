"""Critical tokens must still be *found* in Turkish written without diacritics.

Apple Vision produced `ı ş ğ İ` exactly zero times across 148 lines of Turkish
medical text (docs/FAZ0-BULGULAR.md): `görülmemiştir` arrives as
`gorulmemistir`, `sağ` as `sag`. Without folding, the detector finds no
negation and no laterality in that text at all — and a token that was never
detected cannot be compared, so the passage reads as one that simply contains
no negation. That is the hole these tests close.

**Detection folds; comparison does not.** The distinction is the whole point:

* detection folds, so `sag` is recognized as laterality instead of vanishing
* comparison does *not* fold, so gold `sağ` read as `sag` is still reported —
  the chosen OCR (Google Document AI) can write Turkish, and §24.3 requires
  those characters to survive
* the payoff is a clearer verdict: `replace: sağ -> sag` instead of
  `delete: sağ -> —`, which wrongly suggests the word disappeared
"""

from __future__ import annotations

import pytest

from evals.ocr_eval.critical_tokens import contains_critical_token, detect_critical_tokens
from evals.ocr_eval.metrics import (
    added_critical_tokens,
    critical_token_error_rate,
    critical_token_mismatches,
)
from evals.ocr_eval.normalize import fold_diacritics

#: Sentences whose critical tokens must be found with or without diacritics.
SENTENCES = [
    "görülmemiştir",
    "bu doğru değildir",
    "sağ böbrekte kitle",
    "sol böbrekte kitle",
    "kullanılmamalıdır",
    "yükselir",
    "çoğalır",
    "düşürür",
    "gerilemez",
    "hipokalemi gelişmez",
    "0,5 mg IM uygulanmaz",
    "beklemeksizin verilir",
]


def classes(text: str) -> list[str]:
    return sorted(t.token_class for t in detect_critical_tokens(text))


@pytest.mark.parametrize("sentence", SENTENCES)
def test_same_classes_with_and_without_diacritics(sentence):
    assert classes(sentence) == classes(fold_diacritics(sentence))


@pytest.mark.parametrize("sentence", SENTENCES)
def test_every_sentence_actually_has_a_critical_token(sentence):
    """Guards the guard — comparing two empty lists would pass vacuously."""
    assert classes(sentence), f"örnek kritik token içermiyor: {sentence}"


@pytest.mark.parametrize("sentence", SENTENCES)
def test_ascii_turkish_is_not_mistaken_for_safe_text(sentence):
    """The safety-critical consequence: a passage whose negation was written
    without diacritics must not answer "no critical token here"."""
    assert contains_critical_token(fold_diacritics(sentence))


def test_the_fold_is_length_preserving():
    """Spans are reported against the original string, so any length change
    here would silently shift every following offset."""
    for sentence in SENTENCES:
        assert len(fold_diacritics(sentence)) == len(sentence)


def test_reported_span_is_sliced_from_the_original_text():
    """§0.5: the detector reports what was written; it never rewrites it."""
    text = "sağ böbrekte kitle görülmemiştir"
    for token in detect_critical_tokens(text):
        assert token.text == text[token.start:token.end]


def test_folding_does_not_merge_left_and_right():
    """The collision that would matter most: sağ/sol must stay distinct after
    folding, or a reversed laterality would score as correct."""
    assert fold_diacritics("sağ") != fold_diacritics("sol")
    assert critical_token_mismatches("sag böbrek", "sol böbrek")


def test_folded_patterns_are_derived_not_duplicated():
    """A pattern added to `_PATTERNS` must be covered by the folded pass
    automatically; a second hand-written list is how one silently falls
    behind."""
    from evals.ocr_eval.critical_tokens import _FOLDED_PATTERNS, _PATTERNS

    assert len(_FOLDED_PATTERNS) == len(_PATTERNS)
    assert [c for c, _ in _FOLDED_PATTERNS] == [c for c, _ in _PATTERNS]
    for (_, original), (_, folded) in zip(_PATTERNS, _FOLDED_PATTERNS):
        assert folded.pattern == fold_diacritics(original.pattern)
        assert folded.flags == original.flags


class TestLostDiacriticIsStillReported:
    """§24.3: the OCR we chose can write Turkish, so losing a diacritic is a
    real transcription defect. Detection folding must not forgive it."""

    CASES = [
        ("sağ böbrekte kitle", ["sağ"]),
        ("ilaç kullanılmamalıdır", ["kullanılmamalıdır"]),
        ("hipokalemi görülmemiştir", ["hipokalemi", "görülmemiştir"]),
    ]

    @pytest.mark.parametrize("gold,tokens", CASES)
    def test_the_gate_does_not_pass_ascii_turkish(self, gold, tokens):
        hypothesis = fold_diacritics(gold)
        fired = (
            bool(critical_token_mismatches(gold, hypothesis))
            or critical_token_error_rate(tokens, hypothesis) > 0.0
            or bool(added_critical_tokens(gold, hypothesis))
        )
        assert fired, f"diakritik kaybı sessizce geçti: {gold!r}"

    def test_the_verdict_names_both_sides(self):
        """Because the token is now detected on both sides, the mismatch reads
        as a substitution rather than a disappearance."""
        mismatches = critical_token_mismatches("sağ böbrekte", "sag böbrekte")
        assert mismatches
        joined = " ".join(mismatches)
        assert "replace" in joined
        assert "sağ" in joined and "sag" in joined


class TestRealChangesAreStillCaught:
    """Folding must not swallow a genuine meaning flip — in either spelling."""

    CASES = [
        ("sağ böbrekte kitle", "sol böbrekte kitle", ["sağ"]),
        ("sag bobrekte kitle", "sol bobrekte kitle", ["sag"]),
        ("kullanılmamalıdır", "kullanılmalıdır", ["kullanılmamalıdır"]),
        ("kullanilmamalidir", "kullanilmalidir", ["kullanilmamalidir"]),
        ("0,5 mg IM", "0,5 mg IV", ["IM"]),
        ("0,5 mg", "0,05 mg", ["0,5"]),
        ("hipokalemi", "hiperkalemi", ["hipokalemi"]),
        ("gorulmemistir", "gorulmustur", ["gorulmemistir"]),
    ]

    @pytest.mark.parametrize("gold,hypothesis,tokens", CASES)
    def test_at_least_one_measure_fires(self, gold, hypothesis, tokens):
        fired = (
            bool(critical_token_mismatches(gold, hypothesis))
            or critical_token_error_rate(tokens, hypothesis) > 0.0
            or bool(added_critical_tokens(gold, hypothesis))
        )
        assert fired, f"anlam değişimi kaçtı: {gold!r} -> {hypothesis!r}"
