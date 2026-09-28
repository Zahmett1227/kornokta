"""The one module that opens a PDF: pdfplumber pages → `columns.Page`.

Kept apart so the rest of A1 runs on plain word boxes; tests never need a
PDF (and no booklet page is ever a fixture — §5.13).
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterator, List, Optional

from .columns import Box, Page, Word

# ÖSYM's 2006–2011 booklets tile a watermark out of thousands of tiny images
# (5×6 pt). They are not figures; a real figure is never this small.
MIN_FIGURE_SIDE = 12.0

# pdfplumber's default (3 pt) merges words in booklets that set no space
# glyph and justify with ~2.5 pt gaps (2013/2: "Otuzsekizyaşındakikadınhasta",
# 2011/2: "tabanındayer"). Glyphs inside a word sit within 0.1 pt of each
# other. Measured on one page of every readable file: 1.5 pt splits those
# words; 1.0 pt splits nothing more except a slash from its operand
# ("HCO3/CI" → "HCO3 / CI"). What 1.5 separates that 3 did not — a Greek
# letter from its hyphen ("β" "-hücresi") — `columns.join_words` rejoins.
X_TOLERANCE = 1.5


def _fake_spaces(chars) -> set:
    """Spaces that overlap the glyph before them.

    The Tusdata compilation sets "fi"/"fl" as ligatures and follows each with
    a space glyph that starts *inside* the ligature ("Nervus fi bularis").
    A real space starts where the previous glyph ends; these start ~2 pt
    earlier. Dropping them rejoins the word without guessing at spelling
    ("hipertrofi ve" keeps its real space)."""
    fake = set()
    prev = None
    for c in chars:
        if c["text"] == " " and prev is not None and prev["text"] != " " \
                and abs(c["top"] - prev["top"]) < 1 and c["x0"] < prev["x1"] - 0.5:
            fake.add((round(c["x0"], 2), round(c["top"], 2)))
        prev = c
    return fake


def drop_watermark(words: List[Word]) -> List[Word]:
    """2013–2017 booklets print "Ö S Y M" across each page as ~250 pt
    letters. As words they are harmless; as *boxes* each one is taller than
    twenty lines and swallows every line it overlaps into one. Nothing a
    question says is set at three times the body size."""
    if not words:
        return words
    sizes = sorted(w.size for w in words)
    median = sizes[len(sizes) // 2]
    limit = max(30.0, 3 * median)
    return [w for w in words if w.size <= limit]


def _gutter_hint(page) -> Optional[float]:
    """F3/F4 booklets print a vertical rule between the columns."""
    for line in page.lines:
        if abs(line["x0"] - line["x1"]) < 1 and (line["bottom"] - line["top"]) > 0.4 * page.height \
                and 0.35 * page.width < line["x0"] < 0.65 * page.width:
            return float(line["x0"])
    return None


def read_page(page, number: int) -> Page:
    # Some running heads are printed twice, a hair apart, to look bold
    # ("2013-TUS2013-TUS SonbaharSonbahar"); drop the overprinted copy.
    page = page.dedupe_chars(tolerance=1)
    # 2026/1 sets a watermark sentence diagonally, glyph by glyph, at body
    # size — too small for the size filter, but every glyph is rotated 45°.
    # Question text is never rotated; a rotated axis label belongs to a
    # figure, which is cropped from the page, not read.
    page = page.filter(lambda o: o.get("object_type") != "char"
                       or (abs(o["matrix"][1]) < 0.01 and abs(o["matrix"][2]) < 0.01))
    fake = _fake_spaces(page.chars)
    if fake:
        page = page.filter(lambda o: not (o.get("object_type") == "char" and o.get("text") == " "
                                          and (round(o["x0"], 2), round(o["top"], 2)) in fake))
    words = [
        Word(text=w["text"], x0=float(w["x0"]), x1=float(w["x1"]), top=float(w["top"]),
             bottom=float(w["bottom"]), size=float(w.get("size") or 9.0))
        for w in page.extract_words(x_tolerance=X_TOLERANCE, extra_attrs=["size"], use_text_flow=False)
    ]
    words = drop_watermark(words)
    graphics: List[Box] = []
    for img in page.images:
        w, h = float(img["x1"]) - float(img["x0"]), float(img["bottom"]) - float(img["top"])
        if w < MIN_FIGURE_SIDE or h < MIN_FIGURE_SIDE:
            continue
        sig = ("image", tuple(img.get("srcsize") or ()), round(w), round(h))
        graphics.append(Box(float(img["x0"]), float(img["x1"]), float(img["top"]), float(img["bottom"]), "image",
                            sig, img.get("tag") == "Artifact"))
    for kind, objs in (("curve", page.curves), ("rect", page.rects), ("line", page.lines)):
        for o in objs:
            box = (float(o["x0"]), float(o["x1"]), float(o["top"]), float(o["bottom"]))
            graphics.append(Box(*box, kind, (kind,) + tuple(round(v) for v in box), o.get("tag") == "Artifact"))
    return Page(number=number, width=float(page.width), height=float(page.height), words=words,
                gutter_hint=_gutter_hint(page), graphics=graphics)


def read_pages(path: Path) -> Iterator[Page]:
    import logging

    import pdfplumber  # imported here: the rest of the pipeline and its tests do not need it

    # pdfminer warns once per unparseable colour operator in some booklets
    # ("Cannot set gray non-stroke color …") — hundreds of lines, no bearing
    # on text or positions.
    logging.getLogger("pdfminer").setLevel(logging.ERROR)

    with pdfplumber.open(str(path)) as pdf:
        for i, page in enumerate(pdf.pages, start=1):
            yield read_page(page, i)
            page.flush_cache()
