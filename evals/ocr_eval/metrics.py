"""OCR and selection metrics for the gold test set (ANA-PLAN §23.2).

All metrics are deterministic and dependency-free so they can double as a
reference for the future Swift implementation.
"""

from __future__ import annotations

import re
from collections import Counter
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


#: Any letter, Unicode-aware, so Turkish characters count.
_LETTER = r"[^\W\d_]"

#: Turkish *inflectional* suffixes — they attach to a word without changing
#: which word it is, so 'hiperkalemide' still contains 'hiperkalemi'.
#: Derivational suffixes (-lı, -lık, -sız, -ce) are deliberately absent: they
#: build a different lexeme, and allowing them would let 'sağlıklı' satisfy the
#: laterality token 'sağ'. Longer alternatives come first so the regex prefers
#: the fullest suffix.
_SUFFIX = (
    "leri|ları|ler|lar"
    "|den|dan|ten|tan"
    "|nin|nın|nun|nün"
    "|de|da|te|ta"
    "|in|ın|un|ün"
    "|yle|yla|le|la"
    "|miz|mız|muz|müz|niz|nız|nuz|nüz"
    "|ye|ya|yi|yı|yu|yü"
    "|si|sı|su|sü|ni|nı|nu|nü"
    "|e|a|i|ı|u|ü|m|n"
)
#: Copular endings, which may follow a suffix ('adrenalindir', 'evredeydi').
_COPULA = "dir|dır|dur|dür|tir|tır|tur|tür|di|dı|du|dü|ti|tı|tu|tü"


def _token_occurrence_pattern(token: str) -> re.Pattern[str]:
    """Regex matching `token` as a real occurrence, not as part of another value.

    Plain substring search is wrong here — gold '1' is "found" inside '10 mg'
    and gold '0,1' inside '10,1 mg' — so boundaries are chosen per token:

    - Digits: the token must not touch another digit, nor a separator that
      itself joins a digit. '1' is not satisfied by '10' or '1,5', but ordinary
      sentence punctuation ('Evre 1.') still counts as a genuine occurrence.
    - Letters: the token must not be preceded by a letter ('adrenalin' is not
      satisfied by 'noradrenalin'), and may only be followed by a recognised
      inflectional suffix. Arbitrary trailing letters would let 'sol' be
      satisfied by 'solunum' and 'sağ' by 'sağlıklı' — a reversed laterality
      scoring as correct.
    """
    left = right = ""
    if token[:1].isdigit():
        # Not after a digit, and not after a separator that joins a digit.
        left = r"(?<!\d)(?<!\d[.,])"
    elif token[:1].isalpha():
        left = f"(?<!{_LETTER})"

    if token[-1:].isdigit():
        right = r"(?!\d)(?![.,]\d)"
    elif token[-1:].isalpha():
        right = f"(?:{_SUFFIX})?(?:{_COPULA})?(?!{_LETTER})"

    return re.compile(left + re.escape(token) + right)


def critical_token_error_rate(gold_tokens: Iterable[str], hypothesis: str) -> float:
    """Fraction of gold critical tokens NOT reproduced in the hypothesis.

    Comparison is case/whitespace-normalized but character-exact otherwise:
    '0,1' vs '0.1' or 'hipo' vs 'hiper' counts as an error (ANA-PLAN §10.5).

    Repeated gold tokens are matched to *distinct* occurrences. Searching each
    gold entry independently would let one surviving '5' satisfy both doses of
    '5 mg sabah, 5 mg akşam' even after the second was misread as '50'.
    """
    tokens = [normalize_for_compare(t) for t in gold_tokens if t.strip()]
    if not tokens:
        return 0.0
    haystack = normalize_for_compare(hypothesis)

    required = Counter(tokens)
    missing = 0
    for token, needed in required.items():
        available = len(_token_occurrence_pattern(token).findall(haystack))
        missing += max(0, needed - available)
    return missing / len(tokens)
