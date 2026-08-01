"""Score AppleVisionSpike output against the gold manifest.

    python -m evals.ocr_eval.vision_report evals/reports/vision.json

Reads the JSON written by `ios/spikes/AppleVisionSpike`, matches each page to
its manifest entry by image path, and reports the Faz 0 OCR metrics: CER, WER
and the three-measure critical-token gate (ANA-PLAN §23.2, §24.3).

Entries still marked `pending` in the manifest are skipped — they have no gold
transcription to score against.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .metrics import (
    added_critical_tokens,
    cer,
    critical_token_error_rate,
    critical_token_mismatches,
    wer,
)

EVALS_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = EVALS_ROOT / "gold-manifest.json"


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def index_manifest(manifest: dict) -> dict[str, dict]:
    """Map image basename -> annotated entry."""
    return {
        Path(entry["imagePath"]).name: entry
        for entry in manifest.get("entries", [])
        if entry.get("status") == "annotated"
    }


def score_page(page: dict, entry: dict) -> dict:
    hypothesis = "\n".join(line["text"] for line in page.get("lines", []))
    gold_text = entry.get("exactTranscription", "")
    gold_tokens = [t["token"] for t in entry.get("criticalTokens", [])]

    mismatches = critical_token_mismatches(gold_text, hypothesis, gold_tokens=gold_tokens)
    missing_rate = critical_token_error_rate(gold_tokens, hypothesis)
    added = added_critical_tokens(gold_text, hypothesis)

    return {
        "id": entry["id"],
        "category": entry["category"],
        "cer": cer(gold_text, hypothesis),
        "wer": wer(gold_text, hypothesis),
        "critical_mismatches": mismatches,
        "critical_missing_rate": missing_rate,
        "critical_added": added,
        "gate_passes": not mismatches and missing_rate == 0.0 and not added,
        "elapsed_ms": page.get("elapsedMs"),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vision_json", type=Path, help="AppleVisionSpike çıktısı")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--verbose", action="store_true", help="Her uyuşmazlığı yaz")
    args = parser.parse_args(argv)

    run = load_json(args.vision_json)
    by_name = index_manifest(load_json(args.manifest))

    results = []
    unmatched = []
    for page in run.get("pages", []):
        name = Path(page.get("imagePath", "")).name
        entry = by_name.get(name)
        if entry is None:
            unmatched.append(name)
            continue
        results.append(score_page(page, entry))

    if not results:
        print("Eşleşen etiketli görüntü yok. Manifestteki imagePath adları ile "
              "Vision çıktısındaki dosya adları aynı mı?", file=sys.stderr)
        if unmatched:
            print(f"Eşleşmeyen: {', '.join(sorted(unmatched)[:10])}", file=sys.stderr)
        return 1

    print(f"{'id':10} {'kategori':24} {'CER':>6} {'WER':>6} {'kapı':>6}  kritik")
    for r in sorted(results, key=lambda r: r["id"]):
        gate = "geçti" if r["gate_passes"] else "KALDI"
        detail = ""
        if not r["gate_passes"]:
            bits = []
            if r["critical_mismatches"]:
                bits.append(f"{len(r['critical_mismatches'])} uyuşmazlık")
            if r["critical_missing_rate"]:
                bits.append(f"eksik={r['critical_missing_rate']:.2f}")
            if r["critical_added"]:
                bits.append(f"eklenen={r['critical_added']}")
            detail = ", ".join(bits)
        print(f"{r['id']:10} {r['category']:24} {r['cer']:6.3f} {r['wer']:6.3f} {gate:>6}  {detail}")
        if args.verbose:
            for line in r["critical_mismatches"]:
                print(f"           {line}")

    passed = sum(1 for r in results if r["gate_passes"])
    mean_cer = sum(r["cer"] for r in results) / len(results)
    mean_wer = sum(r["wer"] for r in results) / len(results)
    latencies = [r["elapsed_ms"] for r in results if r["elapsed_ms"] is not None]

    print(f"\n{len(results)} görüntü  |  kapıyı geçen: {passed}/{len(results)}"
          f"  |  ortalama CER: {mean_cer:.3f}  WER: {mean_wer:.3f}")
    if latencies:
        latencies.sort()
        print(f"Gecikme: medyan {latencies[len(latencies) // 2]} ms, "
              f"en yüksek {latencies[-1]} ms")
    if unmatched:
        print(f"Manifestte karşılığı olmayan {len(unmatched)} görüntü atlandı.")

    # ANA-PLAN §24.3: printed text must not record a critical-token error.
    return 0 if passed == len(results) else 2


if __name__ == "__main__":
    sys.exit(main())
