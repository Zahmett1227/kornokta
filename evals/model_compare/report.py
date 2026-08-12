"""Joins a blind quality scoring against the model that actually produced each
card, and puts the result next to what each model cost.

This is the second half of the model comparison (`npm run compare` in
`backend/` is the first). That script measures the money exactly, from the
providers' own reported token counts. It cannot measure whether the cheaper
tier reads faint highlighter and margin handwriting as well on *these* pages —
no published benchmark covers that, and the only honest answer comes from the
owner scoring cards against the §23.3 rubric.

Scoring happens blind, against `blind-<stamp>.json`, which carries no model
attribution. This module is what un-blinds it. The order matters and is the
whole methodology: a borderline card graded while knowing it came from the
cheap tier is not evidence, and every card in a comparison worth running is
borderline by construction — nobody switches tiers over an obvious collapse.

Usage:
    python -m evals.model_compare.report \\
        --scores evals/reports/scores.json \\
        --key evals/reports/key-<stamp>.json \\
        --report evals/reports/compare-<stamp>.json

Deliberately prints no verdict. §23.3 fixes the per-card thresholds; it does
not say how much quality a 60% saving is worth, and inventing that trade-off
would be exactly the kind of made-up number §0.6 forbids. The two columns go
side by side and the owner decides.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from evals.card_quality.aggregate import ScoredCard, score_entries
from evals.card_quality.rubric import MAX_TOTAL


@dataclass(frozen=True)
class ModelQuality:
    model: str
    total: int
    accept: int
    revise: int
    reject: int
    mean_score: float

    @property
    def accept_fraction(self) -> float:
        return self.accept / self.total if self.total else 0.0


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def card_key(key_file: dict) -> dict[str, str]:
    """cardId → model, from either key-file shape.

    The file grew a second mapping (`byPageLabel`) when the perception round
    was added, and a key written before that is a bare cardId → model object.
    Both are read rather than one being migrated: these files are experiment
    records, and rewriting a record after the fact is how a comparison quietly
    stops being reproducible.
    """
    by_card = key_file.get("byCard")
    return by_card if isinstance(by_card, dict) else key_file


def group_by_model(scored: list[ScoredCard], key: dict[str, str]) -> dict[str, list[ScoredCard]]:
    """Buckets scored cards by the model that produced them.

    A card id missing from the key is an error, not something to skip: it means
    the scores and the key are from different runs, and quietly dropping it
    would report a comparison over a subset nobody chose.
    """
    grouped: dict[str, list[ScoredCard]] = {}
    unknown = [card.card_id for card in scored if card.card_id not in key]
    if unknown:
        raise SystemExit(
            "Bu kart kimlikleri anahtarda yok — puanlar ve anahtar farklı koşulardan olabilir:\n  "
            + "\n  ".join(unknown[:10])
            + (f"\n  … ve {len(unknown) - 10} tane daha" if len(unknown) > 10 else "")
        )
    for card in scored:
        grouped.setdefault(key[card.card_id], []).append(card)
    return grouped


def quality_of(model: str, cards: list[ScoredCard]) -> ModelQuality:
    accept = sum(1 for card in cards if card.result.verdict == "accept")
    revise = sum(1 for card in cards if card.result.verdict == "revise")
    reject = sum(1 for card in cards if card.result.verdict == "reject")
    mean = sum(card.result.total for card in cards) / len(cards) if cards else 0.0
    return ModelQuality(
        model=model, total=len(cards), accept=accept, revise=revise, reject=reject, mean_score=mean
    )


def format_report(qualities: list[ModelQuality], cost_rows: dict[str, dict]) -> str:
    lines = ["Model karşılaştırması — kalite ve maliyet yan yana", ""]

    for quality in sorted(qualities, key=lambda q: q.model):
        cost = cost_rows.get(quality.model, {})
        total_cost = cost.get("totalCostUSD")
        per_page = cost.get("costPerPageUSD")
        failed = cost.get("failed")

        lines.append(f"  {quality.model}")
        lines.append(
            f"    kalite : {quality.total} kart · ortalama {quality.mean_score:.1f}/{MAX_TOTAL} · "
            f"{quality.accept} kabul / {quality.revise} inceleme / {quality.reject} ret "
            f"(kabul %{quality.accept_fraction * 100:.0f})"
        )
        if total_cost is not None:
            # A model that fails often is not cheap: failed calls are priced
            # into the total, exactly as the app's own ledger prices them.
            failure_note = f" · {failed} başarısız çağrı" if failed else ""
            lines.append(
                f"    maliyet: ${total_cost:.4f} toplam · ${per_page:.4f}/sayfa{failure_note}"
            )
            if quality.total:
                lines.append(f"    kabul edilen kart başına: ${cost_per_accept(cost, quality):.4f}")
        else:
            lines.append("    maliyet: raporda bu model yok")
        if cost.get("pricesInherited"):
            lines.append(
                "    ⚠ bu modele kendi fiyatı verilmemiş; maliyet .env'deki tek fiyat setinden "
                "hesaplandı ve karşılaştırılabilir değil"
            )
        lines.append("")

    lines.append(
        "Bu rapor kasten bir karar vermiyor. §23.3 kart başına eşikleri koyar; "
        "bir tasarrufun ne kadar kaliteye değdiğini söylemez (§0.6)."
    )
    return "\n".join(lines)


def cost_per_accept(cost: dict, quality: ModelQuality) -> float:
    """Money divided by cards that actually passed the rubric.

    The number the raw per-page cost hides: a tier that is half the price but
    produces a third as many usable cards is not cheaper, and the two totals on
    their own would say it was. Falls back to the plain total when nothing was
    accepted, rather than dividing by zero.
    """
    total = cost.get("totalCostUSD", 0.0)
    return total / quality.accept if quality.accept else total


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scores", type=Path, required=True, help="Rubrik puanları (§23.3 şeması)")
    parser.add_argument("--key", type=Path, required=True, help="cardId → model (compare çıktısı)")
    parser.add_argument("--report", type=Path, help="compare-<stamp>.json; maliyet buradan okunur")
    args = parser.parse_args(argv)

    scored = score_entries(load_json(args.scores))
    if not scored:
        print("Puan dosyasında kart yok.", file=sys.stderr)
        return 1

    key = card_key(load_json(args.key))
    grouped = group_by_model(scored, key)
    qualities = [quality_of(model, cards) for model, cards in grouped.items()]

    cost_rows: dict[str, dict] = {}
    if args.report:
        report = load_json(args.report)
        cost_rows = {row["model"]: row for row in report.get("perModel", [])}

    print(format_report(qualities, cost_rows))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
