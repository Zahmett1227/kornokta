import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/_auth.js";
import { MAX_IMAGE_BYTES } from "../api/_image.js";
import {
  handleSecondOpinionRequest,
  parseCard,
  type SecondOpinionDependencies,
  type SecondOpinionProviderLike,
} from "../api/_secondOpinion.js";
import { HANDWRITING_SECOND_OPINION_PROMPT_VERSION } from "../prompts/handwritingSecondOpinion.js";
import { GeminiError, type SecondOpinionRequest, type SecondOpinionResult } from "../providers/gemini.js";

const TOKEN = "t".repeat(MIN_TOKEN_LENGTH);
const IMAGE = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");

const RESULT: SecondOpinionResult = {
  verdict: "contradicts",
  reading: "hipokalemi (hiperkalemi değil)",
  note: "Önek ters okunmuş.",
  usage: { provider: "gemini", model: "gemini-3.5-flash", inputTokens: 800, outputTokens: 90, estimatedCostUSD: 0 },
};

/** Records what it was handed, so privacy claims can be checked — same role as `stubGenerator`. */
function stubProvider(result: SecondOpinionResult | Error) {
  const seen: SecondOpinionRequest[] = [];
  const provider: SecondOpinionProviderLike = {
    async secondOpinion(request) {
      seen.push(request);
      if (result instanceof Error) throw result;
      return result;
    },
  };
  return { provider, seen };
}

function deps(
  overrides: Partial<SecondOpinionDependencies> = {},
): SecondOpinionDependencies & { logged: Record<string, unknown>[] } {
  const logged: Record<string, unknown>[] = [];
  return {
    provider: stubProvider(RESULT).provider,
    deviceToken: TOKEN,
    log: (entry) => logged.push(entry),
    logged,
    ...overrides,
  };
}

function post(body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request("https://example.test/api/second-opinion", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const VALID_BODY = {
  requestId: "card-1",
  mimeType: "image/jpeg",
  imageBase64: IMAGE,
  card: { front: "K düzeyi?", back: "Hipokalemi", explanation: "NKCC2 defekti" },
};

describe("parseCard", () => {
  it("requires non-empty front and back", () => {
    expect(parseCard({ front: "a", back: "b" })).toEqual({ front: "a", back: "b" });
    expect(parseCard({ front: " ", back: "b" })).toBeNull();
    expect(parseCard({ front: "a" })).toBeNull();
    expect(parseCard("kart")).toBeNull();
    expect(parseCard(null)).toBeNull();
  });

  it("keeps a non-empty explanation and drops a blank one", () => {
    expect(parseCard({ front: "a", back: "b", explanation: "c" })).toEqual({
      front: "a",
      back: "b",
      explanation: "c",
    });
    expect(parseCard({ front: "a", back: "b", explanation: "  " })).toEqual({ front: "a", back: "b" });
    // Malformed is malformed, not silently dropped.
    expect(parseCard({ front: "a", back: "b", explanation: 3 })).toBeNull();
  });
});

describe("POST /api/second-opinion", () => {
  it("returns the verdict, reading and prompt version", async () => {
    const response = await handleSecondOpinionRequest(post(VALID_BODY), deps());
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.requestId).toBe("card-1");
    expect(body.verdict).toBe("contradicts");
    expect(body.reading).toContain("hipokalemi");
    expect(body.note).toBe("Önek ters okunmuş.");
    expect(body.promptVersion).toBe(HANDWRITING_SECOND_OPINION_PROMPT_VERSION);
  });

  it("hands the decoded image and the trimmed card to the provider", async () => {
    const { provider, seen } = stubProvider(RESULT);
    await handleSecondOpinionRequest(post(VALID_BODY), deps({ provider }));
    expect(seen).toHaveLength(1);
    expect(seen[0]!.requestId).toBe("card-1");
    expect(seen[0]!.mimeType).toBe("image/jpeg");
    expect(seen[0]!.image.length).toBeGreaterThan(0);
    expect(seen[0]!.card).toEqual(VALID_BODY.card);
  });

  describe("authorization", () => {
    it("rejects a request with no token and does not call the provider", async () => {
      const { provider, seen } = stubProvider(RESULT);
      const response = await handleSecondOpinionRequest(post(VALID_BODY, null), deps({ provider }));
      expect(response.status).toBe(401);
      expect(seen).toHaveLength(0);
    });

    it("answers 500 when the server has no DEVICE_TOKEN, not 401", async () => {
      const response = await handleSecondOpinionRequest(
        post(VALID_BODY),
        deps({ deviceToken: undefined }),
      );
      expect(response.status).toBe(500);
    });
  });

  describe("validation", () => {
    it("rejects a missing requestId", async () => {
      const { requestId: _drop, ...rest } = VALID_BODY;
      const response = await handleSecondOpinionRequest(post(rest), deps());
      expect(response.status).toBe(400);
      expect(((await response.json()) as { error: string }).error).toContain("requestId");
    });

    it("rejects an unsupported mime type", async () => {
      const response = await handleSecondOpinionRequest(
        post({ ...VALID_BODY, mimeType: "application/pdf" }),
        deps(),
      );
      expect(response.status).toBe(415);
    });

    it("rejects a corrupt imageBase64", async () => {
      const response = await handleSecondOpinionRequest(
        post({ ...VALID_BODY, imageBase64: "böyle base64 olmaz!!" }),
        deps(),
      );
      expect(response.status).toBe(400);
    });

    it("rejects an oversized image before decoding it", async () => {
      const response = await handleSecondOpinionRequest(
        post({ ...VALID_BODY, imageBase64: "A".repeat(Math.ceil(MAX_IMAGE_BYTES * 1.4) + 1) }),
        deps(),
      );
      expect(response.status).toBe(413);
    });

    it("rejects a missing or half-formed card", async () => {
      for (const card of [undefined, {}, { front: "a" }, { front: "a", back: "" }]) {
        const response = await handleSecondOpinionRequest(post({ ...VALID_BODY, card }), deps());
        expect(response.status, JSON.stringify(card)).toBe(400);
      }
    });

    it("rejects a non-JSON body", async () => {
      const response = await handleSecondOpinionRequest(post("{bozuk"), deps());
      expect(response.status).toBe(400);
    });

    it("only answers POST", async () => {
      const response = await handleSecondOpinionRequest(
        new Request("https://example.test/api/second-opinion", { method: "GET" }),
        deps(),
      );
      expect(response.status).toBe(405);
    });
  });

  describe("provider failures", () => {
    it("maps a transient GeminiError to 503 retryable, keeping its message", async () => {
      const { provider } = stubProvider(new GeminiError("Gemini kotası/kredisi tükenmiş görünüyor (429)...", 429, true));
      const response = await handleSecondOpinionRequest(post(VALID_BODY), deps({ provider }));
      expect(response.status).toBe(503);
      const body = (await response.json()) as { error: string; retryable: boolean };
      // The quota message travels to the phone intact — that is the whole
      // point of naming the suspect server-side.
      expect(body.error).toContain("kota");
      expect(body.retryable).toBe(true);
    });

    it("maps a permanent GeminiError to 502 non-retryable", async () => {
      const { provider } = stubProvider(new GeminiError("Gemini API anahtarı reddedildi (403)", 403, false));
      const response = await handleSecondOpinionRequest(post(VALID_BODY), deps({ provider }));
      expect(response.status).toBe(502);
      expect(((await response.json()) as { retryable: boolean }).retryable).toBe(false);
    });

    it("maps an unknown error to a generic 500 without leaking its message", async () => {
      const { provider } = stubProvider(new Error("iç detay: kart metni buraya sızmasın"));
      const response = await handleSecondOpinionRequest(post(VALID_BODY), deps({ provider }));
      expect(response.status).toBe(500);
      const body = (await response.json()) as { error: string; retryable: boolean };
      expect(body.error).not.toContain("sızmasın");
      expect(body.retryable).toBe(true);
    });
  });

  describe("privacy (§7.3)", () => {
    it("logs ids, counts and the verdict — never the reading, note or card text", async () => {
      const d = deps();
      await handleSecondOpinionRequest(post(VALID_BODY), d);
      expect(d.logged).toHaveLength(1);
      const line = JSON.stringify(d.logged[0]);
      expect(d.logged[0]!.event).toBe("second_opinion.ok");
      expect(d.logged[0]!.verdict).toBe("contradicts");
      expect(line).not.toContain("hipokalemi");
      expect(line).not.toContain("Önek");
      expect(line).not.toContain("K düzeyi");
      expect(line).not.toContain(IMAGE);
    });
  });
});
