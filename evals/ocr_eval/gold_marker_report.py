"""Faz 2 exit-gate measurement: marker detection against real, gold-labeled pages.

    python -m evals.ocr_eval.gold_marker_report --vision evals/reports/vision.json

Runs the marker detector (`evals.spikes.marker_detection.detector`) against
each annotated gold-manifest entry's real image, using Apple Vision's own line
geometry for that image — the same geometry F2-5/F2-6 use on the phone.
Reports the one-tap rate ANA-PLAN §25's Faz 2 exit gate asks for.

This doubles as the missing measurement of whether Vision's line boxes are
geometrically trustworthy (FAZ2-PLAN.md, "Ölçüm hâlâ eksik"): the whole
pipeline here runs on Vision's boxes and never reads its OCR text, so a good
score is itself the evidence — a bad score could equally mean the boxes are
off, independent of Vision's well-established inability to read Turkish.

Entries with no matching page in `--vision`, or whose image file cannot be
read, are skipped and reported separately rather than silently dropped —
missing coverage should never look the same as a passing measurement.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from ..spikes.marker_detection.detector import LineBox, analyze_page, load_config, selected_line_ids

EVALS_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = EVALS_ROOT / "gold-manifest.json"


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def index_vision_pages(vision_run: dict) -> dict[str, dict]:
    """Map image basename -> OCR page. Basename, not the full path: the path a
    capture tool wrote is whatever local filesystem layout produced it, and
    the manifest's `imagePath` is relative to `evals/` — the two agree on the
    filename and nothing else."""
    return {Path(page["imagePath"]).name: page for page in vision_run.get("pages", [])}


def to_line_boxes(page: dict) -> list[LineBox]:
    """Normalized (0–1) OCR line boxes to the pixel space the detector works in."""
    width, height = page["imageWidth"], page["imageHeight"]
    return [
        LineBox(
            line_id=line["lineId"],
            x=round(line["x"] * width),
            y=round(line["y"] * height),
            width=round(line["width"] * width),
            height=round(line["height"] * height),
            ocr_confidence=line.get("confidence", 0.9),
        )
        for line in page.get("lines", [])
    ]


def score_entry(entry: dict, page: dict, image_bgr: Any, cfg: dict) -> dict:
    lines = to_line_boxes(page)
    confidences = [line.ocr_confidence for line in lines]
    document_quality = sum(confidences) / len(confidences) if confidences else 0.0

    detections = analyze_page(image_bgr, lines, document_quality=document_quality, cfg=cfg)
    auto = set(selected_line_ids(detections))
    reachable = set(selected_line_ids(detections, include_pending=True))
    gold = {line["lineId"] for line in entry.get("goldSelectedLines", [])}

    return {
        "id": entry["id"],
        "category": entry["category"],
        "gold": sorted(gold),
        "auto": sorted(auto),
        "reachable": sorted(reachable),
        "one_tap_match": auto == gold,
        "reachable_match": reachable == gold,
        # A line the detector auto-accepted that the user never marked: the
        # dangerous direction: §19.3 forbids a card appearing with no marker
        # and no tap, and this is exactly that happening silently.
        "false_positives": sorted(auto - gold),
        # A marked line the detector never reaches even with a confirm tap:
        # annoying (the user has to select manually) but not unsafe.
        "false_negatives": sorted(gold - reachable),
    }


def _print_report(results: list[dict], unmatched: list[str]) -> None:
    if unmatched:
        print(
            f"UYARI: {len(unmatched)} girdi ölçülemedi "
            f"(Vision çıktısında sayfa yok ya da görsel okunamadı): {', '.join(unmatched)}\n",
            file=sys.stderr,
        )

    if not results:
        return

    print(f"{'id':10} {'kategori':24} {'altın':14} {'tek-dokunuş':12} {'ulaşılabilir':13} {'yanlış-pozitif'}")
    for r in results:
        one_tap = "EVET" if r["one_tap_match"] else "hayır"
        reachable = "EVET" if r["reachable_match"] else "hayır"
        fp = ",".join(r["false_positives"]) or "-"
        gold = ",".join(r["gold"]) or "-"
        print(f"{r['id']:10} {r['category']:24} {gold:14} {one_tap:12} {reachable:13} {fp}")

    n = len(results)
    one_tap_n = sum(1 for r in results if r["one_tap_match"])
    reachable_n = sum(1 for r in results if r["reachable_match"])
    fp_n = sum(1 for r in results if r["false_positives"])

    print(f"\nÖzet ({n} görüntü ölçüldü):")
    print(f"  Tek dokunuşta doğru (auto_candidate tek başına altınla eşleşiyor): {one_tap_n}/{n} (%{100 * one_tap_n / n:.0f})")
    print(f"  Bir onayla ulaşılabilir (quick_confirm dahil eşleşiyor):            {reachable_n}/{n} (%{100 * reachable_n / n:.0f})")
    print(f"  Yanlış-pozitif içeren görüntü (işaretsiz satır otomatik seçildi):   {fp_n}/{n}")
    if fp_n:
        print("  UYARI: yanlış-pozitif, §19.3'ün yasakladığı şey — onaysız kart oluşabilir demek.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vision", type=Path, required=True, help="AppleVisionSpike (veya aynı şemadaki başka bir motorun) JSON çıktısı")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--config", type=Path, help="Eşik config.json'ı override et")
    args = parser.parse_args(argv)

    try:
        import cv2
    except Exception:
        print("HATA: gerçek görüntüleri okumak için OpenCV gerekli; pip install opencv-python-headless", file=sys.stderr)
        return 2

    manifest = load_json(args.manifest)
    vision_run = load_json(args.vision)
    cfg = load_config(args.config) if args.config else load_config()
    pages_by_name = index_vision_pages(vision_run)

    annotated = [e for e in manifest.get("entries", []) if e.get("status") == "annotated"]
    if not annotated:
        print("Etiketlenmiş (status=annotated) girdi yok.", file=sys.stderr)
        return 1

    results = []
    unmatched = []
    for entry in annotated:
        image_name = Path(entry["imagePath"]).name
        page = pages_by_name.get(image_name)
        if page is None:
            unmatched.append(entry["id"])
            continue

        image_path = (args.manifest.parent / entry["imagePath"]).resolve()
        image_bgr = cv2.imread(str(image_path))
        if image_bgr is None:
            unmatched.append(entry["id"])
            continue

        results.append(score_entry(entry, page, image_bgr, cfg))

    _print_report(results, unmatched)
    if not results:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
