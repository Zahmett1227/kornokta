"""Freeze detector behaviour into cases both implementations must satisfy.

    python -m evals.ocr_eval.export_cases

The detector runs here and in the TypeScript backend. Generating the patterns
(`export_patterns.py`) keeps the *rules* identical; this keeps the *behaviour*
identical, which is not the same thing — a difference in how the two engines
apply the same rule, or in how each de-duplicates and sorts, would slip past a
pattern-level check.

Expected values come from the Python detector because it is the reference: it
carries the test suite this project has built up. Freezing them means a change
in either implementation shows up as a failing case rather than as two systems
quietly disagreeing about whether a passage contains a negation.

The sentence list is deliberately hostile — it is where both implementations
have already been wrong at least once.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .critical_tokens import detect_critical_tokens
from .normalize import fold_diacritics

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "evals" / "shared" / "critical-token-cases.json"

#: Each entry is a sentence the detector must handle identically in both
#: implementations. Grouped by what they are guarding.
SENTENCES: list[tuple[str, str]] = [
    # --- doses, numbers, units: the classes a wrong reading harms most ---
    ("doz", "Anafilakside 0,3–0,5 mg IM adrenalin uygulanır."),
    ("doz", "5 mg/kg/gün dozunda başlanır."),
    ("doz", "Günde 3 kez 500 mg verilir."),
    ("doz", "q8h uygulanır."),
    ("doz", "2 x 40 mg"),
    ("birim", "Serum potasyumu 5,5 mEq/L üzerindedir."),
    ("birim", "Kan basıncı 120 mmHg."),
    ("birim", "10 mL izotonik."),
    # 'g' as a unit must not be satisfied by 'gün'
    ("birim", "gün içinde verilir"),
    ("sayı", "Evre 3 hastalık."),
    ("sayı", "1 ile 10 arasında."),

    # --- route: IM vs IV is a different drug order ---
    ("yol", "0,5 mg IM uygulanır."),
    ("yol", "0,5 mg IV uygulanır."),
    ("yol", "intravenöz verilir"),
    ("yol", "damar içine verilir"),
    ("yol", "kas içi uygulanır"),
    ("yol", "ağızdan alınır"),
    ("yol", "5 mg iv"),
    # bare 'in', 'top', 'ot' are deliberately not routes
    ("yol", "top oynarken düştü"),
    ("yol", "otların arasında"),

    # --- negation: the sharpest meaning flip in clinical prose ---
    ("olumsuzluk", "kullanılmamalıdır"),
    ("olumsuzluk", "kullanılmalıdır"),
    ("olumsuzluk", "görülmemiştir"),
    ("olumsuzluk", "görülmüştür"),
    ("olumsuzluk", "etkilemiyor"),
    ("olumsuzluk", "artmaz"),
    ("olumsuzluk", "bu doğru değildir"),
    ("olumsuzluk", "beklemeksizin verilir"),
    ("olumsuzluk", "verilmeden çekim yapılır"),
    ("olumsuzluk", "kullanılmasında sakınca yoktur"),
    ("olumsuzluk", "kanama görüldü"),
    # bare -ma/-me verbal nouns must NOT be flagged (§24.2)
    ("olumsuzluk", "kanama, uygulama ve gelişme izlendi"),
    ("olumsuzluk", "beslenme ve büyüme normaldi"),

    # --- laterality and direction ---
    ("yön", "sağ böbrekte kitle"),
    ("yön", "sol böbrekte kitle"),
    # 'sağ' must not be satisfied by 'sağlıklı' or the verb 'sağlar'
    ("yön", "sağlıklı bireylerde"),
    ("yön", "sağlar"),
    # 'sol' must not be satisfied by 'solunum'
    ("yön", "solunum sesleri"),
    ("yön", "proksimal tübülde"),

    # --- ions, symbols, comparisons ---
    ("iyon", "Na+ ve K+ dengesi"),
    ("iyon", "na+ artışı"),
    ("iyon", "Fe+3 birikimi"),
    ("iyon", "HCO3- düzeyi"),
    ("simge", "%40 oranında"),
    ("simge", "% 40 oranında"),
    ("simge", "< 90 mmHg"),
    ("simge", "≥ 140"),
    ("simge", "alfa ve β blokerler"),
    ("simge", "(+) sonuç"),
    ("simge", "test pozitif"),

    # --- hypo/hyper: one syllable inverts the meaning ---
    ("hipo_hiper", "hipokalemi gelişti"),
    ("hipo_hiper", "hiperkalemi gelişti"),

    # --- ASCII-fied Turkish: what an engine without ı ş ğ İ produces ---
    ("diakritiksiz", "sag bobrekte kitle"),
    ("diakritiksiz", "ilac kullanilmamalidir"),
    ("diakritiksiz", "gorulmemistir"),
    ("diakritiksiz", "hipokalemi gelismez"),
    ("diakritiksiz", "0,5 mg IM uygulanmaz"),

    # --- mixed and adversarial ---
    ("karışık", "Hiperkalemide EKG'de en erken bulgu sivri T dalgasıdır."),
    ("karışık", "Sağ akciğerde 2,5 cm nodül; sol tarafta bulgu yok."),
    ("karışık", "İLAÇ adrenalin 1 mg IV"),
    ("karışık", "noradrenalin infüzyonu"),
    ("boş", ""),
    ("boş", "   "),
]


def build_payload() -> dict:
    cases = []
    for group, sentence in SENTENCES:
        tokens = detect_critical_tokens(sentence)
        cases.append(
            {
                "group": group,
                "text": sentence,
                "expected": [
                    {
                        "text": token.text,
                        "tokenClass": token.token_class,
                        "start": token.start,
                        "end": token.end,
                    }
                    for token in tokens
                ],
            }
        )

    # The folded form of every sentence is a case in its own right: the two
    # implementations must agree there too, and that is exactly where a
    # `\w`/`\b` translation error would show up.
    folded = []
    for group, sentence in SENTENCES:
        text = fold_diacritics(sentence)
        tokens = detect_critical_tokens(text)
        folded.append(
            {
                "group": f"{group}_katlanmis",
                "text": text,
                "expected": [
                    {
                        "text": token.text,
                        "tokenClass": token.token_class,
                        "start": token.start,
                        "end": token.end,
                    }
                    for token in tokens
                ],
            }
        )

    return {
        "_comment": (
            "GENERATED by `python -m evals.ocr_eval.export_cases`. Expected "
            "values come from the Python detector, which is the reference. "
            "Both implementations are tested against this file."
        ),
        "cases": cases + folded,
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
                "Düzeltmek için: python -m evals.ocr_eval.export_cases",
                file=sys.stderr,
            )
            return 1
        print(f"{args.output} güncel.")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(payload, encoding="utf-8")
    print(f"Yazıldı: {args.output}  ({len(build_payload()['cases'])} vaka)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
