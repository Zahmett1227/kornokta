"""The generated artefacts must stay in step with their Python source.

`backend/providers/criticalTokenPatterns.json` and
`evals/shared/critical-token-cases.json` are produced from
`evals/ocr_eval/critical_tokens.py`. Editing the detector without regenerating
them would leave the backend running yesterday's rules while the eval suite
scored today's — the exact "one behaviour, two places, only one updated"
failure this arrangement exists to prevent.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from evals.ocr_eval.export_cases import main as export_cases_main
from evals.ocr_eval.export_gate_cases import main as export_gate_cases_main
from evals.ocr_eval.export_patterns import (
    JS_WORD_BOUNDARY,
    JS_WORD_CHAR,
    PatternTranslationError,
    main as export_patterns_main,
    to_javascript_source,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
PATTERNS_JSON = REPO_ROOT / "backend" / "providers" / "criticalTokenPatterns.json"
CASES_JSON = REPO_ROOT / "evals" / "shared" / "critical-token-cases.json"


class TestGeneratedFilesAreCurrent:
    def test_pattern_file_matches_its_source(self):
        assert export_patterns_main(["--check"]) == 0, (
            "criticalTokenPatterns.json güncel değil. "
            "Çalıştır: python -m evals.ocr_eval.export_patterns"
        )

    def test_gate_case_file_matches_its_source(self):
        assert export_gate_cases_main(["--check"]) == 0, (
            "gate-cases.json güncel değil. "
            "Çalıştır: python -m evals.ocr_eval.export_gate_cases"
        )

    def test_case_file_matches_its_source(self):
        assert export_cases_main(["--check"]) == 0, (
            "critical-token-cases.json güncel değil. "
            "Çalıştır: python -m evals.ocr_eval.export_cases"
        )


class TestTranslation:
    """The two constructs that genuinely differ between the engines."""

    def test_word_char_becomes_a_unicode_class(self):
        assert to_javascript_source(r"\w+") == f"{JS_WORD_CHAR}+"

    def test_word_boundary_becomes_lookarounds(self):
        assert to_javascript_source(r"\bsağ\b") == f"{JS_WORD_BOUNDARY}sağ{JS_WORD_BOUNDARY}"

    def test_word_char_inside_a_class_drops_the_brackets(self):
        # The bug this caught in review: substituting the bracketed form inside
        # a class produced `[[\p{L}\p{N}_]+-]`, which is a syntax error.
        translated = to_javascript_source(r"[\w+-]")
        assert translated == r"[\p{L}\p{N}_+-]"
        assert "[[" not in translated

    def test_backslash_b_inside_a_class_stays_a_backspace(self):
        assert to_javascript_source(r"[\b]") == r"[\b]"

    def test_other_escapes_pass_through(self):
        for source in [r"\d+", r"\s*", r"\.", r"\\", r"\(", r"[.,]"]:
            assert to_javascript_source(source) == source

    def test_an_escaped_backslash_is_not_read_as_an_escape(self):
        # `\\w` is a literal backslash followed by `w`, not `\w`.
        assert to_javascript_source(r"\\w") == r"\\w"

    def test_closing_bracket_as_first_class_member_is_literal(self):
        assert to_javascript_source(r"[]\w]") == r"[]\p{L}\p{N}_]"
        assert to_javascript_source(r"[^]\w]") == r"[^]\p{L}\p{N}_]"

    def test_negated_word_class_inside_a_class_is_refused_not_guessed(self):
        # Emitting anything here would silently change what the pattern
        # matches, so it fails loudly instead.
        with pytest.raises(PatternTranslationError):
            to_javascript_source(r"[\W]")

    def test_unclosed_class_is_refused(self):
        with pytest.raises(PatternTranslationError):
            to_javascript_source(r"[abc")


class TestGeneratedPatternFile:
    @pytest.fixture(scope="class")
    @classmethod
    def payload(cls):
        return json.loads(PATTERNS_JSON.read_text(encoding="utf-8"))

    def test_no_ascii_only_constructs_survive(self, payload):
        # `\w` and `\b` are ASCII-only in JavaScript. One surviving would make
        # the detector go quiet on Turkish text — silently, with no error.
        for entry in payload["patterns"]:
            assert not re.search(r"(?<!\\)\\w", entry["source"]), entry["tokenClass"]
            assert not re.search(r"(?<!\\)\\b(?![^\[]*\])", entry["source"]), entry["tokenClass"]

    def test_every_pattern_carries_the_unicode_flag(self, payload):
        # `\p{...}` is only recognised under `u`; without it every pattern
        # would throw at construction.
        for entry in payload["patterns"]:
            assert "u" in entry["flags"], entry["tokenClass"]

    def test_every_pattern_compiles_as_a_javascript_regex(self, payload):
        """Checked here as well as in the backend suite, so a broken export
        fails in the repo that produced it rather than only downstream."""
        for entry in payload["patterns"]:
            # Balanced-bracket check: the failure mode already seen was an
            # unbalanced `[[`, which Python's own engine would also reject.
            source = entry["source"]
            depth = 0
            index = 0
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == "[":
                    depth += 1
                    assert depth == 1, f"{entry['tokenClass']}: iç içe [ — {source}"
                elif source[index] == "]" and depth:
                    depth -= 1
                index += 1
            assert depth == 0, f"{entry['tokenClass']}: kapanmamış [ — {source}"

    def test_carries_the_route_vocabulary(self, payload):
        from evals.ocr_eval.critical_tokens import ROUTE_SYNONYMS

        assert set(payload["routeSynonyms"]) == set(ROUTE_SYNONYMS)
        for code, surfaces in ROUTE_SYNONYMS.items():
            assert payload["routeSynonyms"][code] == list(surfaces)


class TestSharedCases:
    @pytest.fixture(scope="class")
    @classmethod
    def cases(cls):
        return json.loads(CASES_JSON.read_text(encoding="utf-8"))["cases"]

    def test_python_still_produces_the_frozen_expectations(self, cases):
        """The reference must agree with the file it generated. This fails if
        the detector changed and the file was not regenerated."""
        from evals.ocr_eval.critical_tokens import detect_critical_tokens

        for case in cases:
            actual = [
                {
                    "text": token.text,
                    "tokenClass": token.token_class,
                    "start": token.start,
                    "end": token.end,
                }
                for token in detect_critical_tokens(case["text"])
            ]
            assert actual == case["expected"], case["text"]

    def test_the_list_is_not_vacuous(self, cases):
        assert len(cases) > 50
        assert sum(1 for case in cases if case["expected"]) > 30

    def test_covers_the_classes_a_wrong_reading_harms_most(self, cases):
        found = {token["tokenClass"] for case in cases for token in case["expected"]}
        for required in ("route", "negation_pair", "laterality", "number_decimal", "unit"):
            assert required in found, f"{required} sınıfı hiçbir vakada yok"

    def test_includes_ascii_fied_turkish(self, cases):
        # The engine we replaced could not write ı ş ğ İ at all, and the
        # detector has to keep working on output like that.
        folded = [case for case in cases if case["group"].endswith("_katlanmis")]
        assert len(folded) > 20
        assert any(case["expected"] for case in folded)
