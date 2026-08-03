"""Aggregate human rubric scores into a corpus-level report (ANA-PLAN §23.3,
§25 Faz 3 exit gate).

`rubric.py` scores one card. This module is the missing next layer: reading a
file of scores for every card generated from the gold passages and reporting
how many landed in each verdict bucket. It deliberately does not invent a
single pass/fail number for the whole corpus — ANA-PLAN states the per-card
thresholds (§23.3) but not a corpus-wide acceptance percentage, and making one
up would violate §0.6 ("never a made-up number"). The distribution is printed
so the person running the gate (who has read §25's wording) decides.

Usage:
    python -m evals.card_quality.aggregate path/to/scores.json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from jsonschema import Draft202012Validator

from evals.card_quality.rubric import RubricResult, score_card

EVALS_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA_PATH = Path(__file__).resolve().parent / "scores.schema.json"


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def schema_errors(scores_file: dict, schema: dict) -> list[str]:
    validator = Draft202012Validator(schema)
    return [
        f"schema: {'/'.join(str(p) for p in err.absolute_path) or '<root>'}: {err.message}"
        for err in sorted(validator.iter_errors(scores_file), key=lambda e: list(e.absolute_path))
    ]


def consistency_errors(scores_file: dict) -> list[str]:
    """Rules a JSON Schema alone cannot express."""
    errors: list[str] = []
    seen_ids: set[str] = set()
    for entry in scores_file.get("entries", []):
        card_id = entry.get("cardId", "<no-id>")
        if card_id in seen_ids:
            errors.append(f"duplicate cardId: {card_id!r} — a card scored twice would double-count it")
        seen_ids.add(card_id)
    return errors


@dataclass(frozen=True)
class ScoredCard:
    card_id: str
    gold_passage_label: str | None
    result: RubricResult


@dataclass(frozen=True)
class CorpusSummary:
    total: int
    accept: int
    revise: int
    reject: int

    @property
    def accept_fraction(self) -> float:
        return self.accept / self.total if self.total else 0.0


def score_entries(scores_file: dict) -> list[ScoredCard]:
    """Runs every entry through `score_card`. Raises on the first malformed
    entry rather than silently skipping it — a corpus report built on top of
    data that quietly dropped a card would misrepresent the actual gate."""
    scored = []
    for entry in scores_file.get("entries", []):
        result = score_card(entry["scores"])
        scored.append(
            ScoredCard(
                card_id=entry["cardId"],
                gold_passage_label=entry.get("goldPassageLabel"),
                result=result,
            )
        )
    return scored


def summarize(scored: list[ScoredCard]) -> CorpusSummary:
    accept = sum(1 for s in scored if s.result.verdict == "accept")
    revise = sum(1 for s in scored if s.result.verdict == "revise")
    reject = sum(1 for s in scored if s.result.verdict == "reject")
    return CorpusSummary(total=len(scored), accept=accept, revise=revise, reject=reject)


def format_report(scored: list[ScoredCard], summary: CorpusSummary) -> str:
    lines = []
    for s in scored:
        label = f" ({s.gold_passage_label})" if s.gold_passage_label else ""
        lines.append(f"  {s.card_id}{label}: {s.result.total}/14 -> {s.result.verdict}")
    lines.append("")
    lines.append(
        f"Toplam {summary.total} kart: "
        f"{summary.accept} kabul, {summary.revise} inceleme, {summary.reject} ret "
        f"(kabul oranı %{summary.accept_fraction * 100:.0f})"
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scores", type=Path, help="Path to a card-quality-scores.json file")
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA_PATH)
    args = parser.parse_args(argv)

    scores_file = load_json(args.scores)
    schema = load_json(args.schema)

    errors = schema_errors(scores_file, schema)
    errors.extend(consistency_errors(scores_file))
    if errors:
        for error in errors:
            print(f"ERROR {error}")
        print(f"FAIL: {len(errors)} error(s)")
        return 1

    scored = score_entries(scores_file)
    summary = summarize(scored)
    print(format_report(scored, summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
