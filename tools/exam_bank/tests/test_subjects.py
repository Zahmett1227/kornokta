"""A7's monotone segmentation (§5.10/2)."""
from tools.exam_bank import subjects as sj


def test_one_wrong_vote_is_outvoted_by_its_block():
    votes = ["Anatomi"] * 5 + ["Farmakoloji"] + ["Anatomi"] * 4 + ["Fizyoloji"] * 10
    result = sj.settle(votes, "T", 2019)
    assert result["labels"][5] == "Anatomi"
    assert result["monotone"] and result["corrected"] == 1


def test_block_boundaries_follow_the_votes():
    votes = ["Dahiliye"] * 6 + ["Pediatri"] * 3 + ["Genel Cerrahi"] * 4
    labels, kept = sj.segment(votes, sj.KLINIK)
    assert labels == votes and kept == len(votes)


def test_a_missing_block_is_skipped_not_invented():
    votes = ["Anatomi"] * 3 + ["Fizyoloji"] * 3     # no Histoloji-Embriyoloji block
    labels, _ = sj.segment(votes, sj.TEMEL)
    assert "Histoloji-Embriyoloji" not in labels


def test_questions_without_a_vote_take_their_neighbours_block():
    votes = ["Anatomi", None, "Anatomi", "Patoloji", None, "Patoloji"]
    labels, kept = sj.segment(votes, sj.TEMEL)
    assert labels == ["Anatomi"] * 3 + ["Patoloji"] * 3 and kept == 4


def test_a_paper_that_does_not_follow_the_order_keeps_its_votes():
    votes = ["Farmakoloji", "Anatomi"] * 10
    result = sj.settle(votes, "T", 2019)
    assert not result["monotone"] and result["labels"] == votes


def test_older_klinik_papers_have_no_kucuk_stajlar():
    assert "Küçük Stajlar" not in sj.order_for("K", 2007)
    assert sj.order_for("K", 2009)[-1] == "Küçük Stajlar"
    assert sj.order_for("T2", 2012) == sj.TEMEL


def test_histology_maps_to_the_apps_fizyoloji():
    assert sj.TO_APP["Histoloji-Embriyoloji"] == "Fizyoloji"
    assert set(sj.TO_APP) == set(sj.OSYM_SUBJECTS)


def test_every_mapped_subject_is_one_the_app_knows():
    import json
    from pathlib import Path
    schema = json.loads((Path(__file__).parents[3] / "backend/schemas/subject_topics.json").read_text("utf-8"))
    assert set(sj.TO_APP.values()) <= {s["name"] for s in schema["subjects"]}
