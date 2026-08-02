import { describe, expect, it } from "vitest";

import type { GeminiConfig } from "../config.js";
import { HANDWRITING_SECOND_OPINION_PROMPT } from "../prompts/handwritingSecondOpinion.js";
import {
  GeminiError,
  GeminiHandwritingSecondOpinion,
  estimateGeminiCostUSD,
  type Transport,
} from "../providers/gemini.js";

const CONFIG: GeminiConfig = {
  model: "gemini-3.5-flash",
  maxOutputTokens: 700,
  timeoutMs: 1_000,
};

const COST = { geminiUsdPerMillionInputTokens: 1, geminiUsdPerMillionOutputTokens: 4 };

const REQUEST = {
  image: new Uint8Array([9, 9, 9]),
  mimeType: "image/jpeg",
  primaryReading: "krea 1.2 yükseldi",
};

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

function geminiEnvelope(json: unknown, usage = { promptTokenCount: 300, candidatesTokenCount: 60 }) {
  return {
    candidates: [{ content: { parts: [{ text: JSON.stringify(json) }] }, finishReason: "STOP" }],
    usageMetadata: usage,
  };
}

describe("estimateGeminiCostUSD", () => {
  it("computes from per-million pricing", () => {
    expect(estimateGeminiCostUSD(1_000_000, 1_000_000, COST)).toBeCloseTo(5);
  });

  it("is zero when pricing is unset", () => {
    expect(
      estimateGeminiCostUSD(1_000_000, 1_000_000, { geminiUsdPerMillionInputTokens: 0, geminiUsdPerMillionOutputTokens: 0 }),
    ).toBe(0);
  });
});

describe("GeminiHandwritingSecondOpinion", () => {
  it("addresses the configured model and hands the key to the transport", async () => {
    // The key-as-query-param convention is `fetchTransport`'s job (below);
    // the provider only has to pick the right endpoint and pass the key
    // through, which is what an injected stub transport can observe.
    const { transport, calls } = stubTransport(
      200,
      geminiEnvelope({ text: "kreatinin 1,2 yükseldi", uncertainSpans: [] }),
    );
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);

    await generator.getSecondOpinion(REQUEST);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.apiKey).toBe("gm-test-key");
    expect(calls[0]!.url).toBe(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent",
    );
  });

  it("fetchTransport puts the API key in the URL query string, not a header (Gemini's own convention)", async () => {
    const { fetchTransport } = await import("../providers/gemini.js");
    const originalFetch = globalThis.fetch;
    let requestedUrl = "";
    globalThis.fetch = (async (input: unknown) => {
      requestedUrl = String(input);
      return new Response(JSON.stringify({ candidates: [] }), { status: 200 });
    }) as typeof fetch;

    try {
      await fetchTransport.post("https://example.test/generateContent", "gm-test-key", {}, 1_000);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(requestedUrl).toBe("https://example.test/generateContent?key=gm-test-key");
  });

  it("sends the system prompt, the image, and the primary reading for comparison", async () => {
    const { transport, calls } = stubTransport(
      200,
      geminiEnvelope({ text: "kreatinin 1,2 yükseldi", uncertainSpans: [] }),
    );
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);

    await generator.getSecondOpinion(REQUEST);

    const body = calls[0]!.body;
    expect(body.systemInstruction.parts[0].text).toBe(HANDWRITING_SECOND_OPINION_PROMPT);
    expect(body.contents[0].parts[0].text).toContain(REQUEST.primaryReading);
    expect(body.contents[0].parts[1].inlineData.mimeType).toBe("image/jpeg");
    expect(body.contents[0].parts[1].inlineData.data).toBe(Buffer.from(REQUEST.image).toString("base64"));
    expect(body.generationConfig.responseMimeType).toBe("application/json");
  });

  it("parses the transcription and uncertain spans, and the real usage counts", async () => {
    const { transport } = stubTransport(
      200,
      geminiEnvelope(
        {
          text: "kreatinin 1,2 yükseldi",
          uncertainSpans: [
            { text: "1,2", alternatives: ["1,2", "12"], reason: "el_yazisi_belirsiz", critical: true, requiresUserConfirmation: true },
          ],
        },
        { promptTokenCount: 400, candidatesTokenCount: 90 },
      ),
    );
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);

    const result = await generator.getSecondOpinion(REQUEST);

    expect(result.opinion.text).toBe("kreatinin 1,2 yükseldi");
    expect(result.opinion.uncertainSpans).toHaveLength(1);
    expect(result.opinion.uncertainSpans[0]!.critical).toBe(true);
    expect(result.rawUsage).toEqual({ inputTokens: 400, outputTokens: 90 });
  });

  it("never asks for or accepts cards — only transcription and uncertainty (§15.3)", async () => {
    const withCards = { text: "x", uncertainSpans: [], cards: [{ front: "sneaky" }] };
    const { transport } = stubTransport(200, geminiEnvelope(withCards));
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);
    // additionalProperties: false on the §15.3 schema rejects the extra field outright.
    await expect(generator.getSecondOpinion(REQUEST)).rejects.toThrow(GeminiError);
  });

  it("rejects more than three alternatives per span (§15.3: 'en fazla üç aday')", async () => {
    const tooMany = {
      text: "x",
      uncertainSpans: [{ text: "a", alternatives: ["1", "2", "3", "4"], reason: "r", critical: false, requiresUserConfirmation: false }],
    };
    const { transport } = stubTransport(200, geminiEnvelope(tooMany));
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);
    await expect(generator.getSecondOpinion(REQUEST)).rejects.toThrow(/§15.3/);
  });

  it("treats a non-STOP finishReason as untrustworthy rather than parsing partial JSON", async () => {
    const { transport } = stubTransport(200, {
      candidates: [{ content: { parts: [{ text: "{" }] }, finishReason: "MAX_TOKENS" }],
      usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 700 },
    });
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);
    await expect(generator.getSecondOpinion(REQUEST)).rejects.toThrow(/tamamlamadı/);
  });

  it("marks 429 and 5xx as retryable", async () => {
    for (const status of [429, 500, 503]) {
      const { transport } = stubTransport(status, { error: { message: "boom" } });
      const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);
      const error = await generator.getSecondOpinion(REQUEST).catch((caught) => caught as GeminiError);
      expect((error as GeminiError).transient, `status ${status}`).toBe(true);
    }
  });

  it("marks 400/401/403/404 as permanent", async () => {
    for (const status of [400, 401, 403, 404]) {
      const { transport } = stubTransport(status, { error: { message: "nope" } });
      const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-test-key", COST, transport);
      const error = await generator.getSecondOpinion(REQUEST).catch((caught) => caught as GeminiError);
      expect((error as GeminiError).transient, `status ${status}`).toBe(false);
    }
  });

  it("never puts the API key or the image/text content into a thrown error (§7.3)", async () => {
    const secretText = "gizli tutulması gereken el yazısı adayı";
    const { transport } = stubTransport(500, { error: { message: "sunucu hatası" } });
    const generator = new GeminiHandwritingSecondOpinion(CONFIG, "gm-super-secret", COST, transport);

    let message = "";
    try {
      await generator.getSecondOpinion({ ...REQUEST, primaryReading: secretText });
      expect.unreachable("500 hata fırlatmalıydı");
    } catch (caught) {
      message = (caught as Error).message;
    }
    expect(message).not.toContain("gm-super-secret");
    expect(message).not.toContain(secretText);
  });
});
