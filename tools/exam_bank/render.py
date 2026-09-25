"""Page and crop images for the model stages and for V8 (pypdfium2, which
pdfplumber already depends on).

Boxes are pdfplumber's (points, origin top-left). pdfium crops by the
distance to trim from each edge of the page, origin bottom-left — the same
conversion the phone makes (§6: y_pdfkit = pageHeight − bottom). That only
holds for a page whose box starts at the origin and is not rotated;
`check_geometry` refuses anything else rather than cropping the wrong place.
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterable, List, Sequence, Tuple


def _document(path: Path):
    import pypdfium2 as pdfium  # optional at import time, like pdfplumber

    return pdfium.PdfDocument(str(path))


def check_geometry(path: Path, pages: Iterable[int]) -> List[str]:
    """Pages (1-based) whose crop box is offset or rotated."""
    doc = _document(path)
    problems = []
    for n in pages:
        page = doc[n - 1]
        left, bottom, _, _ = page.get_cropbox()
        if abs(left) > 0.5 or abs(bottom) > 0.5 or page.get_rotation() % 360:
            problems.append(f"{path.name} s.{n}: kırpma kutusu kaydırılmış ya da sayfa döndürülmüş")
    return problems


def crop(path: Path, page_number: int, bbox: Sequence[float], dpi: int = 150):
    """PIL image of `bbox` on the page."""
    doc = _document(path)
    page = doc[page_number - 1]
    width, height = page.get_size()
    x0, top, x1, bottom = bbox
    trim = (max(0.0, x0), max(0.0, height - bottom), max(0.0, width - x1), max(0.0, top))
    return page.render(scale=dpi / 72, crop=trim).to_pil()


def page_image(path: Path, page_number: int, dpi: int = 200):
    doc = _document(path)
    return doc[page_number - 1].render(scale=dpi / 72).to_pil()


def ink_share(image) -> float:
    """Share of pixels that are not near-white — V8's "the crop is not
    empty" (§5.11: ≥ 2 %)."""
    gray = image.convert("L")
    hist = gray.histogram()
    dark = sum(hist[:230])
    return dark / max(1, sum(hist))


def stacked(images: Sequence) -> "object":
    """Several crops of one question (it ran across a column or page) as one
    image, top to bottom, the way it reads."""
    from PIL import Image

    width = max(im.width for im in images)
    out = Image.new("RGB", (width, sum(im.height for im in images)), "white")
    y = 0
    for im in images:
        out.paste(im, (0, y))
        y += im.height
    return out


def save_question_crop(source_dir: Path, provenance: Sequence[dict], dest: Path, dpi: int = 150) -> Tuple[int, int]:
    """Renders a question's provenance boxes into one PNG. Returns its size."""
    parts = [crop(source_dir / r["file"], r["page"], r["bbox"], dpi) for r in provenance]
    image = parts[0] if len(parts) == 1 else stacked(parts)
    dest.parent.mkdir(parents=True, exist_ok=True)
    image.save(dest)
    return image.size
