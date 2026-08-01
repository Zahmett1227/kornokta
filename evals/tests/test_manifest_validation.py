import copy
import json
from pathlib import Path

from evals.ocr_eval.validate_manifest import (
    DEFAULT_SCHEMA_PATH,
    consistency_errors,
    load_json,
    schema_errors,
)

EVALS_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = EVALS_ROOT / "gold-manifest.json"


def load_fixtures():
    return load_json(MANIFEST_PATH), load_json(DEFAULT_SCHEMA_PATH)


class TestStarterManifest:
    def test_schema_valid(self):
        manifest, schema = load_fixtures()
        assert schema_errors(manifest, schema) == []

    def test_consistency_valid(self):
        manifest, _ = load_fixtures()
        errors, _warnings = consistency_errors(manifest)
        assert errors == []

    def test_quota_targets_sum_to_at_least_100(self):
        manifest, _ = load_fixtures()
        total = sum(q["target"] for q in manifest["categories"].values())
        assert total >= 100  # ANA-PLAN §23.1


class TestSchemaRejections:
    def test_unknown_category_rejected(self):
        manifest, schema = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"][0]["category"] = "selfie"
        assert schema_errors(broken, schema)

    def test_annotated_entry_needs_two_cards(self):
        manifest, schema = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"][0]["acceptableCards"] = broken["entries"][0]["acceptableCards"][:1]
        assert schema_errors(broken, schema)

    def test_invalid_reject_reason(self):
        manifest, schema = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"][0]["rejectCardExamples"][0]["rejectReason"] = "just_bad"
        assert schema_errors(broken, schema)

    def test_image_path_must_be_under_fixtures(self):
        manifest, schema = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"][0]["imagePath"] = "/tmp/leak.png"
        assert schema_errors(broken, schema)

    def test_pending_entry_may_be_sparse(self):
        manifest, schema = load_fixtures()
        extended = copy.deepcopy(manifest)
        extended["entries"].append({
            "id": "gold_099",
            "category": "poor_capture",
            "imagePath": "fixtures/poor/img_099.jpg",
            "status": "pending",
            "expectedOutcome": "reject",
            "goldSelectedLines": [],
            "exactTranscription": "",
            "criticalTokens": [],
            "handwriting": [],
            "acceptableCards": [],
            "rejectCardExamples": [],
        })
        assert schema_errors(extended, schema) == []


class TestConsistencyRules:
    def test_duplicate_id_detected(self):
        manifest, _ = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"].append(copy.deepcopy(broken["entries"][0]))
        errors, _ = consistency_errors(broken)
        assert any("duplicate entry id" in e for e in errors)

    def test_phantom_critical_token_detected(self):
        manifest, _ = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"][0]["criticalTokens"].append(
            {"token": "amiodaron", "tokenClass": "drug_name"}
        )
        errors, _ = consistency_errors(broken)
        assert any("amiodaron" in e for e in errors)

    def test_unknown_source_line_id_detected(self):
        manifest, _ = load_fixtures()
        broken = copy.deepcopy(manifest)
        broken["entries"][0]["acceptableCards"][0]["sourceLineIds"] = ["line_99"]
        errors, _ = consistency_errors(broken)
        assert any("line_99" in e for e in errors)

    def test_missing_image_reported_when_checking_files(self, tmp_path):
        manifest, _ = load_fixtures()
        errors, _ = consistency_errors(manifest, fixtures_root=tmp_path)
        assert all("image file not found" in e for e in errors)
        assert len(errors) == len(manifest["entries"])
