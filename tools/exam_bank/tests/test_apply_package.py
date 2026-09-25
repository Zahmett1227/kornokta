"""Folding model results in (A5–A7, V6), the gates' own logic, and the
package document (A9) — all on synthetic data."""
import json

from tools.exam_bank import apply, gates, package
from tools.exam_bank import registry as reg


def _q(qid="TUS-2013-2-T-028", stem="Histamin hangi reseptörle etki eder?", options=("", "CCK-B", "", "", ""),
       status="needsRepair", answer=0, **kw):
    q = {"id": qid, "paperId": qid[:-4], "number": int(qid[-3:]), "stem": stem, "options": list(options),
         "answer": answer, "answerSource": "osym", "status": status, "problems": ["A şıkkı boş"],
         "figure": "none", "provenance": [{"file": "f.pdf", "page": 3, "bbox": [40, 100, 295, 200]}],
         "altProvenance": [], "textQuality": "native", "textSource": "osym", "printedAs": None, "similarTo": []}
    q.update(kw)
    return q


def _result(stem, *opts):
    return {"output": dict(stem=stem, **dict(zip("abcde", opts)))}


def test_repair_is_kept_when_it_reads_the_same_question():
    q = _q()
    notes = apply.apply_repair([q], {q["id"]: _result("Histamin hangi reseptörle etki eder?",
                                                         "H₂", "CCK-B", "H₃", "H₁A", "M₃")})
    assert notes == [] and q["options"] == ["H₂", "CCK-B", "H₃", "H₁A", "M₃"]
    assert q["status"] == "ok" and q["textQuality"] == "repaired" and q["problems"] == []


def test_repair_of_another_question_is_refused():
    q = _q()
    notes = apply.apply_repair([q], {q["id"]: _result("Böbrekte glomerül hangi hücrelerden oluşur?",
                                                         "a", "b", "c", "d", "e")})
    assert q["status"] == "needsHuman" and "örtüşmüyor" in notes[0]


def test_drawn_options_become_pictures_and_do_not_count_against_the_repair():
    q = _q(stem="Hangi açık formül tirozine aittir?", options=["(cid:129)"] * 5)
    drawing = "COOH\n |\nH-C-H\n |\nCH2"
    apply.apply_repair([q], {q["id"]: _result("52. Hangi açık formül tirozine aittir?", *[drawing] * 5)})
    assert q["options"] == ["[görsel]"] * 5 and q["figure"] == "required"
    assert q["stem"] == "Hangi açık formül tirozine aittir?"   # the copied number is dropped
    assert q["status"] == "ok"


def test_a_source_that_prints_one_option_twice_is_not_scoreable():
    q = _q(stem="Hangileri fototerapi endikasyonudur?", options=["I, II ve III", "II, IV ve V", "", "", ""])
    notes = apply.apply_repair([q], {q["id"]: _result("Hangileri fototerapi endikasyonudur?", "I, II ve III",
                                                         "II, IV ve V", "I, II ve IV", "I, III, IV ve V",
                                                         "II, IV ve V")})
    assert q["status"] == "needsHuman" and "iki şık aynı" in notes[0]


def test_tidy_joins_wrapped_lines_and_keeps_premises_and_table_columns():
    assert apply.tidy("Sağlıklı bir bireye ait\ngrafik verilmiştir.\n\nBuna göre hangisi?") == \
        "Sağlıklı bir bireye ait grafik verilmiştir.\nBuna göre hangisi?"
    assert apply.tidy("Aşağıdakilerden\nI. Birinci\nII. İkinci") == "Aşağıdakilerden\nI. Birinci\nII. İkinci"
    assert apply.tidy("cHCO₃⁻ azalması　　　pCO₂ artması") == "cHCO₃⁻ azalması – pCO₂ artması"


def test_v6_scores_the_models_blind_answers_against_the_key():
    items = [{"id": "TUS-2019-1-T", "questions": [{"k": i + 1, "id": f"q{i}"} for i in range(15)]}]
    answers = {f"q{i}": 0 for i in range(15)}
    good = {"TUS-2019-1-T": {"output": {"items": [{"k": i + 1, "answer": "A"} for i in range(15)]}}}
    chance = {"TUS-2019-1-T": {"output": {"items": [{"k": i + 1, "answer": "ABCDE"[i % 5]} for i in range(15)]}}}
    assert apply.apply_check(items, good, answers)["TUS-2019-1-T"]["pass"]
    assert not apply.apply_check(items, chance, answers)["TUS-2019-1-T"]["pass"]


def test_labels_settle_by_block_and_keep_a_topic_only_when_the_vote_agrees():
    paper = reg.Paper("TUS-2019-1-T", None, 4, 0, None, "unknown", "osym")
    qs = [dict(_q(f"TUS-2019-1-T-00{n}"), status="ok") for n in range(1, 5)]
    jobs = [{"id": "TUS-2019-1-T|1", "questions": [{"k": n, "id": q["id"]} for n, q in enumerate(qs, 1)]}]
    votes = [("Anatomi", "Üst Ekstremite"), ("Farmakoloji", "Otonom"), ("Anatomi", "Alt Ekstremite"),
             ("Fizyoloji", "Kalp")]
    results = {"TUS-2019-1-T|1": {"output": {"items": [{"k": i + 1, "subject": s, "topic": t}
                                                          for i, (s, t) in enumerate(votes)]}}}
    topics = {"Anatomi": ["Üst Ekstremite", "Alt Ekstremite"], "Fizyoloji": ["Kalp"]}
    apply.apply_labels([paper], qs, jobs, results, topics)
    assert [q["osymSubject"] for q in qs] == ["Anatomi", "Anatomi", "Anatomi", "Fizyoloji"]
    assert [q["topic"] for q in qs] == ["Üst Ekstremite", None, "Alt Ekstremite", "Kalp"]


# --- gates -------------------------------------------------------------------

def test_v2_passes_picture_options_and_catches_a_blank_one():
    ok = _q(status="ok", options=["[görsel]"] * 5)
    blank = _q("TUS-2019-1-T-001", status="ok", options=["a", "", "c", "d", "e"])
    assert gates.v2([ok])["pass"]
    assert not gates.v2([ok, blank])["pass"]


def test_v9_needs_an_approval_of_this_very_sample():
    sample = [_q(status="ok")]
    assert not gates.v9(sample, None)["pass"]
    assert not gates.v9(sample, {"by": "x", "at": "t", "sample": ["başka"]})["pass"]
    assert gates.v9(sample, {"by": "x", "at": "t", "sample": [sample[0]["id"]]})["pass"]


# --- package -------------------------------------------------------------------

def test_bank_document_renumbers_regions_into_the_packaged_pdfs_and_validates():
    q = _q(status="ok", options=["a", "b", "c", "d", "e"], osymSubject="Biyokimya", subject="Biyokimya",
           topic=None, altProvenance=[{"file": "g.pdf", "page": 40, "bbox": [1, 2, 3, 4]}])
    a7 = {"questions": [q], "papers": [{
        "id": "TUS-2013-2-T", "year": 2013, "session": 2, "test": "T", "date": "2013-09-08", "questionCount": 120,
        "timeLimitMinutes": None, "sessionTimeLimitMinutes": None, "penalty": "quarter", "sourceKind": "osym",
        "keySource": "osym", "sources": [{"file": "f.pdf", "family": "F3", "sourceKind": "osym", "keySource": "osym"}]}]}
    paths = {"f.pdf": "pdf/" + "a" * 64 + ".pdf", "g.pdf": "pdf/" + "b" * 64 + ".pdf"}
    page_map = {("f.pdf", 3): 3, ("g.pdf", 40): 2}   # g.pdf was an F4 booklet cut to its visible pages
    doc = package.bank_document(a7, paths, page_map, "2026-09-25.1", "2026-09-25T20:00:00+00:00", 1)
    assert doc["questions"][0]["altProvenance"] == [{"pdf": paths["g.pdf"], "page": 2, "bbox": [1, 2, 3, 4]}]
    assert "file" not in json.dumps(doc["questions"][0]["provenance"])
    assert package.validate(doc) == []


def test_schema_rejects_what_the_phone_could_not_use():
    doc = {"schemaVersion": 1, "bankVersion": "2026-09-25.1", "subjectSchemaVersion": 1,
           "builtAt": "2026-09-25T20:00:00+00:00", "papers": [], "questions": [{"id": "TUS-2019-1-T-001"}]}
    assert package.validate(doc)


def test_bank_version_counts_packages_written_within_a_day(tmp_path):
    assert package.bank_version(tmp_path, "2026-09-25") == "2026-09-25.1"
    assert package.bank_version(tmp_path, "2026-09-25") == "2026-09-25.1"   # nothing written yet
    package.commit_version(tmp_path, "2026-09-25.1")
    assert package.bank_version(tmp_path, "2026-09-25") == "2026-09-25.2"
    assert package.bank_version(tmp_path, "2026-09-26") == "2026-09-26.1"


def test_a_cancelled_slot_without_text_packages_with_no_options():
    q = _q(status="cancelled", options=(), answer=None, answerSource=None, osymSubject="Anatomi",
           subject="Anatomi", topic=None, stem="Bu soru iptal edilmiştir.")
    q["options"] = None
    a7 = {"questions": [q], "papers": []}
    doc = package.bank_document(a7, {"f.pdf": "pdf/" + "a" * 64 + ".pdf"}, {("f.pdf", 3): 3},
                                "2026-09-25.1", "2026-09-25T20:00:00+00:00", 1)
    assert doc["questions"][0]["options"] == []
    assert package.validate(doc) == []
    doc["questions"][0]["options"] = ["a", "b"]
    assert package.validate(doc)
