import numpy as np
import pytest

from evals.ocr_eval.metrics import selection_prf
from evals.spikes.marker_detection.detector import (
    LineBox,
    analyze_page,
    group_selected_passage,
    load_config,
)
from evals.spikes.marker_detection.synthetic import make_page


@pytest.fixture(scope="module")
def cfg():
    return load_config()


class TestConfig:
    def test_weights_sum_to_one(self, cfg):
        assert sum(cfg["confidenceWeights"].values()) == pytest.approx(1.0)

    def test_thresholds_ordered(self, cfg):
        assert cfg["decisionThresholds"]["autoCandidate"] > cfg["decisionThresholds"]["quickConfirm"]


class TestHighlightDetection:
    @pytest.mark.parametrize("color", ["yellow", "green", "pink", "blue"])
    def test_highlighted_line_detected(self, cfg, color):
        page = make_page(n_lines=6, marked={3: f"highlight:{color}"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_03")
        assert target.selection_type == "highlight"
        assert target.detail["highlight_overlap"] > cfg["highlight"]["minOverlapRatio"]

    def test_unmarked_lines_not_selected(self, cfg):
        page = make_page(n_lines=6, marked={3: "highlight:yellow"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        for d in detections:
            if d.line_id != "line_03":
                assert d.selection_type == "none"


class TestUnderlineDetection:
    def test_pen_underline_detected(self, cfg):
        page = make_page(n_lines=6, marked={2: "underline:pen"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        assert target.selection_type == "underline"
        assert target.detail["underline_extent_ratio"] >= cfg["underline"]["minHorizontalExtentRatio"]

    def test_pencil_underline_detected(self, cfg):
        page = make_page(n_lines=6, marked={4: "underline:pencil"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.9, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_04")
        assert target.selection_type == "underline"


class TestPassageGrouping:
    def test_selected_passage_matches_truth(self, cfg):
        page = make_page(n_lines=8, marked={2: "highlight:yellow", 5: "underline:pen"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        selected = group_selected_passage(detections)
        prf = selection_prf(page.marked_line_ids, selected)
        assert prf.recall == 1.0
        assert prf.false_positives == 0

    def test_consecutive_highlight_grouped(self, cfg):
        page = make_page(n_lines=8, marked={3: "highlight:yellow", 4: "highlight:yellow"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        selected = set(group_selected_passage(detections))
        assert {"line_03", "line_04"} <= selected


class TestConfidenceComponents:
    def test_confidence_in_unit_range(self, cfg):
        page = make_page(n_lines=6, marked={2: "highlight:yellow"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.9, cfg=cfg)
        for d in detections:
            assert 0.0 <= d.selection_confidence <= 1.0

    def test_low_ocr_confidence_lowers_score(self, cfg):
        page = make_page(n_lines=4, marked={1: "highlight:yellow"})
        lines_high = page.lines
        lines_low = [LineBox(l.line_id, l.x, l.y, l.width, l.height, 0.2) for l in page.lines]
        high = analyze_page(page.image_bgr, lines_high, document_quality=0.9, cfg=cfg)
        low = analyze_page(page.image_bgr, lines_low, document_quality=0.9, cfg=cfg)
        h = next(d for d in high if d.line_id == "line_01").selection_confidence
        l = next(d for d in low if d.line_id == "line_01").selection_confidence
        assert l < h


class TestHsvFallback:
    def test_numpy_hsv_matches_shape(self):
        from evals.spikes.marker_detection.detector import _bgr_to_hsv_numpy

        img = np.zeros((5, 5, 3), dtype=np.uint8)
        img[..., 0] = 255  # blue in BGR
        hsv = _bgr_to_hsv_numpy(img)
        assert hsv.shape == img.shape
        assert hsv[..., 1].min() > 0  # saturated color has non-zero S
