import copy
import json
from pathlib import Path

from jsonschema import Draft202012Validator

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCHEMA_PATH = REPO_ROOT / "backend" / "schemas" / "llm_output.schema.json"


def load_schema():
    with open(SCHEMA_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def sample_payload():
    """Canonical §14 example, minimally filled."""
    return {
        "schemaVersion": "1.0",
        "requestId": "req-0001",
        "transcription": {
            "exactText": "Hiperkalemide EKG'de en erken bulgu sivri T dalgasıdır.",
            "cleanText": "Hiperkalemide EKG'de en erken bulgu sivri T dalgasıdır.",
            "language": "tr",
            "overallConfidence": 0.97,
            "isHandwritten": False,
            "selectedLineIds": ["line_07"],
            "uncertainSpans": [
                {
                    "text": "0,1",
                    "alternatives": ["0,1", "1"],
                    "reason": "decimal_disagreement",
                    "critical": True,
                    "requiresUserConfirmation": True,
                }
            ],
        },
        "knowledgeUnits": [
            {
                "id": "ku_1",
                "canonicalClaim": "Hiperkalemide EKG'deki en erken bulgu sivri T dalgasıdır.",
                "mechanism": None,
                "tags": ["Dahiliye", "Elektrolit bozuklukları"],
                "sourceConcern": None,
                "requiresUserApproval": False,
            }
        ],
        "cards": [
            {
                "id": "card_1",
                "knowledgeUnitId": "ku_1",
                "type": "direct_recall",
                "front": "Hiperkalemide EKG'deki en erken bulgu nedir?",
                "back": "Sivri T dalgası.",
                "explanation": "",
                "sourceQuote": "Hiperkalemide EKG'de en erken bulgu sivri T dalgasıdır.",
                "sourceLineIds": ["line_07"],
                "sourceFaithful": True,
                "enriched": False,
                "difficulty": 2,
                "riskFlags": [],
                "requiresUserApproval": False,
            }
        ],
        "quality": {
            "sourceCoverage": 0.98,
            "duplicateCardRisk": 0.05,
            "medicalMeaningChangeRisk": 0.01,
            "warnings": [],
        },
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

    def test_unknown_risk_flag_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["riskFlags"] = ["made_up_flag"]
        assert errors_for(payload)

    def test_all_spec_risk_flags_accepted(self):
        spec_flags = [
            "ocr_disagreement", "handwriting_uncertain", "critical_number",
            "critical_unit", "negation_risk", "symbol_risk", "drug_name_risk",
            "organism_name_risk", "source_insufficient", "source_possible_error",
            "model_added_information", "duplicate_card", "ambiguous_question",
            "multiple_possible_answers",
        ]
        payload = sample_payload()
        payload["cards"][0]["riskFlags"] = spec_flags
        assert errors_for(payload) == []

    def test_unknown_card_type_rejected(self):
        payload = sample_payload()
        payload["cards"][0]["type"] = "multiple_choice"
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

    def test_max_three_alternatives_per_uncertain_span(self):
        # §15.3: her uyuşmazlık için en fazla üç aday.
        payload = sample_payload()
        payload["transcription"]["uncertainSpans"][0]["alternatives"] = ["a", "b", "c", "d"]
        assert errors_for(payload)
