import pytest

from evals.card_quality.rubric import (
    ACCEPT_MIN,
    CRITERIA,
    MAX_TOTAL,
    RubricResult,
    score_card,
    verdict_for,
)


def full(value):
    return {name: value for name in CRITERIA}


class TestThresholds:
    def test_max_total_is_14(self):
        assert MAX_TOTAL == 14

    def test_accept_boundary(self):
        assert verdict_for(12) == "accept"
        assert verdict_for(11) == "revise"

    def test_revise_boundary(self):
        assert verdict_for(9) == "revise"
        assert verdict_for(8) == "reject"

    def test_perfect_card_accepted(self):
        result = score_card(full(2))
        assert result.total == 14
        assert result.verdict == "accept"

    def test_zero_card_rejected(self):
        assert score_card(full(0)).verdict == "reject"


class TestValidation:
    def test_missing_criterion_raises(self):
        scores = full(2)
        del scores["medical_accuracy"]
        with pytest.raises(ValueError, match="missing"):
            score_card(scores)

    def test_unknown_criterion_raises(self):
        scores = full(2)
        scores["style_points"] = 2
        with pytest.raises(ValueError, match="unknown"):
            score_card(scores)

    def test_out_of_range_raises(self):
        scores = full(2)
        scores["question_clarity"] = 3
        with pytest.raises(ValueError):
            score_card(scores)

    def test_result_type(self):
        assert isinstance(score_card(full(1)), RubricResult)
