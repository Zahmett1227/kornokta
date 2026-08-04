import json
from pathlib import Path

from jsonschema import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "backend" / "schemas" / "llm_output.schema.json"


def load_schema():
    with open(SCHEMA_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def sample_payload():
    """Canonical v2 example (Faz 6, docs/FAZ6-PLAN.md §6), minimally filled."""
    return {
        "schemaVersion": "2.0",
        "requestId": "req-0001",
        "readText": "Hiperkalemide EKG'de en erken bulgu sivri T dalgasıdır.",
        "cards": [
            {
                "id": "card_1",
                "type": "direct_recall",
                "front": "Hiperkalemide EKG'deki en erken bulgu nedir?",
                "back": "Sivri T dalgası.",
                "explanation": "",
                "difficulty": 2,
                "tags": ["Dahiliye", "Elektrolit bozuklukları"],
                "lowConfidence": False,
            }
        ],
        "usage": {
            "provider": "openai",
            "model": "gpt-5.6-sol",
            "inputTokens": 1200,
            "outputTokens": 420,
            "estimatedCostUSD": 0.011,
        },
    }


def errors_for(payload):
    validator = Draft202012Validator(load_schema())
    return list(validator.iter_errors(payload))


class TestLlmOutputSchema:
    def test_canonical_payload_valid(self):
        assert errors_for(sample_payload()) == []

    def test_unknown_card_type_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["type"] = "multiple_choice"
        assert errors_for(payload)

    def test_difficulty_out_of_range_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["difficulty"] = 9
        assert errors_for(payload)

    def test_empty_front_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["front"] = ""
        assert errors_for(payload)

    def test_missing_usage_rejected(self):
        payload = sample_payload()
        del payload["usage"]
        assert errors_for(payload)

    def test_extra_field_rejected(self):
        # Providers must not smuggle undeclared fields past validation (§14).
        payload = sample_payload()
        payload["cards"][0]["hallucinatedField"] = True
        assert errors_for(payload)

    def test_non_boolean_low_confidence_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["lowConfidence"] = "evet"
        assert errors_for(payload)

    def test_pinned_schema_version(self):
        payload = sample_payload()
        payload["schemaVersion"] = "1.0"
        assert errors_for(payload)

    def test_risk_flag_def_retained_for_rollback(self):
        # The riskFlag $def is intentionally kept (SAFE_MODE / anti-drift sync
        # tests) even though the v2 card no longer references it.
        assert "riskFlag" in load_schema()["$defs"]
