"""Card quality rubric (ANA-PLAN §23.3).

Seven criteria, each scored 0-2 (14 max):
  >= 12  accept
  9-11   revise / review
  <= 8   reject

This module encodes the *scoring scale and thresholds* deterministically so
human or model scores can be aggregated consistently. It does NOT auto-grade
card content — that is a human/LLM-judge task in Faz 3; this is the scaffolding
those scores flow through.
"""

from __future__ import annotations

from dataclasses import dataclass

CRITERIA = (
    "source_faithfulness",
    "single_clear_answer",
    "medical_accuracy",
    "question_clarity",
    "learning_value",
    "non_redundancy",
    "appropriate_difficulty",
)

MAX_PER_CRITERION = 2
MAX_TOTAL = len(CRITERIA) * MAX_PER_CRITERION  # 14

ACCEPT_MIN = 12
REVISE_MIN = 9


@dataclass(frozen=True)
class RubricResult:
    total: int
    verdict: str  # "accept" | "revise" | "reject"
    scores: dict[str, int]


def verdict_for(total: int) -> str:
    if total >= ACCEPT_MIN:
        return "accept"
    if total >= REVISE_MIN:
        return "revise"
    return "reject"


def score_card(scores: dict[str, int]) -> RubricResult:
    """Aggregate per-criterion scores (each 0-2) into a verdict.

    Raises on unknown criteria, missing criteria, or out-of-range scores so a
    malformed rubric entry fails loudly rather than skewing aggregate stats.
    """
    missing = set(CRITERIA) - set(scores)
    if missing:
        raise ValueError(f"missing rubric criteria: {sorted(missing)}")
    unknown = set(scores) - set(CRITERIA)
    if unknown:
        raise ValueError(f"unknown rubric criteria: {sorted(unknown)}")
    for name, value in scores.items():
        if not isinstance(value, int) or not (0 <= value <= MAX_PER_CRITERION):
            raise ValueError(f"score for {name!r} must be an int in 0..{MAX_PER_CRITERION}, got {value!r}")

    total = sum(scores[name] for name in CRITERIA)
    return RubricResult(total=total, verdict=verdict_for(total), scores=dict(scores))
