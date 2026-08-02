"""Freeze gate behaviour into cases both implementations must satisfy.

    python -m evals.ocr_eval.export_gate_cases

Companion to `export_cases.py`, which pins the *detector*. This pins the three
gate measures on top of it (ANA-PLAN §23.2, §24.3). Detecting the same tokens
is not the same as reaching the same verdict: alignment, de-duplication and
canonicalization all sit between the two, and each has already been a source of
a real bug in the Python version.

Expected values come from the Python implementation because it is the
reference.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .metrics import (
    added_critical_tokens,
    critical_token_mismatches,
    critical_token_recall_loss,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "evals" / "shared" / "gate-cases.json"

#: (group, source text, reading). Every pair is one the gate must judge the
#: same way in both implementations.
PAIRS: list[tuple[str, str, str]] = [
    # --- identical readings: the gate must stay quiet ---
    ("temiz", "0,3–0,5 mg IM adrenalin", "0,3–0,5 mg IM adrenalin"),
    ("temiz", "sağ böbrekte kitle", "sağ böbrekte kitle"),
    ("temiz", "kullanılmamalıdır", "kullanılmamalıdır"),
    ("temiz", "hiçbir kritik değer yok burada", "hiçbir kritik değer yok burada"),

    # --- route: same route, different spelling -> equal (§10.5.1) ---
    ("yol_esdeger", "0,5 mg IM uygulanır", "0,5 mg im uygulanır"),
    ("yol_esdeger", "intravenöz verilir", "IV verilir"),
    ("yol_esdeger", "kas içi uygulanır", "IM uygulanır"),
    ("yol_esdeger", "ağızdan alınır", "PO alınır"),

    # --- route: different routes -> never equal ---
    ("yol_farkli", "0,5 mg IM uygulanır", "0,5 mg IV uygulanır"),
    ("yol_farkli", "intravenöz verilir", "kas içi verilir"),
    ("yol_farkli", "PO alınır", "SL alınır"),
    ("yol_farkli", "intratekal verilir", "intraartiküler verilir"),

    # --- dose and number: the errors that hurt most ---
    ("doz", "0,5 mg verilir", "0,05 mg verilir"),
    ("doz", "0,5 mg verilir", "0.5 mg verilir"),
    ("doz", "1 mg verilir", "1–2 mg verilir"),
    ("doz", "5 mg/kg", "5 mg/gün"),
    ("doz", "günde 2 kez", "günde 3 kez"),
    ("doz", "0,3–0,5 mg", "0,3-0,5 mg"),
    ("doz", "5 mg sabah, 5 mg akşam", "5 mg sabah, 50 mg akşam"),

    # --- dropped and invented values ---
    ("eksik", "0,3–0,5 mg IM adrenalin", "IM adrenalin"),
    ("eksik", "sağ böbrekte kitle", "böbrekte kitle"),
    ("fazla", "IM adrenalin", "0,5 mg IM adrenalin"),
    ("fazla", "böbrekte kitle", "sağ böbrekte kitle"),

    # --- units ---
    ("birim", "5 mEq/L", "5 mmol/L"),
    ("birim", "10 mL", "10 L"),
    ("birim", "120 mmHg", "120 mmol/L"),

    # --- negation: the sharpest flip ---
    ("olumsuzluk", "kullanılmamalıdır", "kullanılmalıdır"),
    ("olumsuzluk", "görülmemiştir", "görülmüştür"),
    ("olumsuzluk", "kanama yoktur", "kanama vardır"),
    ("olumsuzluk", "etkilemiyor", "etkiliyor"),

    # --- laterality and direction ---
    ("yon", "sağ böbrekte kitle", "sol böbrekte kitle"),
    ("yon", "proksimal tübülde", "distal tübülde"),

    # --- hypo/hyper and ions ---
    ("hipo_hiper", "hipokalemi gelişti", "hiperkalemi gelişti"),
    ("iyon", "Na+ artışı", "Na- artışı"),
    ("iyon", "Fe+2 birikimi", "Fe+3 birikimi"),

    # --- symbols ---
    ("simge", "%40 oranında", "%50 oranında"),
    ("simge", "%40 oranında", "% 40 oranında"),
    ("simge", "< 90 mmHg", "> 90 mmHg"),
    ("simge", "test pozitif", "test negatif"),

    # --- diacritic loss: detected, and still reported (§24.3) ---
    ("diakritik", "sağ böbrekte kitle", "sag böbrekte kitle"),
    ("diakritik", "kullanılmamalıdır", "kullanilmamalidir"),
    ("diakritik", "görülmemiştir", "gorulmemistir"),
    # both sides already ASCII: a real change must still be caught
    ("diakritik", "sag bobrekte kitle", "sol bobrekte kitle"),
    ("diakritik", "kullanilmamalidir", "kullanilmalidir"),

    # --- whitespace and casing must not be errors on their own ---
    ("bicimsel", "%40 oranında", "%40   oranında"),
    ("bicimsel", "0,5 mg IM", "0,5 mg  IM"),

    # --- degenerate inputs ---
    ("bos", "", ""),
    ("bos", "0,5 mg", ""),
    ("bos", "", "0,5 mg"),
]


def build_payload() -> dict:
    cases = []
    for group, gold, reading in PAIRS:
        mismatches = critical_token_mismatches(gold, reading)
        # The reconciliation measure, not the manifest one: neither side of an
        # Apple-vs-Google comparison is annotated, so both are detected.
        missing = critical_token_recall_loss(gold, reading)
        added = added_critical_tokens(gold, reading)
        cases.append(
            {
                "group": group,
                "gold": gold,
                "reading": reading,
                "mismatches": mismatches,
                "missingRate": missing,
                "added": added,
                "passes": not mismatches and missing == 0.0 and not added,
            }
        )
    return {
        "_comment": (
            "GENERATED by `python -m evals.ocr_eval.export_gate_cases`. "
            "Expected values come from the Python gate, which is the "
            "reference. Both implementations are tested against this file."
        ),
        "cases": cases,
    }


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
                "Düzeltmek için: python -m evals.ocr_eval.export_gate_cases",
                file=sys.stderr,
            )
            return 1
        print(f"{args.output} güncel.")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(payload, encoding="utf-8")
    print(f"Yazıldı: {args.output}  ({len(PAIRS)} vaka)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
