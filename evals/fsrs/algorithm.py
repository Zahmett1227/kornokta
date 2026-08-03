"""FSRS-6 reference implementation (ANA-PLAN §18.1).

Formulas cross-checked against two independent readings of the
open-spaced-repetition project's published algorithm spec and its
`fsrs-optimizer` reference source before being used here (§0.6: never a
number this codebase invented). Ratings follow FSRS's own convention:
Again=1, Hard=2, Good=3, Easy=4 — the same order ANA-PLAN §18.2 lists them
in ("Unuttum, Zor, Bildim, Kolay").

Deliberate choices this module makes that the algorithm spec itself leaves
to the implementer:

* Elapsed time between reviews is a continuous duration
  (`(now - last_reviewed_at) / 1 day`), never a calendar-date difference.
  A calendar-date boundary shifts when the device's time zone changes,
  which is exactly the "time zone change causes a lost or doubled review"
  failure ANA-PLAN §18.1 forbids. Duration-based elapsed time cannot drift
  with the clock's zone.
* "Same-day" (the short-term stability formula) is `elapsed_days < 1.0`,
  not a calendar-day equality check, for the same reason.
* Stability is floored at a small positive epsilon rather than left free to
  reach zero: a zero or negative stability would make `S ** -w9` and the
  interval formula's `S / FACTOR` blow up. The algorithm spec does not
  state a floor; this one is this module's own defensive addition.
* The maximum interval (100 years) is the widely-used FSRS convention for
  avoiding an absurd or overflowing due date, not a number specific to this
  app.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

WEIGHTS_PATH = Path(__file__).with_name("weights.json")

AGAIN, HARD, GOOD, EASY = 1, 2, 3, 4
RATINGS = (AGAIN, HARD, GOOD, EASY)

MIN_DIFFICULTY = 1.0
MAX_DIFFICULTY = 10.0
MIN_STABILITY = 0.01
MAX_INTERVAL_DAYS = 36_500.0


def load_weights(path: Path | str = WEIGHTS_PATH) -> dict:
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
    weights = payload["weights"]
    if len(weights) != 21:
        raise ValueError(f"FSRS-6 needs 21 weights, got {len(weights)}")
    return payload


@dataclass(frozen=True)
class MemoryState:
    stability: float
    difficulty: float


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def init_difficulty(rating: int, w: list[float]) -> float:
    d0 = w[4] - math.exp(w[5] * (rating - 1)) + 1
    return _clamp(d0, MIN_DIFFICULTY, MAX_DIFFICULTY)


def init_stability(rating: int, w: list[float]) -> float:
    return max(w[rating - 1], MIN_STABILITY)


def next_difficulty(difficulty: float, rating: int, w: list[float]) -> float:
    delta_d = -w[6] * (rating - 3)
    linear_damped = difficulty + delta_d * (10 - difficulty) / 9
    d0_easy = w[4] - math.exp(w[5] * (EASY - 1)) + 1
    reverted = w[7] * d0_easy + (1 - w[7]) * linear_damped
    return _clamp(reverted, MIN_DIFFICULTY, MAX_DIFFICULTY)


def retrievability(elapsed_days: float, stability: float, w: list[float]) -> float:
    """R(t, S): probability of recall after `elapsed_days` (§18.1)."""
    decay = -w[20]
    factor = 0.9 ** (1 / decay) - 1
    return (1 + factor * elapsed_days / stability) ** decay


def next_interval(stability: float, w: list[float], desired_retention: float) -> float:
    """Days until retrievability decays to `desired_retention` (§18.3's
    "bugün bekleyen kartlar" is exactly this: due when R would fall to the
    target)."""
    decay = -w[20]
    factor = 0.9 ** (1 / decay) - 1
    days = (stability / factor) * (desired_retention ** (1 / decay) - 1)
    return _clamp(days, 0.0, MAX_INTERVAL_DAYS)


def _next_stability_success(difficulty: float, stability: float, r: float, rating: int, w: list[float]) -> float:
    hard_penalty = w[15] if rating == HARD else 1.0
    easy_bonus = w[16] if rating == EASY else 1.0
    increase = (
        1
        + math.exp(w[8])
        * (11 - difficulty)
        * (stability ** -w[9])
        * (math.exp((1 - r) * w[10]) - 1)
        * hard_penalty
        * easy_bonus
    )
    return max(stability * increase, MIN_STABILITY)


def _next_stability_failure(difficulty: float, stability: float, r: float, w: list[float]) -> float:
    value = (
        w[11]
        * (difficulty ** -w[12])
        * (((stability + 1) ** w[13]) - 1)
        * math.exp((1 - r) * w[14])
    )
    return max(value, MIN_STABILITY)


def _next_stability_short_term(stability: float, rating: int, w: list[float]) -> float:
    increase = math.exp(w[17] * (rating - 3 + w[18])) * (stability ** -w[19])
    return max(stability * increase, MIN_STABILITY)


def schedule(
    state: MemoryState | None,
    rating: int,
    elapsed_days: float,
    w: list[float],
    desired_retention: float,
) -> tuple[MemoryState, float]:
    """Returns the next `MemoryState` and the interval (days) until due.

    `state=None` means this card has never been reviewed — §18.1's initial
    stability/difficulty. Otherwise `elapsed_days` (a continuous duration,
    see the module docstring) picks the short-term formula for a same-day
    repeat or the normal success/failure formula for anything a day or more
    later.
    """
    if rating not in RATINGS:
        raise ValueError(f"unknown rating: {rating}")

    if state is None:
        difficulty = init_difficulty(rating, w)
        stability = init_stability(rating, w)
    elif elapsed_days < 1.0:
        difficulty = next_difficulty(state.difficulty, rating, w)
        stability = _next_stability_short_term(state.stability, rating, w)
    else:
        r = retrievability(elapsed_days, state.stability, w)
        difficulty = next_difficulty(state.difficulty, rating, w)
        if rating == AGAIN:
            stability = _next_stability_failure(state.difficulty, state.stability, r, w)
        else:
            stability = _next_stability_success(state.difficulty, state.stability, r, rating, w)

    interval = next_interval(stability, w, desired_retention)
    return MemoryState(stability=stability, difficulty=difficulty), interval
