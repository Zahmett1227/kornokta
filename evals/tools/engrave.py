"""Turn public-domain medical engravings into faint, theme-tinted line art.

Used once (2026-09-14) to produce the subject figures behind Tekrar and
Egzersiz questions (`ios/App/Assets.xcassets/Figures`). Kept in the repo so the
figures can be regenerated or replaced without guessing how they were made;
the raw downloads are not committed — their sources and licences are listed in
`docs/FIGURES-SOURCES.md`.

What it does to each image, in order:

1. Crops to the subject (per-figure boxes below: page headers, figure labels
   outside the drawing, neighbouring sub-figures on a botanical plate).
2. Greyscale, then normalises the paper: the brightest few percent become pure
   white, so a yellowed 1819 page and a clean Gray's scan end up on the same
   ground instead of one of them printing as a tinted rectangle.
3. Ink → alpha: dark lines become opaque, paper becomes transparent. A gamma
   above 1 thins the mid-tones, which keeps filled areas (a coloured leaf, a
   shaded bone) from turning into solid blots once tinted.
4. Trims the transparent margin and saves an 8-bit grey+alpha PNG.

The app renders these as template images in the ink colour at a few percent
opacity, so the black here never appears as black.

    .venv/bin/python evals/tools/engrave.py RAW_DIR OUT_DIR
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageOps

# name: (file, crop box as fractions (left, top, right, bottom), gamma)
FIGURES: dict[str, tuple[str, tuple[float, float, float, float], float]] = {
    "anatomi": ("anatomi.png", (0.0, 0.0, 1.0, 1.0), 1.4),
    "fizyoloji": ("fizyoloji.png", (0.0, 0.0, 1.0, 1.0), 1.6),
    "biyokimya": ("biyokimya.png", (0.0, 0.0, 1.0, 1.0), 1.4),
    # The whole plant; its numbered detail figures are masked out below.
    "farmakoloji": ("farmakoloji.jpg", (0.07, 0.0, 1.0, 0.975), 1.9),
    # The left margin carries bleed-through text from the facing page.
    "mikrobiyoloji": ("mikrobiyoloji.jpg", (0.10, 0.0, 1.0, 1.0), 1.3),
    "patoloji": ("patoloji.png", (0.0, 0.0, 1.0, 1.0), 1.2),
    # Drops the page gutter running down the left edge of the scan.
    "dahiliye": ("dahiliye.jpg", (0.065, 0.0, 1.0, 1.0), 1.5),
    # Drops the "ARMAMENTARII CHIRURGICI, TABULA VII" running head.
    "cerrahi": ("cerrahi.jpg", (0.0, 0.07, 1.0, 1.0), 1.3),
    "kadindogum": ("kadindogum.png", (0.0, 0.0, 1.0, 1.0), 1.3),
    # Drops the "Frontal fontanel" / "Occipital fontanel" captions.
    "pediatri": ("pediatri.png", (0.0, 0.10, 1.0, 0.915), 1.5),
    "kucukstajlar": ("kucukstajlar.png", (0.0, 0.0, 1.0, 1.0), 1.4),
}

# Areas painted out as paper before anything else, as fractions of the original
# (left, top, right, bottom). Köhler's plate surrounds the plant with numbered
# detail drawings (stamens, seed sections, a cut flower) that sit *inside* the
# plant's bounding box, so no rectangular crop can drop them.
MASKS: dict[str, list[tuple[float, float, float, float]]] = {
    "farmakoloji": [
        (0.00, 0.02, 0.08, 0.18),   # 7
        (0.27, 0.01, 0.45, 0.16),   # 2
        (0.31, 0.15, 0.44, 0.29),   # 2 (lower part)
        (0.50, 0.02, 0.59, 0.09),   # 5
        (0.56, 0.00, 1.00, 0.14),   # 1
        (0.63, 0.14, 0.86, 0.28),   # 3
        (0.90, 0.12, 1.00, 0.37),   # 4
        (0.00, 0.29, 0.14, 0.65),   # 6
        (0.00, 0.64, 0.19, 0.93),   # 8
        (0.22, 0.79, 0.34, 0.89),   # 9
        (0.79, 0.65, 0.99, 0.815),  # 10
        (0.70, 0.81, 1.00, 0.98),   # 11–13 and the signature
    ],
}

PAPER_PERCENTILE = 0.93
# Drawn at about 60% of a phone's width at a few percent opacity: 900 px is
# already past the screen's own resolution there, and anything larger is bytes
# nobody can see.
MAX_LONG_EDGE = 900
# Alpha steps kept. At the opacity the app uses, 32 are indistinguishable from
# 256 and the PNG is several times smaller.
ALPHA_LEVELS = 32


def percentile(image: Image.Image, fraction: float) -> int:
    histogram = image.histogram()
    target = fraction * sum(histogram)
    running = 0
    for value, count in enumerate(histogram):
        running += count
        if running >= target:
            return value
    return 255


def engrave(
    source: Path,
    box: tuple[float, float, float, float],
    gamma: float,
    masks: list[tuple[float, float, float, float]] | None = None,
) -> Image.Image:
    image = Image.open(source).convert("L")
    w, h = image.size
    if masks:
        from PIL import ImageDraw
        paper_before = percentile(image, PAPER_PERCENTILE)
        draw = ImageDraw.Draw(image)
        for left, top, right, bottom in masks:
            draw.rectangle((left * w, top * h, right * w, bottom * h), fill=paper_before)
    image = image.crop((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)))

    paper = max(1, percentile(image, PAPER_PERCENTILE))
    ink = percentile(image, 0.01)
    span = max(1, paper - ink)

    def to_alpha(value: int) -> int:
        darkness = (paper - value) / span          # 0 at paper, 1 at darkest ink
        darkness = min(1.0, max(0.0, darkness))
        return round(255 * darkness ** gamma)

    alpha = image.point(to_alpha)
    bbox = alpha.point(lambda a: 255 if a > 8 else 0).getbbox()
    if bbox:
        alpha = alpha.crop(bbox)
    if max(alpha.size) > MAX_LONG_EDGE:
        alpha.thumbnail((MAX_LONG_EDGE, MAX_LONG_EDGE), Image.LANCZOS)

    step = 256 // ALPHA_LEVELS
    alpha = alpha.point(lambda a: min(255, (a // step) * step + (step // 2 if a >= step else 0)))

    out = Image.new("LA", alpha.size, 0)
    out.putalpha(alpha)
    return out


def main(raw_dir: str, out_dir: str) -> None:
    raw, out = Path(raw_dir), Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, (file, box, gamma) in FIGURES.items():
        figure = engrave(raw / file, box, gamma, MASKS.get(name))
        target = out / f"{name}.png"
        figure.save(target, optimize=True)
        print(f"{name:14s} {figure.size[0]}x{figure.size[1]}  {target.stat().st_size // 1024} KB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
