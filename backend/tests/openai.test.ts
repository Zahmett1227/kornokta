import { describe, expect, it } from "vitest";

import type { OpenAIConfig } from "../config.js";
import { CARD_GENERATION_SYSTEM_PROMPT } from "../prompts/cardGeneration.js";
import { LLM_OUTPUT_SCHEMA } from "../schemas/validateLlmOutput.js";
import {
  OpenAICardGenerator,
  OpenAIError,
  buildModelResponseSchema,
  estimateOpenAICostUSD,
  stricterMode,
  type Transport,
} from "../providers/openai.js";

const CONFIG: OpenAIConfig = {
  model: "gpt-5.6-sol",
  reasoningEffort: "low",
  imageDetail: "high",
  maxOutputTokens: 700,
  maxCardsPerKnowledgeUnit: 4,
  multipleChoiceMode: "mixed",
  // Not 1_000. That is a *real* wall-clock abort timer (`setTimeout` →
  // `controller.abort()`), and every test here stubs `fetch` to resolve
  // immediately — so the timer exists only to fire spuriously. On a loaded
  // machine the event loop can stall past a second between arming the timer
  // and the stub resolving, aborting calls the test expects to succeed; that
  // is the shape of the intermittent multi-test failure seen twice in this
  // suite, both times on runs that took ~3× the usual duration.
  //
  // No test waits for this timer (the abort path constructs its own
  // AbortError) and nothing asserts on the number, so a value that cannot
  // fire is strictly better. `clearTimeout` runs in a `finally`, so the long
  // timer never delays the run.
  timeoutMs: 60_000,
};

const COST = {
  openaiUsdPerMillionInputTokens: 2,
  openaiUsdPerMillionCachedInputTokens: 0.2,
  openaiUsdPerMillionOutputTokens: 8,
};

/** A `TokenUsage` with nothing cached and nothing reasoned — the old two-number shape. */
function plainUsage(inputTokens: number, outputTokens: number) {
  return { inputTokens, cachedInputTokens: 0, outputTokens, reasoningTokens: 0 };
}

const REQUEST = {
  requestId: "req_1",
  image: new Uint8Array([1, 2, 3]),
  mimeType: "image/jpeg",
  hint: "sadece sol sütun",
};

/** The shape the model itself must produce: the full v2 contract minus usage/requestId. */
function modelOutput(overrides: Record<string, unknown> = {}) {
  return {
    schemaVersion: "2.0",
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

/** The billed-failure cases all follow the same shape: call, catch, inspect. */
async function failWith(status: number, body: unknown): Promise<OpenAIError> {
  const { transport } = stubTransport(status, body);
  const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
  const caught = await generator.generateCards(REQUEST).catch((error) => error as OpenAIError);
  expect(caught).toBeInstanceOf(OpenAIError);
  return caught as OpenAIError;
}

describe("failed calls carry what they spent (§16.8, §20.3)", () => {
  it("attaches usage to a response truncated at max_output_tokens", async () => {
    // The most expensive failure in the system: every output token was
    // generated and billed, and the truncated JSON is worth nothing. Before
    // this the caller saw a message and no figure, so the ledger recorded the
    // call as if it had never happened.
    const error = await failWith(200, {
      status: "incomplete",
      incomplete_details: { reason: "max_output_tokens" },
      usage: {
        input_tokens: 4200,
        output_tokens: 8192,
        input_tokens_details: { cached_tokens: 3000 },
        output_tokens_details: { reasoning_tokens: 6000 },
      },
    });
    expect(error.usage).toEqual({
      inputTokens: 4200,
      cachedInputTokens: 3000,
      outputTokens: 8192,
      reasoningTokens: 6000,
    });
    expect(error.reason).toBe("incomplete_max_output_tokens");
    expect(error.transient).toBe(true);
  });

  it("attaches usage to a schema-invalid response", async () => {
    const broken = { ...(modelOutput() as Record<string, unknown>), cards: "not-an-array" };
    const error = await failWith(200, responsesEnvelope(broken, { input_tokens: 900, output_tokens: 400 }));
    expect(error.usage?.outputTokens).toBe(400);
    expect(error.reason).toBe("schema_invalid");
  });

  it("attaches usage to a refusal", async () => {
    const error = await failWith(200, {
      output: [{ type: "message", content: [{ type: "refusal", refusal: "olmaz" }] }],
      usage: { input_tokens: 700, output_tokens: 30 },
    });
    expect(error.usage?.inputTokens).toBe(700);
    expect(error.reason).toBe("refusal");
  });

  it("attaches NO usage to a request the API rejected before generating", async () => {
    // A 429 or a bad key costs nothing, and recording a zero-token call as
    // "billed" would be just as wrong as hiding a real one. `reason` is what
    // lets the ledger tell the two apart without parsing prose.
    const error = await failWith(429, { error: { message: "slow down", code: "rate_limit_exceeded" } });
    expect(error.usage).toBeUndefined();
    expect(error.reason).toBe("http_429");
    expect(error.transient).toBe(true);
  });

  it("names an aborted call as a timeout and says the tokens may still have been billed", async () => {
    // The abort path used to leave this method as an anonymous Error, which
    // both the ledger and the phone reported as "provider unreachable" — the
    // same words as a connection that never opened and cost nothing.
    const aborted = Object.assign(new Error("The operation was aborted."), { name: "AbortError" });
    const transport: Transport = {
      async post() {
        throw aborted;
      },
    };
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const error = (await generator
      .generateCards(REQUEST)
      .catch((caught) => caught)) as OpenAIError;

    expect(error).toBeInstanceOf(OpenAIError);
    expect(error.reason).toBe("timeout");
    expect(error.message).toMatch(/ücretlendirilmiş olabilir/);
    // No figures to report — that is exactly what `billing: "unmeasured"`
    // downstream is for.
    expect(error.usage).toBeUndefined();
    expect(error.transient).toBe(true);
  });

  it("keeps a connection failure distinct from an abort", async () => {
    const transport: Transport = {
      async post() {
        throw new Error("ECONNREFUSED");
      },
    };
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const error = (await generator.generateCards(REQUEST).catch((caught) => caught)) as OpenAIError;
    expect(error.reason).toBe("transport");
  });
});

describe("buildModelResponseSchema", () => {
  it("strips usage and requestId — the model never invents its own cost or id", () => {
    const schema = buildModelResponseSchema(4) as { required: string[]; properties: Record<string, unknown> };
    expect(schema.required).not.toContain("usage");
    expect(schema.required).not.toContain("requestId");
    expect(schema.properties.usage).toBeUndefined();
    expect(schema.properties.requestId).toBeUndefined();
    // Everything else survives.
    expect(schema.required).toContain("cards");
    expect(schema.required).toContain("readText");
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

  it("never leaves a const/enum node without an explicit 'type' — OpenAI's Structured Outputs rejects that", () => {
    // Confirmed with a real (keyed) call: OpenAI returned
    // `400 Invalid schema for response_format ...: schema must have a 'type'
    // key` for `schemaVersion: { const: "2.0" }`. Plain JSON Schema does not
    // require `type` alongside `const`/`enum` — ajv accepted it happily —
    // but OpenAI's stricter subset does, so this has to be checked
    // separately from `validateLlmOutput`.
    function assertNoBareConstOrEnum(node: unknown, path: string): void {
      if (typeof node !== "object" || node === null) return;
      const obj = node as Record<string, unknown>;
      if (("const" in obj || "enum" in obj) && !("type" in obj)) {
        throw new Error(`${path}: 'const'/'enum' node without a 'type' key`);
      }
      for (const [key, value] of Object.entries(obj)) {
        if (Array.isArray(value)) {
          value.forEach((item, index) => assertNoBareConstOrEnum(item, `${path}.${key}[${index}]`));
        } else {
          assertNoBareConstOrEnum(value, `${path}.${key}`);
        }
      }
    }

    expect(() => assertNoBareConstOrEnum(buildModelResponseSchema(4), "$")).not.toThrow();
    // The topic enum is injected into the same schema, so it has to satisfy
    // the same rule — and it is on every job that carries a subject, i.e.
    // every ordinary capture once the picker is in use.
    expect(() =>
      assertNoBareConstOrEnum(buildModelResponseSchema(4, ["İnflamasyon", "Neoplazi"]), "$"),
    ).not.toThrow();
  });

  it("lists every card property in `required` — strict mode has no optional keys", () => {
    // `options`/`correctOption` are optional in the canonical §14 schema so a
    // v2.0 payload still validates, but OpenAI rejects a strict schema whose
    // `required` does not name every key in `properties`.
    const schema = buildModelResponseSchema(4) as {
      properties: { cards: { items: { required: string[]; properties: Record<string, unknown> } } };
    };
    const card = schema.properties.cards.items;
    expect([...card.required].sort()).toEqual(Object.keys(card.properties).sort());
    expect(card.required).toContain("options");
    expect(card.required).toContain("correctOption");
  });

  it("pins the model's schemaVersion to 2.3", () => {
    const schema = buildModelResponseSchema(4) as {
      properties: { schemaVersion: { const?: string; type?: string } };
    };
    expect(schema.properties.schemaVersion.const).toBe("2.3");
    expect(schema.properties.schemaVersion.type).toBe("string");
  });

  it("asks for the mark register and caps it above the card ceiling (schema v2.3)", () => {
    const schema = buildModelResponseSchema(6) as {
      required: string[];
      properties: {
        marks: { maxItems?: number; items: { required: string[]; properties: Record<string, unknown> } };
        cards: { items: { required: string[] } };
      };
    };

    // Optional in the canonical schema (a v2.0–v2.2 payload has no register),
    // so strict mode only gets it if it is promoted here — the same move
    // `topic` needed. Without the promotion OpenAI rejects the whole schema.
    expect(schema.required).toContain("marks");
    expect(schema.properties.cards.items.required).toContain("markId");
    expect([...schema.properties.marks.items.required].sort()).toEqual(
      Object.keys(schema.properties.marks.items.properties).sort(),
    );

    // Above the card ceiling on purpose: a page can carry more marks than it
    // can carry cards, and a register capped at the card count could not
    // report the very case the ceiling creates (Tur A: 18 of 18 pages).
    expect(schema.properties.marks.maxItems).toBe(18);
  });

  it("constrains topic to the subject's list when one is given, nullable either way", () => {
    const topics = ["İnflamasyon", "Neoplazi"];
    const withEnum = buildModelResponseSchema(4, topics) as {
      properties: { cards: { items: { required: string[]; properties: Record<string, unknown> } } };
    };
    const card = withEnum.properties.cards.items;
    expect(card.required).toContain("topic");
    expect(card.properties.topic).toEqual({
      anyOf: [{ type: "string", enum: topics }, { type: "null" }],
    });
    // Strict mode still needs every key in `required` with the enum injected.
    expect([...card.required].sort()).toEqual(Object.keys(card.properties).sort());

    // Without a subject the canonical nullable-string stays: the prompt says
    // "leave it null" and `sanitizeTopics` enforces it.
    const withoutEnum = buildModelResponseSchema(4) as {
      properties: { cards: { items: { required: string[]; properties: Record<string, { type?: unknown }> } } };
    };
    expect(withoutEnum.properties.cards.items.required).toContain("topic");
    expect(withoutEnum.properties.cards.items.properties.topic?.type).toEqual(["string", "null"]);
  });

  it("leaves the canonical schema alone (options stay optional there)", () => {
    buildModelResponseSchema(4);
    const canonical = LLM_OUTPUT_SCHEMA as unknown as {
      properties: { cards: { items: { required: string[] } } };
    };
    expect(canonical.properties.cards.items.required).not.toContain("options");
  });
});

describe("stricterMode", () => {
  /// Codex, PR #29: the job row carries the mode chosen at submit time and the
  /// worker may run on a deployment whose ceiling has since been lowered. An
  /// old row must not talk the new deployment into producing more.
  it("keeps the lower of the two on the off < mixed < all scale", () => {
    expect(stricterMode("all", "off")).toBe("off");
    expect(stricterMode("off", "all")).toBe("off");
    expect(stricterMode("all", "mixed")).toBe("mixed");
    expect(stricterMode("mixed", "all")).toBe("mixed");
    expect(stricterMode("mixed", "mixed")).toBe("mixed");
  });
});

describe("estimateOpenAICostUSD", () => {
  it("computes from per-million pricing", () => {
    expect(estimateOpenAICostUSD(plainUsage(1_000_000, 1_000_000), COST)).toBeCloseTo(10);
    expect(estimateOpenAICostUSD(plainUsage(500_000, 0), COST)).toBeCloseTo(1);
  });

  it("is zero when pricing is unset (§0.6 default: no guessed price)", () => {
    expect(estimateOpenAICostUSD(plainUsage(1_000_000, 1_000_000), {
      openaiUsdPerMillionInputTokens: 0,
      openaiUsdPerMillionCachedInputTokens: 0,
      openaiUsdPerMillionOutputTokens: 0,
    })).toBe(0);
  });
});

describe("OpenAICardGenerator", () => {
  it("sends the system prompt, the full-page image, and the optional hint (Faz 6)", async () => {
    const { transport, calls } = stubTransport(200, responsesEnvelope(modelOutput()));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);

    await generator.generateCards(REQUEST);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.apiKey).toBe("sk-test");
    expect(calls[0]!.body.model).toBe("gpt-5.6-sol");
    expect(calls[0]!.body.reasoning.effort).toBe("low");
    expect(calls[0]!.body.input[0].content[0].text).toBe(CARD_GENERATION_SYSTEM_PROMPT);
    const userText = calls[0]!.body.input[1].content[0].text as string;
    expect(userText).toContain("sadece sol sütun");
    const imagePart = calls[0]!.body.input[1].content[1];
    expect(imagePart.type).toBe("input_image");
    expect(imagePart.image_url).toBe(`data:image/jpeg;base64,${Buffer.from(REQUEST.image).toString("base64")}`);
    // Faz 6/B3: high detail so faint handwriting/highlighter is legible.
    expect(imagePart.detail).toBe("high");
  });

  it("works without a hint", async () => {
    const { transport, calls } = stubTransport(200, responsesEnvelope(modelOutput()));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const { hint: _drop, ...noHint } = REQUEST;
    await generator.generateCards(noHint);
    const userText = calls[0]!.body.input[1].content[0].text as string;
    expect(userText).toContain("(yok)");
  });

  it("injects the subject's topic enum and instruction, and keeps a valid topic", async () => {
    const { transport, calls } = stubTransport(
      200,
      responsesEnvelope(modelOutput({ cards: [{ ...modelOutput().cards[0], topic: "İnflamasyon" }] })),
    );
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);

    const result = await generator.generateCards({ ...REQUEST, subject: "Patoloji" });

    const schema = calls[0]!.body.text.format.schema as {
      properties: { cards: { items: { properties: { topic: unknown } } } };
    };
    expect(schema.properties.cards.items.properties.topic).toEqual({
      anyOf: [{ type: "string", enum: expect.arrayContaining(["İnflamasyon", "Neoplazi"]) }, { type: "null" }],
    });
    const userText = calls[0]!.body.input[1].content[0].text as string;
    expect(userText).toContain('"Patoloji" dersinden');
    expect(userText).toContain("İnflamasyon");
    expect(result.output.cards[0]!.topic).toBe("İnflamasyon");
  });

  it("sanitizes an off-list or unknown-subject topic to null instead of failing the job", async () => {
    const card = { ...modelOutput().cards[0], topic: "Bakteriyoloji" }; // valid elsewhere, not Patoloji
    {
      const { transport } = stubTransport(200, responsesEnvelope(modelOutput({ cards: [card] })));
      const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
      const result = await generator.generateCards({ ...REQUEST, subject: "Patoloji" });
      expect(result.output.cards[0]!.topic).toBeNull();
    }
    {
      // An unknown subject (stale job row, older client) degrades to "no
      // topic": the schema gets no enum and whatever comes back is nulled.
      const { transport, calls } = stubTransport(200, responsesEnvelope(modelOutput({ cards: [card] })));
      const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
      const result = await generator.generateCards({ ...REQUEST, subject: "Uydurma Ders" });
      const userText = calls[0]!.body.input[1].content[0].text as string;
      expect(userText).toContain("Konu ataması yapma");
      expect(result.output.cards[0]!.topic).toBeNull();
    }
  });

  it("tells the model to leave topic null when no subject was sent", async () => {
    const { transport, calls } = stubTransport(200, responsesEnvelope(modelOutput()));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    await generator.generateCards(REQUEST);
    const userText = calls[0]!.body.input[1].content[0].text as string;
    expect(userText).toContain("Konu ataması yapma");
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
      estimatedCostUSD: estimateOpenAICostUSD(plainUsage(1000, 200), COST),
    });
    expect(result.rawUsage).toEqual(plainUsage(1000, 200));
  });

  it("returns output that independently passes schema validation", async () => {
    const { transport } = stubTransport(200, responsesEnvelope(modelOutput()));
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const result = await generator.generateCards(REQUEST);
    expect(result.output.cards).toHaveLength(1);
    expect(result.output.schemaVersion).toBe("2.0");
  });

  it("throws when the model's own JSON fails §14 validation, rather than returning it", async () => {
    const broken = modelOutput();
    (broken as any).cards[0].difficulty = 9; // schema caps difficulty at 5
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

  it("treats status:'incomplete' as untrustworthy rather than parsing the truncated JSON fragment", async () => {
    // Confirmed live: a reasoning-capable model can spend part of
    // max_output_tokens on hidden reasoning before emitting any JSON, and
    // the truncated fragment that's left fails JSON.parse with a message
    // that doesn't say why. This checks status first so the real cause
    // (a token ceiling, not a malformed response) is what the caller sees.
    const { transport } = stubTransport(200, {
      status: "incomplete",
      incomplete_details: { reason: "max_output_tokens" },
      output: [{ type: "message", content: [{ type: "output_text", text: '{"schemaVersion":"2.0"' }] }],
      usage: { input_tokens: 500, output_tokens: 700 },
    });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const error = await generator.generateCards(REQUEST).catch((caught) => caught as OpenAIError);
    expect(error).toBeInstanceOf(OpenAIError);
    expect((error as OpenAIError).message).toMatch(/max_output_tokens/);
    // Transient: token spend is stochastic (reasoning tokens vary run to run),
    // and with jobId = page id a permanent classification would lock the page
    // out of /api/jobs forever.
    expect((error as OpenAIError).transient).toBe(true);
  });

  it("surfaces a 2xx body whose status is 'failed' with the provider's own message, as retryable", async () => {
    const { transport } = stubTransport(200, {
      status: "failed",
      error: { message: "The model produced invalid output." },
      usage: { input_tokens: 500, output_tokens: 0 },
    });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const error = await generator.generateCards(REQUEST).catch((caught) => caught as OpenAIError);
    expect(error).toBeInstanceOf(OpenAIError);
    // Without the status check this fell through to extractOutputText and the
    // provider's actual reason was replaced by a generic "no text" error.
    expect((error as OpenAIError).message).toMatch(/invalid output/);
    expect((error as OpenAIError).transient).toBe(true);
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

  it("names the exhausted balance on 429 insufficient_quota, per the owner's requirement", async () => {
    // OpenAI reports an empty balance as a bare 429 — the same status as an
    // ordinary rate limit. The message must say "kredi/kota" and point at
    // Billing so the real fix is never hunted for ("sorunu arayıp arayıp
    // durmayalım", 2026-08-11). The Gemini provider does the same for its 429.
    const { transport } = stubTransport(429, {
      error: { message: "You exceeded your current quota.", code: "insufficient_quota", type: "insufficient_quota" },
    });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    const error = await generator.generateCards(REQUEST).catch((caught) => caught as OpenAIError);
    expect(error).toBeInstanceOf(OpenAIError);
    expect((error as OpenAIError).message).toMatch(/kredisi|kotası/);
    expect((error as OpenAIError).message).toContain("Billing");
    // Still transient: a permanent failure would lock the page behind the
    // `force` re-submit guard (_jobs.ts); after a top-up the next retry
    // succeeds on its own.
    expect((error as OpenAIError).transient).toBe(true);
  });

  it("carries OpenAI's own error message so a misconfiguration is diagnosable", async () => {
    const { transport } = stubTransport(401, { error: { message: "Invalid API key provided" } });
    const generator = new OpenAICardGenerator(CONFIG, "sk-test", COST, transport);
    await expect(generator.generateCards(REQUEST)).rejects.toThrow(/Invalid API key provided/);
  });

  it("never puts the API key or the hint content into a thrown error (§7.3)", async () => {
    const secretText = "hasta bilgisi olmayan ama yine de gizli tutulması gereken ipucu";
    const { transport } = stubTransport(500, { error: { message: "sunucu hatası" } });
    const generator = new OpenAICardGenerator(CONFIG, "sk-super-secret-key", COST, transport);

    let message = "";
    try {
      await generator.generateCards({ ...REQUEST, hint: secretText });
      expect.unreachable("500 hata fırlatmalıydı");
    } catch (caught) {
      message = (caught as Error).message;
    }
    expect(message).not.toContain("sk-super-secret-key");
    expect(message).not.toContain(secretText);
  });
});
