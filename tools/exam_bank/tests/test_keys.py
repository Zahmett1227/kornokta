"""A2 — reading printed answer keys (§5.4), on synthetic key pages."""
from tools.exam_bank import keys
from tools.exam_bank import registry as reg

from .layout import page, row


def _grid(first, last, columns=4, x0=76.0, step=123.0, top=150.0, pitch=19.0, dotted=True,
          answers="ABCDE", cancelled=()):
    """A key grid as the booklets print it: numbers run down each column."""
    per = -(-(last - first + 1) // columns)
    rows_ = {}
    for i, n in enumerate(range(first, last + 1)):
        col, r = divmod(i, per)
        letter = "İptal" if n in cancelled else answers[n % 5]
        label = f"{n}." if dotted else str(n)
        rows_.setdefault(r, []).extend(row(f"{label} {letter}", x0 + col * step, top + r * pitch))
    return list(rows_.values())


def _paper(pid, expected=120, offset=0, key="osym"):
    return reg.Paper(pid, None, expected, offset, None, "unknown", key)


def test_f3_grid_with_cancellations():
    p = page(24, row("TEMEL TIP BİLİMLERİ TESTİ", 180, 80), *_grid(1, 120, columns=3, cancelled={6, 38}))
    src = reg.Source("x/TUS_2015_Sonbahar_Klinik.pdf", "a" * 64, "F3", "osym", (_paper("TUS-2015-2-K"),))
    key = keys.read_keys(src, [page(1, row("soru sayfası", 60, 100)), p])["TUS-2015-2-K"]
    assert keys.completeness(key, 120) == []
    assert key.entries[6].cancelled and key.entries[6].answer is None
    assert key.entries[7].answer == "ABCDE".index("ABCDE"[7 % 5])


def test_f2_pages_are_told_apart_by_their_heading():
    temel = page(31, row("TEMEL TIP BİLİMLERİ TESTİ-1", 200, 88), row("A KİTAPÇIĞI", 270, 110), *_grid(1, 100))
    ikinci = page(32, row("TEMEL TIP BİLİMLERİ TESTİ-2", 200, 88), row("A KİTAPÇIĞI", 270, 110),
                  *_grid(1, 100, answers="EDCBA"))
    src = reg.Source("x/TUS_2011_Ilkbahar_TemelKlinik.pdf", "b" * 64, "F2", "osym",
                     (_paper("TUS-2011-1-T", 100), _paper("TUS-2011-1-T2", 100)))
    found = keys.read_keys(src, [temel, ikinci])
    assert set(found) == {"TUS-2011-1-T", "TUS-2011-1-T2"}
    assert found["TUS-2011-1-T"].entries[1].answer == "ABCDE".index("B")
    assert found["TUS-2011-1-T2"].entries[1].answer == "ABCDE".index("D")
    assert all(keys.completeness(k, 100) == [] for k in found.values())


def test_klinik_heading():
    klinik = page(32, row("KLİNİK TIP BİLİMLERİ TESTİ", 200, 88), *_grid(1, 100))
    src = reg.Source("x/f.pdf", "c" * 64, "F2", "osym", (_paper("TUS-2009-1-T", 100), _paper("TUS-2009-1-K", 100)))
    assert set(keys.read_keys(src, [klinik])) == {"TUS-2009-1-K"}


def test_compilation_key_beside_questions_is_read_from_its_column_only():
    # 2025/1: questions in the left column, the key under a heading in the right.
    questions = [row(f"{n}. A vitamini eksikliğinde hangisi görülür?", 42, 300 + 12 * n) for n in range(1, 30)]
    key_rows = _grid(1, 100, columns=5, x0=320, step=48, top=265, pitch=12)
    p = page(62, *questions, row("TEMEL BİLİMLER CEVAP ANAHTARI", 341, 250), *key_rows)
    pairs = keys.pairs_in(keys.key_region(p), 62)
    assert sorted(pr.number for pr in pairs) == list(range(1, 101))


def test_compilation_key_goes_to_the_exam_before_it():
    grid = _grid(1, 200, columns=10, x0=40, step=52, top=130, pitch=14)
    key_page = page(43, row("TEMEL BİLİMLER CEVAP ANAHTARI", 60, 100) + row("KLİNİK BİLİMLER CEVAP ANAHTARI", 330, 100),
                    *grid)
    papers = (_paper("TUS-2024-1-T", 100, 0, "none"), _paper("TUS-2024-1-K", 100, 100, "none"),
              _paper("TUS-2024-2-T", 100, 0, "tusdata"), _paper("TUS-2024-2-K", 100, 100, "tusdata"))
    src = reg.Source("x/derleme.pdf", "d" * 64, "F5", "tusdata", papers)
    spans = {"TUS-2024-1-T": (1, 11), "TUS-2024-1-K": (12, 23), "TUS-2024-2-T": (25, 32), "TUS-2024-2-K": (33, 42)}
    found = keys.read_keys(src, [key_page], spans)
    assert set(found) == {"TUS-2024-2-T", "TUS-2024-2-K"}   # 2024/1 has no key in the compilation
    assert sorted(found["TUS-2024-2-K"].entries) == list(range(1, 101))
    assert found["TUS-2024-2-K"].entries[1].answer == "ABCDE".index("ABCDE"[101 % 5])


def test_reconstruction_table_without_dots():
    p = page(11, row("Cevap Anahtarı (1–100)", 40, 43), row("Soru Cevap Soru Cevap", 60, 98),
             *_grid(1, 100, dotted=False, top=118, pitch=20))
    src = reg.Source("x/Temel.pdf", "e" * 64, "F6", "reconstruction", (_paper("TUS-2026-2-T", 100, 0, "reconstruction"),))
    key = keys.read_keys(src, [p])["TUS-2026-2-T"]
    assert keys.completeness(key, 100) == []


def test_completeness_names_every_fault():
    key = keys.Key("TUS-2019-1-T", "osym", "f.pdf")
    for n in (1, 2, 4, 121):
        key.entries[n] = keys.Pair(n, 0, False, 1)
    key.duplicates.append(2)
    problems = " ".join(keys.completeness(key, 4))
    assert "eksik numara [3]" in problems and "[121]" in problems and "iki kez" in problems


def test_glued_pair():
    assert [(p.number, p.answer) for p in keys.pairs_in(row("7.C 8. D", 60, 100), 1)] == [(7, 2), (8, 3)]


def test_a_question_page_is_not_a_key_page():
    p = page(3, *[row(f"{n}. Aşağıdakilerden hangisi doğrudur?", 49, 100 + 30 * n) for n in range(1, 8)])
    assert keys.key_pages([p]) == []
