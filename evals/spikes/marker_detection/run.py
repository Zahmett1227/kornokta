"""CLI for the marker-detection spike (ANA-PLAN §9).

    python -m evals.spikes.marker_detection.run --demo
    python -m evals.spikes.marker_detection.run --image path/to/page.png --lines lines.json

--demo builds a synthetic page (highlight + pen + pencil marks) and prints the
per-line decision, so the pipeline is runnable with no fixtures and no network.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from .detector import LineBox, analyze_page, group_selected_passage, load_config


def _print_report(detections) -> None:
    print(f"{'line':8} {'type':10} {'conf':>6} {'decision':16} detail")
    for d in detections:
        print(
            f"{d.line_id:8} {d.selection_type:10} {d.selection_confidence:6.3f} "
            f"{d.decision:16} {json.dumps(d.detail, ensure_ascii=False)}"
        )
    passage = group_selected_passage(detections)
    print(f"\nSelected passage lines: {passage or '(none)'}")


def run_demo(cfg: dict) -> int:
    from .synthetic import make_page

    page = make_page(
        n_lines=8,
        marked={2: "highlight:yellow", 5: "underline:pen"},
    )
    print(f"Synthetic page: {page.image_bgr.shape[1]}x{page.image_bgr.shape[0]}, "
          f"marked lines (truth): {page.marked_line_ids}\n")
    detections = analyze_page(page.image_bgr, page.lines, document_quality=0.95, cfg=cfg)
    _print_report(detections)
    return 0


def run_image(image_path: Path, lines_path: Path, cfg: dict) -> int:
    try:
        import cv2
    except Exception:
        print("ERROR: OpenCV required to load real images; install opencv-python-headless", file=sys.stderr)
        return 2
    image_bgr = cv2.imread(str(image_path))
    if image_bgr is None:
        print(f"ERROR: could not read image {image_path}", file=sys.stderr)
        return 2
    raw = json.loads(Path(lines_path).read_text(encoding="utf-8"))
    lines = [
        LineBox(l["line_id"], l["x"], l["y"], l["width"], l["height"], l.get("ocr_confidence", 0.9))
        for l in raw
    ]
    detections = analyze_page(image_bgr, lines, document_quality=raw and 0.9 or 0.9, cfg=cfg)
    _print_report(detections)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", action="store_true", help="Run on a generated synthetic page")
    parser.add_argument("--image", type=Path, help="Path to a page image")
    parser.add_argument("--lines", type=Path, help="JSON list of OCR line boxes")
    parser.add_argument("--config", type=Path, help="Override config.json path")
    args = parser.parse_args(argv)

    cfg = load_config(args.config) if args.config else load_config()

    if args.demo:
        return run_demo(cfg)
    if args.image and args.lines:
        return run_image(args.image, args.lines, cfg)
    parser.error("provide --demo, or both --image and --lines")


if __name__ == "__main__":
    sys.exit(main())
