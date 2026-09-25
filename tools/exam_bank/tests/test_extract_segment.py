"""Question numbers → blocks (A1 §5.3/3)."""
from tools.exam_bank.extract import segment

from .layout import LEFT_NUM, LEFT_TEXT, RIGHT_NUM, RIGHT_TEXT, page, question, row


def _stream(*pages):
    return segment.build_stream(list(pages))


def _numbers(stream, first=1, last=None, sparse=False, style="number"):
    found = segment.markers(stream, style)
    last = last if last is not None else first + 50
    run = segment.chain(stream, found, first, last, sparse=sparse)
    return run


def _paper(first, count, per_column=3, start_top=100):
    """Questions first…first+count-1 on one page, `per_column` to a column."""
    rows = []
    for i in range(count):
        n = first + i
        col = 0 if i < per_column else 1
        top = start_top + (i % per_column) * 150
        rows.extend(question(n, top, [f"Soru {n} kökü", "aşağıdakilerden hangisidir?"],
                             [f"şık{j}" for j in range(5)], column=col))
    return rows


def test_sequence_across_columns_and_pages():
    st = _stream(page(1, *_paper(1, 6), gutter=297), page(2, *_paper(7, 6), gutter=297))
    run = _numbers(st, last=12)
    assert [m.number for m in run.accepted] == list(range(1, 13))
    assert [(st.lines[m.index].line.page, st.lines[m.index].line.column) for m in run.accepted[2:4]] == \
        [(1, 0), (1, 1)]
    assert run.missing == []


def test_wrapped_line_starting_with_a_number_is_not_a_question():
    rows = question(1, 100, ["Hastanın torakal", "6. omurilik segmentinde yarım kesi", "saptanıyor. Hangisi?"],
                    list("abcde"))
    rows += question(2, 300, ["İkinci soru"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297))
    run = _numbers(st, last=2)
    assert [m.number for m in run.accepted] == [1, 2]


def test_premises_are_not_questions():
    rows = [row("5.", LEFT_NUM, 100) + row("I. Nucleus nervi facialis", LEFT_TEXT + 10, 100),
            row("II. Nucleus principalis", LEFT_TEXT + 10, 116),
            row("Hangileri kornea refleksinde yer alır?", LEFT_TEXT, 132)]
    rows += [row(f"{l}) şık", LEFT_TEXT, 150 + 16 * i) for i, l in enumerate("ABCDE")]
    st = _stream(page(1, *rows, gutter=297))
    run = _numbers(st, first=5, last=5)
    assert [m.number for m in run.accepted] == [5]
    block = segment.blocks(st, run.accepted, len(st.lines))[0]
    assert block.lines[0].text.startswith("I. Nucleus")


def test_cover_instructions_do_not_start_the_paper():
    # "1. Bu sınavda …" on the cover hangs like a question but has no options.
    cover = page(1,
                 row("1.", LEFT_NUM, 100) + row("Bu sınavda her adaya bir cevap kâğıdı verilir.", LEFT_TEXT, 100),
                 row("2.", LEFT_NUM, 130) + row("Bu kitapçıkta iki test vardır.", LEFT_TEXT, 130),
                 row("3.", RIGHT_NUM, 100) + row("Süre 210 dakikadır.", RIGHT_TEXT, 100),
                 gutter=297)
    body = page(2, *question(1, 100, ["Gerçek soru"], list("abcde")),
                *question(2, 300, ["İkinci"], list("abcde")), gutter=297)
    st = _stream(cover, body)
    run = _numbers(st, last=2)
    assert [st.lines[m.index].line.page for m in run.accepted] == [2, 2]


def test_a_single_unseen_number_is_bridged_and_reported():
    rows = []
    for i, n in enumerate([1, 2, 4, 5, 6]):
        rows += question(n, 80 + 140 * i, [f"Soru {n}"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297, height=900))
    run = _numbers(st, last=6)
    assert [m.number for m in run.accepted] == [1, 2, 4, 5, 6]
    assert run.missing == [3]


def test_a_number_printed_twice_stands_for_the_one_before():
    # 2013/2 Klinik: "9." printed for question 8, then "9." again.
    rows = []
    for i, n in enumerate([7, 9, 9, 10]):
        rows += question(n, 80 + 160 * i, [f"Soru {i}"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297, height=900))
    run = _numbers(st, first=7, last=10)
    assert [m.number for m in run.accepted] == [7, 8, 9, 10]
    assert run.misprinted == {8: 9}


def test_a_number_that_lost_its_first_digit():
    # The compilation's text layer has "08." for 108.
    rows = []
    for i, n in enumerate(["107", "08", "109"]):
        rows += question(n, 80 + 180 * i, [f"Soru {i}"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297, height=900))
    run = _numbers(st, first=107, last=109)
    assert [m.number for m in run.accepted] == [107, 108, 109]
    assert run.misprinted == {108: 8}


def test_a_number_at_the_text_edge_is_taken_only_when_nothing_else_can_be():
    rows = question(103, 80, ["Soru 103"], list("abcde"))
    rows += [row("104. Elli dokuz yaşındaki hasta", LEFT_TEXT, 260)] + \
        [row(f"{l}) x", LEFT_TEXT, 280 + 16 * i) for i, l in enumerate("ABCDE")]
    rows += question(105, 400, ["Soru 105"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297, height=900))
    run = _numbers(st, first=103, last=105)
    assert [m.number for m in run.accepted] == [103, 104, 105]


def test_two_papers_in_one_file_each_from_one():
    # F2: Temel 1–2 then Klinik 1–2, the second run starting after the first.
    rows = question(1, 80, ["Temel bir"], list("abcde")) + question(2, 250, ["Temel iki"], list("abcde"))
    rows2 = question(1, 80, ["Klinik bir"], list("abcde")) + question(2, 250, ["Klinik iki"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297), page(2, *rows2, gutter=297))
    found = segment.markers(st)
    t = segment.chain(st, found, 1, 2)
    k = segment.chain(st, found, 1, 2, start_at=t.accepted[-1].index + 1)
    assert [st.lines[m.index].line.page for m in t.accepted] == [1, 1]
    assert [st.lines[m.index].line.page for m in k.accepted] == [2, 2]


def test_soru_markers():
    rows = [row("Soru 1", 40, 80), row("Birinci kök?", 40, 92)] + \
        [row(f"{l}) x", 50, 110 + 12 * i) for i, l in enumerate("ABCDE")]
    rows += [row("Soru 2", 40, 200), row("İkinci kök?", 40, 212)] + \
        [row(f"{l}) y", 50, 230 + 12 * i) for i, l in enumerate("ABCDE")]
    st = _stream(page(1, *rows, gutter=297))
    run = _numbers(st, last=2, style="soru")
    blocks = segment.blocks(st, run.accepted, len(st.lines), "soru")
    assert [b.lines[0].text for b in blocks] == ["Birinci kök?", "İkinci kök?"]


def test_block_collects_osym_answer_and_stops_at_end_of_test():
    rows = question(1, 80, ["Kök"], list("abcde"))
    rows += [row("DOĞRU CEVAP: B", LEFT_TEXT, 200), row("BİRİNCİ TEST BİTTİ.", LEFT_TEXT, 230),
             row("SINAVDA UYULACAK KURALLAR", LEFT_TEXT, 260)]
    st = _stream(page(1, *rows, gutter=297))
    run = _numbers(st, last=1)
    block = segment.blocks(st, run.accepted, len(st.lines))[0]
    assert block.answer_marks == ["B"]
    assert block.stopped
    assert all("KURALLAR" not in l.text for l in block.lines)


def test_shared_case_goes_to_every_question_it_names():
    rows = question(39, 80, ["Önceki soru"], list("abcde"))
    rows += [row("40.-41. SORULARI AŞAĞIDAKİ BİLGİLERE", LEFT_TEXT, 200),
             row("GÖRE CEVAPLAYINIZ.", LEFT_TEXT, 210),
             row("Beş yaşında bir çocuk sarılıkla getiriliyor.", LEFT_TEXT, 225)]
    rows += question(40, 260, ["Tanı nedir?"], list("abcde"))
    rows += question(41, 420, ["Tedavi nedir?"], list("abcde"))
    st = _stream(page(1, *rows, gutter=297, height=900))
    run = _numbers(st, first=39, last=41)
    blocks = segment.blocks(st, run.accepted, len(st.lines))
    assert all("sarılık" not in l.text for l in blocks[0].lines)       # not glued to 39's option E
    assert [l.text for l in blocks[1].shared] == ["Beş yaşında bir çocuk sarılıkla getiriliyor."]
    assert blocks[2].shared == blocks[1].shared


def test_running_head_is_noise_whatever_its_wording():
    pages = []
    for n in range(1, 6):
        pages.append(page(n, row("TUS KTBT/NİSAN 2008", 430, 88),
                          *question(n, 120, [f"Soru {n}"], list("abcde")), gutter=297))
    st = _stream(*pages)
    heads = [sl for sl in st.lines if "KTBT" in sl.text]
    assert heads and all(sl.kind == segment.NOISE for sl in heads)
