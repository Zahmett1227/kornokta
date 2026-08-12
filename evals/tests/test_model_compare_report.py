"""The un-blinding join, tested where it can silently mislead.

Every assertion here is about a way this could report a comparison that looks
sound and is not: cards attributed to the wrong model, a subset silently
dropped, or a cheap tier that looks cheap only because half its cards were
rejected.
"""

from __future__ import annotations

import pytest

from evals.card_quality.aggregate import score_entries
from evals.model_compare.report import (
    cost_per_accept,
    format_report,
    group_by_model,
    quality_of,
)

PERFECT = dict.fromkeys(
    (
        "source_faithfulness",
        "single_clear_answer",
        "medical_accuracy",
        "question_clarity",
        "learning_value",
        "non_redundancy",
        "appropriate_difficulty",
    ),
    2,
)
POOR = {name: 1 for name in PERFECT}


def scores_file(entries):
    return {"schemaVersion": "1.0", "entries": entries}


def test_cards_are_attributed_to_the_model_that_made_them():
    scored = score_entries(
        scores_file(
            [
                {"cardId": "a", "scores": PERFECT},
                {"cardId": "b", "scores": POOR},
                {"cardId": "c", "scores": PERFECT},
            ]
        )
    )
    key = {"a": "sol", "b": "terra", "c": "terra"}

    grouped = group_by_model(scored, key)

    assert sorted(grouped) == ["sol", "terra"]
    assert [card.card_id for card in grouped["terra"]] == ["b", "c"]

    terra = quality_of("terra", grouped["terra"])
    assert terra.total == 2
    assert terra.accept == 1  # 14/14
    assert terra.reject == 1  # 7/14
    assert terra.mean_score == pytest.approx(10.5)


def test_a_card_missing_from_the_key_fails_loudly():
    # Scores and key from different runs would otherwise produce a report over
    # a silently chosen subset — the failure mode that looks most like a result.
    scored = score_entries(scores_file([{"cardId": "a", "scores": PERFECT}]))
    with pytest.raises(SystemExit) as excinfo:
        group_by_model(scored, {"other": "sol"})
    assert "anahtarda yok" in str(excinfo.value)


def test_cost_per_accepted_card_exposes_a_false_bargain():
    # Half the price, a third of the usable cards. Per-page cost calls that a
    # win; per-accepted-card calls it what it is.
    cheap = quality_of(
        "luna",
        score_entries(
            scores_file(
                [
                    {"cardId": "1", "scores": PERFECT},
                    {"cardId": "2", "scores": POOR},
                    {"cardId": "3", "scores": POOR},
                ]
            )
        ),
    )
    dear = quality_of(
        "sol",
        score_entries(
            scores_file(
                [
                    {"cardId": "4", "scores": PERFECT},
                    {"cardId": "5", "scores": PERFECT},
                    {"cardId": "6", "scores": PERFECT},
                ]
            )
        ),
    )

    assert cost_per_accept({"totalCostUSD": 0.10}, cheap) == pytest.approx(0.10)
    assert cost_per_accept({"totalCostUSD": 0.20}, dear) == pytest.approx(0.0667, abs=1e-4)


def test_cost_per_accept_does_not_divide_by_zero():
    none_accepted = quality_of(
        "luna", score_entries(scores_file([{"cardId": "1", "scores": POOR}]))
    )
    assert none_accepted.accept == 0
    assert cost_per_accept({"totalCostUSD": 0.10}, none_accepted) == pytest.approx(0.10)


def test_report_warns_when_a_model_had_no_price_of_its_own():
    # Without its own prices a model is costed from the deployment's single
    # set, which makes the comparison meaningless. Saying so is the point.
    quality = quality_of("terra", score_entries(scores_file([{"cardId": "a", "scores": PERFECT}])))
    text = format_report(
        [quality],
        {"terra": {"totalCostUSD": 0.1, "costPerPageUSD": 0.05, "pricesInherited": True}},
    )
    assert "karşılaştırılabilir değil" in text


def test_report_survives_a_model_absent_from_the_cost_report():
    quality = quality_of("terra", score_entries(scores_file([{"cardId": "a", "scores": PERFECT}])))
    text = format_report([quality], {})
    assert "raporda bu model yok" in text


def test_report_never_prints_a_verdict():
    # §0.6: the rubric fixes per-card thresholds, not how much quality a saving
    # is worth. A "winner" line here would be an invented trade-off.
    quality = quality_of("sol", score_entries(scores_file([{"cardId": "a", "scores": PERFECT}])))
    text = format_report([quality], {"sol": {"totalCostUSD": 0.2, "costPerPageUSD": 0.1}}).lower()
    for banned in ("kazanan", "öneri", "tercih et", "geç"):
        assert banned not in text
