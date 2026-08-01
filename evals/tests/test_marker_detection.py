import numpy as np
import pytest

from evals.ocr_eval.metrics import selection_prf
from evals.spikes.marker_detection.detector import (
    LineBox,
    analyze_page,
    group_selected_passages,
    load_config,
    selected_line_ids,
)
from evals.spikes.marker_detection.synthetic import (
    draw_overhanging_underline,
    draw_table_rule,
    make_page,
)


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
    def test_selected_lines_match_truth(self, cfg):
        page = make_page(n_lines=8, marked={2: "highlight:yellow", 5: "underline:pen"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        prf = selection_prf(page.marked_line_ids, selected_line_ids(detections))
        assert prf.recall == 1.0
        assert prf.false_positives == 0

    def test_consecutive_highlight_is_one_passage(self, cfg):
        page = make_page(n_lines=8, marked={3: "highlight:yellow", 4: "highlight:yellow"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        assert group_selected_passages(detections) == [["line_03", "line_04"]]

    def test_separated_marks_are_distinct_passages(self, cfg):
        # line_02 and line_05 are unrelated regions; merging them would feed
        # disjoint source text to card generation as one passage.
        page = make_page(n_lines=8, marked={2: "highlight:yellow", 5: "underline:pen"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        assert group_selected_passages(detections) == [["line_02"], ["line_05"]]

    def test_no_marks_yields_no_passages(self, cfg):
        page = make_page(n_lines=4)
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        assert group_selected_passages(detections) == []


class TestThickDarkBandRejection:
    def _page_with_dark_band(self, cfg, band_height):
        """A page whose line_02 sits above a thick dark region (shadow/table rule)."""
        import numpy as np

        page = make_page(n_lines=6)
        line = next(l for l in page.lines if l.line_id == "line_02")
        page.image_bgr[line.y2: line.y2 + band_height, line.x: line.x2] = 5
        return page, line

    def test_thick_band_not_classified_as_underline(self, cfg):
        page, _ = self._page_with_dark_band(cfg, band_height=30)
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        assert target.detail["rejected_too_thick"] is True
        assert target.selection_type == "none"

    def test_thick_band_never_auto_accepted(self, cfg):
        page, _ = self._page_with_dark_band(cfg, band_height=30)
        detections = analyze_page(page.image_bgr, page.lines, document_quality=1.0, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        assert target.decision == "user_selection"
        assert target.selection_confidence < cfg["decisionThresholds"]["autoCandidate"]

    def test_thin_underline_still_accepted(self, cfg):
        page = make_page(n_lines=6, marked={2: "underline:pen"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        assert target.detail["rejected_too_thick"] is False
        assert target.selection_type == "underline"


class TestTableRuleRejection:
    """A ruled table border is thin enough to pass the thickness test, so it
    must be separated from a pen stroke by some other evidence (§9.2)."""

    @pytest.mark.parametrize("thickness", [2, 3, 5])
    def test_thin_table_rule_not_an_underline(self, cfg, thickness):
        page = make_page(n_lines=6)
        draw_table_rule(page, below_line_index=2, thickness=thickness)
        detections = analyze_page(page.image_bgr, page.lines, document_quality=1.0, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        # Precondition: this is exactly the case thickness alone cannot catch.
        assert target.detail["underline_thickness_ratio"] <= cfg["underline"]["maxComponentThicknessRatio"]
        assert target.detail["rejected_spans_beyond_line"] is True
        assert target.selection_type == "none"

    def test_table_rule_never_auto_accepted(self, cfg):
        page = make_page(n_lines=6)
        draw_table_rule(page, below_line_index=2, thickness=3)
        detections = analyze_page(page.image_bgr, page.lines, document_quality=1.0, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        assert target.decision == "user_selection"
        assert target.selection_confidence < cfg["decisionThresholds"]["quickConfirm"]

    def test_pen_underline_does_not_overrun(self, cfg):
        page = make_page(n_lines=6, marked={2: "underline:pen"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_02")
        assert target.detail["rejected_spans_beyond_line"] is False
        assert target.selection_type == "underline"

    def test_pencil_underline_does_not_overrun(self, cfg):
        page = make_page(n_lines=6, marked={4: "underline:pencil"})
        detections = analyze_page(page.image_bgr, page.lines, document_quality=0.9, cfg=cfg)
        target = next(d for d in detections if d.line_id == "line_04")
        assert target.detail["rejected_spans_beyond_line"] is False
        assert target.selection_type == "underline"

    def test_hand_underline_may_overhang_a_tight_box(self, cfg):
        # OCR often returns a snug box around a short phrase while the stroke
        # runs a little past both ends; that is a pen mark, not a rule.
        page = make_page(n_lines=6)
        tight = draw_overhanging_underline(page, line_index=2, overhang_px=18)
        lines = [tight] + [l for l in page.lines if l.line_id != tight.line_id]
        detections = analyze_page(page.image_bgr, lines, document_quality=0.95, cfg=cfg)
        target = next(d for d in detections if d.line_id == tight.line_id)
        assert target.detail["rejected_spans_beyond_line"] is False
        assert target.selection_type == "underline"


class TestUnobservableOverrun:
    """When no margin beside the line is visible the overrun signal carries no
    information; it must read as unknown, never as 'no overrun' (§19.2)."""

    def _edge_line_over_rule(self, cfg):
        page = make_page(n_lines=6)
        draw_table_rule(page, below_line_index=2, thickness=3)
        original = page.lines[2]
        edge = LineBox(
            original.line_id, 0, original.y, page.image_bgr.shape[1], original.height, 0.95
        )
        lines = [edge] + [l for l in page.lines if l.line_id != edge.line_id]
        return page, lines, edge

    def test_clipped_margin_marks_overrun_unobserved(self, cfg):
        page, lines, edge = self._edge_line_over_rule(cfg)
        detections = analyze_page(page.image_bgr, lines, document_quality=1.0, cfg=cfg)
        target = next(d for d in detections if d.line_id == edge.line_id)
        assert target.detail["underline_overrun_observed"] is False

    def test_clipped_margin_never_auto_accepted(self, cfg):
        # A cropped full-width table rule is indistinguishable from an
        # underline here, so it must not slip through as an auto candidate.
        page, lines, edge = self._edge_line_over_rule(cfg)
        detections = analyze_page(page.image_bgr, lines, document_quality=1.0, cfg=cfg)
        target = next(d for d in detections if d.line_id == edge.line_id)
        assert target.decision != "auto_candidate"


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
