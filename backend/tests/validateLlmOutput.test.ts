import { describe, expect, it } from "vitest";

import { assertLlmOutput, validateLlmOutput } from "../schemas/validateLlmOutput.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";

/** A minimal but fully schema-conformant v2 response, cloned per test. */
function validOutput(): LlmOutput {
  return {
    schemaVersion: "2.0",
    requestId: "req_1",
    readText: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
    cards: [
      {
        id: "card_1",
        type: "direct_recall",
        front: "Anafilakside ilk seçenek tedavi nedir?",
        back: "0,3–0,5 mg IM adrenalin.",
        explanation: "",
        difficulty: 2,
        tags: ["Farmakoloji"],
        lowConfidence: false,
      },
    ],
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
    delete broken.cards;
    const result = validateLlmOutput(broken);
    expect(result.valid).toBe(false);
    expect(result.errors.join(" ")).toContain("cards");
  });

  it("rejects an unknown card type", () => {
    const broken = validOutput();
    // @ts-expect-error deliberately invalid for the test
    broken.cards[0]!.type = "multiple_choice";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects a difficulty outside 1..5", () => {
    const broken = validOutput();
    broken.cards[0]!.difficulty = 9;
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects an empty front (schema minLength 1)", () => {
    const broken = validOutput();
    broken.cards[0]!.front = "";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects additional properties a provider might add unbidden", () => {
    const broken = validOutput() as unknown as Record<string, unknown>;
    broken.unexpectedField = "sürpriz";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects a non-boolean lowConfidence", () => {
    const broken = validOutput() as unknown as { cards: Array<Record<string, unknown>> };
    broken.cards[0]!.lowConfidence = "evet";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects schemaVersion values other than the pinned v2 one", () => {
    const broken = validOutput() as unknown as Record<string, unknown>;
    broken.schemaVersion = "1.0";
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
