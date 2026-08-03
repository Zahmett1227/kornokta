"""The exported FSRS test-vector file must stay in step with its Python
source (same reasoning as `test_pattern_export.py`): editing the algorithm
without regenerating `fsrs-cases.json` would leave the Swift port tested
against yesterday's numbers while the Python suite checked today's."""

from __future__ import annotations

import json
from pathlib import Path

from evals.fsrs.export_cases import main as export_cases_main

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CASES_JSON = REPO_ROOT / "evals" / "shared" / "fsrs-cases.json"


def test_case_file_matches_its_source():
    assert export_cases_main(["--check"]) == 0, (
        "fsrs-cases.json güncel değil. Çalıştır: python -m evals.fsrs.export_cases"
    )


class TestSharedCases:
    def _cases(self):
        return json.loads(CASES_JSON.read_text(encoding="utf-8"))["cases"]

    def test_not_vacuous(self):
        assert len(self._cases()) >= 20

    def test_covers_every_rating(self):
        ratings = {case["input"]["rating"] for case in self._cases()}
        assert ratings == {1, 2, 3, 4}

    def test_covers_first_reviews_same_day_and_long_term(self):
        names = {case["name"] for case in self._cases()}
        assert any(n.startswith("first_") for n in names)
        assert any(n.startswith("same_day_") for n in names)
        assert any("60d" in n or "3d" in n for n in names)

    def test_covers_the_short_term_long_term_boundary(self):
        names = {case["name"] for case in self._cases()}
        assert "boundary_just_under_one_day" in names
        assert "boundary_exactly_one_day" in names
