"""The source registry (`sources.json`) and its validator.

Two halves: the real registry must stay valid and keep describing the folder
the owner actually has (the counts below were measured from the PDFs on
2026-09-25), and the validator must reject the mistakes a bulk edit makes.
"""
import copy
import unicodedata

import pytest

from tools.exam_bank import registry as reg


@pytest.fixture(scope="module")
def real():
    return reg.load()


def test_real_registry_is_valid(real):
    assert real.errors == []


def test_real_registry_counts(real):
    # 12 F1 + 6 F2 + 41 F3 + 20 F4 + 1 F5 + 2 F6 files.
    assert len(real.sources) == 82
    assert len(real.papers) == 95
    # 2006–2021: 16 years × 2 sessions × 2 tests, plus the extra Temel
    # Testi-2 of 2011/1 and 2012/1, minus 2011/1's Klinik (not in the
    # folder); 2022–2026: 5 × 2 × 2.
    assert len(real.paper_ids()) == 64 + 2 - 1 + 20


def test_every_exam_2006_2026_is_registered_and_the_one_gap_is_known(real):
    # 2011/1's booklet is Temel Testi-1 and Temel Testi-2 (its cover says so;
    # found while reading its key in Faz A1). That exam's Klinik test is not
    # in the owner's folder — a gap to report, not to paper over.
    assert reg.missing_tests(real) == ["TUS-2011-1-K"]
    exams = {(p.year, p.session) for _, p in real.papers}
    assert exams == {(y, s) for y in range(2006, 2027) for s in (1, 2)}


def test_keys_are_where_the_pdfs_have_them(real):
    by_id = {}
    for source, paper in real.papers:
        by_id.setdefault(paper.id, set()).add((source.family, paper.key_source))
    # No key anywhere for 2006–2008.
    assert by_id["TUS-2007-2-K"] == {("F1", "none")}
    # 2024/1: ÖSYM shows 10% with answers; the compilation has no key.
    assert by_id["TUS-2024-1-T"] == {("F4", "osym"), ("F5", "none")}
    # 2024/2: both, and the compilation's key agreed 18/18 with ÖSYM.
    assert by_id["TUS-2024-2-K"] == {("F4", "osym"), ("F5", "tusdata")}
    # 2026/2 exists in full only as the reconstruction.
    assert by_id["TUS-2026-2-T"] == {("F4", "osym"), ("F6", "reconstruction")}


def test_compilation_numbers_each_exam_straight_through(real):
    compilation = next(s for s in real.sources if s.family == "F5")
    offsets = {p.id: p.number_offset for p in compilation.papers}
    assert offsets["TUS-2025-1-T"] == 0
    assert offsets["TUS-2025-1-K"] == 100


def test_question_counts_follow_the_format_changes(real):
    expected = {p.id: p.expected for _, p in real.papers}
    assert expected["TUS-2008-1-T"] == 100   # 2006–2011: 100 per test
    assert expected["TUS-2012-1-T2"] == 120  # 2012–2023/1: 120
    assert expected["TUS-2023-1-K"] == 120
    assert expected["TUS-2023-2-K"] == 100   # 2023/2 onward: 100


# --- validator -------------------------------------------------------------

BASE = {
    "schemaVersion": 1,
    "sources": [
        {
            "file": "2013-2021/TUS_2019_Ilkbahar_Temel.pdf",
            "sha256": "a" * 64,
            "family": "F3",
            "sourceKind": "osym",
            "papers": [{
                "id": "TUS-2019-1-T", "date": "2019-02-24", "expected": 120,
                "numberOffset": 0, "timeLimitMinutes": None, "penalty": "unknown", "keySource": "osym",
            }],
        }
    ],
    "excluded": [],
}


def errors_for(mutate):
    doc = copy.deepcopy(BASE)
    mutate(doc)
    return reg.parse(doc).errors


def test_base_fixture_is_valid():
    assert reg.parse(copy.deepcopy(BASE)).errors == []


@pytest.mark.parametrize("bad", ["TUS-2019-3-T", "TUS-19-1-T", "TUS-2019-1-X", "2019-1-T"])
def test_rejects_malformed_paper_ids(bad):
    errs = errors_for(lambda d: d["sources"][0]["papers"][0].update(id=bad))
    assert any("geçersiz kağıt kimliği" in e for e in errs)


def test_rejects_a_date_from_another_year():
    errs = errors_for(lambda d: d["sources"][0]["papers"][0].update(date="2018-02-24"))
    assert any("yılı" in e for e in errs)


@pytest.mark.parametrize("path", ["/abs/TUS.pdf", "../TUS.pdf", "2019/TUS.txt", ""])
def test_rejects_unsafe_or_non_pdf_paths(path):
    errs = errors_for(lambda d: d["sources"][0].update(file=path))
    assert any("dosya yolu" in e for e in errs)


def test_rejects_a_key_the_family_cannot_have():
    # F1 booklets (2006–2008) carry no answer key.
    def mutate(d):
        d["sources"][0]["family"] = "F1"
        d["sources"][0]["papers"][0]["expected"] = 100
    errs = errors_for(mutate)
    assert any("F1 ailesi keySource" in e for e in errs)


def test_rejects_an_official_label_on_a_reconstruction():
    def mutate(d):
        d["sources"][0]["family"] = "F6"
        d["sources"][0]["papers"][0]["keySource"] = "osym"
    errs = errors_for(mutate)
    assert any("F6 ailesi sourceKind" in e for e in errs)
    assert any("F6 ailesi keySource" in e for e in errs)


def two_papers(family, kind, key, offsets, test_letters=("T", "K")):
    def mutate(d):
        s = d["sources"][0]
        s.update(family=family, sourceKind=kind, file="x/TUS_2025_derleme.pdf")
        s["papers"] = [{
            "id": f"TUS-2025-1-{t}", "date": None, "expected": 100, "numberOffset": o,
            "timeLimitMinutes": None, "penalty": "unknown", "keySource": key,
        } for t, o in zip(test_letters, offsets)]
    return mutate


def test_straight_through_numbering_must_not_overlap():
    assert errors_for(two_papers("F5", "tusdata", "tusdata", (0, 100))) == []
    errs = errors_for(two_papers("F5", "tusdata", "tusdata", (0, 50)))
    assert any("çakışıyor" in e for e in errs)


def test_per_test_numbering_restarts_at_one():
    # 2009–2011: Temel and Klinik are both numbered 1–100 in one booklet.
    # The first validator run flagged the real registry here — the rule,
    # not the data, was wrong.
    assert errors_for(two_papers("F2", "osym", "osym", (0, 0))) == []
    errs = errors_for(two_papers("F2", "osym", "osym", (0, 100)))
    assert any("numberOffset 0 olmalı" in e for e in errs)
    errs = errors_for(two_papers("F2", "osym", "osym", (0, 0), test_letters=("T", "T")))
    assert any("iki kez" in e for e in errs)


def test_rejects_duplicate_content_under_two_names():
    def mutate(d):
        twin = copy.deepcopy(d["sources"][0])
        twin["file"] = "kopya/TUS_2019_Ilkbahar_Temel.pdf"
        twin["papers"][0]["id"] = "TUS-2019-1-K"
        d["sources"].append(twin)
    errs = errors_for(mutate)
    assert any("kopya kaydedilmiş" in e for e in errs)


def test_sources_of_one_paper_must_agree_on_what_it_is():
    def mutate(d):
        other = copy.deepcopy(d["sources"][0])
        other.update(file="2022-2026/derleme.pdf", sha256="b" * 64, family="F5", sourceKind="tusdata")
        other["papers"][0].update(expected=100, keySource="tusdata")
        d["sources"].append(other)
    errs = errors_for(mutate)
    assert any("expected konusunda uyuşmuyor" in e for e in errs)


def test_exclusions_need_a_reason_and_cannot_hide_a_registered_file():
    errs = errors_for(lambda d: d["excluded"].append({"pattern": "x/*"}))
    assert any("reason zorunlu" in e for e in errs)
    errs = errors_for(lambda d: d["excluded"].append({"pattern": "2013-2021/*", "reason": "deneme"}))
    assert any("hem kayıtlı hem dışarıda" in e for e in errs)


def test_exclusion_matches_a_decomposed_file_name():
    # The folder's `yenikeşif/` comes back from macOS as NFD; the pattern in
    # sources.json is NFC. The first dry run against the real folder missed
    # this and reported three excluded copies as unregistered.
    rule = reg.Exclusion(pattern="2022-2026/yenikeşif/*", reason="kopya")
    nfd = unicodedata.normalize("NFD", "2022-2026/yenikeşif/Temel_Bilimler_Sinav_1-100.pdf")
    assert nfd != unicodedata.normalize("NFC", nfd)
    assert rule.matches(nfd)


def test_missing_tests_reports_gaps_without_failing():
    doc = copy.deepcopy(BASE)
    registry = reg.parse(doc)
    assert registry.errors == []
    assert reg.missing_tests(registry) == ["TUS-2019-1-K"]
