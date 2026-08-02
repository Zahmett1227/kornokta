"""Turkish-aware text normalization for OCR comparison (ANA-PLAN §10.3, §23.4).

Normalization is used ONLY to compare two OCR outputs — it must never alter
what gets stored or shown. Medically meaningful characters (decimal commas,
units, ion charges, Greek letters, comparison signs) are preserved verbatim.
"""

from __future__ import annotations

import re
import unicodedata

_WHITESPACE_RE = re.compile(r"\s+")

# Turkish casing: 'I' lowercases to 'ı' (dotless) and 'İ' to 'i'. Python's
# str.lower() applies English rules ('I'→'i', 'İ'→'i̇'), which corrupts
# comparisons like "İLAÇ" vs "ilaç".
_TR_LOWER_MAP = str.maketrans({"I": "ı", "İ": "i"})


def nfc(text: str) -> str:
    """Canonical Unicode composition so 'i̇' (i + combining dot) == 'i'."""
    return unicodedata.normalize("NFC", text)


def turkish_lower(text: str) -> str:
    return nfc(text).translate(_TR_LOWER_MAP).lower()


# Turkish-only letters and their ASCII twins. Strictly one character to one
# character, so folding never shifts an offset.
_DIACRITIC_MAP = str.maketrans({
    "ı": "i", "İ": "I",
    "ş": "s", "Ş": "S",
    "ğ": "g", "Ğ": "G",
    "ç": "c", "Ç": "C",
    "ö": "o", "Ö": "O",
    "ü": "u", "Ü": "U",
})


def fold_diacritics(text: str) -> str:
    """Map Turkish diacritics onto ASCII, preserving length.

    Used **only** for matching and comparison, never to produce text a human
    reads or that gets stored (§0.5) — the caller slices its surface from the
    original string.

    This exists because an OCR engine may be unable to emit these letters at
    all. Apple Vision produced `ı ş ğ İ` exactly zero times across 148 lines of
    Turkish medical text (docs/FAZ0-BULGULAR.md), turning `görülmemiştir` into
    `gorulmemistir` and `sağ` into `sag`. Without folding, negation and
    laterality — two of the sharpest meaning-flip classes in §10.5 — would stop
    being detected on such output, and the gate would fall silent exactly where
    it matters most.
    """
    return text.translate(_DIACRITIC_MAP)


def collapse_whitespace(text: str) -> str:
    return _WHITESPACE_RE.sub(" ", text).strip()


def normalize_for_compare(text: str) -> str:
    """Normalization applied before comparing two OCR hypotheses.

    Deliberately conservative: casing, Unicode form and whitespace only.
    Decimal separators, dashes, symbols and units are left untouched because
    differences there are medically meaningful (ANA-PLAN §10.5).
    """
    return collapse_whitespace(turkish_lower(text))
