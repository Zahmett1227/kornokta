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
    """Crop, clamped to the image. Returns an empty array when the requested
    rectangle lies wholly outside it — clamping alone is not enough, because a
    negative upper bound would be read as an offset from the far edge and slice
    a large unrelated region.
    """
    H, W = image.shape[:2]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return image[0:0, 0:0]
    return image[y0:y1, x0:x1]


def detect_highlight_overlap(image_bgr: np.ndarray, line: LineBox, cfg: dict) -> float:
    """Fraction of the line box covered by highlighter-colored pixels."""
    roi = _region(image_bgr, line.x, line.y, line.width, line.height)
    if roi.size == 0:
        return 0.0
    hsv = _to_hsv(roi)
    mask = _highlight_mask(hsv, cfg["highlight"])
    return float(mask.mean())


@dataclass(frozen=True)
class UnderlineEvidence:
    dark_ratio: float
    extent_ratio: float
    thickness_ratio: float
    overrun_ratio: float
    #: False when no margin beside the line was visible (line touches the image
    #: edge / cropped page). Then overrun_ratio carries no information and must
    #: be read as "unknown", never as "no overrun".
    overrun_observed: bool = True


def _dark_mask(region: np.ndarray) -> np.ndarray:
    gray = region.mean(axis=-1)
    threshold = max(80.0, gray.mean() - 2.0 * gray.std())
    return gray < threshold


def detect_underline(image_bgr: np.ndarray, line: LineBox, cfg: dict) -> UnderlineEvidence:
    """Measure evidence for a dark horizontal mark below the text baseline."""
    ucfg = cfg["underline"]
    band_h = max(3, int(round(line.height * ucfg["bandHeightRatio"])))
    # Band hugs the baseline: a small overlap above (for underlines touching
    # descenders) plus band_h below, where underlines actually sit. Keeping it
    # tight avoids diluting the dark-pixel ratio for thin pencil strokes.
    band_top = line.y2 - 2
    band_height = band_h + 2
    band = _region(image_bgr, line.x, band_top, line.width, band_height)
    if band.size == 0:
        return UnderlineEvidence(0.0, 0.0, 0.0, 0.0, overrun_observed=False)

    dark = _dark_mask(band)
    dark_ratio = float(dark.mean())

    # Horizontal extent: fraction of columns that contain a dark pixel — a real
    # underline spans most of the line, stray specks do not.
    columns_with_dark = dark.any(axis=0)
    extent_ratio = float(columns_with_dark.mean()) if columns_with_dark.size else 0.0

    # Thickness: how many consecutive rows form the wide dark stripe. An
    # underline is thin; a shadow or filled graphic is thick.
    wide_rows = dark.mean(axis=1) >= ucfg["minHorizontalExtentRatio"]
    thickness_ratio = _longest_run(wide_rows) / max(1, line.height)

    # Overrun: does the mark continue past the ends of the text line? A ruled
    # table border or page rule runs the full column width regardless of where
    # the text stops; a pen underline starts and ends at the text. Thickness
    # alone cannot separate a 3px table rule from a 3px pen stroke — this can.
    overrun_ratio, overrun_observed = _horizontal_overrun(
        image_bgr, line, band_top, band_height, ucfg
    )

    return UnderlineEvidence(
        dark_ratio,
        extent_ratio,
        float(thickness_ratio),
        overrun_ratio,
        overrun_observed=overrun_observed,
    )


def _horizontal_overrun(
    image_bgr: np.ndarray,
    line: LineBox,
    band_top: int,
    band_height: int,
    ucfg: dict,
) -> tuple[float, bool]:
    """How strongly the mark continues past the ends of the text line.

    Returns (overrun_ratio, observed).

    A hand underline often overhangs a tight OCR box by a little, so the zone
    immediately beside the line is *skipped*: only the region past that
    tolerance is sampled. A pen stroke dies out there; a ruled border does not.

    Sides are combined with min() so a mark must continue in BOTH directions to
    read as a rule. When a side is off-image (cropped page, line at the edge)
    the visible side is used alone, and when neither side is visible `observed`
    is False — the caller must treat that as unknown rather than as evidence of
    no overrun.
    """
    # Both distances scale with line HEIGHT, not length: how far a hand stroke
    # overshoots depends on the size of the text, not on how long the line is.
    # Scaling by width made the tolerance on a full-width line so large that it
    # swallowed the whole page margin and the signal was never observable.
    tolerance = max(2, int(round(line.height * ucfg["penOverhangToleranceRatio"])))
    margin = max(6, int(round(line.height * ucfg["overrunMarginRatio"])))

    left = _region(image_bgr, line.x - tolerance - margin, band_top, margin, band_height)
    right = _region(image_bgr, line.x2 + tolerance, band_top, margin, band_height)

    coverages = []
    for side in (left, right):
        # Require most of the intended margin to be on-image; a sliver gives an
        # unreliable coverage figure.
        if side.size == 0 or side.shape[1] < margin // 2:
            continue
        coverages.append(float(_dark_mask(side).any(axis=0).mean()))

    if not coverages:
        return 0.0, False
    return min(coverages), True


def _longest_run(flags: np.ndarray) -> int:
    """Length of the longest run of True values."""
    best = run = 0
    for flag in flags:
        run = run + 1 if flag else 0
        best = max(best, run)
    return best


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
    evidence = detect_underline(image_bgr, line, cfg)
    dark_ratio = evidence.dark_ratio
    extent_ratio = evidence.extent_ratio

    ucfg = cfg["underline"]
    # Two ways a non-underline passes the darkness and extent tests:
    # a filled dark region (shadow, graphic) is too thick, and a ruled table
    # border is thin enough to look like a pen stroke but runs past the text.
    too_thick = evidence.thickness_ratio > ucfg["maxComponentThicknessRatio"]
    spans_beyond_line = (
        evidence.overrun_observed
        and evidence.overrun_ratio > ucfg["maxOutsideOverrunRatio"]
    )
    rejected = too_thick or spans_beyond_line
    is_underline = (
        dark_ratio >= ucfg["minDarkPixelRatio"]
        and extent_ratio >= ucfg["minHorizontalExtentRatio"]
        and not rejected
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
        if rejected:
            # Don't let a rejected mark report near-perfect evidence; the score
            # should read as "no usable marker", not "very confident".
            marker_overlap = 0.0
            line_geometry = 0.0
        else:
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
    # An underline whose margins were not visible cannot be told apart from a
    # cropped table rule, so it must not be auto-accepted however high the other
    # components score — unknown is routed to the user, not silently trusted
    # (ANA-PLAN §19.2, P3).
    overrun_unknown = selection_type == "underline" and not evidence.overrun_observed

    if selection_type == "none":
        decision = "user_selection"
    elif confidence >= thresholds["autoCandidate"] and not overrun_unknown:
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
            "underline_thickness_ratio": round(evidence.thickness_ratio, 4),
            "underline_overrun_ratio": round(evidence.overrun_ratio, 4),
            "underline_overrun_observed": bool(evidence.overrun_observed),
            "rejected_too_thick": bool(too_thick),
            "rejected_spans_beyond_line": bool(spans_beyond_line),
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


def _is_accepted(detection: LineDetection, include_pending: bool) -> bool:
    if detection.selection_type == "none":
        return False
    if detection.decision == "auto_candidate":
        return True
    return include_pending and detection.decision == "quick_confirm"


def selected_line_ids(
    detections: Sequence[LineDetection], include_pending: bool = False
) -> list[str]:
    """Lines whose marker was accepted outright.

    By default only `auto_candidate`. A `quick_confirm` line still owes the
    user a tap (ANA-PLAN §19.2) — exporting it here would let a caller hand it
    to card generation as though it had been confirmed, which is exactly the
    silent auto-accept §24.2 forbids. Pass `include_pending=True` when the
    caller is the confirmation UI itself and will ask for that tap.
    """
    return [d.line_id for d in detections if _is_accepted(d, include_pending)]


def group_selected_passages(
    detections: Sequence[LineDetection], include_pending: bool = False
) -> list[list[str]]:
    """Group accepted lines into passages of consecutive lines (§9.2 adım 7).

    `detections` must be in page order. A gap — any unaccepted line between two
    accepted ones — starts a new passage, so separately marked regions are not
    merged into one passage and fed to card generation as a single source text.

    `include_pending` carries the same meaning as in `selected_line_ids`: off by
    default so lines awaiting confirmation never reach card generation.
    """
    passages: list[list[str]] = []
    current: list[str] = []
    for detection in detections:
        if _is_accepted(detection, include_pending):
            current.append(detection.line_id)
        elif current:
            passages.append(current)
            current = []
    if current:
        passages.append(current)
    return passages
