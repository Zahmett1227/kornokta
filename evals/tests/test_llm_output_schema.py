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
        # Was "multiple_choice" until schema v2.1 made that a real type (§13.3).
        payload["cards"][0]["type"] = "true_false"
        assert errors_for(payload)

    def test_five_option_card_valid(self):
        """§13.3: five options, exactly one correct, a reason on each wrong one."""
        payload = sample_payload()
        payload["schemaVersion"] = "2.1"
        payload["cards"][0]["type"] = "multiple_choice"
        payload["cards"][0]["options"] = [
            {"text": "Sivri T dalgası", "correct": True, "why": ""},
            {"text": "U dalgası", "correct": False, "why": "Hipokalemide görülür."},
            {"text": "Delta dalgası", "correct": False, "why": "WPW bulgusudur."},
            {"text": "Osborn dalgası", "correct": False, "why": "Hipotermide görülür."},
            {"text": "Epsilon dalgası", "correct": False, "why": "ARVD bulgusudur."},
        ]
        payload["cards"][0]["correctOption"] = 0
        assert errors_for(payload) == []

    def test_wrong_option_count_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["type"] = "multiple_choice"
        payload["cards"][0]["options"] = [
            {"text": "A", "correct": True, "why": ""},
            {"text": "B", "correct": False, "why": "yanlış"},
        ]
        payload["cards"][0]["correctOption"] = 0
        assert errors_for(payload)

    def test_correct_option_out_of_range_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["correctOption"] = 5
        assert errors_for(payload)

    def test_plain_card_may_omit_the_option_fields(self):
        """A v2.0 payload predates them and must stay valid (kanonik şemada
        isteğe bağlı; modele giden katı sürümde zorunlu)."""
        assert errors_for(sample_payload()) == []

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
