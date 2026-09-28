"""Columns, lines and word joining (A1 §5.3/1–2)."""
from tools.exam_bank.extract import columns
from tools.exam_bank.extract.columns import Word

from .layout import LEFT_NUM, LEFT_TEXT, RIGHT_NUM, RIGHT_TEXT, WIDTH, page, row


def test_two_columns_read_left_then_right():
    # Rows at the same height in both columns must not interleave — the bug
    # plain text extraction has ("1. 2. Elli dokuz yaşındaki …").
    p = page(1,
             row("1.", LEFT_NUM, 100) + row("Sol birinci", LEFT_TEXT, 100),
             row("2.", RIGHT_NUM, 100) + row("Sağ birinci", RIGHT_TEXT, 100),
             row("sol ikinci", LEFT_TEXT, 110),
             row("sağ ikinci", RIGHT_TEXT, 110))
    lines, wide = columns.column_lines(p)
    assert [l.text for l in lines] == ["1. Sol birinci", "sol ikinci", "2. Sağ birinci", "sağ ikinci"]
    assert [l.column for l in lines] == [0, 0, 1, 1]
    assert wide == []


def test_full_width_rows_are_set_aside():
    title = row("TEMEL TIP BİLİMLERİ TESTİ ve uzun bir açıklama satırı sayfanın ortasını geçer", 120, 60)
    p = page(1, title,
             row("1.", LEFT_NUM, 100) + row("Soru metni", LEFT_TEXT, 100),
             row("2.", RIGHT_NUM, 100) + row("Öbür sütun", RIGHT_TEXT, 100))
    lines, wide = columns.column_lines(p)
    assert [l.text for l in wide] == [columns.join_words(title)]
    assert all("TEMEL" not in l.text for l in lines)


def test_gutter_is_the_gap_nearest_the_middle():
    # Right-column numbers hang at 304 with text at 335: the number–text gap
    # (≈318–335) is as clean as the real gutter (≈291–304) and wider.
    rows_ = []
    for i in range(8):
        y = 100 + 12 * i
        rows_.append(row("sol sütun metni burada biter", 60, y, char=9.2))   # ends ≈ 291
        rows_.append(row(f"{i + 10}.", 304, y) + row("sağ metin", 335, y))
    gutter = columns.find_gutter([w for r in rows_ for w in r], WIDTH)
    assert 290 < gutter < 304


def test_document_gutter_steadies_an_odd_page():
    good = [page(n, row("sol metin", LEFT_TEXT, 100), row("sağ metin", RIGHT_TEXT, 100), gutter=297.0)
            for n in (1, 2, 3)]
    odd = page(4, row("tek sütunlu tablo satırı", 200, 100))
    gutters = columns.page_gutters(good + [odd])
    assert gutters[4] == 297.0


def test_subscript_folds_into_its_line():
    base = row("H", LEFT_TEXT, 100)
    sub = [Word("1", base[0].x1 + 0.2, base[0].x1 + 3.2, 103.0, 109.0, 6.0)]
    rest = [Word("-reseptör", sub[0].x1 + 0.2, sub[0].x1 + 40, 100.0, 109.0, 9.0)]
    lines = columns.group_lines(base + sub + rest)
    assert [l.text for l in lines] == ["H1-reseptör"]


def test_superscript_does_not_open_a_line_of_its_own():
    base = row("Ca", LEFT_TEXT, 100)
    sup = [Word("2+", base[0].x1 + 0.1, base[0].x1 + 6, 97.5, 103.5, 6.0)]
    lines = columns.group_lines(base + sup + row("düzeyi", base[0].x1 + 9, 100))
    assert [l.text for l in lines] == ["Ca2+ düzeyi"]


def test_narrow_gap_between_same_size_words_is_a_space():
    # The compilation's letters overlap the space before them: a real word
    # gap can be 0.5 pt. Same size, same baseline → still a space.
    a = Word("Travma", 100, 130, 100, 109, 8.0)
    b = Word("sonrası", 130.5, 160, 100, 109, 8.0)
    assert columns.join_words([a, b]) == "Travma sonrası"


def test_font_change_before_a_hyphen_is_not_a_space():
    a = Word("β", 100, 105, 100, 109, 9.0)
    b = Word("-hücresi", 107, 140, 100, 109, 9.0)
    assert columns.join_words([a, b]) == "β-hücresi"


def test_letter_spaced_line_is_read_as_words():
    words = []
    x = 60.0
    for token in ("Aşağıdaki", "inflamasyon", "mediatörlerinden"):
        for ch in token:
            words.append(Word(ch, x, x + 4, 100, 109, 9.0))
            x += 5.5        # 1.5 pt between letters
        x += 4.0            # plus 4 pt between words
    assert columns.join_words(words) == "Aşağıdaki inflamasyon mediatörlerinden"


def test_a_cell_centred_beside_a_two_line_cell_does_not_chain_the_rows():
    # 2017/2 Klinik 2: "Neisseria / meningitidis" beside a centred "– Sefotaksim".
    rows_ = [Word("Neisseria", 75, 115, 419.6, 428.6), Word("meningitidis", 75, 125, 430.1, 439.1),
             Word("–", 157, 161, 424.9, 433.9), Word("Sefotaksim", 182, 230, 424.9, 433.9)]
    lines = columns.group_lines(rows_)
    assert [l.text for l in lines] == ["Neisseria", "– Sefotaksim", "meningitidis"]
