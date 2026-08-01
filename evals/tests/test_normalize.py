import unicodedata

from evals.ocr_eval.normalize import (
    collapse_whitespace,
    nfc,
    normalize_for_compare,
    turkish_lower,
)


class TestTurkishLower:
    def test_dotted_capital_i_maps_to_i(self):
        assert turkish_lower("İLAÇ") == "ilaç"

    def test_dotless_capital_i_maps_to_dotless_i(self):
        assert turkish_lower("ILICA") == "ılıca"

    def test_mixed_medical_term(self):
        assert turkish_lower("HİPERKALEMİ") == "hiperkalemi"

    def test_preserves_turkish_specials(self):
        assert turkish_lower("ÖĞÜN ŞÜphe Çift") == "öğün şüphe çift"


class TestNfc:
    def test_combining_dot_composed(self):
        decomposed = unicodedata.normalize("NFD", "iç")
        assert nfc(decomposed) == "iç"

    def test_greek_letters_survive(self):
        assert nfc("β-blokör α₁") == "β-blokör α₁"


class TestNormalizeForCompare:
    def test_whitespace_collapsed(self):
        assert collapse_whitespace("a  b\t c\n") == "a b c"

    def test_decimal_comma_preserved(self):
        assert "0,1" in normalize_for_compare("Doz  0,1  mg/kg")

    def test_symbols_preserved(self):
        text = "Na⁺ > 145 mEq/L ise %3 NaCl"
        normalized = normalize_for_compare(text)
        for token in ("na⁺", ">", "145", "meq/l", "%3"):
            assert token in normalized

    def test_case_insensitive_match_for_same_word(self):
        assert normalize_for_compare("HİPOKALEMİ") == normalize_for_compare("hipokalemi")
