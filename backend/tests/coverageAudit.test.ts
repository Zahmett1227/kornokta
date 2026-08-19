import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/_auth.js";
import {
  MAX_AUDITED_CARDS,
  handleCoverageRequest,
  parseAuditCards,
  type CoverageDependencies,
} from "../api/_coverage.js";
import type { GeminiConfig } from "../config.js";
import { COVERAGE_AUDIT_PROMPT, buildCoverageAuditInstruction } from "../prompts/coverageAudit.js";
import {
  GeminiCoverageAudit,
  GeminiError,
  type CoverageAuditRequest,
  type CoverageAuditResult,
  type GeminiTransport,
} from "../providers/gemini.js";

const TOKEN = "t".repeat(MIN_TOKEN_LENGTH);
const IMAGE = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");

const CONFIG: GeminiConfig = {
  model: "gemini-3.5-flash",
  maxOutputTokens: 4096,
  coverageMaxOutputTokens: 8192,
  timeoutMs: 1_000,
};

const COST = {
  geminiUsdPerMillionInputTokens: 1,
  geminiUsdPerMillionCachedInputTokens: 0.1,
  geminiUsdPerMillionOutputTokens: 4,
};

const REQUEST: CoverageAuditRequest = {
  requestId: "page-1",
  image: new Uint8Array([1, 2, 3]),
  mimeType: "image/jpeg",
  cards: [
    { front: "Reed-Sternberg hücresi hangi belirteci taşır?", back: "CD30" },
    { front: "Hodgkin lenfomada en sık alt tip nedir?", back: "Nodüler sklerozan" },
  ],
};

function envelope(json: unknown, finishReason = "STOP") {
  return {
    candidates: [{ content: { parts: [{ text: JSON.stringify(json) }] }, finishReason }],
    usageMetadata: { promptTokenCount: 1500, candidatesTokenCount: 300 },
  };
}

function stubTransport(status: number, body: unknown) {
  const calls: Array<{ url: string; body: any }> = [];
  const transport: GeminiTransport = {
    async post(url, _apiKey, requestBody) {
      calls.push({ url, body: requestBody });
      return { status, body };
    },
  };
  return { transport, calls };
}

describe("coverage audit prompt", () => {
  it("forbids writing cards and forbids judging the ones it is shown", () => {
    // The two things that would turn an audit into a second generator (and a
    // second bill). The schema has nowhere to put a card; the prompt says so
    // in words too, the same belt-and-braces `handwritingSecondOpinion` uses.
    expect(COVERAGE_AUDIT_PROMPT).toContain("KART ÜRETME");
    expect(COVERAGE_AUDIT_PROMPT).toContain("DOĞRU olup olmadığını değerlendirme");
  });

  it("asks for verbatim quotes and refuses invented marks", () => {
    // A claimed mark that is not on the page costs the owner a decision every
    // single time, and a personal tool that cries wolf gets switched off.
    expect(COVERAGE_AUDIT_PROMPT).toContain("BİREBİR");
    expect(COVERAGE_AUDIT_PROMPT).toContain("görmediğin bir işareti YAZMA");
  });

  it("numbers the cards so coveredByCardIndex means something", () => {
    const instruction = buildCoverageAuditInstruction("page-1", REQUEST.cards);
    expect(instruction).toContain("[0] S: Reed-Sternberg");
    expect(instruction).toContain("[1] S: Hodgkin");
  });

  it("says every mark is uncovered when the page produced no cards", () => {
    // The case that matters most and is easiest to get wrong: a page whose job
    // produced nothing. Handing the model an empty list without a sentence
    // invites it to answer as if coverage were fine.
    const instruction = buildCoverageAuditInstruction("page-1", []);
    expect(instruction).toContain("HİÇ kart üretilmemiş");
  });
});

describe("GeminiCoverageAudit", () => {
  it("returns the uncovered marks, most valuable tier first", async () => {
    const { transport } = stubTransport(
      200,
      envelope({
        marks: [
          { kind: "highlight", quote: "geniş vurgu", coveredByCardIndex: null },
          { kind: "underline", quote: "nodüler sklerozan", coveredByCardIndex: 1 },
          { kind: "handwriting", quote: "hoca: EBV ilişkisi", coveredByCardIndex: null },
        ],
      }),
    );
    const result = await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);

    expect(result.marks).toHaveLength(3);
    // Handwriting before highlighter — prompt rule 3's ladder, shared with the
    // generator's own register through `markPriority`.
    expect(result.uncovered.map((mark) => mark.quote)).toEqual(["hoca: EBV ilişkisi", "geniş vurgu"]);
    expect(result.discarded).toBe(0);
    expect(result.usage.provider).toBe("gemini");
    expect(result.usage.estimatedCostUSD).toBeGreaterThan(0);
  });

  it("discards a row pointing at a card that does not exist, without calling it uncovered", async () => {
    // The auditor losing track of the list is not evidence about the mark.
    // Reading it as "uncovered" would manufacture exactly the false positive
    // the prompt spends a rule avoiding, so it is dropped and counted.
    const { transport } = stubTransport(
      200,
      envelope({
        marks: [
          { kind: "symbol", quote: "★ CD30", coveredByCardIndex: 7 },
          { kind: "symbol", quote: "★ gerçekten kartsız", coveredByCardIndex: null },
        ],
      }),
    );
    const result = await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);

    expect(result.discarded).toBe(1);
    expect(result.uncovered.map((mark) => mark.quote)).toEqual(["★ gerçekten kartsız"]);
  });

  it("drops rows with an unknown tier or an empty quote", async () => {
    const { transport } = stubTransport(
      200,
      envelope({
        marks: [
          { kind: "scribble", quote: "bilinmeyen kademe", coveredByCardIndex: null },
          { kind: "underline", quote: "   ", coveredByCardIndex: null },
          { kind: "underline", quote: "gerçek", coveredByCardIndex: null },
        ],
      }),
    );
    const result = await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);

    expect(result.marks.map((mark) => mark.quote)).toEqual(["gerçek"]);
    expect(result.discarded).toBe(2);
  });

  it("makes the coverage verdict required, so omission cannot pass as 'uncovered'", async () => {
    // Codex, PR #47: with the field merely optional, a row carrying only
    // `kind` and `quote` was schema-valid and read exactly like an explicit
    // `null` — inventing a "you skipped this" out of a formatting slip. The
    // model must now state `null` deliberately.
    const { transport, calls } = stubTransport(200, envelope({ marks: [] }));
    await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);

    const schema = calls[0]!.body.generationConfig.responseSchema;
    expect(schema.properties.marks.items.required).toContain("coveredByCardIndex");
    expect(schema.properties.marks.items.properties.coveredByCardIndex.nullable).toBe(true);
  });

  it("discards a row that omits the verdict instead of calling it uncovered", async () => {
    const { transport } = stubTransport(
      200,
      envelope({
        marks: [
          { kind: "symbol", quote: "alanı hiç yazmadı" },
          { kind: "symbol", quote: "açıkça kartsız", coveredByCardIndex: null },
        ],
      }),
    );
    const result = await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);

    expect(result.discarded).toBe(1);
    expect(result.uncovered.map((mark) => mark.quote)).toEqual(["açıkça kartsız"]);
  });

  it("speaks the generator's own four tiers, not a second vocabulary", async () => {
    // Two readers describing marks in two vocabularies could not be merged on
    // the phone, which is the entire reason for running both.
    const { transport, calls } = stubTransport(200, envelope({ marks: [] }));
    await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);

    const schema = calls[0]!.body.generationConfig.responseSchema;
    expect(schema.properties.marks.items.properties.kind.enum).toEqual([
      "handwriting",
      "symbol",
      "underline",
      "highlight",
    ]);
  });

  it("spends its own output ceiling, not the second opinion's", async () => {
    // A register of twenty verbatim quotes is a much bigger answer than a
    // one-line verdict; sharing the 4096 would truncate exactly the dense
    // pages worth auditing.
    const { transport, calls } = stubTransport(200, envelope({ marks: [] }));
    await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport).audit(REQUEST);
    expect(calls[0]!.body.generationConfig.maxOutputTokens).toBe(8192);
  });

  it("names its own budget variable when the answer is truncated", async () => {
    // Sending someone to raise GEMINI_MAX_OUTPUT_TOKENS would have them turn a
    // knob that does not affect this call at all.
    const { transport } = stubTransport(200, {
      candidates: [{ content: { parts: [{ text: '{"marks":[{"kind":"sym' }] }, finishReason: "MAX_TOKENS" }],
    });
    const error = await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport)
      .audit(REQUEST)
      .catch((caught) => caught as GeminiError);

    expect((error as GeminiError).message).toContain("GEMINI_COVERAGE_MAX_OUTPUT_TOKENS");
    expect((error as GeminiError).transient).toBe(true);
  });

  it("refuses an answer with no marks list rather than reporting a clean page", async () => {
    // "No register" and "nothing uncovered" are different answers, and only one
    // of them is good news.
    const { transport } = stubTransport(200, envelope({ notes: "hiçbir şey" }));
    const error = await new GeminiCoverageAudit(CONFIG, "g-test", COST, transport)
      .audit(REQUEST)
      .catch((caught) => caught as GeminiError);

    expect(error).toBeInstanceOf(GeminiError);
    expect((error as GeminiError).transient).toBe(false);
  });
});

describe("parseAuditCards", () => {
  it("accepts an empty list — a page that produced nothing is the point", () => {
    expect(parseAuditCards([])).toEqual([]);
  });

  it("rejects the whole list rather than skipping a malformed card", () => {
    // `coveredByCardIndex` is an index into this array: dropping one entry
    // shifts every index after it and turns covered marks into uncovered ones.
    expect(parseAuditCards([{ front: "a", back: "b" }, { front: "c" }])).toBeNull();
    expect(parseAuditCards([{ front: "  ", back: "b" }])).toBeNull();
    expect(parseAuditCards("kart")).toBeNull();
    expect(parseAuditCards(Array.from({ length: MAX_AUDITED_CARDS + 1 }, () => ({ front: "a", back: "b" })))).toBeNull();
  });
});

describe("POST /api/coverage", () => {
  function deps(
    result: CoverageAuditResult | Error = {
      marks: [{ kind: "symbol", quote: "★ CD30", coveredByCardIndex: null }],
      uncovered: [{ kind: "symbol", quote: "★ CD30", coveredByCardIndex: null }],
      discarded: 0,
      usage: {
        provider: "gemini",
        model: "gemini-3.5-flash",
        inputTokens: 1500,
        cachedInputTokens: 0,
        outputTokens: 300,
        reasoningTokens: 0,
        estimatedCostUSD: 0.0027,
      },
    },
  ): CoverageDependencies & { logged: Record<string, unknown>[] } {
    const logged: Record<string, unknown>[] = [];
    return {
      auditor: {
        async audit() {
          if (result instanceof Error) throw result;
          return result;
        },
      },
      deviceToken: TOKEN,
      log: (entry) => logged.push(entry),
      logged,
    };
  }

  function post(body: unknown, token: string | null = TOKEN): Request {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    return new Request("https://example.test/api/coverage", {
      method: "POST",
      headers,
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
  }

  const VALID_BODY = {
    requestId: "page-1",
    mimeType: "image/jpeg",
    imageBase64: IMAGE,
    cards: [{ front: "soru", back: "cevap" }],
  };

  it("returns the audit with the prompt version the ledger needs", async () => {
    const response = await handleCoverageRequest(post(VALID_BODY), deps());
    expect(response.status).toBe(200);

    const body = (await response.json()) as {
      requestId: string;
      uncovered: unknown[];
      promptVersion: string;
      usage: { estimatedCostUSD: number };
    };
    expect(body.requestId).toBe("page-1");
    expect(body.uncovered).toHaveLength(1);
    expect(body.promptVersion).toBe("1.0");
    expect(body.usage.estimatedCostUSD).toBeGreaterThan(0);
  });

  it("requires the device token", async () => {
    const response = await handleCoverageRequest(post(VALID_BODY, null), deps());
    expect(response.status).toBe(401);
  });

  it("rejects a body without a request id, an image or a card list", async () => {
    for (const body of [
      { ...VALID_BODY, requestId: "" },
      { ...VALID_BODY, imageBase64: undefined },
      { ...VALID_BODY, cards: undefined },
      { ...VALID_BODY, mimeType: "application/pdf" },
    ]) {
      const response = await handleCoverageRequest(post(body), deps());
      expect(response.status).toBeGreaterThanOrEqual(400);
      expect(response.status).toBeLessThan(500);
    }
  });

  it("logs counts only — a mark's quote is page content (§7.3)", async () => {
    const dependencies = deps({
      marks: [{ kind: "handwriting", quote: "sayfadan gizli kalması gereken metin", coveredByCardIndex: null }],
      uncovered: [{ kind: "handwriting", quote: "sayfadan gizli kalması gereken metin", coveredByCardIndex: null }],
      discarded: 2,
      usage: {
        provider: "gemini",
        model: "gemini-3.5-flash",
        inputTokens: 10,
        cachedInputTokens: 0,
        outputTokens: 5,
        reasoningTokens: 0,
        estimatedCostUSD: 0.0001,
      },
    });
    await handleCoverageRequest(post(VALID_BODY), dependencies);

    const entry = dependencies.logged.find((line) => line.event === "coverage.ok");
    expect(entry?.markCount).toBe(1);
    expect(entry?.uncoveredMarkCount).toBe(1);
    expect(entry?.discardedMarkCount).toBe(2);
    expect(JSON.stringify(dependencies.logged)).not.toContain("gizli kalması");
  });

  it("passes the provider's own message through, with its retryability", async () => {
    // The quota message is the one the owner asked to see by name; rewording
    // it here would undo exactly that.
    const dependencies = deps(new GeminiError("Gemini kotası/kredisi tükenmiş görünüyor (429).", 429, true));
    const response = await handleCoverageRequest(post(VALID_BODY), dependencies);

    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: string; retryable: boolean };
    expect(body.error).toContain("kotası/kredisi");
    expect(body.retryable).toBe(true);
  });

  it("tells the phone how a failed call should be billed (Codex, PR #47)", async () => {
    // `retryable` is not a billing signal and the two disagree in both
    // directions: a 429 is retryable and *free* (Gemini rejected it), while a
    // safety stop is permanent and *billed* (it generated first). The phone
    // cannot derive that — only the server sees which happened — so it is
    // stated on the wire.
    const rejected = deps(new GeminiError("Gemini kotası tükendi (429).", 429, true));
    const rejectedBody = (await (await handleCoverageRequest(post(VALID_BODY), rejected)).json()) as {
      retryable: boolean;
      billing?: string;
    };
    expect(rejectedBody.retryable).toBe(true);
    expect(rejectedBody.billing).toBe("none");

    const generated = deps(new GeminiError("Model üretimi temiz bitmedi (SAFETY).", undefined, false));
    const generatedBody = (await (await handleCoverageRequest(post(VALID_BODY), generated)).json()) as {
      retryable: boolean;
      billing?: string;
    };
    expect(generatedBody.retryable).toBe(false);
    expect(generatedBody.billing).toBe("unmeasured");
  });

  it("calls a pre-provider refusal free rather than leaving the phone to guess", async () => {
    // Every refusal in this file happens before Gemini is called. Omitting the
    // field made the phone guess, and guessing "possibly billed" filed
    // configuration errors as spend (Codex, PR #47).
    for (const body of [
      { ...VALID_BODY, cards: undefined },
      { ...VALID_BODY, mimeType: "application/pdf" },
      { ...VALID_BODY, requestId: "" },
    ]) {
      const response = await handleCoverageRequest(post(body), deps());
      const parsed = (await response.json()) as { billing?: string };
      expect(parsed.billing).toBe("none");
    }
  });
});
