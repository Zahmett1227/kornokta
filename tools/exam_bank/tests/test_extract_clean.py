"""Line classification and text assembly (A1 §5.3/5–6)."""
import pytest

from tools.exam_bank.extract import clean
from tools.exam_bank.extract.columns import Line

from .layout import LEFT_TEXT, row


def _lines(*rows):
    return [Line(1, 0, r) for r in rows]


def test_line_end_hyphenation_is_joined_only_before_lower_case():
    text = clean.assemble(_lines(row("Fossa cranii media ile infratemporalis’i bir-", LEFT_TEXT, 100),
                                 row("leştiren oluşum; HMG-", LEFT_TEXT, 110),
                                 row("KoA redüktaz", LEFT_TEXT, 120)))
    assert text == "Fossa cranii media ile infratemporalis’i birleştiren oluşum; HMG-KoA redüktaz"


def test_paragraphs_and_premises_keep_their_breaks():
    text = clean.assemble(_lines(row("Elli yaşında hasta başvuruyor.", LEFT_TEXT, 100),
                                 row("Tetkikler normal.", LEFT_TEXT, 110),
                                 row("I. Nucleus nervi facialis", LEFT_TEXT, 130),
                                 row("II. Nucleus principalis", LEFT_TEXT, 146),
                                 row("Yukarıdakilerden hangileri doğrudur?", LEFT_TEXT, 162)))
    assert text.split("\n") == ["Elli yaşında hasta başvuruyor. Tetkikler normal.",
                                "I. Nucleus nervi facialis", "II. Nucleus principalis",
                                "Yukarıdakilerden hangileri doğrudur?"]


def test_text_is_nfc():
    decomposed = "ş"  # "ş" as s + combining cedilla
    assert clean.assemble(_lines(row(f"ka{decomposed}", LEFT_TEXT, 100))) == "kaş"


def test_the_compilations_tag_is_not_question_text():
    text = clean.assemble(_lines(row("Hangisi bulunmaz? (DUS’da sorulmaya uygun)", LEFT_TEXT, 100)))
    assert text == "Hangisi bulunmaz?"


@pytest.mark.parametrize("line", [
    "Diğer sayfaya geçiniz.", "1 Diğer sayfaya geçiniz.", "2019-TUS 1. Dönem/TTBT",
    "2013-TUS2013-TUS SonbaharSonbahar//TTBTTTBT", "Bu testte 120 soru vardır.",
    "2006-B-TTBT-1", "(DUS’da sorulmaya uygun)", "TUS İLKBAHAR 2024", "KLİNİK BİLİMLER TESTİ",
])
def test_noise(line):
    assert clean.is_noise(line)


@pytest.mark.parametrize("line", [
    "BİRİNCİ TEST BİTTİ.", "TEMEL TIP BİLİMLERİ TESTİ-1 BİTTİ.", "KLİNİK TIP BİLİMLERİ TESTİNE GEÇİNİZ.",
    "TEMEL BİLİMLER CEVAP ANAHTARI", "A KİTAPÇIĞI", "SINAVDA UYULACAK KURALLAR", "04-10-2020",
])
def test_stop(line):
    assert clean.is_stop(line)


@pytest.mark.parametrize("line,expected", [
    ("1. A 48. D 95. D", True),
    ("88. İPTAL", True),
    ("1. B 48.", True),               # the pair's letter fell in the other column
    ("E 180. E 200.", True),          # and here its number did
    ("1 E 26 D 51 B 76 D", True),     # F6 table
    ("12. A vitamini eksikliğinde", False),
    ("A) Nervus facialis", False),
    ("48.", False),
])
def test_key_lines(line, expected):
    assert clean.is_key_line(line) is expected


def test_revision_notes():
    assert clean.is_revision_note("Bu sorunun orijinal hali hatalı olması nedeniyle modifiye edilmiştir…")
    assert clean.is_revision_note("hazırlanmış bu soru minör revizyon ile onarılmış, sonraki nesillere")
    assert not clean.is_revision_note("Kolon kanserinin modifiye edilebilen risk faktörleri")


def test_group_head():
    m = clean.GROUP_HEAD.match("73. ve 74. SORULARI AŞAĞIDAKİ BİLGİLERE")
    assert (m.group(1), m.group(2)) == ("73", "74")
    assert clean.GROUP_HEAD.match("40.-41. SORULARI AŞAĞIDAKİ BİLGİLERE GÖRE CEVAPLAYINIZ.")


def test_symbol_font_code_points_become_unicode():
    assert clean.nfc("Ca2 ve -ketoglutarat, 39 C, BMI 40") == "Ca+2 ve α-ketoglutarat, 39 °C, BMI ≥40"
    assert not clean.unreadable(clean.nfc(""))


def test_unmapped_glyphs_are_reported_not_guessed():
    assert clean.unreadable("(cid:129)")
    assert clean.unreadable("x")
