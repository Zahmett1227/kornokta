"""Minimal coverage for the AppleVisionSpike report reader.

Deliberately small — the gate measures themselves are tested elsewhere; this
only checks that Vision output is wired to the manifest correctly.
"""

from __future__ import annotations

import json

import pytest

from evals.ocr_eval.vision_report import index_manifest, main, score_page

GOLD_TEXT = "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir."

ENTRY = {
    "id": "gold_001",
    "category": "printed_highlight",
    "imagePath": "fixtures/highlight/a.jpg",
    "status": "annotated",
    "exactTranscription": GOLD_TEXT,
    "criticalTokens": [
        {"token": "0,3–0,5", "tokenClass": "number_decimal"},
        {"token": "mg", "tokenClass": "unit"},
        {"token": "IM", "tokenClass": "route"},
    ],
}


def page_with(text: str) -> dict:
    return {
        "imagePath": "/Users/x/kornokta/evals/fixtures/highlight/a.jpg",
        "elapsedMs": 120,
        "lines": [{"lineId": "line_00", "text": text, "confidence": 0.95}],
    }


class TestIndexManifest:
    def test_only_annotated_entries_are_indexed(self):
        manifest = {"entries": [ENTRY, {**ENTRY, "id": "gold_002", "status": "pending",
                                        "imagePath": "fixtures/highlight/b.jpg"}]}
        assert set(index_manifest(manifest)) == {"a.jpg"}


class TestScorePage:
    def test_perfect_reading_passes_the_gate(self):
        result = score_page(page_with(GOLD_TEXT), ENTRY)
        assert result["gate_passes"]
        assert result["cer"] == 0.0

    def test_route_change_fails_the_gate(self):
        result = score_page(page_with(GOLD_TEXT.replace("IM", "IV")), ENTRY)
        assert not result["gate_passes"]

    def test_lost_decimal_fails_the_gate(self):
        result = score_page(page_with(GOLD_TEXT.replace("0,3–0,5", "3–5")), ENTRY)
        assert not result["gate_passes"]
        assert result["critical_missing_rate"] > 0.0


class TestCli:
    def _write(self, tmp_path, page_text):
        vision = tmp_path / "vision.json"
        vision.write_text(json.dumps({"generatedBy": "test", "pages": [page_with(page_text)]}),
                          encoding="utf-8")
        manifest = tmp_path / "manifest.json"
        manifest.write_text(json.dumps({"entries": [ENTRY]}), encoding="utf-8")
        return vision, manifest

    def test_exit_zero_when_every_page_passes(self, tmp_path):
        vision, manifest = self._write(tmp_path, GOLD_TEXT)
        assert main([str(vision), "--manifest", str(manifest)]) == 0

    def test_exit_two_when_a_page_fails(self, tmp_path):
        vision, manifest = self._write(tmp_path, GOLD_TEXT.replace("IM", "IV"))
        assert main([str(vision), "--manifest", str(manifest)]) == 2

    def test_exit_one_when_nothing_matches(self, tmp_path, capsys):
        vision = tmp_path / "vision.json"
        vision.write_text(json.dumps({"pages": [
            {"imagePath": "/x/unknown.jpg", "lines": []}
        ]}), encoding="utf-8")
        manifest = tmp_path / "manifest.json"
        manifest.write_text(json.dumps({"entries": [ENTRY]}), encoding="utf-8")
        assert main([str(vision), "--manifest", str(manifest)]) == 1
