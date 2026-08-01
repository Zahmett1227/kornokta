"""OCR and selection metrics for the gold test set (ANA-PLAN §23.2).

All metrics are deterministic and dependency-free so they can double as a
reference for the future Swift implementation.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass
from typing import Iterable, Sequence

from .normalize import nfc, normalize_for_compare


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

# Turkish *inflectional* suffixes attach without changing which word it is, so
# 'hiperkalemide' still contains 'hiperkalemi'. Derivational suffixes (-lı,
# -lık, -sız, -ce) are deliberately absent: they build a different lexeme, and
# allowing them would let 'sağlıklı' satisfy the laterality token 'sağ'.
#
# The slots are kept separate and applied in Turkish order — plural, then
# possessive, then case, then copula. A flat "any suffix, repeated" rule would
# re-open the very hole this exists to close: 'solunum' decomposes into
# 'sol' + 'un' + 'um' if arbitrary chains are allowed, whereas here 'um' is in
# no case slot, so the parse fails and the laterality error is reported.
_PLURAL = "ler|lar"
_POSSESSIVE = (
    "imiz|ımız|umuz|ümüz|iniz|ınız|unuz|ünüz"
    "|leri|ları"
    "|im|ım|um|üm|in|ın|un|ün"
    "|si|sı|su|sü"
    "|i|ı|u|ü"
)
_CASE = (
    "nden|ndan|den|dan|ten|tan"
    "|nde|nda|de|da|te|ta"
    "|nin|nın|nun|nün"
    "|yle|yla|le|la"
    "|ye|ya|ne|na"
    "|yi|yı|yu|yü|ni|nı|nu|nü"
    "|e|a|i|ı|u|ü"
)
#: Copular endings, which may follow the case slot. Turkish inserts a buffer
#: 'y' when the copula lands on a vowel-final case suffix, so 'sağdaydı' is
#: 'sağ' + 'da' + 'y' + 'dı' — without the buffer a perfect transcription would
#: be scored as a critical-token error.
_COPULA = "y?(?:dir|dır|dur|dür|tir|tır|tur|tür|di|dı|du|dü|ti|tı|tu|tü)"

#: Below this length a token is matched exactly, with no suffix tolerance.
#: Unit symbols are short and are not inflected in running text, while ordinary
#: words readily start with the same letters: applying the suffix policy to the
#: unit 'g' lets 'gün' ("day") satisfy it and hides a lost unit.
_MIN_LENGTH_FOR_SUFFIXES = 3

#: Plural is only allowed from this length up. '-lar/-ler' turns many short
#: roots into an unrelated word — 'sağlar' is the verb "provides", not the
#: plural of the laterality 'sağ' — so a lost 'sağ' would be satisfied by a
#: sentence that merely contains that verb. Longer roots ('hiperkalemiler',
#: 'adrenalinler') do not have this collision.
_MIN_LENGTH_FOR_PLURAL = 5


def _suffix_chain(token: str) -> str:
    plural = f"(?:{_PLURAL})?" if len(token) >= _MIN_LENGTH_FOR_PLURAL else ""
    return f"{plural}(?:{_POSSESSIVE})?(?:{_CASE})?(?:{_COPULA})?"


def _token_occurrence_pattern(token: str) -> re.Pattern[str]:
    """Regex matching `token` as a real occurrence, not as part of another value.

    Plain substring search is wrong here — gold '1' is "found" inside '10 mg'
    and gold '0,1' inside '10,1 mg' — so boundaries are chosen per token:

    - Digits: the token must not touch another digit, nor a separator that
      itself joins a digit. '1' is not satisfied by '10' or '1,5', but ordinary
      sentence punctuation ('Evre 1.') still counts as a genuine occurrence.
    - Letters: the token must not be preceded by a letter ('adrenalin' is not
      satisfied by 'noradrenalin'), and may only be followed by an ordered
      chain of inflectional suffixes. Arbitrary trailing letters would let
      'sol' be satisfied by 'solunum' and 'sağ' by 'sağlıklı' — a reversed
      laterality scoring as correct. Tokens shorter than
      `_MIN_LENGTH_FOR_SUFFIXES` take no suffixes at all, so the unit 'g' is
      not satisfied by 'gün'.
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
        chain = _suffix_chain(token) if len(token) >= _MIN_LENGTH_FOR_SUFFIXES else ""
        right = f"{chain}(?!{_LETTER})"

    return re.compile(left + re.escape(token) + right)


def critical_token_error_rate(gold_tokens: Iterable[str], hypothesis: str) -> float:
    """Fraction of gold critical tokens NOT reproduced in the hypothesis.

    This measures one direction only — whether what the source said survived.
    Pair it with `added_critical_tokens` for the other direction; a clean score
    here does not by itself mean the hypothesis is safe.

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


def _canonical(text: str, token_class: str | None = None) -> str:
    collapsed = re.sub(r"\s+", "", normalize_for_compare(text))
    if token_class == "route":
        # Routes are case-insensitive abbreviations, so 'IM' and 'im' are the
        # same value. Turkish lowercasing maps 'I' to 'ı', which would leave
        # them comparing unequal and report a correct transcription as a
        # mismatch; folding up puts both spellings on 'IM'.
        return collapsed.upper()
    return collapsed


def _annotated_spans(text: str, tokens: Iterable[str]) -> list[tuple[int, int, str]]:
    """Locate human-annotated tokens in `text`, with the same boundary rules."""
    spans: list[tuple[int, int, str]] = []
    for token in tokens:
        token = nfc(token).strip()
        if not token:
            continue
        pattern = re.compile(
            _token_occurrence_pattern(token).pattern, re.IGNORECASE
        )
        for match in pattern.finditer(text):
            spans.append((match.start(), match.end(), match.group(0)))
    return spans


def critical_token_sequence(
    text: str,
    wordlists: "Wordlists | None" = None,
    annotated_tokens: Iterable[str] | None = None,
) -> list[tuple[str, str]]:
    """Ordered (class, canonical value) pairs for every critical span in `text`.

    `annotated_tokens` are the manifest's hand-marked criticalTokens. They are
    needed because the automatic detector only knows the patterns and word
    lists compiled into it: a drug absent from `Wordlists` is invisible to it,
    so a passage naming two such drugs yields the same sequence however the
    doses are assigned. The manifest — not the detector — is the authority on
    what counts as critical (ANA-PLAN §23.1).
    """
    from .critical_tokens import detect_critical_tokens

    text = nfc(text)
    detected = detect_critical_tokens(text, wordlists)
    entries = [
        (t.start, t.end, t.token_class, _canonical(t.text, t.token_class))
        for t in detected
    ]

    if annotated_tokens:
        # Suppress an annotation only when the detector already produced the
        # *same span* — a true duplicate. Dropping partial overlaps instead
        # would discard the annotation whenever it merely contains a detected
        # token: 'β-bloker' overlaps the greek letter 'β', so both drug names
        # in 'β-bloker 1 mg, β-agonist 2 mg' would vanish and a swap between
        # them would pass the gate.
        exact = {(t.start, t.end) for t in detected}
        for start, end, surface in _annotated_spans(text, annotated_tokens):
            if (start, end) not in exact:
                entries.append((start, end, "annotated", _canonical(surface)))

    entries.sort(key=lambda e: (e[0], e[1], e[2]))
    return [(cls, value) for _s, _e, cls, value in entries]


def _sequence_with_surfaces(
    text: str,
    wordlists: "Wordlists | None",
    annotated_tokens: Iterable[str] | None,
) -> list[tuple[tuple[str, str], str]]:
    """((class, canonical), surface) pairs — canonical drives comparison, the
    surface is what a human reads in the report. They differ for values whose
    normalization is lossy: 'IM' folds to 'ım' under Turkish lowercasing."""
    from .critical_tokens import detect_critical_tokens

    text = nfc(text)
    detected = detect_critical_tokens(text, wordlists)
    entries = [
        (t.start, t.end, t.token_class, _canonical(t.text, t.token_class), t.text)
        for t in detected
    ]

    if annotated_tokens:
        exact = {(t.start, t.end) for t in detected}
        for start, end, surface in _annotated_spans(text, annotated_tokens):
            if (start, end) not in exact:
                entries.append((start, end, "annotated", _canonical(surface), surface))

    entries.sort(key=lambda e: (e[0], e[1], e[2]))
    return [((cls, value), surface) for _s, _e, cls, value, surface in entries]


def critical_token_mismatches(
    gold_text: str,
    hypothesis: str,
    wordlists: "Wordlists | None" = None,
    gold_tokens: Iterable[str] | None = None,
) -> list[str]:
    """Ordered differences between the two texts' critical-token sequences.

    Both count-based measures — `critical_token_error_rate` and
    `added_critical_tokens` — compare multisets, which discards the pairing
    between values. Swapping two units keeps every count identical:
    'A ilacı 1 mg, B ilacı 2 g' read as 'A ilacı 1 g, B ilacı 2 mg' scores
    clean on both while the doses have exchanged units. Comparing the ordered
    sequences catches it, so the Faz 0 gate needs this alongside the other two
    (ANA-PLAN §23.2, §24.3).

    Pass the manifest's `criticalTokens` as `gold_tokens`: they are applied to
    *both* texts, so values the built-in detector cannot recognise — an
    unlisted drug name, say — still take part in the ordering. Without them a
    swapped drug/dose assignment goes unseen.

    Returns one human-readable entry per divergence; empty means the sequences
    agree.
    """
    import difflib

    gold_entries = _sequence_with_surfaces(gold_text, wordlists, gold_tokens)
    hyp_entries = _sequence_with_surfaces(hypothesis, wordlists, gold_tokens)
    gold_keys = [key for key, _surface in gold_entries]
    hyp_keys = [key for key, _surface in hyp_entries]

    def render(entries: Sequence[tuple[tuple[str, str], str]]) -> str:
        return ", ".join(f"{surface} ({key[0]})" for key, surface in entries) or "—"

    matcher = difflib.SequenceMatcher(a=gold_keys, b=hyp_keys, autojunk=False)
    mismatches: list[str] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        mismatches.append(
            f"{tag}: kaynak [{render(gold_entries[i1:i2])}] "
            f"-> okuma [{render(hyp_entries[j1:j2])}]"
        )
    return mismatches


def added_critical_tokens(
    gold_text: str, hypothesis: str, wordlists: "Wordlists | None" = None
) -> list[str]:
    """Critical tokens the hypothesis introduces that the gold text lacks.

    `critical_token_error_rate` only measures one direction — whether the gold
    tokens survived — so an OCR run that *adds* a critical value scores zero
    while changing the meaning: gold '1 mg' read as '1–2 mg' keeps every gold
    token and gains a dose endpoint. The Faz 0 gate needs both directions
    (ANA-PLAN §23.2, §24.3), so this reports the surplus side.

    Returns the surplus occurrences, so a value appearing twice in the
    hypothesis but once in the source is reported once.
    """
    from .critical_tokens import detect_critical_tokens

    def counted(text: str) -> Counter:
        # Key on (class, canonical value). Several patterns accept optional
        # spacing — '%40' and '% 40', 'q8h' and 'q8 h' — so keying on the raw
        # surface would report a re-spaced value as a newly introduced one.
        return Counter(
            (t.token_class, re.sub(r"\s+", "", normalize_for_compare(t.text)))
            for t in detect_critical_tokens(text, wordlists)
        )

    surplus = counted(hypothesis) - counted(gold_text)
    return sorted(value for _cls, value in surplus.elements())
