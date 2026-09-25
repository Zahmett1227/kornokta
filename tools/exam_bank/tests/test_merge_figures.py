"""A3 (one record per question) and A4 (does it need its picture)."""
from tools.exam_bank import figures, merge
from tools.exam_bank import registry as reg
from tools.exam_bank.extract.columns import Box

from .layout import page


def _registry():
    doc = {"schemaVersion": 1, "excluded": [], "sources": [
        {"file": "2022-2026/TUS_2025_Ilkbahar_Temel.pdf", "sha256": "a" * 64, "family": "F4",
         "sourceKind": "osymPartial", "papers": [
             {"id": "TUS-2025-1-T", "date": None, "expected": 100, "numberOffset": 0, "timeLimitMinutes": None,
              "penalty": "unknown", "keySource": "osym"}]},
        {"file": "2022-2026/derleme.pdf", "sha256": "b" * 64, "family": "F5", "sourceKind": "tusdata",
         "papers": [{"id": "TUS-2025-1-T", "date": None, "expected": 100, "numberOffset": 0,
                     "timeLimitMinutes": None, "penalty": "unknown", "keySource": "tusdata"}]},
    ]}
    r = reg.parse(doc)
    assert r.errors == []
    return r


STEM = "Canalis inguinalis ön duvarında lifleri görülebilecek en olası yapı aşağıdakilerden hangisidir?"
OPTS = ["Musculus transversus abdominis", "Musculus obliquus internus abdominis", "Fascia transversalis",
        "Ligamentum inguinale", "Ligamentum lacunare"]


def _q(n, stem=STEM, options=OPTS, empty=False, revised=False, problems=(), page_no=3):
    return {"number": n, "printed": n, "stem": stem, "options": list(options) if options else options,
            "regions": [{"page": page_no, "bbox": [40, 100, 295, 300]}], "problems": list(problems),
            "answerMarks": [], "empty": empty, "cancelled": False, "revised": revised}


def _a(n, answer, source):
    return {"number": n, "answer": answer, "answerSource": source, "cancelled": False}


def _inputs(official, copy, official_answers, copy_answers):
    a1 = {"papers": [
        {"paperId": "TUS-2025-1-T", "file": "2022-2026/TUS_2025_Ilkbahar_Temel.pdf", "family": "F4",
         "missing": [], "questions": official},
        {"paperId": "TUS-2025-1-T", "file": "2022-2026/derleme.pdf", "family": "F5", "missing": [],
         "questions": copy}]}
    a2 = {"papers": [
        {"paperId": "TUS-2025-1-T", "file": "2022-2026/TUS_2025_Ilkbahar_Temel.pdf", "family": "F4",
         "answers": official_answers},
        {"paperId": "TUS-2025-1-T", "file": "2022-2026/derleme.pdf", "family": "F5", "answers": copy_answers}]}
    return a1, a2


def test_official_text_page_and_answer_win_and_the_copy_becomes_alt_provenance():
    retyped = STEM.replace("aşağıdakilerden", "aşağıdakilerden ").replace("en olası", "en  olası")
    a1, a2 = _inputs([_q(1, empty=True), _q(2)], [_q(1, "Başka soru"), _q(2, retyped, page_no=7)],
                     [_a(1, None, None), _a(2, 1, "osym")], [_a(1, 3, "tusdata"), _a(2, 1, "tusdata")])
    result = merge.run(_registry(), a1, a2)
    by_id = {q["id"]: q for q in result["questions"]}
    q2 = by_id["TUS-2025-1-T-002"]
    assert q2["stem"] == STEM and q2["answerSource"] == "osym" and q2["textSource"] == "osym"
    assert q2["provenance"][0]["file"].endswith("Temel.pdf")
    assert [r["page"] for r in q2["altProvenance"]] == [7]
    q1 = by_id["TUS-2025-1-T-001"]
    assert q1["textSource"] == "tusdata" and q1["answer"] == 3 and q1["status"] == "ok"
    assert result["v5"] == {"compared": 1, "failed": 0} and result["problems"] == []


def test_v5_catches_a_different_question_under_the_same_number():
    a1, a2 = _inputs([_q(2)], [_q(2, "Tamamen başka bir soru metni burada yer alıyor ve hiç örtüşmüyor",
                                  ["a", "b", "c", "d", "e"])],
                     [_a(2, 1, "osym")], [_a(2, 1, "tusdata")])
    result = merge.run(_registry(), a1, a2)
    assert result["v5"]["failed"] == 1 and "V5 TUS-2025-1-T-002" in result["problems"][0]


def test_a_revised_copy_is_modified_unless_the_official_text_exists():
    a1, a2 = _inputs([_q(5)], [_q(5, revised=True), _q(6, "Değiştirilmiş soru", revised=True)],
                     [_a(5, 0, "osym")], [_a(5, 0, "tusdata"), _a(6, 2, "tusdata")])
    by_id = {q["id"]: q for q in merge.run(_registry(), a1, a2)["questions"]}
    assert by_id["TUS-2025-1-T-005"]["status"] == "ok"
    assert by_id["TUS-2025-1-T-006"]["status"] == "modified"


def test_status_order():
    a1, a2 = _inputs([], [_q(1, problems=["A şıkkı boş"]), _q(2)], [], [_a(1, 0, "tusdata"), _a(2, None, None)])
    by_id = {q["id"]: q for q in merge.run(_registry(), a1, a2)["questions"]}
    assert by_id["TUS-2025-1-T-001"]["status"] == "needsRepair"
    assert by_id["TUS-2025-1-T-002"]["status"] == "keyless"


def test_fold_is_case_and_dot_blind():
    assert merge.fold("İLAÇ Işık") == merge.fold("ilaç ışık") == "ilaç işik"


def test_near_identical_questions_in_different_exams_are_linked():
    qs = []
    for pid in ("TUS-2014-1-T", "TUS-2019-2-T", "TUS-2020-1-T"):
        stem = STEM if pid != "TUS-2020-1-T" else "Böbrek glomerül bazal membranı hangi kollajenden oluşur?"
        qs.append({"id": f"{pid}-001", "stem": stem, "options": OPTS, "status": "ok", "similarTo": []})
    merge._link_similar(qs)
    assert qs[0]["similarTo"] == ["TUS-2019-2-T-001"] and qs[2]["similarTo"] == []


# --- A4 ----------------------------------------------------------------------

def test_watermark_repeated_on_every_page_is_not_a_figure():
    mark = Box(150, 300, 400, 560, "image", ("image", (759, 743), 150, 160))
    pages = [page(n) for n in range(1, 5)]
    for p in pages:
        p.graphics.append(mark)
    decor = figures.furniture(pages)
    images, vectors = figures.evidence([{"page": 2, "bbox": [40, 380, 295, 600]}], {p.number: p for p in pages}, decor)
    assert (images, vectors) == (0, 0)


def test_artifact_tag_is_not_a_figure():
    p = page(1)
    p.graphics.append(Box(60, 200, 150, 300, "image", ("image", (10, 10), 140, 150), artifact=True))
    assert figures.evidence([{"page": 1, "bbox": [40, 100, 295, 320]}], {1: p}, set()) == (0, 0)


def test_an_ecg_drawn_in_vectors_is_a_figure():
    p = page(1)
    for i in range(40):
        p.graphics.append(Box(60 + i * 5, 65 + i * 5, 150, 190, "curve", ("curve", i)))
    images, vectors = figures.evidence([{"page": 1, "bbox": [40, 100, 295, 320]}], {1: p}, set())
    assert figures.classify("Yukarıdaki EKG hangisiyle uyumludur?", [], images, vectors) == "required"


def test_underlines_and_the_column_rule_are_not_figures():
    p = page(1)
    p.graphics.append(Box(120, 160, 180, 180.5, "line", ("line", 1)))     # under "en olası"
    p.graphics.append(Box(297, 297.5, 80, 760, "line", ("line", 2)))      # column rule
    assert figures.evidence([{"page": 1, "bbox": [40, 100, 299, 320]}], {1: p}, set()) == (0, 0)


def test_classes():
    assert figures.classify("Şekildeki yapı hangisidir?", [], 1, 0) == "required"
    assert figures.classify("Yukarıdaki tabloda verilen değerlere göre?", [], 0, 0) == "reference"
    assert figures.classify("Hangisi doğrudur?", ["A şıkkı boş"], 0, 0) == "required"   # options are pictures
    assert figures.classify("Hangisi doğrudur?", [], 0, 2) == "none"


def _t(i):
    return ({"stem": f"Soru {i}: " + " ".join(f"kelime{i}x{j}" for j in range(12)), "options": list("abcde")}, {})


def test_copy_numbers_are_corrected_by_osym_anchors_and_ambiguous_ones_left_out():
    # The copy lacks ÖSYM's 4 and carries an extra X between 6 and 7 — the
    # shape measured in the compilation's 2024/1 Klinik.
    official = {2: _t(2), 6: _t(6), 7: _t(7)}
    copy = {1: _t(1), 2: _t(2), 3: _t(3), 4: _t(5), 5: _t(6), 6: _t(99), 7: _t(7)}
    aligned, failed, lost, note = merge.renumber(official, copy, expected=7)
    assert failed == []
    assert sorted(aligned) == [1, 2, 6, 7]
    assert aligned[6][0]["stem"].startswith("Soru 6:")
    assert lost == [3, 4, 6] and "kayıyor" in note


def test_an_osym_question_missing_from_the_copy_fails_v5():
    aligned, failed, lost, _ = merge.renumber({3: _t(3)}, {1: _t(1), 2: _t(2), 3: _t(40)}, expected=3)
    assert failed and failed[0][0] == 3


def test_matching_ignores_the_dot_on_i():
    assert merge.overlap("TNF IL-1 IL-2 IL-6 IL-8 makrofaj sitokin", "TNF İL-1 İL-2 İL-6 İL-8 makrofaj sitokin") == 1.0
