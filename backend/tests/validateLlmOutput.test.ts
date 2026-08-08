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
    // Was "multiple_choice" until schema v2.1 made that a real type (§13.3).
    // @ts-expect-error deliberately invalid for the test
    broken.cards[0]!.type = "true_false";
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("accepts a five-option multiple-choice card (v2.1)", () => {
    const output = validOutput();
    output.schemaVersion = "2.1";
    output.cards[0]!.type = "multiple_choice";
    output.cards[0]!.options = [
      { text: "Hipokalemi", correct: true, why: "" },
      { text: "Hiperkalemi", correct: false, why: "EKG'de sivri T dalgası yapar." },
      { text: "Hiponatremi", correct: false, why: "Sodyum tablosu farklıdır." },
      { text: "Hipokalsemi", correct: false, why: "Tetani ön plandadır." },
      { text: "Hipomagnezemi", correct: false, why: "Eşlik eder ama tablo bu değildir." },
    ];
    output.cards[0]!.correctOption = 0;
    expect(validateLlmOutput(output)).toEqual({ valid: true, errors: [] });
  });

  it("rejects a multiple-choice card with the wrong number of options", () => {
    const broken = validOutput();
    broken.cards[0]!.type = "multiple_choice";
    broken.cards[0]!.options = [
      { text: "A", correct: true, why: "" },
      { text: "B", correct: false, why: "yanlış" },
    ];
    broken.cards[0]!.correctOption = 0;
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("rejects an out-of-range correctOption", () => {
    const broken = validOutput();
    broken.cards[0]!.correctOption = 5;
    expect(validateLlmOutput(broken).valid).toBe(false);
  });

  it("accepts a v2.2 card with a topic, and a topicless v2.1 payload stays valid", () => {
    const withTopic = validOutput();
    withTopic.schemaVersion = "2.2";
    withTopic.cards[0]!.topic = "İnflamasyon";
    expect(validateLlmOutput(withTopic)).toEqual({ valid: true, errors: [] });

    withTopic.cards[0]!.topic = null;
    expect(validateLlmOutput(withTopic)).toEqual({ valid: true, errors: [] });

    // Backward compatibility: a pre-topic payload (no `topic` key at all)
    // must keep validating — old results stored in job rows are re-read.
    const legacy = validOutput();
    legacy.schemaVersion = "2.1";
    expect(validateLlmOutput(legacy)).toEqual({ valid: true, errors: [] });
  });

  it("rejects a non-string topic", () => {
    const broken = validOutput() as unknown as { cards: Array<Record<string, unknown>> };
    broken.cards[0]!.topic = 42;
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
