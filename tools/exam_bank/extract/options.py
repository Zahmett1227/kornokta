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

    options = []
    for letter in LETTERS:
        by_line: Dict[int, List[Word]] = {}
        for li, w in parts[letter]:
            by_line.setdefault(li, []).append(w)
        opt_lines = [Line(lines[li].page, lines[li].column, ws) for li, ws in sorted(by_line.items())]
        options.append(clean.assemble(opt_lines, pitch=0))
    stem = clean.assemble(stem_lines)

    problems = []
    if not stem:
        problems.append("kök boş")
    for letter, text in zip(LETTERS, options):
        if not text:
            problems.append(f"{letter} şıkkı boş")
    return Parsed(stem=stem, options=options, problems=problems)


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
