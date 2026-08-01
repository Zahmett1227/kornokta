import pytest

from evals.ocr_eval.metrics import (
    cer,
    critical_token_error_rate,
    levenshtein,
    selection_prf,
    wer,
)


class TestLevenshtein:
    def test_identical(self):
        assert levenshtein("abc", "abc") == 0

    def test_substitution(self):
        assert levenshtein("kitten", "sitten") == 1

    def test_empty(self):
        assert levenshtein("", "abc") == 3

    def test_word_sequences(self):
        assert levenshtein(["a", "b", "c"], ["a", "x", "c"]) == 1


class TestCer:
    def test_perfect(self):
        assert cer("hiperkalemi", "hiperkalemi") == 0.0

    def test_case_normalized(self):
        assert cer("HİPERKALEMİ", "hiperkalemi") == 0.0

    def test_single_char_error(self):
        # 'hipokalemi' vs 'hiperkalemi': small char distance, huge meaning change —
        # this is exactly why CER alone is not a quality gate (§10.5).
        assert 0 < cer("hiperkalemi", "hipokalemi") < 0.3

    def test_empty_reference(self):
        assert cer("", "") == 0.0
        assert cer("", "x") == 1.0


class TestWer:
    def test_perfect(self):
        assert wer("doz 0,1 mg/kg", "doz 0,1 mg/kg") == 0.0

    def test_one_word_wrong(self):
        assert wer("doz 0,1 mg/kg", "doz 0.1 mg/kg") == pytest.approx(1 / 3)


class TestSelectionPrf:
    def test_perfect_selection(self):
        result = selection_prf(["line_04", "line_05"], ["line_04", "line_05"])
        assert result.precision == 1.0
        assert result.recall == 1.0
        assert result.f1 == 1.0

    def test_neighbor_line_error(self):
        # Predicted the line below instead of the marked one.
        result = selection_prf(["line_04"], ["line_05"])
        assert result.precision == 0.0
        assert result.recall == 0.0
        assert result.false_positives == 1
        assert result.false_negatives == 1

    def test_partial_selection(self):
        result = selection_prf(["line_04", "line_05"], ["line_04"])
        assert result.precision == 1.0
        assert result.recall == 0.5

    def test_empty_gold_and_prediction(self):
        result = selection_prf([], [])
        assert result.precision == 1.0
        assert result.recall == 1.0


class TestCriticalTokenErrorRate:
    def test_all_tokens_present(self):
        rate = critical_token_error_rate(
            ["0,3–0,5", "mg", "adrenalin"],
            "Anafilakside ilk seçenek tedavi 0,3–0,5 mg IM adrenalindir.",
        )
        assert rate == 0.0

    def test_decimal_separator_swap_is_an_error(self):
        rate = critical_token_error_rate(["0,1"], "Doz 0.1 mg/kg")
        assert rate == 1.0

    def test_hypo_hyper_swap_is_an_error(self):
        rate = critical_token_error_rate(["hiperkalemi"], "Hipokalemide sivri T görülür")
        assert rate == 1.0

    def test_no_tokens(self):
        assert critical_token_error_rate([], "her şey yolunda") == 0.0
