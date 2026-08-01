from evals.ocr_eval.critical_tokens import (
    Wordlists,
    contains_critical_token,
    detect_critical_tokens,
)


def classes_of(text, wordlists=None):
    return {t.token_class for t in detect_critical_tokens(text, wordlists)}


class TestNumbersAndUnits:
    def test_decimal_number(self):
        assert "number_decimal" in classes_of("doz 0,1 verilir")

    def test_range_with_dash(self):
        tokens = [t for t in detect_critical_tokens("0,3–0,5 mg") if t.token_class == "number_decimal"]
        assert any(t.text == "0,3–0,5" for t in tokens)

    def test_units(self):
        assert "unit" in classes_of("140 mEq/L üzerinde")
        assert "unit" in classes_of("basınç 120 mmHg")
        assert "unit" in classes_of("5 mg tablet")

    def test_dose_frequency(self):
        assert "dose_frequency" in classes_of("0,5 mg/kg başlanır")
        assert "dose_frequency" in classes_of("q8h uygulanır")
        assert "dose_frequency" in classes_of("günde 2 kez")

    def test_percentage(self):
        assert "percentage" in classes_of("%40 oranında")
        assert "percentage" in classes_of("mortalite 15 % bulunmuştur")


class TestSymbols:
    def test_comparators(self):
        assert "comparator" in classes_of("K ≥ 6,5 ise")
        assert "comparator" in classes_of("pH < 7,2")

    def test_greek_letters(self):
        assert "greek_letter" in classes_of("β-blokör kullanımı")
        assert "greek_letter" in classes_of("α reseptör")

    def test_ion_charge_unicode(self):
        assert "ion_charge" in classes_of("Na⁺ kanalları")
        assert "ion_charge" in classes_of("Ca²⁺ girişi")

    def test_ion_charge_ascii(self):
        assert "ion_charge" in classes_of("K+ düzeyi yükselir")

    def test_standalone_plus_minus(self):
        assert "plus_minus" in classes_of("Babinski (+) saptandı")


class TestTurkishSemanticClasses:
    def test_hypo_hyper(self):
        assert "hypo_hyper" in classes_of("hipokalsemi gelişir")
        assert "hypo_hyper" in classes_of("Hipertansiyon sıktır")

    def test_positive_negative(self):
        assert "positive_negative" in classes_of("kültür negatif geldi")

    def test_negation_pairs(self):
        assert "negation_pair" in classes_of("refleks yok")
        assert "negation_pair" in classes_of("renin salınımını artırır")

    def test_laterality(self):
        assert "laterality" in classes_of("sol alt kadran ağrısı")

    def test_proximal_distal(self):
        assert "proximal_distal" in classes_of("proksimal tübülde emilir")

    def test_stage_grade(self):
        assert "stage_grade_class" in classes_of("Evre III hastalık")
        assert "stage_grade_class" in classes_of("2. derece blok")


class TestWordlists:
    def test_drug_name_from_wordlist(self):
        wl = Wordlists(drug_names={"adrenalin", "amiodaron"})
        tokens = detect_critical_tokens("İlk seçenek adrenalindir", wl)
        assert any(t.token_class == "drug_name" and t.text == "adrenalin" for t in tokens)

    def test_organism_name_from_wordlist(self):
        wl = Wordlists(organism_names={"E. coli"})
        assert "organism_name" in classes_of("etken E. coli olabilir", wl)

    def test_empty_wordlist_no_flag(self):
        assert "drug_name" not in classes_of("İlk seçenek adrenalindir")


class TestBehavior:
    def test_plain_text_not_flagged(self):
        assert not contains_critical_token("bu cümlede kritik öğe bulunmuyor")

    def test_overlapping_spans_all_kept(self):
        classes = classes_of("0,5 mg/kg dozunda")
        assert {"dose_frequency", "number_decimal", "unit"} <= classes

    def test_tokens_sorted_by_position(self):
        tokens = detect_critical_tokens("hiperkalemi ve %40 mortalite")
        positions = [t.start for t in tokens]
        assert positions == sorted(positions)
