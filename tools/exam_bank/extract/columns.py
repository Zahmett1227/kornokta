"""Word boxes → reading-ordered lines, one column at a time.

Every booklet in the owner's folder is set in two columns. Plain text
extraction reads straight across the page and interleaves them ("1. 2. Elli
dokuz yaşındaki…" — question 2's first line glued to question 1's number),
which is why this stage exists at all (§5.3/2).

Coordinates are pdfplumber's: points, origin top-left.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple


@dataclass(frozen=True)
class Word:
    text: str
    x0: float
    x1: float
    top: float
    bottom: float
    size: float = 9.0

    @property
    def middle(self) -> float:
        return (self.top + self.bottom) / 2


@dataclass(frozen=True)
class Box:
    """A non-text object on the page (image, curve, rectangle) — what a figure
    is made of (A4)."""
    x0: float
    x1: float
    top: float
    bottom: float
    kind: str = "image"
    sig: tuple = ()          # what makes two copies the same object (A4 repetition test)
    artifact: bool = False   # tagged PDFs mark watermarks and page furniture as /Artifact

    @property
    def width(self) -> float:
        return self.x1 - self.x0

    @property
    def height(self) -> float:
        return self.bottom - self.top


@dataclass
class Page:
    number: int  # 1-based, as a reader counts
    width: float
    height: float
    words: List[Word]
    gutter_hint: Optional[float] = None  # x of a printed column rule, when there is one
    graphics: List[Box] = field(default_factory=list)


@dataclass
class Line:
    page: int
    column: int  # 0 left, 1 right (a single-column page puts everything in 0)
    words: List[Word]

    @property
    def top(self) -> float:
        return min(w.top for w in self.words)

    @property
    def bottom(self) -> float:
        return max(w.bottom for w in self.words)

    @property
    def x0(self) -> float:
        return min(w.x0 for w in self.words)

    @property
    def x1(self) -> float:
        return max(w.x1 for w in self.words)

    @property
    def text(self) -> str:
        return join_words(self.words)

    @property
    def segment(self) -> Tuple[int, int]:
        return (self.page, self.column)


# A narrow gap next to these is a font change inside one word ("β" "-hücresi",
# "Ca" "2+"), not a space.
_CLINGS_RIGHT = tuple("-,.;:)’'/")
_CLINGS_LEFT = tuple("-(/")


def visible(page: Page) -> Page:
    """The page as printed: words and objects whose centre lies on it.

    2011/1 is cut from printed spreads and keeps the neighbouring page's text
    outside its own box (x < 0, x > width). A reader never sees it; left in,
    it lands in a column and joins that column's lines."""
    def on(x0: float, x1: float, top: float, bottom: float) -> bool:
        cx, cy = (x0 + x1) / 2, (top + bottom) / 2
        return 0 <= cx <= page.width and 0 <= cy <= page.height

    words = [w for w in page.words if on(w.x0, w.x1, w.top, w.bottom)]
    graphics = [g for g in page.graphics if on(g.x0, g.x1, g.top, g.bottom)]
    if len(words) == len(page.words) and len(graphics) == len(page.graphics):
        return page
    return Page(page.number, page.width, page.height, words, page.gutter_hint, graphics)


def join_words(words: Sequence[Word]) -> str:
    """Words left to right, a space between them — except where two boxes
    touch. The extractor only splits at a space or a real gap, so touching
    boxes are a subscript or superscript that `group_lines` folded back into
    its line ("H" "1" "-reseptör" → "H1-reseptör"), and a narrow gap before
    a hyphen or after a slash is a font change, not a space.""" 
    ordered = sorted(words, key=lambda w: w.x0)
    tracked = _tracking(ordered)
    out = ""
    prev: Optional[Word] = None
    for w in ordered:
        if prev is not None:
            gap = w.x0 - prev.x1
            if tracked is not None:
                tight = gap < tracked
            else:
                # Touching boxes join only when one is set smaller or off the
                # baseline — a sub/superscript. Same size, same baseline and
                # still two words means a space glyph split them: in the
                # compilation letters overlap the space before them, so a real
                # word gap can measure 0.5 pt ("Travma" "sonrası").
                script = abs(w.bottom - prev.bottom) > 1.0 or abs(w.size - prev.size) > 0.5
                tight = (gap < 1.0 and script) or (
                    gap < 3.0 and (w.text.startswith(_CLINGS_RIGHT) or prev.text.endswith(_CLINGS_LEFT)))
            out += "" if tight else " "
        out += w.text
        prev = w
    return out


def _tracking(ordered: Sequence[Word]) -> Optional[float]:
    """A letter-spaced line ("A ş a ğ ı d a k i  i n f l a m a s y o n") comes
    out one word per letter. When most of a line is single letters, the gaps
    fall into two sizes — between letters and between words — and the
    threshold between them is returned; None for an ordinary line."""
    if len(ordered) < 8 or sum(len(w.text) == 1 for w in ordered) < 0.6 * len(ordered):
        return None
    gaps = sorted(b.x0 - a.x1 for a, b in zip(ordered, ordered[1:]))
    letter = gaps[len(gaps) // 4]
    return max(letter * 1.6, letter + 1.0)


def group_lines(words: Sequence[Word], page: int = 0, column: int = 0) -> List[Line]:
    """Words → lines by vertical overlap.

    A word joins the current line when its middle falls inside the line's
    band. A second pass merges lines whose bands overlap substantially: a
    superscript sits higher than its line, sorts first, and would otherwise
    open a line of its own."""
    lines: List[List[Word]] = []
    band: Tuple[float, float] = (0.0, 0.0)
    for w in sorted(words, key=lambda w: (w.top, w.x0)):
        if lines and band[0] - 0.5 <= w.middle <= band[1] + 0.5:
            lines[-1].append(w)
            band = (min(band[0], w.top), max(band[1], w.bottom))
        else:
            lines.append([w])
            band = (w.top, w.bottom)

    merged: List[List[Word]] = []
    for ws in lines:
        if merged:
            prev = merged[-1]
            p_top, p_bot = min(w.top for w in prev), max(w.bottom for w in prev)
            c_top, c_bot = min(w.top for w in ws), max(w.bottom for w in ws)
            overlap = min(p_bot, c_bot) - max(p_top, c_top)
            shorter = min(p_bot - p_top, c_bot - c_top)
            # A sub/superscript is set smaller and may sit well off its line
            # (40 % overlap is enough). Two runs of the same size must share
            # most of their height: a table cell centred beside a two-line
            # neighbour ("Neisseria / meningitidis" | "– Sefotaksim") overlaps
            # each of its lines by ~40 %, and at that threshold all three
            # rows chained into one (2017/2 Klinik 2).
            # "Smaller" is any real difference: 2007/1 sets its superscripts
            # at 7.9 pt beside 9 pt text (Na⁺/HCO₃⁻) and raises them ~4 pt.
            smaller = min(w.size for w in ws) < 0.95 * max(w.size for w in prev) or \
                min(w.size for w in prev) < 0.95 * max(w.size for w in ws)
            if shorter > 0 and overlap >= (0.4 if smaller else 0.5) * shorter:
                prev.extend(ws)
                continue
        merged.append(list(ws))
    return [Line(page=page, column=column, words=sorted(ws, key=lambda w: w.x0)) for ws in merged]


def rows(words: Sequence[Word], tolerance: float = 2.5) -> List[List[Word]]:
    """Words on one visual row, by top alone — no band chaining. (Chaining
    would let a left-column line and a slightly lower right-column line pull
    each other, and then the whole column, into one "row".)"""
    out: List[List[Word]] = []
    for w in sorted(words, key=lambda w: w.top):
        if out and w.top - out[-1][0].top < tolerance:
            out[-1].append(w)
        else:
            out.append([w])
    return out


def _largest_gap(words: Sequence[Word], a: float, b: float) -> float:
    spans = sorted((max(a, w.x0), min(b, w.x1)) for w in words if w.x1 > a and w.x0 < b)
    if not spans:
        return b - a
    gap, reach = spans[0][0] - a, spans[0][1]
    for s, e in spans[1:]:
        gap = max(gap, s - reach)
        reach = max(reach, e)
    return max(gap, b - reach)


def full_width(words: Sequence[Word], width: float) -> List[Word]:
    """Words of rows set across both columns: running heads, the test title,
    the cover's instructions, the rules page.

    A two-column row always leaves the gutter open — at least ~8 pt between
    where the left text stops and the right column's number starts. A row
    whose words close every gap wider than 6 pt across the middle tenth of the
    page is one piece of text. Measured on every page of all 81 readable
    files: this picks out only titles, copyright notes, instructions and rules
    — never a question line."""
    a, b = 0.45 * width, 0.55 * width
    out: List[Word] = []
    for row in rows(words):
        if min(w.x0 for w in row) < a and max(w.x1 for w in row) > b and _largest_gap(row, a, b) < 6:
            out.extend(row)
    return out


def find_gutter(words: Sequence[Word], width: float) -> Optional[float]:
    """The x between the two columns.

    Coverage is counted over the words of column rows only (full-width rows
    cross everything). Zero-coverage runs appear in two places on a page: the
    real gutter, and the gap between a right-column question number and its
    indented text (e.g. 304 vs 323 pt) — as clean as the gutter and often
    wider. The real one is the run nearest the middle of the page."""
    wide = {id(w) for w in full_width(words, width)}
    body = [w for w in words if id(w) not in wide]
    if not body:
        return None
    lo, hi = int(width * 0.40), int(width * 0.60)
    coverage = [sum(1 for w in body if w.x0 < x < w.x1) for x in range(lo, hi + 1)]
    best = min(coverage)
    if best > max(2, 0.3 * len(rows(body))):
        return None  # most rows cross the middle: not a two-column page
    runs: List[Tuple[int, int]] = []
    start = None
    for i, c in enumerate(coverage + [best + 1]):
        if c == best and start is None:
            start = i
        elif c != best and start is not None:
            runs.append((start, i - 1))
            start = None
    centre = width / 2 - lo
    s, e = min(runs, key=lambda r: (abs((r[0] + r[1]) / 2 - centre), -(r[1] - r[0])))
    return lo + (s + e) / 2


def page_gutters(pages: Sequence[Page]) -> Dict[int, Optional[float]]:
    """One gutter per page, steadied by the document: a book keeps its
    columns, so a page whose own estimate is missing or strays from the
    document's median by more than 12 pt (a cover, a key grid, a page of
    mostly figure) takes the median."""
    own = {p.number: (p.gutter_hint if p.gutter_hint is not None else find_gutter(p.words, p.width))
           for p in pages}
    found = sorted(g for g in own.values() if g is not None)
    if not found:
        return own
    median = found[len(found) // 2]
    return {n: (g if g is not None and abs(g - median) <= 12 else median) for n, g in own.items()}


def column_lines(page: Page, gutter: Optional[float] = None) -> Tuple[List[Line], List[Line]]:
    """(column lines in reading order, full-width lines).

    Full-width rows are set aside first; every other word goes to the column
    its centre falls in."""
    if gutter is None:
        gutter = page.gutter_hint if page.gutter_hint is not None else find_gutter(page.words, page.width)
    if gutter is None:
        return group_lines(page.words, page.number, 0), []
    wide = full_width(page.words, page.width)
    wide_ids = {id(w) for w in wide}
    rest = [w for w in page.words if id(w) not in wide_ids]
    left = [w for w in rest if (w.x0 + w.x1) / 2 < gutter]
    right = [w for w in rest if (w.x0 + w.x1) / 2 >= gutter]
    lines = group_lines(left, page.number, 0) + group_lines(right, page.number, 1)
    return lines, group_lines(wide, page.number, 0)
