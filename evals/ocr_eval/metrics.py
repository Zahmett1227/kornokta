"""OCR and selection metrics for the gold test set (ANA-PLAN §23.2).

All metrics are deterministic and dependency-free so they can double as a
reference for the future Swift implementation.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, Sequence

from .normalize import normalize_for_compare


def levenshtein(a: Sequence, b: Sequence) -> int:
    """Edit distance between two sequences (chars for CER, words for WER)."""
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, item_a in enumerate(a, start=1):
        current = [i]
        for j, item_b in enumerate(b, start=1):
            cost = 0 if item_a == item_b else 1
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost))
        previous = current
    return previous[-1]


def cer(reference: str, hypothesis: str, normalize: bool = True) -> float:
    """Character Error Rate. 0.0 = perfect; can exceed 1.0 for garbage output."""
    if normalize:
        reference = normalize_for_compare(reference)
        hypothesis = normalize_for_compare(hypothesis)
    if not reference:
        return 0.0 if not hypothesis else 1.0
    return levenshtein(reference, hypothesis) / len(reference)


def wer(reference: str, hypothesis: str, normalize: bool = True) -> float:
    """Word Error Rate over whitespace-delimited tokens."""
    if normalize:
        reference = normalize_for_compare(reference)
        hypothesis = normalize_for_compare(hypothesis)
    ref_words = reference.split()
    hyp_words = hypothesis.split()
    if not ref_words:
        return 0.0 if not hyp_words else 1.0
    return levenshtein(ref_words, hyp_words) / len(ref_words)


@dataclass(frozen=True)
class PrecisionRecallF1:
    precision: float
    recall: float
    f1: float
    true_positives: int
    false_positives: int
    false_negatives: int


def selection_prf(gold_line_ids: Iterable[str], predicted_line_ids: Iterable[str]) -> PrecisionRecallF1:
    """Underline/highlight line-selection quality (ANA-PLAN §23.2)."""
    gold = set(gold_line_ids)
    predicted = set(predicted_line_ids)
    tp = len(gold & predicted)
    fp = len(predicted - gold)
    fn = len(gold - predicted)
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    recall = tp / (tp + fn) if (tp + fn) else 1.0
    f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
    return PrecisionRecallF1(precision, recall, f1, tp, fp, fn)


#: A digit, or a decimal separator sitting between digits — the characters that
#: turn one number into a different number.
_NUMERIC_NEIGHBOUR = r"[\d.,]"
#: Any letter, Unicode-aware, so Turkish characters count.
_LETTER = r"[^\W\d_]"


def _token_occurrence_pattern(token: str) -> re.Pattern[str]:
    """Regex that finds `token` as a real occurrence, not as part of a
    different value.

    Plain substring search is wrong here: gold '1' is "found" inside '10 mg'
    and gold '0,1' inside '10,1 mg', so an OCR error that changes the dose
    reports as correct. Boundaries are chosen per token:

    - a token starting/ending in a digit must not touch another digit or a
      decimal separator ('1' is not satisfied by '10');
    - a token starting with a letter must not be preceded by a letter
      ('adrenalin' is not satisfied by 'noradrenalin') while trailing letters
      stay allowed, because Turkish attaches suffixes ('adrenalindir' does
      contain the drug).
    """
    left = right = ""
    if token[:1].isdigit():
        left = f"(?<!{_NUMERIC_NEIGHBOUR})"
    elif token[:1].isalpha():
        left = f"(?<!{_LETTER})"
    if token[-1:].isdigit():
        right = f"(?!{_NUMERIC_NEIGHBOUR})"
    return re.compile(left + re.escape(token) + right)


def critical_token_error_rate(gold_tokens: Iterable[str], hypothesis: str) -> float:
    """Fraction of gold critical tokens NOT reproduced in the hypothesis.

    Comparison is case/whitespace-normalized but character-exact otherwise:
    '0,1' vs '0.1' or 'hipo' vs 'hiper' counts as an error (ANA-PLAN §10.5).
    """
    tokens = [normalize_for_compare(t) for t in gold_tokens if t.strip()]
    if not tokens:
        return 0.0
    haystack = normalize_for_compare(hypothesis)
    missing = sum(
        1 for token in tokens if not _token_occurrence_pattern(token).search(haystack)
    )
    return missing / len(tokens)
