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

from .normalize import fold_diacritics, nfc

TOKEN_CLASSES = (
    "number_decimal",
    "unit",
    "dose_frequency",
    "route",
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


#: Administration routes, keyed by canonical code (ANA-PLAN §10.5).
#:
#: Spellings inside one entry are the SAME route and fold together, so 'IV',
#: 'intravenöz' and 'damar içi' compare equal. Entries never fold into each
#: other: IV and IM are different orders and a disagreement between them is a
#: critical-token error, never an automatic acceptance.
#:
#: Exposed so every gate measure folds identically — the ordered comparison and
#: both count-based measures must agree, or a correct transcription trips one
#: while passing another.
ROUTE_SYNONYMS: dict[str, tuple[str, ...]] = {
    "IV": ("IV", "intravenöz", "intravenoz", "intravenous", "damar içi", "damar içine", "damardan"),
    "IM": ("IM", "intramüsküler", "intramuskuler", "intramuscular", "kas içi", "kas içine"),
    "PO": ("PO", "oral", "oralden", "ağızdan", "agizdan", "per os", "peroral"),
    "SC": ("SC", "SQ", "subkutan", "subcutaneous", "deri altı", "deri altına", "cilt altı"),
    "SL": ("SL", "sublingual", "dil altı", "dil altına"),
    "PR": ("PR", "rektal", "rectal", "makattan"),
    "INH": ("INH", "inhaler", "inhalasyon", "inhalation", "inhale"),
    "IN": ("intranazal", "intranasal", "burun içi", "burun içine"),
    "TOP": ("topikal", "topical"),
    "TD": ("TD", "transdermal"),
    "IT": ("IT", "intratekal", "intrathecal"),
    "IA": ("intraartiküler", "intraartikuler", "intraarticular", "eklem içi"),
    "OPH": ("oftalmik", "ophthalmic", "oftalmolojik"),
    "OT": ("otik", "otic"),
}

#: Deliberately NOT registered as bare abbreviations: IN, IA, TOP, OT, OPH.
#: Each collides with an ordinary word in Turkish or English running text
#: ('in', 'top' = ball, 'ot' = grass), and the full spellings above cover them
#: without flooding the confirmation queue.

#: surface (folded) -> canonical route code
_ROUTE_LOOKUP: dict[str, str] = {
    re.sub(r"\s+", " ", surface.casefold()).strip(): code
    for code, surfaces in ROUTE_SYNONYMS.items()
    for surface in surfaces
}

# Longest first so 'damar içine' wins over 'damar içi', and multi-word forms
# tolerate any run of whitespace between their words.
_ROUTE_ALTERNATION = r"\b(?:" + "|".join(
    r"\s+".join(re.escape(word) for word in surface.split())
    for surface in sorted(
        (s for surfaces in ROUTE_SYNONYMS.values() for s in surfaces),
        key=len,
        reverse=True,
    )
) + r")\b"


def canonical_route(surface: str) -> str:
    """Map any accepted spelling of a route to its canonical code.

    Unknown text folds to its own uppercase form, so an unrecognised value is
    never silently merged with a known route.
    """
    key = re.sub(r"\s+", " ", nfc(surface).casefold()).strip()
    return _ROUTE_LOOKUP.get(key, key.upper())


def is_route_surface(text: str) -> bool:
    key = re.sub(r"\s+", " ", nfc(text).casefold()).strip()
    return key in _ROUTE_LOOKUP


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
    # Administration route. Not named in ANA-PLAN §10.5's list, but it changes
    # medical meaning as sharply as the classes that are — 'IM' read as 'IV'
    # is a different drug order — and the section's stated purpose is to gate
    # meaning-changing disagreements.
    #
    # Case-insensitive: the \b boundaries already stop word-internal matches,
    # so 'evim', 'resim', 'birim' and 'tedavim' do not trigger. Requiring
    # uppercase instead would miss a route change entirely whenever OCR
    # lowercases it ('5 mg iv' vs '5 mg im' would both go undetected).
    ("route", re.compile(_ROUTE_ALTERNATION, re.IGNORECASE)),
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
    # Case-insensitive: OCR readily emits 'na+' or 'NA+' for 'Na⁺', and the
    # standalone sign pattern cannot rescue those (its lookbehind rejects a
    # sign glued to a word character), so a charge reversal like na+ vs na-
    # would produce no critical token at all.
    ("ion_charge", re.compile(
        r"\b(?:Na|K|Ca|Mg|Cl|H|HCO₃|HCO3|PO₄|PO4|NH₄|NH4|Fe)"
        r"(?:[⁺⁻²³]+|\^?\d?[+-])",
        re.IGNORECASE,
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
        # Turkish negation is the -ma/-me morpheme between verb stem and
        # tense/aspect/modality suffix, so match the morpheme plus the suffix
        # that follows it rather than enumerating whole verb forms. One rule
        # covers the whole paradigm:
        #   -maz/-mez      artmaz, göstermez        (aorist)
        #   -mayan/-meyen  olmayan, görülmeyen      (participle)
        #   -madı/-medi    uygulanmadı, yapılmadığı (past)
        #   -mamış/-memiş  görülmemiş, bulunmamıştır(evidential)
        #   -mamalı/-memeli kullanılmamalıdır       (necessity)
        #   -mayacak/-meyecek verilmeyecek          (future)
        #   -mama/-meme    kullanılmaması           (verbal noun)
        # 'kullanılmamalıdır' vs 'kullanılmalıdır' is the sharpest meaning
        # flip in clinical prose, so missing this paradigm is the costliest
        # false negative in the whole detector (ANA-PLAN §10.5).
        #   -mayız/-meyiz    kullanmayız              (1st person plural aorist,
        #                                             buffered with y)
        r"\w+?m[ae](?:z|y[ıi]z|y[ae]n|d[ıi]|m[ıi]ş|m[ae]l[ıi]|y[ae]c[ae]k|m[ae])\w*"
        # Converbs and conditional, which carry the same reversal:
        #   -madan/-meden    verilmeden çekim yapılır
        #   -masa/-mese      kullanmasa da
        #   -mayarak/-meyerek ilacı kullanmayarak
        #   -maksızın        beklemeksizin
        # All require a word boundary so 'maden', 'masa' and noun+conditional
        # forms are not swept in.
        r"|\w+?m[ae](?:d[ae]n|s[ae]|y[ae]r[ae]k|ks[ıi]z[ıi]n)\b"
        # -masın/-mesin needs a word boundary: without it the positive verbal
        # noun plus case ending ('kullanılmasında') would match too.
        r"|\w+?m[ae]s[ıi]n\b"
        # Negative present continuous: görülmüyor, etkilemiyor ...
        r"|\w+?m[ıiuü]yor\w*"
        # 'değil' takes copular suffixes: değil, değildir, değildi, değilse ...
        r"|\bdeğil\w*"
        r"|\b(?:var|yok|yoktur|vardır)\b"
        r"|\b(?:yapar|artar|artırır|azalır|azaltır|görülür|izlenir|saptanır"
        r"|yükselir|yükseltir|düşer|düşürür|çoğalır|gerileri?r|bozar|engeller)\b",
        # Deliberately NOT matched: bare -ma/-me with no following suffix.
        # It is homographic with the (positive) verbal noun, which is pervasive
        # in medical prose — kanama, uygulama, gelişme, büyüme, yayılma,
        # bulaşma, beslenme, daralma. Flagging it would mark almost every
        # passage as critical and make confirmation meaningless, defeating the
        # low-intervention goal in ANA-PLAN §24.2. The bare negative imperative
        # ('ilacı kullanma') is not separable from the noun by morphology
        # alone; it needs the syntactic context available to the LLM
        # reconciliation step (§10.4), not this lexical pass.
        re.IGNORECASE,
    )),
    ("laterality", re.compile(r"\b(?:sağ|sol)\b", re.IGNORECASE)),
    ("proximal_distal", re.compile(r"\b(?:proksimal|distal)\b", re.IGNORECASE)),
    ("stage_grade_class", re.compile(
        r"\b(?:evre|derece|sınıf|grade|stage|tip)\s*(?:[IVX]+|\d+)?\b",
        re.IGNORECASE,
    )),
]

#: The same patterns with their Turkish letters folded to ASCII, for matching
#: output from an engine that cannot produce those letters. Derived from
#: `_PATTERNS` rather than written out again, so a new pattern is covered
#: automatically instead of silently escaping the second pass.
#:
#: Folding maps letters to letters and leaves every metacharacter alone, so the
#: rewritten source stays a valid regex: 'm[ıi]ş' becomes 'm[ii]s' and
#: '\bdeğil\w*' becomes '\bdegil\w*'. Case is preserved, so '[IVX]' and '\W'
#: are untouched.
_FOLDED_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (token_class, re.compile(fold_diacritics(pattern.pattern), pattern.flags))
    for token_class, pattern in _PATTERNS
]


def _fold_preserving_length(text: str) -> str:
    """Case-fold for matching with a guaranteed 1:1 character mapping.

    Offsets are reported back to the caller, so any length change here would
    shift every following span. str.lower() expands a few code points (notably
    'İ' → 'i' + combining dot), so those are mapped explicitly and any other
    expanding character keeps its original form rather than corrupting indices.
    """
    out = []
    for ch in text:
        lowered = ch.translate(_TR_LOWER_MAP_LOCAL).lower()
        out.append(lowered if len(lowered) == 1 else ch.lower()[:1] or ch)
    # Diacritics are folded too, so a wordlist entry matches OCR output that
    # could not represent them ('asetilsalisilik' vs 'asetilsalisilik' with the
    # dotted/dotless i). The map is 1:1, so offsets are still exact.
    return fold_diacritics("".join(out))


_TR_LOWER_MAP_LOCAL = str.maketrans({"I": "ı", "İ": "i"})


def _is_letter(ch: str) -> bool:
    return ch.isalpha()


def _wordlist_matches(text: str, names: Iterable[str], token_class: str) -> list[CriticalToken]:
    """Find configured names, refusing matches that start mid-word.

    A bare substring search reports 'adrenalin' inside 'noradrenalin', so the
    gold span for a passage about noradrenalin becomes the wrong drug — and a
    hypothesis that really says 'adrenalin' then agrees with it, letting a drug
    substitution through both critical-token directions. Requiring a non-letter
    before the match blocks that, while trailing letters stay allowed so
    Turkish suffixes ('adrenalindir') still count as the drug.
    """
    found: list[CriticalToken] = []
    lowered = _fold_preserving_length(text)
    for name in names:
        needle = _fold_preserving_length(nfc(name))
        if not needle:
            continue
        start = 0
        while True:
            idx = lowered.find(needle, start)
            if idx == -1:
                break
            end = idx + len(needle)
            if idx == 0 or not _is_letter(lowered[idx - 1]):
                found.append(CriticalToken(text[idx:end], token_class, idx, end))
            start = idx + 1
    return found


def detect_critical_tokens(text: str, wordlists: Wordlists | None = None) -> list[CriticalToken]:
    """Return all critical spans in `text`, sorted by position.

    Overlapping spans are kept — '0,5 mg/kg' yields dose_frequency,
    number_decimal and unit hits — because each class carries its own
    confirmation rule downstream.

    The input is normalized to NFC once, up front, and every reported
    `start`/`end` indexes that NFC form. Normalizing per-match would be unsafe:
    NFC can change length (decomposed 'İ' is two code points, composed is one),
    so offsets taken from a normalized copy do not address the original string.
    Callers that need to slice should use `nfc(text)` or the token's own `text`.
    """
    text = nfc(text)

    # Two passes: the patterns as written over the text as written, then the
    # diacritic-folded patterns over the diacritic-folded text.
    #
    # Folding only the text would not help — the *patterns* are what carry the
    # diacritics ('değil', 'sağ', 'm[ıi]ş'), so ASCII-fied input like
    # 'gorulmemistir' or 'sag' matches neither side unless both are folded.
    # An OCR engine that cannot emit ı/ş/ğ/İ produces exactly that
    # (docs/FAZ0-BULGULAR.md), and negation and laterality would go undetected.
    #
    # Folding is 1:1, so `match.start()`/`end()` still address the original
    # string, and the reported surface is sliced from `text` — the detector
    # reports what was written and never rewrites it (§0.5).
    passes = ((text, _PATTERNS), (fold_diacritics(text), _FOLDED_PATTERNS))

    tokens: list[CriticalToken] = []
    for haystack, patterns in passes:
        for token_class, pattern in patterns:
            for match in pattern.finditer(haystack):
                if match.group(0).strip():
                    tokens.append(CriticalToken(
                        text[match.start():match.end()],
                        token_class,
                        match.start(),
                        match.end(),
                    ))

    if wordlists is not None:
        tokens.extend(_wordlist_matches(text, wordlists.drug_names, "drug_name"))
        tokens.extend(_wordlist_matches(text, wordlists.organism_names, "organism_name"))

    unique = {(t.start, t.end, t.token_class): t for t in tokens}
    return sorted(unique.values(), key=lambda t: (t.start, t.end, t.token_class))


def contains_critical_token(text: str, wordlists: Wordlists | None = None) -> bool:
    return bool(detect_critical_tokens(text, wordlists))
