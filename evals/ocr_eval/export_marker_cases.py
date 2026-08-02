"""Freeze marker-decision rules into cases both implementations must satisfy.

    python -m evals.ocr_eval.export_marker_cases

The detector runs in two places: here, where it is calibrated against the gold
set, and on the phone, where it decides what the user tapped. Sharing the
thresholds keeps the *numbers* identical; this keeps the *rules* identical.

Only the arithmetic is pinned — measurements in, decision out. The pixel work
is tested separately on each side, because feeding both implementations the
same image would mean shipping images and would still not isolate which half
disagreed. The rules are where the subtlety is: which marks are rejected, and
which are unsafe to auto-accept however high they score.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from evals.spikes.marker_detection.detector import (
    LineBox,
    LineDetection,
    UnderlineEvidence,
    load_config,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "evals" / "shared" / "marker-decision-cases.json"

#: (name, highlight_overlap, underline evidence fields, ocr, quality, separation)
CASES: list[tuple[str, float, dict, float, float, float]] = [
    # --- clean highlight ---
    ("belirgin_fosforlu", 0.80, dict(dark=0.05, extent=0.10, thickness=0.05, overrun=0.0), 0.95, 0.95, 1.0),
    ("zayif_fosforlu", 0.30, dict(dark=0.02, extent=0.05, thickness=0.02, overrun=0.0), 0.90, 0.90, 1.0),
    ("fosforlu_esigin_altinda", 0.20, dict(dark=0.02, extent=0.05, thickness=0.02, overrun=0.0), 0.90, 0.90, 1.0),

    # --- clean underline ---
    ("belirgin_alt_cizgi", 0.01, dict(dark=0.35, extent=0.90, thickness=0.10, overrun=0.05), 0.95, 0.95, 1.0),
    ("ince_kalem_cizgisi", 0.01, dict(dark=0.15, extent=0.55, thickness=0.06, overrun=0.10), 0.90, 0.90, 1.0),
    ("kisa_cizgi_esigin_altinda", 0.01, dict(dark=0.30, extent=0.30, thickness=0.08, overrun=0.0), 0.90, 0.90, 1.0),
    ("soluk_cizgi_esigin_altinda", 0.01, dict(dark=0.08, extent=0.90, thickness=0.05, overrun=0.0), 0.90, 0.90, 1.0),

    # --- rejections: things that look like an underline but are not ---
    ("kalin_golge_reddedilir", 0.01, dict(dark=0.60, extent=0.95, thickness=0.50, overrun=0.10), 0.95, 0.95, 1.0),
    ("tablo_cizgisi_reddedilir", 0.01, dict(dark=0.40, extent=0.95, thickness=0.08, overrun=0.90), 0.95, 0.95, 1.0),
    ("tam_sayfa_cetveli", 0.01, dict(dark=0.50, extent=1.00, thickness=0.10, overrun=1.00), 0.99, 0.99, 1.0),
    ("kil_payi_kalin", 0.01, dict(dark=0.40, extent=0.90, thickness=0.26, overrun=0.10), 0.95, 0.95, 1.0),
    ("kil_payi_ince", 0.01, dict(dark=0.40, extent=0.90, thickness=0.24, overrun=0.10), 0.95, 0.95, 1.0),
    ("kil_payi_tasma", 0.01, dict(dark=0.40, extent=0.90, thickness=0.08, overrun=0.61), 0.95, 0.95, 1.0),

    # --- the "unknown is not evidence" rule (§19.2, P3) ---
    # A high-scoring underline whose margins were never visible must not
    # auto-accept: it cannot be told apart from a cropped table rule.
    ("kenar_gorunmeyen_guclu_cizgi", 0.01,
     dict(dark=0.40, extent=0.95, thickness=0.08, overrun=0.0, observed=False), 0.99, 0.99, 1.0),
    ("kenar_gorunmeyen_zayif_cizgi", 0.01,
     dict(dark=0.15, extent=0.50, thickness=0.05, overrun=0.0, observed=False), 0.80, 0.80, 1.0),

    # --- both markers present ---
    ("fosforlu_ve_cizgi_birlikte", 0.70, dict(dark=0.40, extent=0.90, thickness=0.08, overrun=0.05), 0.95, 0.95, 1.0),
    ("cizgi_fosforludan_guclu", 0.30, dict(dark=0.50, extent=0.90, thickness=0.08, overrun=0.05), 0.95, 0.95, 1.0),

    # --- nothing marked ---
    ("bos_satir", 0.0, dict(dark=0.0, extent=0.0, thickness=0.0, overrun=0.0), 0.95, 0.95, 1.0),
    ("sadece_metin", 0.02, dict(dark=0.06, extent=0.20, thickness=0.03, overrun=0.0), 0.95, 0.95, 1.0),

    # --- crowded lines and poor pages drag the score down ---
    ("bitisik_satirlar", 0.80, dict(dark=0.05, extent=0.10, thickness=0.05, overrun=0.0), 0.95, 0.95, 0.10),
    ("dusuk_sayfa_kalitesi", 0.80, dict(dark=0.05, extent=0.10, thickness=0.05, overrun=0.0), 0.95, 0.30, 1.0),
    ("dusuk_ocr_guveni", 0.80, dict(dark=0.05, extent=0.10, thickness=0.05, overrun=0.0), 0.30, 0.95, 1.0),
    ("her_sey_kotu", 0.30, dict(dark=0.05, extent=0.10, thickness=0.05, overrun=0.0), 0.30, 0.30, 0.10),
]


def build_payload() -> dict:
    from evals.spikes.marker_detection import detector as reference

    cfg = load_config()
    cases = []
    for name, highlight, underline, ocr, quality, separation in CASES:
        evidence = UnderlineEvidence(
            underline["dark"],
            underline["extent"],
            underline["thickness"],
            underline["overrun"],
            overrun_observed=underline.get("observed", True),
        )
        judged = _judge(reference, cfg, name, highlight, evidence, ocr, quality, separation)
        cases.append(
            {
                "name": name,
                "input": {
                    "highlightOverlap": highlight,
                    "underline": {
                        "darkRatio": evidence.dark_ratio,
                        "extentRatio": evidence.extent_ratio,
                        "thicknessRatio": evidence.thickness_ratio,
                        "overrunRatio": evidence.overrun_ratio,
                        "overrunObserved": evidence.overrun_observed,
                    },
                    "ocrConfidence": ocr,
                    "documentQuality": quality,
                    "neighboringSeparation": separation,
                },
                "expected": {
                    "markerOverlap": round(judged.marker_overlap, 6),
                    "lineGeometry": round(judged.line_geometry, 6),
                    "selectionConfidence": judged.selection_confidence,
                    "selectionType": judged.selection_type,
                    "decision": judged.decision,
                },
            }
        )
    return {
        "_comment": (
            "GENERATED by `python -m evals.ocr_eval.export_marker_cases`. "
            "Expected values come from the Python detector, which is the "
            "reference. Both implementations are tested against this file."
        ),
        "cases": cases,
    }


def _judge(reference, cfg, name, highlight, evidence, ocr, quality, separation) -> LineDetection:
    """Runs the reference's judgement with measurements supplied directly.

    `analyze_line` measures from an image; here the measurements are the input,
    so the two are wired together with small stand-ins rather than by
    constructing an image that happens to produce them.
    """
    line = LineBox(line_id=name, x=0, y=0, width=100, height=20, ocr_confidence=ocr)

    original_highlight = reference.detect_highlight_overlap
    original_underline = reference.detect_underline
    original_separation = reference._neighboring_separation
    try:
        reference.detect_highlight_overlap = lambda *_args, **_kwargs: highlight
        reference.detect_underline = lambda *_args, **_kwargs: evidence
        reference._neighboring_separation = lambda *_args, **_kwargs: separation
        return reference.analyze_line(None, line, [line], quality, cfg)
    finally:
        reference.detect_highlight_overlap = original_highlight
        reference.detect_underline = original_underline
        reference._neighboring_separation = original_separation


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    payload = json.dumps(build_payload(), ensure_ascii=False, indent=2) + "\n"

    if args.check:
        if not args.output.exists() or args.output.read_text(encoding="utf-8") != payload:
            print(
                f"{args.output} güncel değil.\n"
                "Düzeltmek için: python -m evals.ocr_eval.export_marker_cases",
                file=sys.stderr,
            )
            return 1
        print(f"{args.output} güncel.")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(payload, encoding="utf-8")
    print(f"Yazıldı: {args.output}  ({len(CASES)} vaka)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
