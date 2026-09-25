"""One source file → papers (A1 end to end on synthetic pages)."""
from tools.exam_bank import registry as reg
from tools.exam_bank.extract import families, paper

from .layout import LEFT_NUM, LEFT_TEXT, RIGHT_NUM, RIGHT_TEXT, page, question, row


def _paper(pid, expected, offset=0, key="osym"):
    return reg.Paper(id=pid, date=None, expected=expected, number_offset=offset, time_limit_minutes=None,
                     penalty="unknown", key_source=key)


def _source(family, *papers):
    return reg.Source(file="x/test.pdf", sha256="a" * 64, family=family,
                      source_kind="osymPartial" if family == "F4" else "osym", papers=tuple(papers))


def test_sparse_paper_keeps_empty_slots_and_the_visible_answer():
    # F4: ÖSYM prints every number but fills ~10% of the slots.
    rows = [row("1.", LEFT_NUM, 100)]
    rows += question(2, 200, ["Görünen soru hangisidir?"], list("abcde"))
    rows += [row("DOĞRU CEVAP: C", LEFT_TEXT, 330)]
    rows += [row("3.", RIGHT_NUM, 100)]
    src = _source("F4", _paper("TUS-2024-2-T", 3))
    [result] = paper.extract_source(src, families.family_for("F4"), [page(1, *rows, gutter=297)])
    assert result.missing == []
    q1, q2, q3 = result.questions
    assert q1.empty and q3.empty
    assert not q2.empty and q2.answer_marks == ["C"] and q2.options == list("abcde")


def test_cancelled_slot():
    rows = question(1, 100, ["Normal soru"], list("abcde"))
    rows += [row("2.", LEFT_NUM, 300) + row("Bu soru iptal edilmiştir.", LEFT_TEXT, 300)]
    rows += question(3, 100, ["Üçüncü"], list("abcde"), column=1)
    src = _source("F3", _paper("TUS-2014-1-T", 3))
    [result] = paper.extract_source(src, families.family_for("F3"), [page(1, *rows, gutter=297)])
    assert [q.cancelled for q in result.questions] == [False, True, False]


def test_straight_through_numbering_is_split_by_offset():
    # F5: Temel 1–2 and Klinik 3–4 in one run → Klinik questions are 1–2.
    rows = question(1, 80, ["t1"], list("abcde")) + question(2, 250, ["t2"], list("abcde"))
    rows += question(3, 80, ["k1"], list("abcde"), column=1) + question(4, 250, ["k2"], list("abcde"), column=1)
    src = reg.Source(file="x/derleme.pdf", sha256="b" * 64, family="F5", source_kind="tusdata",
                     papers=(_paper("TUS-2025-1-T", 2, 0, "tusdata"), _paper("TUS-2025-1-K", 2, 2, "tusdata")))
    t, k = paper.extract_source(src, families.family_for("F5"), [page(1, *rows, gutter=297)])
    assert [(q.number, q.printed, q.stem) for q in k.questions] == [(1, 3, "k1"), (2, 4, "k2")]
    assert [q.stem for q in t.questions] == ["t1", "t2"]


def test_region_takes_in_a_figure_below_the_last_text():
    from tools.exam_bank.extract.columns import Box
    rows = question(1, 100, ["Şekildeki yapı hangisidir?"], list("abcde"))
    p = page(1, *rows, gutter=297)
    p.graphics.append(Box(70, 250, 250, 400, "image"))
    src = _source("F3", _paper("TUS-2019-1-T", 1))
    [result] = paper.extract_source(src, families.family_for("F3"), [p])
    region = result.questions[0].regions[0]
    assert region.bottom >= 400 and region.x1 <= 297


def test_unreadable_text_layer_is_listed():
    # 2011/1's glyphs decode to nonsense; A6 reads it from page images.
    assert "2006-2012/TUS_2011_Ilkbahar_TemelKlinik.pdf" in families.UNREADABLE_TEXT
