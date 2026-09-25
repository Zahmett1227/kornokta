"""A question block → stem and five options (§5.3/4).

The booklets lay options out three ways: one per line; two or three to a
line ("A) Rifampin B) Etambutol C) Sikloserin"); and labels first with the
texts underneath. One rule covers all three: every word after the first
label belongs to the nearest label **to its left and above** — the lowest
label line at or above the word, and on it the rightmost label not to the
word's right. It is a coordinate rule, not a reading-order rule, which is
why the third layout does not come out as "A) B) textA textB".
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

from . import clean
from .columns import Line, Word
from .segment import LABEL

LETTERS = "ABCDE"


@dataclass
class Parsed:
    stem: str
    options: Optional[List[str]]  # five texts, A–E; None when the labels were not all found
    problems: List[str] = field(default_factory=list)


@dataclass(frozen=True)
class _Pos:
    line: int  # index into the block's lines
    word: int


def _labels(lines: Sequence[Line]) -> Dict[str, _Pos]:
    """The last complete A…E run, read backwards from the last E), so an
    "A)" quoted in the stem is not taken for the first option."""
    found: List[Tuple[str, _Pos]] = []
    for li, line in enumerate(lines):
        for wi, w in enumerate(line.words):
            m = LABEL.match(w.text)
            if m:
                found.append((m.group(1), _Pos(li, wi)))
    picked: Dict[str, _Pos] = {}
    want = 4
    for letter, pos in reversed(found):
        if want < 0:
            break
        if letter == LETTERS[want]:
            picked[letter] = pos
            want -= 1
    return picked if len(picked) == 5 else {}


def parse(lines: Sequence[Line]) -> Parsed:
    labels = _labels(lines)
    if not labels:
        return Parsed(stem=clean.assemble(lines), options=None, problems=["şıklar bulunamadı"])

    a = labels["A"]
    stem_lines: List[Line] = list(lines[:a.line])
    head = lines[a.line].words[:a.word]
    if head:  # text before "A)" on its line still belongs to the stem
        stem_lines.append(Line(lines[a.line].page, lines[a.line].column, list(head)))

    # label word → (line index, x0, segment)
    label_at = {letter: (pos.line, lines[pos.line].words[pos.word].x0, lines[pos.line].segment)
                for letter, pos in labels.items()}
    parts: Dict[str, List[Tuple[int, Word]]] = {letter: [] for letter in LETTERS}
    current = "A"
    for li in range(a.line, len(lines)):
        line = lines[li]
        for wi, w in enumerate(line.words):
            if li == a.line and wi < a.word:
                continue
            m = LABEL.match(w.text)
            if m and label_at.get(m.group(1), (None,))[0] == li and \
                    abs(label_at[m.group(1)][1] - w.x0) < 0.01:
                current = m.group(1)
                if m.group(2):
                    parts[current].append((li, Word(m.group(2), w.x0, w.x1, w.top, w.bottom, w.size)))
                continue
            owner = _owner(li, w, line.segment, label_at) or current
            parts[owner].append((li, w))

    per_option: List[List[Line]] = []
    for letter in LETTERS:
        by_line: Dict[int, List[Word]] = {}
        for li, w in parts[letter]:
            by_line.setdefault(li, []).append(w)
        per_option.append([Line(lines[li].page, lines[li].column, ws) for li, ws in sorted(by_line.items())])
    columns = table_columns(per_option)
    options = [cells_text(opt_lines, columns) for opt_lines in per_option]
    stem = clean.assemble(stem_lines)

    problems = []
    if not stem:
        problems.append("kök boş")
    for letter, text in zip(LETTERS, options):
        if not text:
            problems.append(f"{letter} şıkkı boş")
    if any(clean.unreadable(t) for t in [stem] + options):
        problems.append("okunamayan glif")
    # A fraction set as numerator over a rule over denominator, with the
    # factor beside it (2018/1 Klinik 38: "… bebek sayısı / … doğum sayısı
    # × 1000"): read in lines it loses the bar, whichever order the lines
    # come in. The crop shows it; A5 writes it as a fraction.
    if any(len(per_option[i]) > 1 and FRACTION_FACTOR.search(options[i]) for i in range(5)):
        problems.append("kesirli şık")
    seen = {}
    for letter, text in zip(LETTERS, options):
        key = same_option(text)
        if key and key in seen:
            problems.append(f"{seen[key]} ve {letter} şıkkı aynı")
        seen.setdefault(key, letter)
    return Parsed(stem=stem, options=options, problems=problems)


def same_option(text: str) -> str:
    """What makes two options the same, for V2: case and spacing, nothing
    else. Signs are the whole difference between "HBsAg (+)" and "HBsAg (−)",
    so unlike text matching (merge.fold) they are kept."""
    return " ".join(text.casefold().split())


FRACTION_FACTOR = re.compile(r"(?:^|\s)[x×]\s*10{2,}\b")

# Wider than a word space (~2.5 pt), and a justified line can stretch one
# space past it — so a column is only a gap that recurs, at the same x, in
# several options of the question. Measured: the narrowest real column gap
# (2014/2 Klinik 56, "INH profilaksisi | INH-RIF-PZA") is ~10 pt.
CELL_GAP = 8.0
SAME_COLUMN = 4.0
MIN_ROWS = 3
_WORDY = re.compile(r"[^\W\d_]{2,}")


def table_columns(per_option: Sequence[Sequence[Line]]) -> List[float]:
    """x where a table column starts, in a question whose options are rows:
    the start of a word after a wide gap, or of a line indented well past
    the option's text, found at the same place in at least three options."""
    found: List[float] = []
    for opt_lines in per_option:
        if not opt_lines:
            continue
        left = min(w.x0 for w in opt_lines[0].words)
        for line in opt_lines:
            words = sorted(line.words, key=lambda w: w.x0)
            found.extend(b.x0 for a, b in zip(words, words[1:]) if b.x0 - a.x1 >= CELL_GAP)
            # A cell centred beside a two-line neighbour is a line of its own
            # that starts in its column ("– Sefotaksim", 2017/2 Klinik 2).
            if words[0].x0 > left + CELL_GAP:
                found.append(words[0].x0)
    columns: List[float] = []
    for x in sorted(found):
        support = sum(1 for y in found if abs(y - x) <= SAME_COLUMN)
        if support >= MIN_ROWS and not any(abs(c - x) <= SAME_COLUMN for c in columns):
            columns.append(x)
    return columns


def cells_text(opt_lines: Sequence[Line], columns: Sequence[float] = ()) -> str:
    """An option's text, read cell by cell when it is a wrapped table row.

    Pair questions set each option as a row of columns — "Herpes virus |
    Kanser tipi" — and a cell that wraps puts its tail on the next line
    under its own column ("Herpes simpleks / virusu"). Read line by line, the
    tail lands after the neighbouring cell ("Herpes simpleks Orofarengeal
    karsinom virusu", 2010/1 Temel 52, found in the owner's V9 review).

    Only a *wrapped* row is regrouped: a continuation line that leaves some
    column empty. An option whose every line fills every column is a stack
    of rows ("Anne : Azitromisin / Çocuk 1 : …") and reads line by line.
    Cells of words are joined with " – ", the separator the booklets' own
    pair options use; cells of signs ("Normal − + −") keep a space."""
    if not opt_lines:
        return ""
    first_x = min(w.x0 for w in opt_lines[0].words)
    starts = [first_x] + [c for c in columns if c > first_x + CELL_GAP / 2]
    if len(starts) == 1:
        return clean.assemble(opt_lines, pitch=0)

    def column_of(w: Word) -> int:
        return max((i for i, x in enumerate(starts) if x <= w.x0 + 2), default=0)

    rows = [{column_of(w) for w in line.words} for line in opt_lines]
    wrapped = len(opt_lines) > 1 and any(len(r) < len(starts) for r in rows[1:])
    cells: List[List[Line]] = [[] for _ in starts]
    for line in opt_lines:
        buckets: Dict[int, List[Word]] = {}
        for w in line.words:
            buckets.setdefault(column_of(w), []).append(w)
        for index, ws in buckets.items():
            cells[index].append(Line(line.page, line.column, ws))
    if len(opt_lines) > 1 and not wrapped:
        return clean.assemble(opt_lines, pitch=0)
    texts = [clean.assemble(c, pitch=0) for c in cells if c]
    out = texts[0]
    for prev, text in zip(texts, texts[1:]):
        out += (" – " if _WORDY.search(prev) and _WORDY.search(text) else " ") + text
    return out


def _owner(li: int, w: Word, segment, label_at) -> Optional[str]:
    """Nearest label left of and at-or-above the word, in the same column
    segment. None when the word's segment has no such label (an option that
    ran on into the next column) — the caller then keeps the current one."""
    best = None
    for letter, (l_line, l_x0, l_seg) in label_at.items():
        if l_seg != segment or l_line > li or l_x0 > w.x0 + 1:
            continue
        key = (l_line, l_x0)
        if best is None or key > best[0]:
            best = (key, letter)
    return best[1] if best else None
