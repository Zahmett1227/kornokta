import { describe, expect, it } from "vitest";

import type { GeminiConfig } from "../config.js";
import { HANDWRITING_SECOND_OPINION_PROMPT } from "../prompts/handwritingSecondOpinion.js";
import {
  GeminiError,
  GeminiSecondOpinion,
  buildSecondOpinionInstruction,
  estimateGeminiCostUSD,
  type GeminiTransport,
  type SecondOpinionRequest,
} from "../providers/gemini.js";

const CONFIG: GeminiConfig = {
  model: "gemini-3.5-flash",
  maxOutputTokens: 4096,
  timeoutMs: 1_000,
};

const COST = {
  geminiUsdPerMillionInputTokens: 1,
  geminiUsdPerMillionCachedInputTokens: 0.1,
  geminiUsdPerMillionOutputTokens: 4,
};

const REQUEST: SecondOpinionRequest = {
  requestId: "req_1",
  image: new Uint8Array([1, 2, 3]),
  mimeType: "image/jpeg",
  card: {
    front: "Bartter sendromunda potasyum düzeyi nasıldır?",
    back: "Hipokalemi görülür.",
    explanation: "Henle çıkan kolunda NKCC2 defekti.",
  },
};

/** Wraps a model JSON payload in generateContent's own envelope shape. */
function envelope(
  json: unknown,
  usage = { promptTokenCount: 800, candidatesTokenCount: 90 },
  finishReason = "STOP",
) {
  return {
    candidates: [{ content: { parts: [{ text: JSON.stringify(json) }] }, finishReason }],
    usageMetadata: usage,
  };
}

function stubTransport(status: number, body: unknown) {
  const calls: Array<{ url: string; apiKey: string; body: any }> = [];
  const transport: GeminiTransport = {
    async post(url, apiKey, requestBody) {
      calls.push({ url, apiKey, body: requestBody });
      return { status, body };
    },
  };
  return { transport, calls };
}

const OPINION = { verdict: "contradicts", reading: "hiperkalemi değil hipokalemi", note: "Önek ters okunmuş." };

describe("buildSecondOpinionInstruction", () => {
  it("carries the card verbatim and the requestId", () => {
    const text = buildSecondOpinionInstruction(REQUEST);
    expect(text).toContain("requestId: req_1");
    expect(text).toContain(REQUEST.card.front);
    expect(text).toContain(REQUEST.card.back);
    expect(text).toContain("NKCC2");
  });

  it("says (yok) for a missing explanation rather than omitting the line", () => {
    const text = buildSecondOpinionInstruction({ ...REQUEST, card: { front: "a", back: "b" } });
    expect(text).toContain("Açıklama: (yok)");
  });
});

/** A `TokenUsage` with nothing cached and nothing reasoned. */
function plainUsage(inputTokens: number, outputTokens: number) {
  return { inputTokens, cachedInputTokens: 0, outputTokens, reasoningTokens: 0 };
}

describe("estimateGeminiCostUSD", () => {
  it("computes from per-million pricing", () => {
    expect(estimateGeminiCostUSD(plainUsage(1_000_000, 1_000_000), COST)).toBeCloseTo(5);
  });

  it("is zero when pricing is unset (§0.6 default: no guessed price)", () => {
    expect(
      estimateGeminiCostUSD(plainUsage(1_000_000, 1_000_000), {
        geminiUsdPerMillionInputTokens: 0,
        geminiUsdPerMillionCachedInputTokens: 0,
        geminiUsdPerMillionOutputTokens: 0,
      }),
    ).toBe(0);
  });

  it("prices the cached share at its own rate, not the uncached one", () => {
    // The whole reason this function grew a `TokenUsage`: a call whose prompt
    // prefix was served from cache is billed a fraction of the headline input
    // price, and charging it in full is how the Kullanım screen came to
    // disagree with the provider's invoice.
    const halfCached = { inputTokens: 1_000_000, cachedInputTokens: 500_000, outputTokens: 0, reasoningTokens: 0 };
    // 500k uncached @ $1/M + 500k cached @ $0.1/M
    expect(estimateGeminiCostUSD(halfCached, COST)).toBeCloseTo(0.55);
  });
});

describe("GeminiSecondOpinion", () => {
  it("sends the system prompt, the page image inline, and a constrained JSON schema", async () => {
    const { transport, calls } = stubTransport(200, envelope(OPINION));
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);

    await provider.secondOpinion(REQUEST);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.apiKey).toBe("g-test");
    // The model id comes from config, never hardcoded at the call site (§0.6),
    // and the key travels as a header — the URL must not carry it.
    expect(calls[0]!.url).toContain("gemini-3.5-flash");
    expect(calls[0]!.url).not.toContain("g-test");
    expect(calls[0]!.body.systemInstruction.parts[0].text).toBe(HANDWRITING_SECOND_OPINION_PROMPT);
    const parts = calls[0]!.body.contents[0].parts;
    expect(parts[0].text).toContain(REQUEST.card.front);
    expect(parts[1].inlineData).toEqual({
      mimeType: "image/jpeg",
      data: Buffer.from(REQUEST.image).toString("base64"),
    });
    const generation = calls[0]!.body.generationConfig;
    expect(generation.responseMimeType).toBe("application/json");
    expect(generation.responseSchema.properties.verdict.enum).toEqual([
      "supports",
      "contradicts",
      "unclear",
    ]);
  });

  it("returns the verdict, reading and a computed usage block", async () => {
    const { transport } = stubTransport(
      200,
      envelope(OPINION, { promptTokenCount: 1000, candidatesTokenCount: 200 }),
    );
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);

    const result = await provider.secondOpinion(REQUEST);

    expect(result.verdict).toBe("contradicts");
    expect(result.reading).toContain("hipokalemi");
    expect(result.note).toBe("Önek ters okunmuş.");
    // Provider and model ride along so the phone's ModelRun accounting
    // (Ayarlar → Kullanım) counts this call like every other paid one.
    expect(result.usage).toEqual({
      provider: "gemini",
      model: "gemini-3.5-flash",
      inputTokens: 1000,
      cachedInputTokens: 0,
      outputTokens: 200,
      reasoningTokens: 0,
      estimatedCostUSD: estimateGeminiCostUSD(plainUsage(1000, 200), COST),
    });
  });

  it("omits note when the model leaves it blank", async () => {
    const { transport } = stubTransport(200, envelope({ verdict: "supports", reading: "aynı metin", note: "  " }));
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
    const result = await provider.secondOpinion(REQUEST);
    expect(result.verdict).toBe("supports");
    expect(result.note).toBeUndefined();
  });

  it("rejects an off-enum verdict instead of passing it to the phone", async () => {
    const { transport } = stubTransport(200, envelope({ verdict: "belki", reading: "..." }));
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
    await expect(provider.secondOpinion(REQUEST)).rejects.toThrow(/verdict geçersiz/);
  });

  it("names the quota/credit as the suspect on a 429, per the owner's requirement", async () => {
    // Google reports an exhausted quota as a bare 429 — the same status as a
    // per-minute rate limit. The message must say "kota/kredi" and point at
    // the console, so the owner never has to go bug-hunting for a billing
    // problem ("sorunu arayıp arayıp durmayalım", 2026-08-11).
    const { transport } = stubTransport(429, {
      error: { message: "Quota exceeded for quota metric", status: "RESOURCE_EXHAUSTED" },
    });
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
    const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
    expect(error).toBeInstanceOf(GeminiError);
    expect((error as GeminiError).message).toMatch(/kota|kredi/i);
    expect((error as GeminiError).message).toContain("aistudio.google.com");
    // Transient on purpose: retries fail fast and free while the quota is
    // empty, and the first retry after a refill succeeds on its own.
    expect((error as GeminiError).transient).toBe(true);
  });

  it("names the key/billing as the suspect on 401/403, as permanent", async () => {
    for (const status of [401, 403]) {
      const { transport } = stubTransport(status, { error: { message: "API key not valid" } });
      const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
      const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
      expect((error as GeminiError).message, `status ${status}`).toMatch(/anahtar/);
      expect((error as GeminiError).transient, `status ${status}`).toBe(false);
    }
  });

  it("marks 5xx as retryable and 400 as permanent", async () => {
    {
      const { transport } = stubTransport(503, { error: { message: "overloaded" } });
      const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
      const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
      expect((error as GeminiError).transient).toBe(true);
    }
    {
      const { transport } = stubTransport(400, { error: { message: "bad request" } });
      const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
      const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
      expect((error as GeminiError).transient).toBe(false);
    }
  });

  it("blames the token ceiling on MAX_TOKENS instead of failing as a JSON parse error", async () => {
    // Same lesson as OpenAI's status:"incomplete": a thinking-capable model
    // spends hidden tokens from this budget, and the truncated fragment left
    // behind fails JSON.parse with a message that doesn't say why.
    const { transport } = stubTransport(200, {
      candidates: [{ content: { parts: [{ text: '{"verdict":"sup' }] }, finishReason: "MAX_TOKENS" }],
      usageMetadata: { promptTokenCount: 800, candidatesTokenCount: 4096 },
    });
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
    const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
    expect((error as GeminiError).message).toMatch(/GEMINI_MAX_OUTPUT_TOKENS/);
    expect((error as GeminiError).transient).toBe(true);
  });

  it("rejects any candidate that did not stop cleanly, even with schema-valid JSON left behind", async () => {
    // SAFETY/RECITATION/BLOCKLIST can terminate a candidate that still carries
    // parseable JSON; showing it would present a policy-terminated fragment as
    // a trustworthy medical verdict (Codex, PR #39).
    for (const finishReason of ["SAFETY", "RECITATION", "BLOCKLIST"]) {
      const { transport } = stubTransport(200, envelope(OPINION, undefined, finishReason));
      const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
      const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
      expect(error, finishReason).toBeInstanceOf(GeminiError);
      expect((error as GeminiError).message, finishReason).toContain(finishReason);
      expect((error as GeminiError).transient, finishReason).toBe(false);
    }
  });

  it("surfaces a prompt block with its reason, as permanent", async () => {
    const { transport } = stubTransport(200, { promptFeedback: { blockReason: "SAFETY" } });
    const provider = new GeminiSecondOpinion(CONFIG, "g-test", COST, transport);
    const error = await provider.secondOpinion(REQUEST).catch((caught) => caught as GeminiError);
    expect((error as GeminiError).message).toContain("SAFETY");
    expect((error as GeminiError).transient).toBe(false);
  });

  it("never puts the API key or the card content into a thrown error (§7.3)", async () => {
    const { transport } = stubTransport(500, { error: { message: "sunucu hatası" } });
    const provider = new GeminiSecondOpinion(CONFIG, "g-super-secret", COST, transport);
    let message = "";
    try {
      await provider.secondOpinion(REQUEST);
      expect.unreachable("500 hata fırlatmalıydı");
    } catch (caught) {
      message = (caught as Error).message;
    }
    expect(message).not.toContain("g-super-secret");
    expect(message).not.toContain("Bartter");
  });
});
