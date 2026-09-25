"""Reading-ordered lines → one block of lines per question (§5.3/3).

A question starts at its printed number, but a printed number is not always
a question: "I. … II. …" premises, "5. vertebra", a lab value wrapped onto a
new line, the numbered instructions on a cover page, a key grid. Two
constraints separate them:

- **position** — a question number hangs in the column's left margin, left
  of where its text starts; a number that merely begins a wrapped line sits
  at the text edge;
- **sequence** — the next question number is the expected one. A gap is
  bridged only when the numbers after it confirm the run (a single number
  the extractor could not see must not stop the paper).

A paper starts at the first "1." (or its offset) whose block holds option
labels — the cover's "1. Bu sınavda her adaya…" has none.
"""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence

from . import clean
from .columns import Line, Page, Word, column_lines, page_gutters, visible

NUMBER = re.compile(r"^(\d{1,3})\.(.*)$")
SORU = re.compile(r"^Soru\s+(\d{1,3})$")
LABEL = re.compile(r"^([A-E])\)(.*)$")

TEXT, NOISE, STOP, KEY, ANSWER, REVISED = "text", "noise", "stop", "key", "answer", "revised"


@dataclass
class StreamLine:
    line: Line
    kind: str

    @property
    def text(self) -> str:
        return self.line.text


@dataclass
class Stream:
    lines: List[StreamLine]
    pages: Dict[int, Page]
    text_left: Dict[int, float]            # column → x where its text starts
    gutters: Dict[int, Optional[float]]    # page → x between the columns


@dataclass(frozen=True)
class Marker:
    index: int
    number: int
    digits: str = ""  # as printed, leading zeros kept ("08" is not "8")
    weak: bool = False  # at the text edge rather than hanging in the margin


@dataclass
class Block:
    number: int
    lines: List[Line]
    marker_line: Optional[Line] = None
    answer_marks: List[str] = field(default_factory=list)  # "DOĞRU CEVAP: X" seen inside the slot
    stopped: bool = False  # the block ran into a stop line (end of test, key, rules)
    revised: bool = False  # the compiler notes it changed the question
    shared: List[Line] = field(default_factory=list)  # a case set out for several questions (clean.GROUP_HEAD)


def classify(line: Line, page: Page) -> str:
    text = line.text.strip()
    if clean.is_stop(text):
        return STOP
    if clean.is_key_line(text):
        return KEY
    if clean.OSYM_ANSWER.search(text):
        return ANSWER
    if clean.is_revision_note(text):
        return REVISED
    if clean.is_noise(text) or clean.is_page_number(line, page.height):
        return NOISE
    return TEXT


def build_stream(pages: Iterable[Page]) -> Stream:
    pages = [visible(p) for p in pages]
    gutters = page_gutters(pages)
    out: List[StreamLine] = []
    by_number: Dict[int, Page] = {}
    for page in pages:
        by_number[page.number] = page
        lines, wide = column_lines(page, gutters[page.number])
        first_top = min((l.top for l in lines), default=page.height)
        head = [l for l in wide if l.top < first_top]
        tail = [l for l in wide if l.top >= first_top]
        for group, items in ((0, head), (1, lines), (2, tail)):
            for line in items:
                kind = classify(line, page)
                if group != 1 and kind == TEXT:
                    kind = NOISE  # set across both columns: a head, a title, instructions
                out.append(StreamLine(line, kind))
    _mark_running_heads(out, by_number)
    return Stream(lines=out, pages=by_number, text_left=_text_left(out), gutters=gutters)


def _mark_running_heads(lines: List[StreamLine], pages: Dict[int, Page]) -> None:
    """A line in the top or bottom band that recurs on many pages is a running
    head or foot ("TUS KTBT/NİSAN 2008", "2019-TUS 1. Dönem/TTBT") — whatever
    its wording, which the NOISE list cannot know in advance for every year.
    Digits are ignored so page numbers do not make each copy unique."""
    def band(sl: StreamLine) -> bool:
        h = pages[sl.line.page].height
        if NUMBER.match(sl.line.words[0].text) or SORU.match(sl.text.strip()):
            return False  # a question that starts at the top of every page is not a head ("Soru 12")
        return sl.line.top < 0.13 * h or sl.line.bottom > 0.88 * h

    def norm(text: str) -> str:
        return re.sub(r"\s+", " ", re.sub(r"\d+", "#", text)).strip()

    seen: Dict[str, set] = {}
    for sl in lines:
        if sl.kind == TEXT and band(sl):
            seen.setdefault(norm(sl.text), set()).add(sl.line.page)
    threshold = max(3, 0.25 * len(pages))
    for sl in lines:
        if sl.kind == TEXT and band(sl) and len(seen[norm(sl.text)]) >= threshold:
            sl.kind = NOISE


def _text_left(lines: Sequence[StreamLine]) -> Dict[int, float]:
    """Per column, the x most lines start at — where question text begins.
    Numbers hang to its left."""
    result: Dict[int, float] = {}
    for column in (0, 1):
        xs = Counter(round(sl.line.x0) for sl in lines
                     if sl.kind == TEXT and sl.line.column == column and not NUMBER.match(sl.line.words[0].text))
        if xs:
            result[column] = float(xs.most_common(1)[0][0])
    return result


def markers(stream: Stream, style: str = "number") -> List[Marker]:
    found: List[Marker] = []
    for i, sl in enumerate(stream.lines):
        if sl.kind != TEXT:
            continue
        if style == "soru":
            m = SORU.match(sl.text.strip())
            if m:
                found.append(Marker(i, int(m.group(1)), m.group(1)))
            continue
        m = NUMBER.match(sl.line.words[0].text)
        if not m:
            continue
        number, rest = int(m.group(1)), m.group(2)
        if not 1 <= number <= 200 or rest[:1].isdigit():
            continue  # "0.8 mg/dL", "11.5 g/dL" wrapped to the start of a line
        left = stream.text_left.get(sl.line.column)
        weak = left is not None and sl.line.x0 > left - 3
        if weak and (sl.line.x0 > left + 3 or not rest and len(sl.line.words) < 2):
            continue  # indented further than text, or a bare number: not a question start
        found.append(Marker(i, number, m.group(1), weak))
    return found


def has_options(stream: Stream, start: int, end: int) -> bool:
    labels = set()
    for sl in stream.lines[start:end]:
        if sl.kind == TEXT:
            for w in sl.line.words:
                m = LABEL.match(w.text)
                if m:
                    labels.add(m.group(1))
    return len(labels) >= 3


@dataclass
class Run:
    accepted: List[Marker]
    missing: List[int]                                        # numbers never found
    misprinted: Dict[int, int] = field(default_factory=dict)  # number → what the booklet printed


def chain(stream: Stream, found: Sequence[Marker], first: int, last: int, start_at: int = 0,
          sparse: bool = False) -> Run:
    """The run first…last, in stream order, from `start_at` on.

    Besides the plain case, three printing faults seen in the folder are
    taken, each only where the numbers around it vouch for it, and each
    recorded in `misprinted` rather than hidden:

    - a number printed twice, the first standing for one less (2013/2 Klinik
      prints "9." for question 8, then "9." again);
    - a number whose leading digit the text layer lost ("08." for 108, "1."
      for 71 in the compilation) — `_truncated`;
    - a number set at the text edge instead of hanging (a weak marker).

    A gap of up to three numbers is bridged when the two numbers after it
    follow on; the skipped numbers are reported missing (V1)."""
    candidates = [m for m in found if m.index >= start_at]

    def block_end(pos: int, number: int) -> int:
        for m in candidates[pos + 1:]:
            if m.number == number + 1:
                return m.index
        return min(len(stream.lines), candidates[pos].index + 80)

    start_pos = None
    for pos, m in enumerate(candidates):
        if m.weak:
            continue
        if m.number == first and (sparse or has_options(stream, m.index, block_end(pos, m.number))):
            start_pos = pos
            break
    if start_pos is None:
        return Run([], list(range(first, last + 1)))

    run = Run([candidates[start_pos]], [])
    accepted, missing = run.accepted, run.missing
    expected = first + 1
    rest = candidates[start_pos + 1:]
    for pos, m in enumerate(rest):
        if expected > last:
            break
        if m.weak:
            # A number at the text edge is usually a wrapped line ("6.
            # omurilik segmentinde"). Once in the compilation it is a real
            # question start typeset without the hang (2025/1 Klinik 104). It
            # is taken only when it is the expected number and the next
            # hanging number is the one after it — so the real, hanging
            # question number cannot be further on.
            if m.number == expected and _first_strong_after(rest[pos + 1:], expected) == expected + 1:
                accepted.append(m)
                expected += 1
            continue
        if m.number == expected:
            accepted.append(m)
            expected += 1
        elif m.number == expected + 1 and _next_strong(rest[pos + 1:]) == m.number:
            accepted.append(Marker(m.index, expected, m.digits))
            run.misprinted[expected] = m.number
            expected += 1
        elif _truncated(m, expected) and _next_is(rest[pos + 1:], expected + 1, last):
            accepted.append(Marker(m.index, expected, m.digits))
            run.misprinted[expected] = m.number
            expected += 1
        elif expected < m.number <= min(last, expected + 3):
            ahead = [n.number for n in rest[pos + 1:pos + 10] if not n.weak and n.number > m.number][:2]
            confirmed = ahead == [m.number + 1, m.number + 2][:len(ahead)] and (
                len(ahead) == 2 or m.number >= last - 1)
            if confirmed:
                missing.extend(range(expected, m.number))
                accepted.append(m)
                expected = m.number + 1
    missing.extend(range(expected, last + 1))
    return run


def _next_strong(rest: Sequence[Marker]) -> Optional[int]:
    return next((m.number for m in rest if not m.weak), None)


def _first_strong_after(rest: Sequence[Marker], at_least: int) -> Optional[int]:
    for m in rest:
        if not m.weak and m.number >= at_least:
            return m.number
    return None


def _truncated(m: Marker, expected: int) -> bool:
    """The compilation loses the first digit of some numbers in its text
    layer — "08." for 108, "80." for 180, "1." for 71 — and prints the rest a
    digit's width to the right. A marker whose digits are a proper suffix of
    the expected number is that number."""
    want = str(expected)
    return bool(m.digits) and len(m.digits) < len(want) and want.endswith(m.digits)


def _next_is(rest: Sequence[Marker], number: int, last: int) -> bool:
    """The run carries on right after: the next marker that could continue it
    is `number` (or the paper ends here)."""
    if number > last:
        return True
    strong = [m for m in rest if not m.weak][:6]
    return any(m.number == number or _truncated(m, number) for m in strong)


def _strip_marker(line: Line, style: str) -> Optional[Line]:
    if style == "soru":
        return None  # "Soru 7" stands on a line of its own
    first = line.words[0]
    rest = NUMBER.match(first.text).group(2)
    words = list(line.words[1:])
    if rest:
        words.insert(0, Word(rest, first.x0, first.x1, first.top, first.bottom, first.size))
    return Line(line.page, line.column, words) if words else None


def blocks(stream: Stream, accepted: Sequence[Marker], end_index: int, style: str = "number") -> List[Block]:
    """One block per accepted marker: its lines up to the next accepted marker
    (the last one up to `end_index`), cut at the first stop line. A shared
    case ("40.-41. SORULARI …") is lifted out of the block it follows and
    handed to every question it names."""
    out: List[Block] = []
    shared: Dict[int, List[Line]] = {}
    bounds = [m.index for m in accepted] + [end_index]
    for m, stop_at in zip(accepted, bounds[1:]):
        block = Block(number=m.number, lines=[], marker_line=stream.lines[m.index].line)
        first = _strip_marker(stream.lines[m.index].line, style)
        if first is not None:
            block.lines.append(first)
        group: Optional[List[Line]] = None
        for sl in stream.lines[m.index + 1:stop_at]:
            if sl.kind == STOP:
                block.stopped = True
                break
            if sl.kind == ANSWER:
                block.answer_marks.append(clean.OSYM_ANSWER.search(sl.text).group(1))
            elif sl.kind == REVISED:
                block.revised = True
            elif sl.kind == TEXT:
                head = clean.GROUP_HEAD.match(sl.text.strip())
                if head:
                    group = []
                    for n in range(int(head.group(1)), int(head.group(2)) + 1):
                        shared[n] = group
                elif group is not None:
                    if not clean.GROUP_HEAD_TAIL.match(sl.text.strip()):
                        group.append(sl.line)
                else:
                    block.lines.append(sl.line)
        out.append(block)
    for block in out:
        block.shared = shared.get(block.number, [])
    return out
