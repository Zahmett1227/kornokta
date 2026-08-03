"""FSRS-6 reference implementation tests (ANA-PLAN §18.1).

Two kinds of test here, deliberately: algebraic invariants that hold no
matter whose FSRS implementation this is (retrievability at t=S equals the
target retention; interval-then-retrievability round-trips) prove the
formulas are *internally* consistent even without an external ground truth,
and behavioural tests (Again produces a shorter interval than Easy for a
successful review; difficulty stays in [1,10]) check they match what §18.2's
four ratings are supposed to mean.
"""

from __future__ import annotations

import pytest

from evals.fsrs.algorithm import (
    AGAIN,
    EASY,
    GOOD,
    HARD,
    MAX_DIFFICULTY,
    MIN_DIFFICULTY,
    MemoryState,
    RATINGS,
    init_difficulty,
    init_stability,
    load_weights,
    next_difficulty,
    next_interval,
    retrievability,
    schedule,
)

PAYLOAD = load_weights()
W = PAYLOAD["weights"]
RETENTION = PAYLOAD["desiredRetention"]


class TestWeights:
    def test_there_are_21_of_them(self):
        assert len(W) == 21

    def test_desired_retention_is_a_probability(self):
        assert 0 < RETENTION < 1


class TestRetrievabilityInvariants:
    """These hold for *any* correct FSRS implementation, not just this one —
    they follow from how S is defined, independent of the specific weights."""

    @pytest.mark.parametrize("stability", [0.1, 1, 5, 50, 500])
    def test_retrievability_at_t_equals_s_is_the_target_retention(self, stability):
        assert retrievability(stability, stability, W) == pytest.approx(0.9, abs=1e-9)

    def test_retrievability_decreases_as_time_passes(self):
        values = [retrievability(t, 10.0, W) for t in (1, 5, 10, 20, 50, 100)]
        assert all(a > b for a, b in zip(values, values[1:])), values

    def test_retrievability_at_zero_elapsed_is_full_recall(self):
        assert retrievability(0.0, 10.0, W) == pytest.approx(1.0)

    @pytest.mark.parametrize("stability", [1, 10, 100])
    def test_interval_then_retrievability_round_trips(self, stability):
        """next_interval(S) is defined as the t where R(t,S) == desired
        retention — computing one from the other and back must return the
        retention target, or the two formulas have drifted apart."""
        interval = next_interval(stability, W, RETENTION)
        assert retrievability(interval, stability, W) == pytest.approx(RETENTION, abs=1e-9)

    def test_interval_is_proportional_to_stability(self):
        # I(r, S) = (S / FACTOR) * const(r) — linear in S for fixed r.
        i10 = next_interval(10.0, W, RETENTION)
        i20 = next_interval(20.0, W, RETENTION)
        assert i20 == pytest.approx(2 * i10, rel=1e-9)


class TestDifficultyBounds:
    @pytest.mark.parametrize("rating", RATINGS)
    def test_initial_difficulty_is_clamped(self, rating):
        d = init_difficulty(rating, W)
        assert MIN_DIFFICULTY <= d <= MAX_DIFFICULTY

    @pytest.mark.parametrize("rating", RATINGS)
    def test_updated_difficulty_is_clamped(self, rating):
        for start in (1.0, 5.5, 10.0):
            d = next_difficulty(start, rating, W)
            assert MIN_DIFFICULTY <= d <= MAX_DIFFICULTY

    def test_repeated_again_ratings_do_not_escape_the_clamp(self):
        d = 5.0
        for _ in range(50):
            d = next_difficulty(d, AGAIN, W)
        assert MIN_DIFFICULTY <= d <= MAX_DIFFICULTY

    def test_repeated_easy_ratings_do_not_escape_the_clamp(self):
        d = 5.0
        for _ in range(50):
            d = next_difficulty(d, EASY, W)
        assert MIN_DIFFICULTY <= d <= MAX_DIFFICULTY

    def test_again_makes_a_card_harder_than_easy(self):
        harder = next_difficulty(5.0, AGAIN, W)
        easier = next_difficulty(5.0, EASY, W)
        assert harder > easier


class TestFirstReview:
    @pytest.mark.parametrize("rating", RATINGS)
    def test_produces_a_positive_stability_and_a_bounded_difficulty(self, rating):
        state, interval = schedule(None, rating, 0.0, W, RETENTION)
        assert state.stability > 0
        assert MIN_DIFFICULTY <= state.difficulty <= MAX_DIFFICULTY
        assert interval > 0

    def test_easy_schedules_further_out_than_again_hard_good(self):
        again, _ = schedule(None, AGAIN, 0.0, W, RETENTION)
        hard, _ = schedule(None, HARD, 0.0, W, RETENTION)
        good, _ = schedule(None, GOOD, 0.0, W, RETENTION)
        easy, _ = schedule(None, EASY, 0.0, W, RETENTION)
        assert again.stability < hard.stability < good.stability < easy.stability

    def test_matches_init_stability_and_init_difficulty_directly(self):
        state, _ = schedule(None, GOOD, 0.0, W, RETENTION)
        assert state.stability == init_stability(GOOD, W)
        assert state.difficulty == init_difficulty(GOOD, W)


class TestSubsequentReview:
    STATE = MemoryState(stability=5.0, difficulty=5.0)

    def test_harder_ratings_grow_stability_less_than_easier_ones(self):
        """Given these specific published weights, hard_penalty < 1 <
        easy_bonus (§ algorithm.py docstring) — this is a property of the
        current default weights, not a law of the algorithm in general."""
        hard, _ = schedule(self.STATE, HARD, 5.0, W, RETENTION)
        good, _ = schedule(self.STATE, GOOD, 5.0, W, RETENTION)
        easy, _ = schedule(self.STATE, EASY, 5.0, W, RETENTION)
        assert hard.stability < good.stability < easy.stability

    def test_again_is_a_lapse_not_growth(self):
        again, _ = schedule(self.STATE, AGAIN, 5.0, W, RETENTION)
        assert again.stability < self.STATE.stability

    def test_more_elapsed_time_at_the_same_rating_increases_stability_gain(self):
        """Recalling something after a longer gap is stronger evidence of a
        durable memory, so the stability increase should be bigger — this is
        the forgetting-curve term `(1 - R) * w10` in the success formula."""
        soon, _ = schedule(self.STATE, GOOD, 2.0, W, RETENTION)
        later, _ = schedule(self.STATE, GOOD, 20.0, W, RETENTION)
        assert later.stability > soon.stability

    def test_interval_equals_the_new_stability_at_the_default_retention_target(self):
        state, interval = schedule(self.STATE, GOOD, 5.0, W, RETENTION)
        assert interval == pytest.approx(state.stability)


class TestSameDayReview:
    STATE = MemoryState(stability=5.0, difficulty=5.0)

    @pytest.mark.parametrize("rating", RATINGS)
    def test_stays_positive_and_bounded(self, rating):
        state, interval = schedule(self.STATE, rating, 0.3, W, RETENTION)
        assert state.stability > 0
        assert MIN_DIFFICULTY <= state.difficulty <= MAX_DIFFICULTY
        assert interval > 0

    def test_uses_the_short_term_formula_not_the_long_term_one(self):
        """A same-day repeat must not be scored as if a whole forgetting
        curve had elapsed — the two formulas give different numbers for the
        same nominal rating, and this pins which one same-day gets."""
        from evals.fsrs.algorithm import _next_stability_short_term

        state, _ = schedule(self.STATE, GOOD, 0.3, W, RETENTION)
        assert state.stability == _next_stability_short_term(self.STATE.stability, GOOD, W)

    def test_elapsed_days_at_exactly_one_uses_the_long_term_formula(self):
        """The boundary is `< 1.0`, not `<= 1.0` — one full day elapsed is a
        genuine gap, not a same-session repeat."""
        from evals.fsrs.algorithm import _next_stability_success

        state, _ = schedule(self.STATE, GOOD, 1.0, W, RETENTION)
        r = retrievability(1.0, self.STATE.stability, W)
        expected = _next_stability_success(self.STATE.difficulty, self.STATE.stability, r, GOOD, W)
        assert state.stability == pytest.approx(expected)


class TestUnknownRating:
    def test_rejects_a_rating_outside_1_to_4(self):
        with pytest.raises(ValueError):
            schedule(None, 0, 0.0, W, RETENTION)
        with pytest.raises(ValueError):
            schedule(None, 5, 0.0, W, RETENTION)
