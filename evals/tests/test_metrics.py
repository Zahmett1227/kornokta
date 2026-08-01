import pytest

from evals.ocr_eval.metrics import (
    added_critical_tokens,
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

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [
            ("1", "10 mg"),        # dose read ten times too high
            ("0,1", "10,1 mg"),
            ("5", "15 mg"),
            ("0,3", "0,35 mg"),
            ("adrenalin", "noradrenalin verildi"),  # different drug
            ("1", "1,5 mg"),
            ("sol", "solunum sistemi"),   # laterality vs a different word
            ("sağ", "sağlıklı birey"),
        ],
    )
    def test_partial_match_is_not_a_pass(self, gold, hypothesis):
        # Substring membership would score these 0.0 and make the Faz 0
        # critical-token gate look clean on exactly the errors it exists to
        # catch (§24.3).
        assert critical_token_error_rate([gold], hypothesis) == 1.0

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [
            ("0,1", "doz 0,1 mg/kg"),
            ("mg", "500 mg/kg verilir"),
            ("adrenalin", "adrenalindir"),      # Turkish suffix still matches
            ("0,3–0,5", "0,3–0,5 mg IM"),
            ("%40", "%40 oranında"),
            ("hiperkalemi", "Hiperkalemide görülür"),
            ("mmHg", "120 mmHg"),
            ("1", "1 mg verildi"),
            ("sol", "sol alt kadran"),
            ("sağ", "sağa doğru"),        # dative suffix, same word
            ("sol", "solda kitle"),       # locative suffix, same word
            ("1", "Evre 1."),             # sentence-final period is not a decimal
            ("0,1", "Doz 0,1."),
        ],
    )
    def test_genuine_occurrences_still_count_as_correct(self, gold, hypothesis):
        assert critical_token_error_rate([gold], hypothesis) == 0.0

    def test_repeated_tokens_need_distinct_occurrences(self):
        # Searching each gold entry independently would let the surviving '5'
        # satisfy both doses and hide the second one being misread as '50'.
        assert critical_token_error_rate(
            ["5", "5"], "5 mg sabah, 50 mg akşam"
        ) == pytest.approx(0.5)

    def test_repeated_tokens_pass_when_all_present(self):
        assert critical_token_error_rate(["5", "5"], "5 mg sabah, 5 mg akşam") == 0.0

    def test_repeated_tokens_all_missing(self):
        assert critical_token_error_rate(["5", "5"], "50 mg sabah, 50 mg akşam") == 1.0

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [
            ("sağ", "sağında kitle"),          # possessive + case
            ("sol", "solunda kitle"),
            ("hiperkalemi", "hiperkalemilerde"),  # plural + case
            ("adrenalin", "adrenalinlerden"),
        ],
    )
    def test_stacked_inflectional_suffixes_are_accepted(self, gold, hypothesis):
        assert critical_token_error_rate([gold], hypothesis) == 0.0

    def test_suffix_chain_still_rejects_a_different_lexeme(self):
        # The ordered slots must not let 'sol' + 'un' + 'um' parse 'solunum'.
        assert critical_token_error_rate(["sol"], "solunum sistemi") == 1.0

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [("sağ", "Tedavi akım sağlar"), ("sol", "akım sollar")],
    )
    def test_plural_does_not_form_a_homographic_verb(self, gold, hypothesis):
        # 'sağlar' is the verb "provides"; reading it as 'sağ' + plural would
        # let a lost laterality pass whenever that verb appears nearby.
        assert critical_token_error_rate([gold], hypothesis) == 1.0

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [("hiperkalemi", "hiperkalemilerde"), ("adrenalin", "adrenalinlerden")],
    )
    def test_plural_still_allowed_on_longer_roots(self, gold, hypothesis):
        assert critical_token_error_rate([gold], hypothesis) == 0.0

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [
            ("g", "doz 5 q / gün"),   # 'gün' is not the unit 'g' plus a suffix
            ("mg", "mgr değil"),
        ],
    )
    def test_short_unit_tokens_take_no_suffixes(self, gold, hypothesis):
        assert critical_token_error_rate([gold], hypothesis) == 1.0

    @pytest.mark.parametrize(
        "gold, hypothesis",
        [("mg", "500 mg/kg"), ("g", "5 g verildi"), ("L", "2 L sıvı"), ("mmHg", "120 mmHg")],
    )
    def test_units_still_match_when_present(self, gold, hypothesis):
        assert critical_token_error_rate([gold], hypothesis) == 0.0


class TestAddedCriticalTokens:
    def test_clean_reading_adds_nothing(self):
        assert added_critical_tokens("Doz 0,5 mg/kg", "Doz 0,5 mg/kg") == []

    def test_extra_dose_endpoint_is_reported(self):
        # The recall metric alone scores this clean: every gold token survived.
        assert critical_token_error_rate(["1", "mg"], "1–2 mg") == 0.0
        assert added_critical_tokens("1 mg", "1–2 mg") == ["1–2"]

    def test_added_negation_is_reported(self):
        assert "değildir" in added_critical_tokens("etkilidir", "etkili değildir")

    def test_removed_token_is_not_reported_as_added(self):
        assert added_critical_tokens("5 mg ve 10 mg", "5 mg") == []

    @pytest.mark.parametrize(
        "gold_text, hypothesis",
        [("mortalite %40", "mortalite % 40"), ("q8h uygulanır", "q8 h uygulanır")],
    )
    def test_respacing_is_not_an_added_token(self, gold_text, hypothesis):
        # These patterns accept either spacing, so the value is unchanged.
        assert added_critical_tokens(gold_text, hypothesis) == []

    def test_drug_substitution_is_reported(self):
        from evals.ocr_eval.critical_tokens import Wordlists

        wordlists = Wordlists(drug_names={"adrenalin"})
        # 'adrenalin' must not be read out of 'noradrenalin', otherwise both
        # texts look like they mention the same drug and the swap passes.
        assert added_critical_tokens(
            "noradrenalin verildi", "adrenalin verildi", wordlists
        ) == ["adrenalin"]


class TestBufferedCopula:
    @pytest.mark.parametrize(
        "gold, hypothesis",
        [("sağ", "Lezyon sağdaydı"), ("sol", "Lezyon soldaydı")],
    )
    def test_case_plus_buffered_copula_is_accepted(self, gold, hypothesis):
        # Turkish inserts a buffer 'y' between a vowel-final case suffix and
        # the copula; without it a perfect transcription scores as an error.
        assert critical_token_error_rate([gold], hypothesis) == 0.0
