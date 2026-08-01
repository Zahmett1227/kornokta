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


def collapse_whitespace(text: str) -> str:
    return _WHITESPACE_RE.sub(" ", text).strip()


def normalize_for_compare(text: str) -> str:
    """Normalization applied before comparing two OCR hypotheses.

    Deliberately conservative: casing, Unicode form and whitespace only.
    Decimal separators, dashes, symbols and units are left untouched because
    differences there are medically meaningful (ANA-PLAN §10.5).
    """
    return collapse_whitespace(turkish_lower(text))
