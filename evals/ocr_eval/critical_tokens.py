"""Deterministic critical-token detector (ANA-PLAN §10.5, §23.4).

Flags spans whose OCR disagreement must never be auto-accepted: numbers,
units, doses, negations, laterality, ion charges, Greek letters, comparison
signs, hypo/hyper prefixes, stage/grade markers, and (via wordlists) drug and
microorganism names.

The detector over-flags rather than under-flags by design: a false positive
costs one confirmation tap, a false negative can store a wrong dose.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable

from .normalize import turkish_lower

TOKEN_CLASSES = (
    "number_decimal",
    "unit",
    "dose_frequency",
    "percentage",
    "plus_minus",
    "comparator",
    "greek_letter",
    "ion_charge",
    "hypo_hyper",
    "positive_negative",
    "negation_pair",
    "laterality",
    "proximal_distal",
    "stage_grade_class",
    "drug_name",
    "organism_name",
)


@dataclass(frozen=True)
class CriticalToken:
    text: str
    token_class: str
    start: int
    end: int


@dataclass
class Wordlists:
    """Extensible name lists (ANA-PLAN §10.5 son iki sınıf).

    Kept tiny here on purpose; the real lists grow from the user's own
    corrections (personal dictionary, §10.6) and curated sources.
    """

    drug_names: set[str] = field(default_factory=set)
    organism_names: set[str] = field(default_factory=set)


_UNITS = (
    "mEq/L", "mmol/L", "mmHg", "mcg", "µg", "μg", "mg", "ng", "pg",
    "kg", "g", "mL", "ml", "dL", "dl", "L", "IU", "U", "mOsm",
)

_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # Order matters only for readability; overlapping matches are all kept.
    ("dose_frequency", re.compile(
        r"(?:\d+(?:[.,]\d+)?\s*)?(?:mg|mcg|µg|μg|g)/kg(?:/(?:gün|doz|saat))?"
        r"|q\d+\s*h"
        r"|günde\s+\d+"
        r"|haftada\s+\d+"
        r"|\d+\s*[x×]\s*\d+",
        re.IGNORECASE,
    )),
    ("percentage", re.compile(r"%\s*\d+(?:[.,]\d+)?|\d+(?:[.,]\d+)?\s*%")),
    ("number_decimal", re.compile(
        r"\d+(?:[.,]\d+)?(?:\s*[–—-]\s*\d+(?:[.,]\d+)?)?"
    )),
    # Letters (not digits or '/') break a unit match, so 'mg' inside 'mg/kg'
    # and '5mg' both count, while 'mgX' does not. A leading '/' is excluded to
    # avoid re-matching the denominator of composite units like mEq/L.
    ("unit", re.compile(
        r"(?<![A-Za-zÇĞİÖŞÜçğıöşü/])(?:"
        + "|".join(re.escape(u) for u in _UNITS)
        + r")(?![A-Za-zÇĞİÖŞÜçğıöşü])"
    )),
    ("comparator", re.compile(r"[<>≤≥]")),
    ("plus_minus", re.compile(r"(?<![\w+±-])[+±−](?![\w+±−-])|\(\s*[+−-]\s*\)")),
    ("greek_letter", re.compile(r"[α-ωΑ-Ω]")),
    ("ion_charge", re.compile(
        r"\b(?:Na|K|Ca|Mg|Cl|H|HCO₃|HCO3|PO₄|PO4|NH₄|NH4|Fe)"
        r"(?:[⁺⁻²³]+|\^?\d?[+-])"
    )),
    ("hypo_hyper", re.compile(r"\b(?:hipo|hiper)\w*", re.IGNORECASE)),
    ("positive_negative", re.compile(r"\b(?:pozitif|negatif)\b", re.IGNORECASE)),
    # Negation and direction-of-change. Enumerating verb forms misses Turkish
    # inflection ('artar' was listed but 'artmaz' was not), so the negative
    # aorist suffix -maz/-mez is matched as a pattern: one rule covers
    # artmaz, azalmaz, göstermez, etkilemez, değişmez, ... Direction verbs are
    # listed separately because their positive forms carry the same
    # meaning-flip risk as artar/azalır (ANA-PLAN §10.5).
    ("negation_pair", re.compile(
        r"\w+m[ae]z\b"
        r"|\b(?:var|yok|değil)\b"
        r"|\b(?:yapar|artar|artırır|azalır|azaltır|görülür|izlenir|saptanır"
        r"|yükselir|yükseltir|düşer|düşürür|çoğalır|gerileri?r|bozar|engeller)\b",
        re.IGNORECASE,
    )),
    ("laterality", re.compile(r"\b(?:sağ|sol)\b", re.IGNORECASE)),
    ("proximal_distal", re.compile(r"\b(?:proksimal|distal)\b", re.IGNORECASE)),
    ("stage_grade_class", re.compile(
        r"\b(?:evre|derece|sınıf|grade|stage|tip)\s*(?:[IVX]+|\d+)?\b",
        re.IGNORECASE,
    )),
]


def _wordlist_matches(text: str, names: Iterable[str], token_class: str) -> list[CriticalToken]:
    # turkish_lower is length-preserving ('İ'→'i'), unlike str.casefold which
    # expands 'İ' to two code points and would shift every following index.
    found: list[CriticalToken] = []
    lowered = turkish_lower(text)
    for name in names:
        needle = turkish_lower(name)
        start = 0
        while True:
            idx = lowered.find(needle, start)
            if idx == -1:
                break
            found.append(CriticalToken(text[idx:idx + len(name)], token_class, idx, idx + len(name)))
            start = idx + len(name)
    return found


def detect_critical_tokens(text: str, wordlists: Wordlists | None = None) -> list[CriticalToken]:
    """Return all critical spans in `text`, sorted by position.

    Overlapping spans are kept — '0,5 mg/kg' yields dose_frequency,
    number_decimal and unit hits — because each class carries its own
    confirmation rule downstream.
    """
    tokens: list[CriticalToken] = []
    for token_class, pattern in _PATTERNS:
        for match in pattern.finditer(text):
            if match.group(0).strip():
                tokens.append(CriticalToken(match.group(0), token_class, match.start(), match.end()))

    if wordlists is not None:
        tokens.extend(_wordlist_matches(text, wordlists.drug_names, "drug_name"))
        tokens.extend(_wordlist_matches(text, wordlists.organism_names, "organism_name"))

    unique = {(t.start, t.end, t.token_class): t for t in tokens}
    return sorted(unique.values(), key=lambda t: (t.start, t.end, t.token_class))


def contains_critical_token(text: str, wordlists: Wordlists | None = None) -> bool:
    return bool(detect_critical_tokens(text, wordlists))
