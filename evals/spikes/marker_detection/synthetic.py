"""Generate synthetic book-page images with known marked lines.

Lets the marker-detection spike run and be tested deterministically before the
real (copyrighted) gold fixtures exist. NOT a substitute for the gold set — it
only exercises the pipeline's plumbing and obvious success cases.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageDraw

from .detector import LineBox

# BGR, to match OpenCV's channel order used throughout detector.py.
_WHITE = (255, 255, 255)
_BLACK = (10, 10, 10)
_HIGHLIGHT_BGR = {
    "yellow": (60, 240, 250),
    "green": (90, 230, 120),
    "pink": (200, 120, 240),
    "blue": (240, 200, 120),
}


@dataclass
class SyntheticPage:
    image_bgr: np.ndarray
    lines: list[LineBox]
    marked_line_ids: list[str]


def make_page(
    n_lines: int = 8,
    marked: dict[int, str] | None = None,
    width: int = 700,
    margin: int = 40,
    line_height: int = 34,
    line_gap: int = 18,
) -> SyntheticPage:
    """Render a page of text lines. `marked` maps line index -> mark spec:
    "highlight:yellow", "underline:pen", "underline:pencil"."""
    marked = marked or {}
    height = margin * 2 + n_lines * (line_height + line_gap)
    img = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(img)

    lines: list[LineBox] = []
    marked_ids: list[str] = []
    for i in range(n_lines):
        top = margin + i * (line_height + line_gap)
        box = LineBox(f"line_{i:02d}", margin, top, width - 2 * margin, line_height)
        spec = marked.get(i)

        if spec and spec.startswith("highlight"):
            color = spec.split(":", 1)[1] if ":" in spec else "yellow"
            rgb = _HIGHLIGHT_BGR[color][::-1]  # PIL expects RGB
            draw.rectangle([box.x, box.y, box.x2, box.y2], fill=rgb)

        # Text as dark blocks (glyph shapes are irrelevant to detection here).
        _draw_text_blocks(draw, box)

        if spec and spec.startswith("underline"):
            pen = spec.split(":", 1)[1] if ":" in spec else "pen"
            gray = 30 if pen == "pen" else 110  # pencil is lighter
            thickness = 4 if pen == "pen" else 2
            uy = box.y2 + 3
            draw.line([(box.x, uy), (box.x2 - 10, uy)], fill=(gray, gray, gray), width=thickness)

        lines.append(box)
        if spec:
            marked_ids.append(box.line_id)

    rgb_arr = np.array(img)
    bgr = rgb_arr[..., ::-1].copy()
    return SyntheticPage(bgr, lines, marked_ids)


def _draw_text_blocks(draw: ImageDraw.ImageDraw, box: LineBox) -> None:
    """Approximate words as short dark rectangles along the line."""
    x = box.x + 4
    word_w, gap = 46, 14
    text_top = box.y + 8
    text_bottom = box.y2 - 8
    while x + word_w < box.x2:
        draw.rectangle([x, text_top, x + word_w, text_bottom], fill=(20, 20, 20))
        x += word_w + gap


def draw_table_rule(page: SyntheticPage, below_line_index: int, thickness: int = 3) -> None:
    """Draw a full-width horizontal rule below a line, as a table/page rule.

    Geometrically this is a thin dark stripe just like a pen underline; the only
    difference is that it spans the whole page rather than stopping at the text.
    """
    line = page.lines[below_line_index]
    top = line.y2 + 3
    page.image_bgr[top: top + thickness, :] = 20


def save_png(page: SyntheticPage, path: str) -> None:
    rgb = page.image_bgr[..., ::-1]
    Image.fromarray(rgb).save(path)
