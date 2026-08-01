"""Guard against config keys that promise behaviour the code never reads.

A threshold sitting in config.json while no code consults it is worse than no
threshold at all: reviewers, and the docs, read it as an active safety check.
`maxComponentThicknessRatio` shipped exactly that way — declared, documented as
the geometry guard, and never loaded — so this test exists to keep it from
happening again.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

SPIKES_ROOT = Path(__file__).resolve().parent.parent / "spikes"
CONFIGS = sorted(SPIKES_ROOT.glob("*/config.json"))


def leaf_keys(node, prefix=""):
    """Yield (dotted_path, key, value) for every non-comment leaf setting."""
    for key, value in node.items():
        if key.startswith("_"):  # documentation-only entries
            continue
        if isinstance(value, dict):
            yield from leaf_keys(value, f"{prefix}{key}.")
        elif isinstance(value, list):
            continue  # lists are data (candidates, dimensions), not thresholds
        else:
            yield f"{prefix}{key}", key, value


def module_source(config_path: Path) -> str:
    return "".join(p.read_text(encoding="utf-8") for p in config_path.parent.glob("*.py"))


def test_configs_found():
    assert CONFIGS, "no spike config.json files discovered"


@pytest.mark.parametrize("config_path", CONFIGS, ids=lambda p: p.parent.name)
def test_every_setting_is_read_by_its_spike(config_path: Path):
    config = json.loads(config_path.read_text(encoding="utf-8"))
    source = module_source(config_path)

    unread = [
        dotted
        for dotted, key, _ in leaf_keys(config)
        if f'"{key}"' not in source and f"'{key}'" not in source
    ]
    assert not unread, (
        f"{config_path.parent.name}/config.json declares settings no code reads: "
        f"{unread}. Either consume them or remove them — a dormant threshold "
        f"reads as an active safety check."
    )


@pytest.mark.parametrize("config_path", CONFIGS, ids=lambda p: p.parent.name)
def test_no_secret_values_in_config(config_path: Path):
    """Configs may name env vars but must never carry key material (§0.7)."""
    raw = config_path.read_text(encoding="utf-8")
    for marker in ("sk-", "AIza", "-----BEGIN", "Bearer "):
        assert marker not in raw, f"{config_path} appears to contain a secret ({marker!r})"
