"""Coverage for the Faz 2 gold-set marker measurement.

Uses synthetic pages rather than real fixtures — the detector arithmetic is
already pinned elsewhere (`test_marker_detection.py`,
`evals/shared/marker-decision-cases.json`); this only checks that a real
page's detections are matched against the right gold entry and scored the
way §19.3 requires (a false positive is the dangerous direction).
"""

from __future__ import annotations

import numpy as np

from evals.ocr_eval.gold_marker_report import index_vision_pages, score_entry, to_line_boxes
from evals.spikes.marker_detection.detector import LineBox, load_config
from evals.spikes.marker_detection.synthetic import make_page

CFG = load_config()


def vision_page_for(image_bgr: np.ndarray, lines: list[LineBox], image_path: str) -> dict:
    """The AppleVisionSpike output shape for a page: normalized (0–1)
    boxes, top-left origin — same frame `to_line_boxes` expects."""
    height, width = image_bgr.shape[:2]
    return {
        "imagePath": image_path,
        "imageWidth": width,
        "imageHeight": height,
        "lines": [
            {
                "lineId": line.line_id,
                "text": "önemsiz",
                "confidence": line.ocr_confidence,
                "x": line.x / width,
                "y": line.y / height,
                "width": line.width / width,
                "height": line.height / height,
            }
            for line in lines
        ],
    }


def entry_for(gold_line_ids: list[str]) -> dict:
    return {
        "id": "gold_001",
        "category": "printed_highlight",
        "goldSelectedLines": [
            {"lineId": lid, "text": "önemsiz", "selectionType": "highlight"} for lid in gold_line_ids
        ],
    }


def solid_highlight_page(n_lines: int = 4, marked_index: int = 1) -> tuple[np.ndarray, list[LineBox]]:
    """A page with generous line spacing and one line filled edge-to-edge in
    highlighter colour — no text drawn on top to partially occlude it.

    `make_page` (used elsewhere below) draws dark text blocks over its marks,
    which is the more realistic rendering but caps highlight coverage well
    under what `auto_candidate` needs — a real highlighted line's ink also
    isn't highlighter-coloured, and the reference config is calibrated
    accordingly (ANA-PLAN §9.3: "ilk kalibrasyon başlangıcı"). This variant
    exists to exercise the `auto_candidate` branch itself, which nothing else
    in this file reaches.
    """
    width, line_height, gap, margin = 400, 30, 60, 40
    height = margin * 2 + n_lines * (line_height + gap)
    image = np.full((height, width, 3), 255, dtype=np.uint8)  # white, BGR
    lines: list[LineBox] = []
    for i in range(n_lines):
        top = margin + i * (line_height + gap)
        box = LineBox(f"line_{i:02d}", margin, top, width - 2 * margin, line_height)
        lines.append(box)
        if i == marked_index:
            image[box.y : box.y2, box.x : box.x2] = (60, 240, 250)  # BGR yellow
    return image, lines


class TestIndexVisionPages:
    def test_matches_by_basename_not_full_path(self):
        # The capture tool's path and the manifest's `imagePath` never agree
        # on anything but the filename — one is a local absolute path, the
        # other is relative to `evals/`.
        run = {"pages": [{"imagePath": "/Users/x/Desktop/kornokta/evals/fixtures/a.jpg", "lines": []}]}
        assert set(index_vision_pages(run)) == {"a.jpg"}


class TestToLineBoxes:
    def test_denormalizes_into_pixel_space(self):
        page = {
            "imageWidth": 1000,
            "imageHeight": 500,
            "lines": [{"lineId": "line_00", "x": 0.1, "y": 0.2, "width": 0.5, "height": 0.05, "confidence": 0.9}],
        }
        boxes = to_line_boxes(page)
        assert len(boxes) == 1
        assert (boxes[0].x, boxes[0].y, boxes[0].width, boxes[0].height) == (100, 100, 500, 25)


class TestScoreEntry:
    def test_a_clean_highlight_is_a_one_tap_match(self):
        image, lines = solid_highlight_page(marked_index=1)
        vision_page = vision_page_for(image, lines, "a.jpg")
        entry = entry_for(["line_01"])

        result = score_entry(entry, vision_page, image, CFG)

        assert result["one_tap_match"], result
        assert result["reachable_match"]
        assert result["false_positives"] == []
        assert result["false_negatives"] == []

    def test_a_marked_line_reaches_confirmation_even_when_occluded_by_text(self):
        # `make_page` draws dark text over the mark, which — realistically —
        # keeps a correctly highlighted line out of `auto_candidate` under the
        # current (first-pass, ANA-PLAN §9.3) thresholds. It must still be
        # reachable with one confirm tap: a real highlight that never even
        # gets to `quick_confirm` would mean the calibration, not just the
        # one-tap rate, needs revisiting.
        page = make_page(n_lines=8, marked={2: "highlight:yellow"})
        vision_page = vision_page_for(page.image_bgr, page.lines, "a.jpg")
        entry = entry_for(page.marked_line_ids)

        result = score_entry(entry, vision_page, page.image_bgr, CFG)

        assert result["reachable_match"], result
        assert result["false_positives"] == []
        assert result["false_negatives"] == []

    def test_a_line_the_detector_finds_but_nobody_marked_is_a_false_positive(self):
        # The dangerous direction (§19.3): the detector accepts a line that
        # the gold data says was never marked at all.
        image, lines = solid_highlight_page(marked_index=1)
        vision_page = vision_page_for(image, lines, "a.jpg")
        entry = entry_for([])  # gold says nothing was marked

        result = score_entry(entry, vision_page, image, CFG)

        assert not result["one_tap_match"]
        assert result["false_positives"] == ["line_01"]
        assert result["false_negatives"] == []

    def test_a_marked_line_the_detector_misses_is_a_false_negative_not_a_positive(self):
        # A blank page: the detector finds nothing, but gold claims a mark.
        # This has to fail the match without being confused for a false
        # positive — the two are opposite failure modes with opposite risk.
        page = make_page(n_lines=8, marked={})
        vision_page = vision_page_for(page.image_bgr, page.lines, "a.jpg")
        entry = entry_for(["line_02"])

        result = score_entry(entry, vision_page, page.image_bgr, CFG)

        assert not result["one_tap_match"]
        assert not result["reachable_match"]
        assert result["false_positives"] == []
        assert result["false_negatives"] == ["line_02"]

    def test_document_quality_is_the_mean_confidence_not_a_constant(self):
        # A prior version of the single-image CLI this was built from hard-
        # coded document_quality to 0.9 regardless of input — silently wrong
        # for a genuinely blurry page. Two identical pages differing only in
        # OCR confidence must score differently.
        image, lines = solid_highlight_page(marked_index=1)
        entry = entry_for(["line_01"])

        confident = vision_page_for(image, lines, "a.jpg")
        for line in confident["lines"]:
            line["confidence"] = 0.99
        low = vision_page_for(image, lines, "a.jpg")
        for line in low["lines"]:
            line["confidence"] = 0.2

        confident_result = score_entry(entry, confident, image, CFG)
        low_result = score_entry(entry, low, image, CFG)

        # Same geometry and pixels, only confidence differs — the two runs
        # must not silently collapse to the same score.
        assert confident_result != low_result
