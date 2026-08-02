import { describe, expect, it } from "vitest";

import { assertLlmOutput, validateLlmOutput } from "../schemas/validateLlmOutput.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";

/** A minimal but fully schema-conformant §14 response, cloned per test. */
function validOutput(): LlmOutput {
  return {
    schemaVersion: "1.0",
    requestId: "req_1",
    transcription: {
      exactText: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
      cleanText: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
      language: "tr",
      overallConfidence: 0.97,
      isHandwritten: false,
      selectedLineIds: ["line_04"],
      uncertainSpans: [],
    },
    knowledgeUnits: [
      {
        id: "ku_1",
        canonicalClaim: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
        mechanism: null,
        tags: ["Farmakoloji"],
        sourceConcern: null,
        requiresUserApproval: false,
      },
    ],
    cards: [
      {
        id: "card_1",
        knowledgeUnitId: "ku_1",
        type: "direct_recall",
        front: "Anafilakside ilk seçenek tedavi nedir?",
        back: "0,3–0,5 mg IM adrenalin.",
        explanation: "",
        sourceQuote: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
        sourceLineIds: ["line_04"],
        sourceFaithful: true,
        enriched: false,
        difficulty: 2,
        riskFlags: ["critical_number", "critical_unit"],
        requiresUserApproval: false,
      },
    ],
    quality: {
      sourceCoverage: 0.98,
      duplicateCardRisk: 0.05,
      medicalMeaningChangeRisk: 0.01,
      warnings: [],
    },
    usage: {
      provider: "openai",
      model: "gpt-5.6-sol",
      inputTokens: 120,
      outputTokens: 80,
      estimatedCostUSD: 0,
    },
  };
}

describe("validateLlmOutput", () => {
  it("accepts a fully conformant response", () => {
    expect(validateLlmOutput(validOutput())).toEqual({ valid: true, errors: [] });
  });

  it("rejects a missing top-level field", () => {
    const broken = validOutput() as Partial<LlmOutput>;
    delete broken.quality;
    const result = validateLlmOutput(broken);
    expect(result.valid).toBe(false);
    expect(result.errors.join(" ")).toContain("quality");
  });

  it("rejects an unknown risk flag rather than passing it through (§14 riskFlags enum)", () => {
    const broken = validOutput();
    // @ts-expect-error deliberately invalid for the test
    broken.cards[0]!.riskFlags = ["not_a_real_flag"];
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects an unknown card type", () => {
    const broken = validOutput();
    // @ts-expect-error deliberately invalid for the test
    broken.cards[0]!.type = "multiple_choice";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects additional properties a provider might add unbidden", () => {
    const broken = validOutput() as unknown as Record<string, unknown>;
    broken.unexpectedField = "sürpriz";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects confidence values outside 0..1", () => {
    const broken = validOutput();
    broken.transcription.overallConfidence = 1.5;
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects schemaVersion values other than the pinned one", () => {
    const broken = validOutput() as unknown as Record<string, unknown>;
    broken.schemaVersion = "2.0";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("does not crash on a completely unrelated shape", () => {
    expect(validateLlmOutput(null).valid).toBe(false);
    expect(validateLlmOutput("string").valid).toBe(false);
    expect(validateLlmOutput([1, 2, 3]).valid).toBe(false);
    expect(validateLlmOutput({}).valid).toBe(false);
  });
});

describe("assertLlmOutput", () => {
  it("does not throw for a valid response", () => {
    expect(() => assertLlmOutput(validOutput())).not.toThrow();
  });

  it("throws with the schema errors inlined, for a caller that wants to fail loudly", () => {
    const broken = validOutput() as Partial<LlmOutput>;
    delete broken.usage;
    expect(() => assertLlmOutput(broken)).toThrow(/§14 şemasına uymuyor/);
  });
});
