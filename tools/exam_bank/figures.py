"""A4 — does a question need its picture? (docs/PLAN-cikmis-soru-bankasi.md §5.6)

    none       text is the whole question
    reference  the text points at a figure ("yukarıdaki grafikte …") but no
               figure object sits in the question's box — usually a table
               set as text, whose layout the extracted text flattens
    required   a figure is printed inside the question's box (EKG, radiograph,
               graph, formula, a table drawn with rules), or the options or
               stem are themselves pictures (A1 found labels but no text)

The phone shows the PDF crop for `required` (and offers it for `reference`);
the crop is the question's `provenance` box, which A1 already stretches down
over a figure that has no text below it.

What is *not* a figure is the hard part. Every family decorates its pages:
ÖSYM's 2009–2012 watermark is a set of letter images, the compilation tiles
coloured banners, bold words are underlined with short rules. Two tests
remove them without a list of known decorations: tagged PDFs mark them as
/Artifact, and anything that recurs identically on three or more pages is
page furniture, not a question's figure.
"""
from __future__ import annotations

import re
from collections import defaultdict
from typing import Dict, Iterable, List, Sequence, Set, Tuple

from .extract.columns import Box, Page

KEYWORDS = re.compile(
    r"(yukarıdaki|aşağıdaki|verilen|şekildeki|görüntüdeki)\s+(şekil|görüntü|grafik|tablo|resim|"
    r"elektrokardiyogra\w*|EKG|film|radyografi|mikrograf|kesit|fotoğraf|görsel|formül)"
    r"|\b(şekilde|görüntüde|resimde|grafikte|tabloda|mikrografta|radyografide|fotoğrafta|görselde|"
    r"şekildeki|grafikteki|tablodaki)\b",
    re.IGNORECASE)

MIN_IMAGE_AREA = 400.0   # pt² — a 20×20 pt thumbnail; smaller is a bullet or an icon
MIN_VECTORS = 6          # a drawn graph, formula or ruled table; fewer are underlines and boxes
REPEATS = 3              # on this many pages → page furniture


def furniture(pages: Iterable[Page]) -> Set[tuple]:
    """Signatures of graphics that recur on ≥ REPEATS pages of one file."""
    seen: Dict[tuple, Set[int]] = defaultdict(set)
    for page in pages:
        for g in page.graphics:
            if g.sig:
                seen[g.sig].add(page.number)
    return {sig for sig, where in seen.items() if len(where) >= REPEATS}


def _is_figure_part(g: Box, page: Page, box: Tuple[float, float, float, float], decor: Set[tuple]) -> bool:
    x0, top, x1, bottom = box
    if g.artifact or g.sig in decor:
        return False
    if g.width * g.height > 0.5 * page.width * page.height:
        return False  # a full-page background
    if g.width > (x1 - x0) + 10:
        return False  # set across the page: a header or footer rule
    if g.width < 1.5 and g.height > 0.4 * page.height:
        return False  # the column rule
    if g.kind == "line" and g.height < 1.5 and g.width < 150:
        return False  # an underline under a bold word ("en olası")
    cx, cy = (g.x0 + g.x1) / 2, (g.top + g.bottom) / 2
    return x0 <= cx <= x1 and top <= cy <= bottom


def evidence(regions: Sequence[dict], pages: Dict[int, Page], decor: Set[tuple]) -> Tuple[int, int]:
    """(images, vector objects) inside the question's boxes."""
    images = vectors = 0
    for r in regions:
        page = pages.get(r["page"])
        if page is None:
            continue
        box = tuple(r["bbox"])
        for g in page.graphics:
            if not _is_figure_part(g, page, box, decor):
                continue
            if g.kind == "image":
                images += g.width * g.height >= MIN_IMAGE_AREA
            else:
                vectors += 1
    return images, vectors


def classify(stem: str, problems: Sequence[str], images: int, vectors: int) -> str:
    if images or vectors >= MIN_VECTORS or problems:
        return "required"
    if KEYWORDS.search(stem):
        return "reference"
    return "none"


def annotate(questions: List[dict], load_pages) -> Dict[str, int]:
    """Sets `figure` on every question from its primary provenance.
    `load_pages(file)` returns that file's pages. Returns counts by class."""
    by_file: Dict[str, List[dict]] = defaultdict(list)
    for q in questions:
        if q["provenance"]:
            by_file[q["provenance"][0]["file"]].append(q)
    counts: Dict[str, int] = defaultdict(int)
    for file, qs in by_file.items():
        pages = {p.number: p for p in load_pages(file)}
        decor = furniture(pages.values())
        for q in qs:
            regions = [r for r in q["provenance"] if r["file"] == file]
            images, vectors = evidence(regions, pages, decor)
            q["figure"] = classify(q["stem"], q["problems"], images, vectors)
            q["figureEvidence"] = {"images": images, "vectors": vectors}
            counts[q["figure"]] += 1
    for q in questions:
        q.setdefault("figure", "none")
    return dict(counts)
