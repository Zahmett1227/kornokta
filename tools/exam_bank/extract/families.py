"""F1–F6: what differs between the booklet families (§2.1).

The layout rules (columns, hanging numbers, option labels) are shared; what
a family changes is how a question number looks, whether empty slots are
normal, and whether the file's text layer can be read at all.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Family:
    code: str
    marker: str = "number"   # "number" = "12." hanging in the margin; "soru" = a "Soru 12" line
    sparse: bool = False      # most slots are empty on purpose (ÖSYM shows ~10% of the paper)
    text_layer: bool = True   # False: the glyphs are there but their encoding is not (2011/1)


FAMILIES = {
    "F1": Family("F1"),
    "F2": Family("F2"),
    "F3": Family("F3"),
    "F4": Family("F4", sparse=True),
    "F5": Family("F5"),
    "F6": Family("F6", marker="soru"),
}

# Files whose text layer decodes to nonsense: A1 takes only positions from
# them, and A6 reads the text from page images (§5.9).
UNREADABLE_TEXT = {
    "2006-2012/TUS_2011_Ilkbahar_TemelKlinik.pdf",
}


def family_for(code: str) -> Family:
    return FAMILIES[code]
