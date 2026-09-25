"""Synthetic word boxes for the extraction tests.

No booklet page is ever a fixture (§5.13): these helpers set short invented
lines on an A4-sized page with the geometry the families actually use —
columns split near x = 297, question numbers hanging ~12 pt left of the text,
9 pt type on a ~10 pt pitch.
"""
from typing import List

from tools.exam_bank.extract.columns import Page, Word

CHAR = 4.5   # average glyph width at 9 pt
SPACE = 2.5

LEFT_NUM, LEFT_TEXT = 49.0, 61.0
RIGHT_NUM, RIGHT_TEXT = 322.0, 334.0
WIDTH, HEIGHT = 595.0, 842.0


def row(text: str, x: float, top: float, size: float = 9.0, char: float = CHAR, space: float = SPACE) -> List[Word]:
    """One visual row: `text` split on spaces into word boxes from `x`."""
    out = []
    for token in text.split(" "):
        if not token:
            x += space
            continue
        w = len(token) * char * size / 9.0
        out.append(Word(token, x, x + w, top, top + size, size))
        x += w + space
    return out


def page(number: int, *rows: List[Word], gutter: float = None, width: float = WIDTH, height: float = HEIGHT) -> Page:
    words: List[Word] = []
    for r in rows:
        words.extend(r)
    return Page(number=number, width=width, height=height, words=words, gutter_hint=gutter)


def question(number: int, top: float, stem: List[str], options: List[str], column: int = 0,
             pitch: float = 10.0) -> List[List[Word]]:
    """A question as the booklets set it: the number hanging in the margin,
    stem lines at the text edge, one option per line."""
    num_x, text_x = (LEFT_NUM, LEFT_TEXT) if column == 0 else (RIGHT_NUM, RIGHT_TEXT)
    rows: List[List[Word]] = []
    y = top
    first = row(f"{number}.", num_x, y) + row(stem[0], text_x, y)
    rows.append(first)
    for text in stem[1:]:
        y += pitch
        rows.append(row(text, text_x, y))
    y += pitch * 1.8
    for letter, text in zip("ABCDE", options):
        rows.append(row(f"{letter}) {text}", text_x, y))
        y += pitch * 1.6
    return rows


def bottom_of(rows: List[List[Word]]) -> float:
    return max(w.bottom for r in rows for w in r)
