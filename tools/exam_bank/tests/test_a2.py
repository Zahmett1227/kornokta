"""A2's decisions: which answer a question gets, and V4."""
from tools.exam_bank import a2, keys
from tools.exam_bank import registry as reg


def _q(n, cancelled=False, marks=(), empty=False):
    return {"number": n, "cancelled": cancelled, "answerMarks": list(marks), "empty": empty}


def _src(family):
    kind = {"F3": "osym", "F4": "osymPartial", "F5": "tusdata"}[family]
    paper = reg.Paper("TUS-2024-2-T", None, 100, 0, None, "unknown", "tusdata" if family == "F5" else "osym")
    return reg.Source("f.pdf", "a" * 64, family, kind, (paper,)), paper


def _key(entries):
    k = keys.Key("TUS-2024-2-T", "osym", "f.pdf")
    for n, (answer, cancelled) in entries.items():
        k.entries[n] = keys.Pair(n, answer, cancelled, 1)
    return k


def test_osym_mark_is_the_answer_for_a_visible_question():
    src, paper = _src("F4")
    problems = []
    assert a2._answer(_q(4, marks="C"), paper, src, None, problems)["answer"] == 2
    assert a2._answer(_q(5, empty=True), paper, src, None, problems)["answer"] is None
    assert problems == []


def test_a_visible_question_without_exactly_one_mark_fails_v3():
    src, paper = _src("F4")
    problems = []
    a2._answer(_q(4), paper, src, None, problems)
    assert problems and "V3" in problems[0]


def test_either_word_cancels_and_is_counted_not_raised():
    src, paper = _src("F3")
    problems = []
    by_key = a2._answer(_q(1), paper, src, _key({1: (None, True)}), problems)
    by_booklet = a2._answer(_q(2, cancelled=True), paper, src, _key({2: (3, False)}), problems)
    assert by_key["cancelled"] and by_key["answer"] is None and by_key["cancelledBy"] == "key"
    assert by_booklet["cancelled"] and by_booklet["answer"] is None and by_booklet["cancelledBy"] == "booklet"
    assert problems == []


def test_v4_compares_only_where_both_exist():
    papers = [
        {"paperId": "TUS-2025-1-T", "family": "F4", "answers": [
            {"number": 4, "answer": 1, "answerSource": "osym"}, {"number": 9, "answer": 0, "answerSource": "osym"}]},
        {"paperId": "TUS-2025-1-T", "family": "F5", "answers": [
            {"number": 4, "answer": 1, "answerSource": "tusdata"}, {"number": 9, "answer": 3, "answerSource": "tusdata"},
            {"number": 10, "answer": 2, "answerSource": "tusdata"}]},
    ]
    v4 = a2._v4(papers)
    assert v4["compared"] == 2 and v4["agree"] == 1
    assert v4["disagree"] == {("TUS-2025-1-T", 9): (0, 3, "tusdata")}
