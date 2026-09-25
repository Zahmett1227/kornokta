"""One source file → its papers' questions (A1 end to end, per file).

A file may carry several papers (F2: Temel then Klinik, each from 1; F5:
four exams numbered 1–200 straight through). They are taken in registry
order, each starting after the previous one ended.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

from .. import registry as reg
from . import clean, options, segment
from .columns import Box, Line, Page
from .families import Family


@dataclass(frozen=True)
class Region:
    """Where a question is printed: page (1-based) and a box in points,
    origin top-left (pdfplumber). One per column/page the question spans."""
    page: int
    x0: float
    top: float
    x1: float
    bottom: float

    def as_list(self) -> List[float]:
        return [round(self.x0, 1), round(self.top, 1), round(self.x1, 1), round(self.bottom, 1)]


@dataclass
class Extracted:
    paper_id: str
    number: int                     # within the paper, 1…N
    printed: int                    # as printed (F5 Klinik: 101…200; a misprint stays visible here)
    stem: str
    options: Optional[List[str]]
    regions: List[Region]
    problems: List[str] = field(default_factory=list)
    answer_marks: List[str] = field(default_factory=list)
    empty: bool = False             # an empty slot (F4 shows ~10% of the paper)
    cancelled: bool = False         # "Bu soru iptal edilmiştir."
    revised: bool = False           # the compilation notes it changed the question


@dataclass
class PaperResult:
    paper: reg.Paper
    questions: List[Extracted]
    missing: List[int]              # numbers (within the paper) never found


def extract_source(source: reg.Source, family: Family, pages: Sequence[Page]) -> List[PaperResult]:
    stream = segment.build_stream(pages)
    found = segment.markers(stream, family.marker)
    results: List[PaperResult] = []
    pos = 0
    runs: List[Tuple[reg.Paper, segment.Run]] = []
    for paper in source.papers:
        first, last = paper.number_offset + 1, paper.number_offset + paper.expected
        run = segment.chain(stream, found, first, last, start_at=pos, sparse=family.sparse)
        runs.append((paper, run))
        if run.accepted:
            pos = run.accepted[-1].index + 1

    for i, (paper, run) in enumerate(runs):
        nxt = next((r.accepted[0].index for _, r in runs[i + 1:] if r.accepted), len(stream.lines))
        blocks = segment.blocks(stream, run.accepted, nxt, family.marker)
        regions = _regions(blocks, stream)
        questions = []
        for block, regs in zip(blocks, regions):
            q = Extracted(paper_id=paper.id, number=block.number - paper.number_offset,
                          printed=run.misprinted.get(block.number, block.number),
                          stem="", options=None, regions=regs, answer_marks=block.answer_marks,
                          revised=block.revised)
            if block.shared:
                # The shared case reads first, as in the booklet, and is part of
                # where the question is printed.
                regs = _regions([segment.Block(block.number, list(block.shared))], stream)[0] + regs
                q.regions = regs
            text = " ".join(l.text for l in block.lines).strip()
            if not text:
                q.empty = True
            elif clean.CANCELLED.search(text):
                q.cancelled = True
                q.stem = clean.assemble(block.lines)
            else:
                parsed = options.parse(block.lines)
                q.stem, q.options, q.problems = parsed.stem, parsed.options, parsed.problems
                if block.shared:
                    q.stem = clean.assemble(block.shared) + "\n" + q.stem
            questions.append(q)
        results.append(PaperResult(paper=paper, questions=questions,
                                   missing=[n - paper.number_offset for n in run.missing]))
    return results


def _regions(blocks: Sequence[segment.Block], stream: segment.Stream) -> List[List[Region]]:
    """A box per column segment: the column's width, from the number's top to
    where the next question starts in that column — or, when the question is
    the last one there, to the lowest text or graphic above the footer. The
    box is what the phone crops for a figure (A4) and highlights for "Kaynağı
    göster", so it must take in a figure that has no text below it."""
    spans: List[Dict[Tuple[int, int], List[float]]] = []
    for block in blocks:
        segs: Dict[Tuple[int, int], List[float]] = {}
        lines = ([block.marker_line] if block.marker_line is not None else []) + list(block.lines)
        for line in lines:
            s = segs.setdefault(line.segment, [line.top, line.bottom])
            s[0], s[1] = min(s[0], line.top), max(s[1], line.bottom)
        spans.append(segs)

    starts: Dict[Tuple[int, int], List[float]] = {}
    for segs in spans:
        for seg, (top, _) in segs.items():
            starts.setdefault(seg, []).append(top)

    out: List[List[Region]] = []
    for segs in spans:
        regs = []
        for (page_no, column), (top, bottom) in segs.items():
            page = stream.pages[page_no]
            x0, x1 = _column_x(page, column, stream)
            later = [t for t in starts[(page_no, column)] if t > top + 1]
            limit = min(later) - 2 if later else _body_bottom(page, stream)
            for g in page.graphics:
                if g.width > (x1 - x0) + 10 or g.width < 1 and g.height > 0.4 * page.height:
                    continue  # set across the page, or the column rule itself
                cx = (g.x0 + g.x1) / 2
                if x0 <= cx <= x1 and g.top >= top - 2 and g.bottom <= limit:
                    bottom = max(bottom, g.bottom)
            regs.append(Region(page_no, x0, max(0.0, top - 3), x1, min(page.height, bottom + 3)))
        out.append(regs)
    return out


def _column_x(page: Page, column: int, stream: segment.Stream) -> Tuple[float, float]:
    gutter = stream.gutters.get(page.number)
    if gutter is None:
        return 20.0, page.width - 20.0
    xs = [sl.line for sl in stream.lines if sl.line.page == page.number and sl.line.column == column]
    if column == 0:
        return max(0.0, min((l.x0 for l in xs), default=30.0) - 4), gutter - 2
    return gutter + 2, min(page.width, max((l.x1 for l in xs), default=page.width - 30) + 4)


def _body_bottom(page: Page, stream: segment.Stream) -> float:
    """Top of the footer: the page number / "Diğer sayfaya geçiniz." line."""
    footer = [sl.line.top for sl in stream.lines
              if sl.line.page == page.number and sl.kind == segment.NOISE and sl.line.top > 0.8 * page.height]
    return min(footer) - 2 if footer else page.height - 40
