"""The design system's subject colour arc must cover every canonical ders.

"Kemik & Oxblood" gives the app a single accent that is not a brand colour but
a *position*: the colour of whatever subject is being studied. `CizgiSubject`
carries that arc — one colour per ders, all at the same lightness and
saturation, only the hue rotating.

That makes the arc a second copy of the subject list, and this project has been
bitten twice by "aynı davranış iki yerde" (CLAUDE.md, anti-drift). The canonical
list is `backend/schemas/subject_topics.json`; the arc shipped with nine stops
while the schema carries eleven, and `CizgiSubject.cerrahi` said "Cerrahi" where
the schema says "Genel Cerrahi".

Neither mistake breaks anything loudly. A ders with no stop falls through to the
time-of-day accent, and `SubjectDistributionBar` drops its cards from the strip
entirely — the cards are valid, active and due, the screen looks healthy, and
the deck it describes is wrong. That is the silent class this project locks
with tests rather than trusting to review: generate nothing by hand, lock it.

Python rather than Swift because the arc lives in the App target, which only
compiles on a Mac — and this check has to run wherever the evals do.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "ios" / "App" / "Theme" / "CizgiTheme.swift"
SCHEMA = ROOT / "backend" / "schemas" / "subject_topics.json"


def canonical_subjects() -> list[str]:
    data = json.loads(SCHEMA.read_text(encoding="utf-8"))
    subjects = data["subjects"] if isinstance(data, dict) else data
    return [s["name"] if isinstance(s, dict) else s for s in subjects]


def arc_block(name: str) -> str:
    """The body of one `var` on `CizgiSubject`, sliced from its own block.

    Sliced rather than searched whole-file for the reason prompt rule 3's lock
    learned the hard way: a bare substring search over the file finds matches in
    unrelated switches and protects nothing.
    """
    source = THEME.read_text(encoding="utf-8")
    start = source.index("enum CizgiSubject")
    end = source.index("\n}\n", start)
    body = source[start:end]
    at = body.index(f"var {name}:")
    nxt = body.find("\n    var ", at + 1)
    nxt = nxt if nxt != -1 else body.find("\n    static func", at + 1)
    return body[at:nxt if nxt != -1 else len(body)]


def test_every_canonical_subject_has_a_stop_on_the_arc() -> None:
    names = set(re.findall(r'return "([^"]+)"', arc_block("displayName")))
    missing = set(canonical_subjects()) - names
    assert not missing, (
        "Bu dersler renk yayında yok, vurguları saate düşer ve dağılım "
        f"şeridinden sessizce kaybolurlar: {sorted(missing)}"
    )


def test_the_arc_invents_no_subject_the_schema_does_not_have() -> None:
    names = set(re.findall(r'return "([^"]+)"', arc_block("displayName")))
    extra = names - set(canonical_subjects())
    assert not extra, (
        "Yayda şemada olmayan ders adı var; `CizgiSubject.matching` onu hiçbir "
        f"karta bağlayamaz: {sorted(extra)}"
    )


def test_every_case_has_a_colour() -> None:
    """A case without a `dyn(...)` line cannot happen — Swift's switch is
    exhaustive — but a case sharing another's colour silently collapses two
    dersler into one stop, which the eye reads as "these are the same subject".
    """
    colours = re.findall(r"return dyn\((\([^)]*\), \([^)]*\))\)", arc_block("color"))
    cases = re.findall(r"case \.(\w+):", arc_block("color"))
    assert len(colours) == len(cases), "her ders bir dyn(...) satırı taşımalı"
    assert len(set(colours)) == len(colours), "iki ders aynı rengi paylaşıyor"


def test_case_order_matches_display_order() -> None:
    """`SubjectDistributionBar` and the Görünüm preview both iterate
    `allCases`, so enum order *is* the on-screen order of the arc. Keeping the
    two switches in the same order is what makes that order reviewable here.
    """
    assert re.findall(r"case \.(\w+):", arc_block("displayName")) == \
        re.findall(r"case \.(\w+):", arc_block("color"))
