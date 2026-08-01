"""Validate the gold test-set manifest against its JSON Schema plus
consistency rules that a schema alone cannot express (ANA-PLAN §23.1).

Usage:
    python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json [--check-files]

Exit code 0 when the manifest is valid (warnings allowed), 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

EVALS_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA_PATH = EVALS_ROOT / "gold-manifest.schema.json"


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def schema_errors(manifest: dict, schema: dict) -> list[str]:
    validator = Draft202012Validator(schema)
    return [
        f"schema: {'/'.join(str(p) for p in err.absolute_path) or '<root>'}: {err.message}"
        for err in sorted(validator.iter_errors(manifest), key=lambda e: list(e.absolute_path))
    ]


def consistency_errors(manifest: dict, fixtures_root: Path | None = None) -> tuple[list[str], list[str]]:
    """Return (errors, warnings) for rules beyond the JSON Schema."""
    errors: list[str] = []
    warnings: list[str] = []
    entries = manifest.get("entries", [])

    seen_ids: set[str] = set()
    seen_paths: set[str] = set()
    category_counts: dict[str, int] = {}

    for entry in entries:
        eid = entry.get("id", "<no-id>")
        category_counts[entry.get("category", "?")] = category_counts.get(entry.get("category", "?"), 0) + 1

        if eid in seen_ids:
            errors.append(f"{eid}: duplicate entry id")
        seen_ids.add(eid)

        image_path = entry.get("imagePath", "")
        if image_path in seen_paths:
            errors.append(f"{eid}: duplicate imagePath {image_path!r}")
        seen_paths.add(image_path)

        if fixtures_root is not None and not (fixtures_root / image_path).is_file():
            errors.append(f"{eid}: image file not found: {image_path}")

        # Every gold critical token must literally occur in the transcription
        # or in a handwriting region — otherwise the annotation is inconsistent.
        haystacks = [entry.get("exactTranscription", "")]
        for hw in entry.get("handwriting", []):
            haystacks.append(hw.get("text", ""))
            haystacks.append(hw.get("expandedText", ""))
        for tok in entry.get("criticalTokens", []):
            token = tok.get("token", "")
            if token and not any(token.casefold() in h.casefold() for h in haystacks):
                errors.append(
                    f"{eid}: critical token {token!r} not found in transcription or handwriting"
                )

        gold_line_ids = {line.get("lineId") for line in entry.get("goldSelectedLines", [])}
        for card in entry.get("acceptableCards", []):
            for line_id in card.get("sourceLineIds", []):
                if line_id not in gold_line_ids:
                    errors.append(
                        f"{eid}: card references unknown sourceLineId {line_id!r}"
                    )

    for category, quota in manifest.get("categories", {}).items():
        target = quota.get("target", 0)
        have = category_counts.get(category, 0)
        annotated = sum(
            1
            for e in entries
            if e.get("category") == category and e.get("status") == "annotated"
        )
        if have < target:
            warnings.append(f"quota {category}: {have}/{target} collected ({annotated} annotated)")
        elif have > target:
            warnings.append(f"quota {category}: {have} exceeds target {target} (extra data is fine)")

    return errors, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="Path to gold-manifest.json")
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA_PATH)
    parser.add_argument(
        "--check-files",
        action="store_true",
        help="Also verify that every imagePath exists under evals/ (local fixtures)",
    )
    args = parser.parse_args(argv)

    manifest = load_json(args.manifest)
    schema = load_json(args.schema)

    errors = schema_errors(manifest, schema)
    fixtures_root = EVALS_ROOT if args.check_files else None
    consistency, warnings = consistency_errors(manifest, fixtures_root=fixtures_root)
    errors.extend(consistency)

    for warning in warnings:
        print(f"WARN  {warning}")
    for error in errors:
        print(f"ERROR {error}")

    total = len(manifest.get("entries", []))
    annotated = sum(1 for e in manifest.get("entries", []) if e.get("status") == "annotated")
    print(f"{'FAIL' if errors else 'OK'}: {total} entries ({annotated} annotated), "
          f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
