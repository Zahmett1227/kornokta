"""Underline / highlighter detection spike (ANA-PLAN §9).

Faz 0 risk-reduction: proves the marked-line detection approach on synthetic
pages before the 100-image gold set exists, and provides a reference the future
Swift/Core Image implementation can be checked against.

Design choices from §9.2:
- Highlighter: HSV saturation + hue range, overlap with the OCR line box.
- Underline: dark, roughly-horizontal components in a band just below the text,
  found via pixel/morphology analysis — NOT Hough lines alone.
- selectionConfidence combines five weighted components (§9.3); all weights and
  thresholds live in config.json, never hardcoded (§0.6).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

import numpy as np

try:  # OpenCV preferred; the pipeline degrades gracefully without it.
    import cv2

    _HAS_CV2 = True
except Exception:  # pragma: no cover - environment dependent
    _HAS_CV2 = False

CONFIG_PATH = Path(__file__).with_name("config.json")


def load_config(path: Path | str = CONFIG_PATH) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


@dataclass(frozen=True)
class LineBox:
    """An OCR text line in pixel coordinates (top-left origin)."""

    line_id: str
    x: int
    y: int
    width: int
    height: int
    ocr_confidence: float = 0.9

    @property
    def x2(self) -> int:
        return self.x + self.width

    @property
    def y2(self) -> int:
        return self.y + self.height


@dataclass
class LineDetection:
    line_id: str
    marker_overlap: float
    line_geometry: float
    local_ocr_confidence: float
    document_quality: float
    neighboring_separation: float
    selection_confidence: float
    selection_type: str  # "highlight" | "underline" | "none"
    decision: str  # "auto_candidate" | "quick_confirm" | "user_selection"
    detail: dict = field(default_factory=dict)


def _to_hsv(image_bgr: np.ndarray) -> np.ndarray:
    if _HAS_CV2:
        return cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    return _bgr_to_hsv_numpy(image_bgr)


def _bgr_to_hsv_numpy(image_bgr: np.ndarray) -> np.ndarray:
    """OpenCV-compatible HSV (H:0-179, S:0-255, V:0-255) without OpenCV."""
    bgr = image_bgr.astype(np.float32) / 255.0
    b, g, r = bgr[..., 0], bgr[..., 1], bgr[..., 2]
    v = np.max(bgr, axis=-1)
    minc = np.min(bgr, axis=-1)
    delta = v - minc
    s = np.where(v > 0, delta / np.where(v == 0, 1, v), 0)
    h = np.zeros_like(v)
    mask = delta > 1e-6
    rc = np.where(mask, (v - r) / np.where(delta == 0, 1, delta), 0)
    gc = np.where(mask, (v - g) / np.where(delta == 0, 1, delta), 0)
    bc = np.where(mask, (v - b) / np.where(delta == 0, 1, delta), 0)
    h = np.where(v == r, bc - gc, h)
    h = np.where(v == g, 2.0 + rc - bc, h)
    h = np.where(v == b, 4.0 + gc - rc, h)
    h = (h / 6.0) % 1.0
    h = np.where(mask, h, 0)
    return np.stack([h * 179.0, s * 255.0, v * 255.0], axis=-1).astype(np.uint8)


def _highlight_mask(hsv_roi: np.ndarray, cfg: dict) -> np.ndarray:
    h, s, v = hsv_roi[..., 0], hsv_roi[..., 1], hsv_roi[..., 2]
    sat_val = (s >= cfg["minSaturation"]) & (v >= cfg["minValue"])
    hue_ok = np.zeros(h.shape, dtype=bool)
    for ranges in cfg["colorHueRangesHSV"].values():
        for lo, hi in ranges:
            hue_ok |= (h >= lo) & (h <= hi)
    return sat_val & hue_ok


def _region(image: np.ndarray, x: int, y: int, w: int, h: int) -> np.ndarray:
    H, W = image.shape[:2]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    return image[y0:y1, x0:x1]


def detect_highlight_overlap(image_bgr: np.ndarray, line: LineBox, cfg: dict) -> float:
    """Fraction of the line box covered by highlighter-colored pixels."""
    roi = _region(image_bgr, line.x, line.y, line.width, line.height)
    if roi.size == 0:
        return 0.0
    hsv = _to_hsv(roi)
    mask = _highlight_mask(hsv, cfg["highlight"])
    return float(mask.mean())


def detect_underline(image_bgr: np.ndarray, line: LineBox, cfg: dict) -> tuple[float, float]:
    """Detect a dark horizontal mark in the band below the text baseline.

    Returns (dark_pixel_ratio, horizontal_extent_ratio) for the band.
    """
    ucfg = cfg["underline"]
    band_h = max(3, int(round(line.height * ucfg["bandHeightRatio"])))
    # Band hugs the baseline: a small overlap above (for underlines touching
    # descenders) plus band_h below, where underlines actually sit. Keeping it
    # tight avoids diluting the dark-pixel ratio for thin pencil strokes.
    band_top = line.y2 - 2
    band = _region(image_bgr, line.x, band_top, line.width, band_h + 2)
    if band.size == 0:
        return 0.0, 0.0

    gray = band.mean(axis=-1)
    threshold = max(80.0, gray.mean() - 2.0 * gray.std())
    dark = gray < threshold
    dark_ratio = float(dark.mean())

    # Horizontal extent: fraction of columns that contain a dark pixel — a real
    # underline spans most of the line, stray specks do not.
    columns_with_dark = dark.any(axis=0)
    extent_ratio = float(columns_with_dark.mean()) if columns_with_dark.size else 0.0
    return dark_ratio, extent_ratio


def _neighboring_separation(line: LineBox, others: Sequence[LineBox]) -> float:
    """1.0 when the line is well separated vertically from its neighbors,
    lower when a neighbor is close enough to be confused with it (§9.3)."""
    if not others:
        return 1.0
    gaps = []
    for other in others:
        if other.line_id == line.line_id:
            continue
        if other.y >= line.y2:  # below
            gaps.append(other.y - line.y2)
        elif other.y2 <= line.y:  # above
            gaps.append(line.y - other.y2)
    if not gaps:
        return 1.0
    min_gap = max(0, min(gaps))
    # Normalize against line height: a gap >= one line height is fully separated.
    return float(min(1.0, min_gap / max(1, line.height)))


def analyze_line(
    image_bgr: np.ndarray,
    line: LineBox,
    all_lines: Sequence[LineBox],
    document_quality: float,
    cfg: dict,
) -> LineDetection:
    highlight_overlap = detect_highlight_overlap(image_bgr, line, cfg)
    dark_ratio, extent_ratio = detect_underline(image_bgr, line, cfg)

    ucfg = cfg["underline"]
    is_underline = (
        dark_ratio >= ucfg["minDarkPixelRatio"]
        and extent_ratio >= ucfg["minHorizontalExtentRatio"]
    )
    is_highlight = highlight_overlap >= cfg["highlight"]["minOverlapRatio"]

    if is_highlight and highlight_overlap >= dark_ratio:
        selection_type = "highlight"
        marker_overlap = min(1.0, highlight_overlap)
        line_geometry = min(1.0, highlight_overlap * 1.5)
    elif is_underline:
        selection_type = "underline"
        # A saturated underline covers only a thin band, so scale the dark ratio
        # up to a comparable 0-1 range before weighting.
        marker_overlap = min(1.0, dark_ratio * 3.0)
        line_geometry = extent_ratio
    else:
        selection_type = "none"
        marker_overlap = max(highlight_overlap, dark_ratio)
        line_geometry = extent_ratio if extent_ratio else highlight_overlap

    separation = _neighboring_separation(line, all_lines)
    weights = cfg["confidenceWeights"]
    confidence = (
        weights["markerOverlap"] * marker_overlap
        + weights["lineGeometry"] * line_geometry
        + weights["localOCRConfidence"] * line.ocr_confidence
        + weights["documentQuality"] * document_quality
        + weights["neighboringLineSeparation"] * separation
    )

    thresholds = cfg["decisionThresholds"]
    if selection_type == "none":
        decision = "user_selection"
    elif confidence >= thresholds["autoCandidate"]:
        decision = "auto_candidate"
    elif confidence >= thresholds["quickConfirm"]:
        decision = "quick_confirm"
    else:
        decision = "user_selection"

    return LineDetection(
        line_id=line.line_id,
        marker_overlap=marker_overlap,
        line_geometry=line_geometry,
        local_ocr_confidence=line.ocr_confidence,
        document_quality=document_quality,
        neighboring_separation=separation,
        selection_confidence=round(confidence, 4),
        selection_type=selection_type,
        decision=decision,
        detail={
            "highlight_overlap": round(highlight_overlap, 4),
            "underline_dark_ratio": round(dark_ratio, 4),
            "underline_extent_ratio": round(extent_ratio, 4),
        },
    )


def analyze_page(
    image_bgr: np.ndarray,
    lines: Sequence[LineBox],
    document_quality: float = 0.9,
    cfg: dict | None = None,
) -> list[LineDetection]:
    cfg = cfg or load_config()
    return [analyze_line(image_bgr, line, lines, document_quality, cfg) for line in lines]


def group_selected_passage(detections: Sequence[LineDetection]) -> list[str]:
    """Consecutive selected lines form one passage (§9.2 adım 7)."""
    return [
        d.line_id
        for d in detections
        if d.selection_type != "none" and d.decision != "user_selection"
    ]
