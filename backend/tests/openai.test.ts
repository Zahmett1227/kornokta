import { describe, expect, it } from "vitest";

import type { OpenAIConfig } from "../config.js";
import { CARD_GENERATION_SYSTEM_PROMPT } from "../prompts/cardGeneration.js";
import {
  OpenAICardGenerator,
  OpenAIError,
  buildModelResponseSchema,
  estimateOpenAICostUSD,
  type Transport,
} from "../providers/openai.js";

const CONFIG: OpenAIConfig = {
  model: "gpt-5.6-sol",
  reasoningEffort: "low",
  maxOutputTokens: 700,
  maxCardsPerKnowledgeUnit: 4,
  timeoutMs: 1_000,
};

const COST = { openaiUsdPerMillionInputTokens: 2, openaiUsdPerMillionOutputTokens: 8 };

const REQUEST = {
  requestId: "req_1",
  image: new Uint8Array([1, 2, 3]),
  mimeType: "image/jpeg",
  cleanText: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
  selectedLineIds: ["line_04"],
  isHandwritten: false,
};

/** The shape the model itself must produce: the full contract minus usage/requestId. */
function modelOutput(overrides: Record<string, unknown> = {}) {
  return {
    schemaVersion: "1.0",
    transcription: {
      exactText: REQUEST.cleanText,
      cleanText: REQUEST.cleanText,
      language: "tr",
      overallConfidence: 0.97,
      isHandwritten: false,
      selectedLineIds: ["line_04"],
      uncertainSpans: [],
    },
    knowledgeUnits: [
      {
        id: "ku_1",
        canonicalClaim: REQUEST.cleanText,
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
        sourceQuote: REQUEST.cleanText,
        sourceLineIds: ["line_04"],
        sourceFaithful: true,
        enriched: false,
        difficulty: 2,
        riskFlags: [],
        requiresUserApproval: false,
      },
    ],
    quality: { sourceCoverage: 0.98, duplicateCardRisk: 0.05, medicalMeaningChangeRisk: 0.01, warnings: [] },
    ...overrides,
  };
}

/** Wraps a model JSON payload in the Responses API's own envelope shape. */
function responsesEnvelope(json: unknown, usage = { input_tokens: 500, output_tokens: 120 }) {
  return {
    output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: JSON.stringify(json) }] }],
    usage,
  };
}

function stubTransport(status: number, body: unknown) {
  const calls: Array<{ url: string; apiKey: string; body: any }> = [];
  const transport: Transport = {
    async post(url, apiKey, requestBody) {
      calls.push({ url, apiKey, body: requestBody });
      return { status, body };
    },
  };
  return { transport, calls };
}

describe("buildModelResponseSchema", () => {
  it("strips usage and requestId — the model never invents its own cost or id", () => {
    const schema = buildModelResponseSchema(4) as { required: string[]; properties: Record<string, unknown> };
    expect(schema.required).not.toContain("usage");
    expect(schema.required).not.toContain("requestId");
    expect(schema.properties.usage).toBeUndefined();
    expect(schema.properties.requestId).toBeUndefined();
    // Everything else survives.
    expect(schema.required).toContain("cards");
    expect(schema.required).toContain("transcription");
  });

  it("caps cards at the configured limit, not a hardcoded 4 (§0.6, §13.2)", () => {
    const schema = buildModelResponseSchema(2) as { properties: { cards: { maxItems?: number } } };
    expect(schema.properties.cards.maxItems).toBe(2);
  });

  it("does not mutate the shared schema object between calls", () => {
    buildModelResponseSchema(1);
    const second = buildModelResponseSchema(4) as { properties: { cards: { maxItems?: number } } };
    expect(second.properties.cards.maxItems).toBe(4);
  });
});

describe("estimateOpenAICostUSD", () => {
  it("computes from per-million pricing", () => {
    expect(estimateOpenAICostUSD(1_000_000, 1_000_000, COST)).toBeCloseTo(10);
    expect(estimateOpenAICostUSD(500_000, 0, COST)).toBeCloseTo(1);
  });

  it("is zero when pricing is unset (§0.6 default: no guessed price)", () => {
    expect(estimateOpenAICostUSD(1_000_000, 1_000_000, { openaiUsdPerMillionInputTokens: 0, openaiUsdPerMillionOutputTokens: 0 })).toBe(0);
  });
});

describe("OpenAICardGenerator", () => {
  it("sends the system prompt, the image, and the reconciled text — not asking the model to re-derive it", async () => {
    const { transport, calls } = stubTransport(200, responsesEnvelope(modelOutput()));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);

    await generator.generateCards(REQUEST);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.apiKey).toBe("sk-test");
    expect(calls[0]!.body.model).toBe("gpt-5.6-sol");
    expect(calls[0]!.body.reasoning.effort).toBe("low");
    expect(calls[0]!.body.input[0].content[0].text).toBe(CARD_GENERATION_SYSTEM_PROMPT);
    const userText = calls[0]!.body.input[1].content[0].text as string;
    expect(userText).toContain(REQUEST.cleanText);
    expect(userText).toContain("line_04");
    const imagePart = calls[0]!.body.input[1].content[1];
    expect(imagePart.type).toBe("input_image");
    expect(imagePart.image_url).toBe(`data:image/jpeg;base64,${Buffer.from(REQUEST.image).toString("base64")}`);
  });

  it("splices in requestId and a computed usage block rather than trusting the model", async () => {
    const { transport } = stubTransport(200, responsesEnvelope(modelOutput(), { input_tokens: 1000, output_tokens: 200 }));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);

    const result = await generator.generateCards(REQUEST);

    expect(result.output.requestId).toBe("req_1");
    expect(result.output.usage).toEqual({
      provider: "openai",
      model: "gpt-5.6-sol",
      inputTokens: 1000,
      outputTokens: 200,
      estimatedCostUSD: estimateOpenAICostUSD(1000, 200, COST),
    });
    expect(result.rawUsage).toEqual({ inputTokens: 1000, outputTokens: 200 });
  });

  it("returns output that independently passes schema validation", async () => {
    const { transport } = stubTransport(200, responsesEnvelope(modelOutput()));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const result = await generator.generateCards(REQUEST);
    expect(result.output.cards).toHaveLength(1);
    expect(result.output.schemaVersion).toBe("1.0");
  });

  it("throws when the model's own JSON fails §14 validation, rather than returning it", async () => {
    const broken = modelOutput();
    (broken as any).cards[0].riskFlags = ["not_a_real_flag"];
    const { transport } = stubTransport(200, responsesEnvelope(broken));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);

    await expect(generator.generateCards(REQUEST)).rejects.toThrow(OpenAIError);
    await expect(generator.generateCards(REQUEST)).rejects.toThrow(/şemasına uymuyor/);
  });

  it("throws on a refusal instead of treating it as empty output", async () => {
    const { transport } = stubTransport(200, {
      output: [{ type: "message", content: [{ type: "refusal", refusal: "tıbbi tavsiye veremem" }] }],
      usage: { input_tokens: 10, output_tokens: 5 },
    });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    await expect(generator.generateCards(REQUEST)).rejects.toThrow(/reddetti/);
  });

  it("throws on output_text that is not valid JSON", async () => {
    const { transport } = stubTransport(200, {
      output: [{ type: "message", content: [{ type: "output_text", text: "{not json" }] }],
      usage: { input_tokens: 10, output_tokens: 5 },
    });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    await expect(generator.generateCards(REQUEST)).rejects.toThrow(/geçerli JSON değil/);
  });

  it("marks 429 and 5xx as retryable, matching the documentAI provider's convention", async () => {
    for (const status of [429, 500, 503]) {
      const { transport } = stubTransport(status, { error: { message: "boom" } });
      const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
      const error = await generator.generateCards(REQUEST).catch((caught) => caught as OpenAIError);
      expect(error).toBeInstanceOf(OpenAIError);
      expect((error as OpenAIError).transient, `status ${status}`).toBe(true);
    }
  });

  it("marks 400/401/403/404 as permanent so a bad key or bad request is not retried forever", async () => {
    for (const status of [400, 401, 403, 404]) {
      const { transport } = stubTransport(status, { error: { message: "nope" } });
      const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
      const error = await generator.generateCards(REQUEST).catch((caught) => caught as OpenAIError);
      expect((error as OpenAIError).transient, `status ${status}`).toBe(false);
    }
  });

  it("carries OpenAI's own error message so a misconfiguration is diagnosable", async () => {
    const { transport } = stubTransport(401, { error: { message: "Invalid API key provided" } });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    await expect(generator.generateCards(REQUEST)).rejects.toThrow(/Invalid API key provided/);
  });

  it("never puts the API key or the image/text content into a thrown error (§7.3)", async () => {
    const secretText = "hasta bilgisi olmayan ama yine de gizli tutulması gereken pasaj";
    const { transport } = stubTransport(500, { error: { message: "sunucu hatası" } });
    const generator = new OpenAICardGenerator(CONFIG, "sk-super-secret-key", COST, transport);

    let message = "";
    try {
      await generator.generateCards({ ...REQUEST, cleanText: secretText });
      expect.unreachable("500 hata fırlatmalıydı");
    } catch (caught) {
      message = (caught as Error).message;
    }
    expect(message).not.toContain("sk-super-secret-key");
    expect(message).not.toContain(secretText);
  });
});
