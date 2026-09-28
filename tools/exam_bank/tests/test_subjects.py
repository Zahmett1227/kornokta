"""A7's monotone segmentation (§5.10/2)."""
from tools.exam_bank import subjects as sj


def test_one_wrong_vote_is_outvoted_by_its_block():
    votes = ["Anatomi"] * 5 + ["Farmakoloji"] + ["Anatomi"] * 4 + ["Fizyoloji"] * 10
    result = sj.settle(votes, "T", 2019)
    assert result["labels"][5] == "Anatomi"
    assert result["monotone"] and result["corrected"] == 1


def test_block_boundaries_follow_the_votes():
    votes = ["Dahiliye"] * 6 + ["Pediatri"] * 3 + ["Genel Cerrahi"] * 4
    labels, kept = sj.segment(votes, sj.KLINIK_ORDER)
    assert labels == votes and kept == len(votes)


def test_a_missing_block_is_skipped_not_invented():
    votes = ["Anatomi"] * 3 + ["Fizyoloji"] * 3     # no Histoloji-Embriyoloji block
    labels, _ = sj.segment(votes, sj.TEMEL)
    assert "Histoloji-Embriyoloji" not in labels


def test_questions_without_a_vote_take_their_neighbours_block():
    votes = ["Anatomi", None, "Anatomi", "Patoloji", None, "Patoloji"]
    labels, kept = sj.segment(votes, sj.TEMEL)
    assert labels == ["Anatomi"] * 3 + ["Patoloji"] * 3 and kept == 4


def test_a_full_paper_that_does_not_follow_the_order_keeps_its_votes():
    votes = ["Farmakoloji", "Anatomi"] * 30
    result = sj.settle(votes, "T", 2019)
    assert not result["monotone"] and result["labels"] == votes


def test_klinik_has_two_kucuk_stajlar_blocks():
    votes = (["Dahiliye"] * 5 + ["Küçük Stajlar"] * 3 + ["Pediatri"] * 5 + ["Genel Cerrahi"] * 5
             + ["Küçük Stajlar"] * 3 + ["Kadın Hastalıkları ve Doğum"] * 4)
    result = sj.settle(votes, "K")
    assert result["monotone"] and result["corrected"] == 0 and result["labels"] == votes


def test_temel_2_order_comes_from_its_votes():
    # 2011/1's Temel Testi-2 sets Mikrobiyoloji before Biyokimya; 2012/1's
    # the reverse. Neither is forced into the Temel-1 order.
    votes = ["Mikrobiyoloji"] * 10 + ["Biyokimya"] * 9 + ["Fizyoloji"] + ["Biyokimya"] * 5
    assert sj.order_for("T2", votes)[:2] == ["Mikrobiyoloji", "Biyokimya"]
    result = sj.settle(votes, "T2")
    assert result["monotone"] and result["labels"][19] == "Biyokimya"


def test_histology_maps_to_the_apps_fizyoloji():
    assert sj.TO_APP["Histoloji-Embriyoloji"] == "Fizyoloji"
    assert set(sj.TO_APP) == set(sj.OSYM_SUBJECTS)


def test_every_mapped_subject_is_one_the_app_knows():
    import json
    from pathlib import Path
    schema = json.loads((Path(__file__).parents[3] / "backend/schemas/subject_topics.json").read_text("utf-8"))
    assert set(sj.TO_APP.values()) <= {s["name"] for s in schema["subjects"]}


def test_a_sparse_paper_trusts_the_known_order_over_a_few_votes():
    # ÖSYM's partial booklets: ~12 visible questions, one or two per block.
    votes = ["Pediatri", "Dahiliye", "Küçük Stajlar", "Küçük Stajlar", "Küçük Stajlar", "Pediatri",
             "Pediatri", "Dahiliye", "Küçük Stajlar", "Genel Cerrahi", "Dahiliye", "Pediatri"]
    result = sj.settle(votes, "K")
    assert result["monotone"] and result["sparse"]
    assert result["labels"][0] == "Dahiliye"
