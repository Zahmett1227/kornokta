"""Model comparison harness skeleton (ANA-PLAN §27).

Runs the same gold passages through candidate models and scores them on the
§27 dimensions. Faz 0 deliverable: the *harness*. Live provider calls are
intentionally NOT implemented here — each provider adapter raises until wired
up in Faz 3, so this script cannot leak keys or spend budget by accident.

    python -m evals.spikes.provider_compare.run --dry-run   # no keys needed
    python -m evals.spikes.provider_compare.run --live      # requires env keys (Faz 3)

Keys are read ONLY from the environment variables named in config.json
(§0.7, §11.3). Nothing is written to the repo.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

CONFIG_PATH = Path(__file__).with_name("config.json")


def load_config(path: Path | str = CONFIG_PATH) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def key_status(cfg: dict) -> dict[str, bool]:
    """Report which candidates *could* run, based on env presence only.

    Never prints or returns the key value — presence (bool) only.
    """
    status: dict[str, bool] = {}
    for cand in cfg["candidates"]:
        status[cand["key"]] = bool(os.environ.get(cand["apiKeyEnv"]))
    status["ocr:" + cfg["ocr"]["provider"]] = bool(os.environ.get(cfg["ocr"]["credentialsEnv"]))
    return status


def call_provider(candidate: dict, image_bytes: bytes, ocr_candidates: dict) -> dict:
    """Adapter boundary — implemented per provider in Faz 3.

    Kept as an explicit NotImplementedError so a --live run fails loudly
    instead of silently doing nothing.
    """
    raise NotImplementedError(
        f"Provider adapter for {candidate['provider']}:{candidate['model']} "
        "is a Faz 3 deliverable. See backend/providers/."
    )


def run_dry(cfg: dict) -> int:
    print("Model comparison harness — DRY RUN (no API calls, no keys required)\n")
    print("Candidates (ANA-PLAN §27):")
    status = key_status(cfg)
    for cand in cfg["candidates"]:
        have = "key present" if status[cand["key"]] else "no key in env"
        print(f"  - {cand['key']:24} {cand['provider']}:{cand['model']:20} "
              f"[{cand['role']}]  ({have})")
    print(f"\nOCR: {cfg['ocr']['provider']} "
          f"({'creds present' if status['ocr:' + cfg['ocr']['provider']] else 'no creds in env'})")
    print("\nEvaluation dimensions:")
    for dim in cfg["evaluationDimensions"]:
        print(f"  - {dim}")
    print("\nDry run OK. Live comparison (--live) is a Faz 3 deliverable; "
          "provider adapters are not yet implemented.")
    return 0


def run_live(cfg: dict) -> int:
    print("ERROR: --live not available in Faz 0.", file=sys.stderr)
    print("Provider adapters (backend/providers/) are implemented in Faz 3; "
          "wire call_provider() then remove this guard.", file=sys.stderr)
    return 3


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--dry-run", action="store_true", help="Describe the plan without calling anything")
    group.add_argument("--live", action="store_true", help="Run real comparison (Faz 3)")
    parser.add_argument("--config", type=Path)
    args = parser.parse_args(argv)

    cfg = load_config(args.config) if args.config else load_config()
    if args.live:
        return run_live(cfg)
    return run_dry(cfg)


if __name__ == "__main__":
    sys.exit(main())
