import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/_auth.js";
import { ACCEPTED_MIME_TYPES, MAX_IMAGE_BYTES } from "../api/_ocr.js";
import {
  handleCardsRequest,
  parseSelectedLineIds,
  type CardsDependencies,
  type CardGeneratorLike,
} from "../api/_cards.js";
import { OpenAIError } from "../providers/openai.js";
import type { CardGenerationRequest, CardGenerationResult } from "../providers/openai.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";
import { CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";

const TOKEN = "t".repeat(MIN_TOKEN_LENGTH);
const IMAGE = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");

function validOutput(overrides: Partial<LlmOutput> = {}): LlmOutput {
  return {
    schemaVersion: "1.0",
    requestId: "job-1",
    transcription: {
      exactText: "0,5 mg IM adrenalin",
      cleanText: "0,5 mg IM adrenalin",
      language: "tr",
      overallConfidence: 0.97,
      isHandwritten: false,
      selectedLineIds: ["line_00"],
      uncertainSpans: [],
    },
    knowledgeUnits: [
      {
        id: "ku_1",
        canonicalClaim: "0,5 mg IM adrenalin",
        mechanism: null,
        tags: [],
        sourceConcern: null,
        requiresUserApproval: false,
      },
    ],
    cards: [
      {
        id: "card_1",
        knowledgeUnitId: "ku_1",
        type: "direct_recall",
        front: "Doz nedir?",
        back: "0,5 mg IM adrenalin",
        explanation: "",
        sourceQuote: "0,5 mg IM adrenalin",
        sourceLineIds: ["line_00"],
        sourceFaithful: true,
        enriched: false,
        difficulty: 2,
        riskFlags: [],
        requiresUserApproval: false,
      },
    ],
    quality: { sourceCoverage: 0.98, duplicateCardRisk: 0.05, medicalMeaningChangeRisk: 0.01, warnings: [] },
    usage: { provider: "openai", model: "gpt-5.6-sol", inputTokens: 500, outputTokens: 120, estimatedCostUSD: 0 },
    ...overrides,
  };
}

/** Records what it was handed, so privacy claims can be checked, mirroring `stubRecognizer` in ocrEndpoint.test.ts. */
function stubGenerator(result: LlmOutput | Error) {
  const seen: CardGenerationRequest[] = [];
  const generator: CardGeneratorLike = {
    async generateCards(request) {
      seen.push(request);
      if (result instanceof Error) throw result;
      return { output: result, rawUsage: { inputTokens: result.usage.inputTokens, outputTokens: result.usage.outputTokens } } satisfies CardGenerationResult;
    },
  };
  return { generator, seen };
}

function deps(overrides: Partial<CardsDependencies> = {}): CardsDependencies & { logged: Record<string, unknown>[] } {
  const logged: Record<string, unknown>[] = [];
  return {
    generator: stubGenerator(validOutput()).generator,
    openai: { maxCardsPerKnowledgeUnit: 4, maxOutputTokens: 700 },
    cost: { openaiUsdPerMillionInputTokens: 0, openaiUsdPerMillionOutputTokens: 0, maxUsdPerCardGeneration: 0 },
    deviceToken: TOKEN,
    log: (entry) => logged.push(entry),
    logged,
    ...overrides,
  };
}

function post(body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request("https://example.test/api/cards", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const VALID_BODY = {
  jobId: "job-1",
  mimeType: "image/jpeg",
  imageBase64: IMAGE,
  cleanText: "0,5 mg IM adrenalin",
  selectedLineIds: ["line_00"],
};

describe("parseSelectedLineIds", () => {
  it("defaults an absent field to an empty array", () => {
    expect(parseSelectedLineIds(undefined)).toEqual([]);
  });

  it("accepts a string array", () => {
    expect(parseSelectedLineIds(["line_00", "line_01"])).toEqual(["line_00", "line_01"]);
  });

  it("rejects a non-array or an array with a non-string entry", () => {
    expect(parseSelectedLineIds("not an array")).toBeNull();
    expect(parseSelectedLineIds([1, 2])).toBeNull();
    expect(parseSelectedLineIds(["ok", 2])).toBeNull();
  });
});

describe("POST /api/cards", () => {
  it("returns the generated output and a per-card gate report", async () => {
    const response = await handleCardsRequest(post(VALID_BODY), deps());
    expect(response.status).toBe(200);
    const body = (await response.json()) as { jobId: string; output: LlmOutput; gate: { verdicts: unknown[] } };
    expect(body.jobId).toBe("job-1");
    expect(body.output.cards).toHaveLength(1);
    expect(body.gate.verdicts).toHaveLength(1);
  });

  it("returns the prompt version used, so the iOS ModelRun record (§16.8) has a real value to store", async () => {
    const response = await handleCardsRequest(post(VALID_BODY), deps());
    const body = (await response.json()) as { cardPromptVersion: string };
    expect(body.cardPromptVersion).toBe(CARD_PROMPT_VERSION);
  });

  it("passes the already-reconciled text through unchanged, not re-deriving it", async () => {
    const { generator, seen } = stubGenerator(validOutput());
    await handleCardsRequest(post(VALID_BODY), deps({ generator }));
    expect(seen[0]!.cleanText).toBe("0,5 mg IM adrenalin");
    expect(seen[0]!.selectedLineIds).toEqual(["line_00"]);
    expect(seen[0]!.requestId).toBe("job-1");
  });

  describe("authorization", () => {
    it("rejects a request with no token", async () => {
      const response = await handleCardsRequest(post(VALID_BODY, null), deps());
      expect(response.status).toBe(401);
    });

    it("does not call the provider when unauthorized", async () => {
      const { generator, seen } = stubGenerator(validOutput());
      await handleCardsRequest(post(VALID_BODY, "wrong-token-value-here-1234567890"), deps({ generator }));
      expect(seen).toHaveLength(0);
    });

    it("reports an unset server token as 500, not 401", async () => {
      const response = await handleCardsRequest(post(VALID_BODY), deps({ deviceToken: undefined }));
      expect(response.status).toBe(500);
    });
  });

  describe("validation", () => {
    it("rejects a non-POST method", async () => {
      const request = new Request("https://example.test/api/cards", { method: "GET" });
      expect((await handleCardsRequest(request, deps())).status).toBe(405);
    });

    it("rejects a body that is not JSON", async () => {
      expect((await handleCardsRequest(post("{not json"), deps())).status).toBe(400);
    });

    it("requires a jobId", async () => {
      for (const jobId of [undefined, "", "   ", 42]) {
        const response = await handleCardsRequest(post({ ...VALID_BODY, jobId }), deps());
        expect(response.status, `jobId: ${jobId}`).toBe(400);
      }
    });

    it("rejects an unaccepted mime type", async () => {
      const response = await handleCardsRequest(post({ ...VALID_BODY, mimeType: "image/heic" }), deps());
      expect(response.status).toBe(415);
    });

    it("accepts every documented mime type", async () => {
      for (const mimeType of ACCEPTED_MIME_TYPES) {
        const response = await handleCardsRequest(post({ ...VALID_BODY, mimeType }), deps());
        expect(response.status, mimeType).toBe(200);
      }
    });

    it("requires imageBase64", async () => {
      const { imageBase64: _drop, ...withoutImage } = VALID_BODY;
      const response = await handleCardsRequest(post(withoutImage), deps());
      expect(response.status).toBe(400);
    });

    it("rejects an oversized upload before calling the provider", async () => {
      const huge = "A".repeat(Math.ceil(MAX_IMAGE_BYTES * 1.4) + 4);
      const { generator, seen } = stubGenerator(validOutput());
      const response = await handleCardsRequest(post({ ...VALID_BODY, imageBase64: huge }), deps({ generator }));
      expect(response.status).toBe(413);
      expect(seen).toHaveLength(0);
    });

    it("rejects a corrupted upload rather than paying to generate cards from it", async () => {
      const { generator, seen } = stubGenerator(validOutput());
      const response = await handleCardsRequest(post({ ...VALID_BODY, imageBase64: "%%%%%%" }), deps({ generator }));
      expect(response.status).toBe(400);
      expect(seen).toHaveLength(0);
    });

    it("requires cleanText — this endpoint does not do its own OCR (§17)", async () => {
      const { cleanText: _drop, ...withoutText } = VALID_BODY;
      const response = await handleCardsRequest(post(withoutText), deps());
      expect(response.status).toBe(400);
      expect(await response.text()).toContain("cleanText");
    });

    it("rejects a malformed selectedLineIds instead of silently dropping it", async () => {
      const response = await handleCardsRequest(post({ ...VALID_BODY, selectedLineIds: "line_00" }), deps());
      expect(response.status).toBe(400);
    });
  });

  describe("cost ceiling (§21.3)", () => {
    it("refuses the call when the output-token upper bound already exceeds the configured ceiling", async () => {
      const { generator, seen } = stubGenerator(validOutput());
      const response = await handleCardsRequest(
        post(VALID_BODY),
        deps({
          generator,
          openai: { maxCardsPerKnowledgeUnit: 4, maxOutputTokens: 1_000_000 },
          cost: { openaiUsdPerMillionInputTokens: 0, openaiUsdPerMillionOutputTokens: 5, maxUsdPerCardGeneration: 0.5 },
        }),
      );
      expect(response.status).toBe(402);
      expect(seen).toHaveLength(0);
    });

    it("does not check the ceiling when it is 0 (disabled, the default — §0.6 no guessed price)", async () => {
      const { generator, seen } = stubGenerator(validOutput());
      const response = await handleCardsRequest(post(VALID_BODY), deps({ generator }));
      expect(response.status).toBe(200);
      expect(seen).toHaveLength(1);
    });
  });

  describe("provider failures", () => {
    it("maps a transient provider failure to 503 and says it is retryable", async () => {
      const { generator } = stubGenerator(new OpenAIError("kısa süreli", 503, true));
      const response = await handleCardsRequest(post(VALID_BODY), deps({ generator }));
      expect(response.status).toBe(503);
      expect(await response.json()).toMatchObject({ retryable: true });
    });

    it("maps a permanent provider failure to 502 and says it is not", async () => {
      const { generator } = stubGenerator(new OpenAIError("kalıcı", 403, false));
      const response = await handleCardsRequest(post(VALID_BODY), deps({ generator }));
      expect(response.status).toBe(502);
      expect(await response.json()).toMatchObject({ retryable: false });
    });

    it("does not leak an unexpected error's message", async () => {
      const secret = "kartın içeriği gizli kalmalı";
      const { generator } = stubGenerator(new Error(secret));
      const response = await handleCardsRequest(post(VALID_BODY), deps({ generator }));
      expect(response.status).toBe(500);
      expect(await response.text()).not.toContain(secret);
    });

    it("tells the log and the client the same retryable value", async () => {
      for (const thrown of [new OpenAIError("geçici", 503, true), new OpenAIError("kalıcı", 403, false), new Error("beklenmeyen")]) {
        const { generator } = stubGenerator(thrown);
        const d = deps({ generator });
        const response = await handleCardsRequest(post(VALID_BODY), d);
        const body = (await response.json()) as { retryable: boolean };
        expect(d.logged[0]!.retryable, thrown.message).toBe(body.retryable);
      }
    });
  });

  describe("card gate integration (§19)", () => {
    it("reports auto_accept for a clean card", async () => {
      const response = await handleCardsRequest(post(VALID_BODY), deps());
      const body = (await response.json()) as { gate: { verdicts: Array<{ decision: string }> } };
      expect(body.gate.verdicts[0]!.decision).toBe("auto_accept");
    });

    it("reports quick_confirm for a card the model itself flagged", async () => {
      const output = validOutput();
      output.cards[0]!.riskFlags = ["critical_number"];
      const { generator } = stubGenerator(output);
      const response = await handleCardsRequest(post(VALID_BODY), deps({ generator }));
      const body = (await response.json()) as { gate: { verdicts: Array<{ decision: string }> } };
      expect(body.gate.verdicts[0]!.decision).toBe("quick_confirm");
    });

    it("uses the configured maxCardsPerKnowledgeUnit, not a hardcoded 4", async () => {
      const output = validOutput({
        cards: [
          { ...validOutput().cards[0]!, id: "card_1" },
          { ...validOutput().cards[0]!, id: "card_2" },
        ],
      });
      const { generator } = stubGenerator(output);
      const response = await handleCardsRequest(
        post(VALID_BODY),
        deps({ generator, openai: { maxCardsPerKnowledgeUnit: 1, maxOutputTokens: 700 } }),
      );
      const body = (await response.json()) as { gate: { droppedForLimit: string[] } };
      expect(body.gate.droppedForLimit).toEqual(["card_2"]);
    });
  });

  describe("privacy (§7.3)", () => {
    it("logs metrics but never card or transcription content", async () => {
      const secretFront = "gizli kalması gereken soru metni";
      const output = validOutput();
      output.cards[0]!.front = secretFront;
      const { generator } = stubGenerator(output);
      const d = deps({ generator });

      await handleCardsRequest(post(VALID_BODY), d);

      const serialized = JSON.stringify(d.logged);
      expect(serialized).not.toContain(secretFront);
      expect(serialized).not.toContain(VALID_BODY.cleanText);
      expect(serialized).not.toContain(IMAGE);
      expect(d.logged[0]).toMatchObject({ jobId: "job-1", event: "cards.ok", cardCount: 1 });
      expect(d.logged[0]).toHaveProperty("elapsedMs");
      expect(d.logged[0]).toHaveProperty("decisions");
    });

    it("logs no content on the failure path either", async () => {
      const secret = "gizli";
      const { generator } = stubGenerator(new OpenAIError(secret, 500, true));
      const d = deps({ generator });
      await handleCardsRequest(post(VALID_BODY), d);
      expect(JSON.stringify(d.logged)).not.toContain(IMAGE);
      expect(d.logged[0]).toMatchObject({ jobId: "job-1", event: "cards.fail" });
    });
  });
});
