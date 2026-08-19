import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/_auth.js";
import {
  handleDarkMapRequest,
  parseCoverageInput,
  type DarkMapDependencies,
  type DarkMapSuccess,
} from "../api/_darkMap.js";
import { DARK_MAP_PROMPT_VERSION } from "../prompts/darkMap.js";
import { topicKey } from "../providers/topicCoverage.js";
import type { DarkMapRankRequest, DarkMapRankerLike, DarkMapRanking } from "../providers/darkMap.js";
import { GeminiError } from "../providers/gemini.js";
import { OpenAIError } from "../providers/openai.js";
import type { DarkMapConfig } from "../config.js";

const TOKEN = "t".repeat(MIN_TOKEN_LENGTH);
const DERMA = topicKey("Patoloji", "Deri Hastalıkları");
const PHARM = topicKey("Farmakoloji", "Genel Farmakoloji");

const CONFIG: DarkMapConfig = {
  maxZones: 12,
  maxSampleFronts: 4,
  reasoningEffort: "medium",
  maxOutputTokens: 16384,
  timeoutMs: 120_000,
};

function ranking(keys: string[], darkness = 4): DarkMapRanking {
  return {
    ratings: keys.map((key) => ({
      topicKey: key,
      darkness,
      tusYield: "high" as const,
      missingConcepts: [],
      reason: `${key} gerekçesi`,
    })),
    droppedUnknown: 0,
    rawUsage: { inputTokens: 2000, cachedInputTokens: 0, outputTokens: 400, reasoningTokens: 250 },
  };
}

/** Records what it was handed, so the closed-universe claim can be checked. */
function stubRanker(family: string, result: DarkMapRanking | Error): DarkMapRankerLike & {
  seen: DarkMapRankRequest[];
} {
  const seen: DarkMapRankRequest[] = [];
  return {
    family,
    model: `${family}-test`,
    seen,
    async rank(request) {
      seen.push(request);
      if (result instanceof Error) throw result;
      return result;
    },
  };
}

function deps(rankers: DarkMapRankerLike[], overrides: Partial<DarkMapDependencies> = {}): DarkMapDependencies {
  return {
    rankers,
    darkMap: CONFIG,
    deviceToken: TOKEN,
    now: () => new Date("2026-08-19T10:00:00.000Z"),
    ...overrides,
  };
}

function post(body: unknown, token = TOKEN): Request {
  return new Request("http://localhost/api/dark-map", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

const COVERAGE = [
  { subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 7, weakCardCount: 1 },
  { subject: "Farmakoloji", topic: "Genel Farmakoloji", cardCount: 2 },
];

describe("handleDarkMapRequest — guards", () => {
  it("refuses anything but POST", async () => {
    const response = await handleDarkMapRequest(
      new Request("http://localhost/api/dark-map", { method: "GET" }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    expect(response.status).toBe(405);
  });

  it("requires the device token", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }, "wrong-token-wrong-token"),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    expect(response.status).toBe(401);
  });

  it("requires a requestId", async () => {
    const response = await handleDarkMapRequest(
      post({ coverage: COVERAGE }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    expect(response.status).toBe(400);
  });

  /**
   * Answered before spending anything: with no canonical topic in scope both
   * calls would be asked to choose from an empty enum — a request that costs
   * money and cannot succeed.
   */
  it("refuses an empty canonical universe without calling a model", async () => {
    const ranker = stubRanker("openai", ranking([DERMA]));
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE, subjects: ["Kardiyoloji"] }),
      deps([ranker]),
    );
    expect(response.status).toBe(400);
    expect(ranker.seen).toHaveLength(0);
  });
});

describe("handleDarkMapRequest — the closed universe", () => {
  it("hands both families the full canonical table, zero-filled", async () => {
    const openai = stubRanker("openai", ranking([DERMA]));
    const gemini = stubRanker("gemini", ranking([DERMA]));
    await handleDarkMapRequest(post({ requestId: "r1", coverage: COVERAGE }), deps([openai, gemini]));

    const openaiSeen = openai.seen[0]!;
    const geminiSeen = gemini.seen[0]!;
    expect(openaiSeen.coverage).toHaveLength(143);
    // Same table for both — a consensus between readers handed different
    // inputs would measure our formatting, not their judgement.
    expect(geminiSeen.coverage).toEqual(openaiSeen.coverage);
    const derma = openaiSeen.coverage.find(
      (row) => row.subject === "Patoloji" && row.topic === "Deri Hastalıkları",
    );
    expect(derma).toMatchObject({ cardCount: 7, weakCardCount: 1 });
  });

  it("reports untouched topics deterministically", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.totals).toMatchObject({
      canonicalTopics: 143,
      coveredTopics: 2,
      untouchedTopics: 141,
      totalCards: 9,
    });
    expect(body.untouched).toHaveLength(141);

    // The pair is the identity, never the bare name. Six topic names live under
    // two subjects each ("Deri Hastalıkları" under Patoloji *and* Genel
    // Cerrahi), so covering one must leave the other untouched — an assertion
    // on the name alone passes for the wrong reason and would keep passing if
    // the whole feature collapsed topics across subjects.
    expect(body.untouched).toContainEqual({ subject: "Genel Cerrahi", topic: "Deri Hastalıkları" });
    expect(body.untouched).not.toContainEqual({ subject: "Patoloji", topic: "Deri Hastalıkları" });
  });

  it("counts a non-canonical client row without merging it", async () => {
    const response = await handleDarkMapRequest(
      post({
        requestId: "r1",
        coverage: [...COVERAGE, { subject: "Kardiyoloji", topic: "Aritmiler", cardCount: 50 }],
      }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.droppedUnknownFromClient).toBe(1);
    expect(body.totals.totalCards).toBe(9);
  });

  /** §21.3: the config is a ceiling; a client may only ever ask for fewer. */
  it("clamps a client asking for more zones than configured", async () => {
    const ranker = stubRanker("openai", ranking([DERMA]));
    await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE, maxZones: 500 }),
      deps([ranker]),
    );
    expect(ranker.seen[0]!.maxZones).toBe(12);
  });

  it("honours a client asking for fewer", async () => {
    const ranker = stubRanker("openai", ranking([DERMA]));
    await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE, maxZones: 3 }),
      deps([ranker]),
    );
    expect(ranker.seen[0]!.maxZones).toBe(3);
  });
});

describe("handleDarkMapRequest — consensus", () => {
  it("labels a zone both families flagged as confirmed", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", ranking([DERMA, PHARM])),
        stubRanker("gemini", ranking([DERMA])),
      ]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.singleRater).toBe(false);
    expect(body.zones.map((z) => [z.topicKey, z.consensus])).toEqual([
      [DERMA, "confirmed"],
      [PHARM, "disputed"],
    ]);
    expect(body.promptVersion).toBe(DARK_MAP_PROMPT_VERSION);
  });

  /**
   * The degradation that must never look like agreement. One family answering
   * still produces a useful study order, but every zone is `disputed` and
   * `singleRater` is set so the phone can say which half is missing.
   */
  it("degrades to a single rater when the other family fails", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", ranking([DERMA])),
        stubRanker("gemini", new GeminiError("Gemini 503: ayrıntı yok", 503, true)),
      ]),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.singleRater).toBe(true);
    expect(body.zones.every((zone) => zone.consensus === "disputed")).toBe(true);
    expect(body.raters).toEqual([
      { family: "openai", model: "openai-test", ok: true, zoneCount: 1, droppedUnknown: 0 },
      {
        family: "gemini",
        model: "gemini-test",
        ok: false,
        error: "Gemini 503: ayrıntı yok",
        zoneCount: 0,
        droppedUnknown: 0,
      },
    ]);
  });

  it("is single-rater by construction when only one ranker is configured", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.singleRater).toBe(true);
    expect(body.raters).toHaveLength(1);
  });

  /**
   * An empty ranking would read as "nothing is dark" — the one answer this
   * feature must never give by accident.
   */
  it("fails loudly when every family fails, naming each one", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", new OpenAIError("OpenAI 500: patladı", 500, true, undefined, "http_500")),
        stubRanker("gemini", new GeminiError("Gemini anahtarı reddedildi (403)", 403, false)),
      ]),
    );
    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: string; retryable: boolean };
    expect(body.retryable).toBe(true);
    expect(body.error).toContain("openai: OpenAI 500: patladı");
    expect(body.error).toContain("gemini: Gemini anahtarı reddedildi (403)");
  });

  it("reports a permanent total failure as non-retryable", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([stubRanker("openai", new OpenAIError("Şema geçersiz", undefined, false, undefined, "schema_invalid"))]),
    );
    expect(response.status).toBe(502);
    expect(((await response.json()) as { retryable: boolean }).retryable).toBe(false);
  });
});

describe("handleDarkMapRequest — the ledger", () => {
  it("writes one entry per family, priced and stamped", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([stubRanker("openai", ranking([DERMA])), stubRanker("gemini", ranking([PHARM]))]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.usage).toHaveLength(2);
    for (const entry of body.usage) {
      expect(entry).toMatchObject({
        attempt: 1,
        purpose: "dark_map",
        promptVersion: DARK_MAP_PROMPT_VERSION,
        outcome: "success",
        billing: "measured",
        at: "2026-08-19T10:00:00.000Z",
      });
      expect(entry.usage.reasoningTokens).toBe(250);
    }
    expect(body.usage.map((entry) => entry.provider)).toEqual(["openai", "gemini"]);
  });

  /**
   * The distinction `tokenUsage.ts` exists for: a call rejected at the door is
   * genuinely free, while one cut off mid-flight was generated and billed with
   * nobody able to say how much.
   */
  it("records a rejected call as free and an aborted one as unmeasured", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", new OpenAIError("zaman aşımı", undefined, true, undefined, "timeout")),
        stubRanker("gemini", new GeminiError("Gemini anahtarı reddedildi (403)", 403, false)),
      ]),
    );
    expect(response.status).toBe(503);
    const body = (await response.json()) as { usage?: Array<Record<string, unknown>> };
    const byProvider = Object.fromEntries((body.usage ?? []).map((e) => [e.provider, e]));
    // Our own timeout: the request reached the model and was billed, amount
    // unknown.
    expect(byProvider.openai).toMatchObject({ billing: "unmeasured", failureReason: "timeout" });
    // Rejected before any generation: genuinely free.
    expect(byProvider.gemini).toMatchObject({ billing: "none" });
  });

  /**
   * The hole this closes: two rankers can each burn their whole output budget
   * and then truncate — billed in full, nothing returned. An error body that
   * dropped the ledger would leave that spend invisible on Ayarlar → Kullanım,
   * which is the exact under-reporting `tokenUsage.ts` was written to end.
   */
  it("carries the ledger out with a both-failed error", async () => {
    const spent = { inputTokens: 3000, cachedInputTokens: 0, outputTokens: 16384, reasoningTokens: 16000 };
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", new OpenAIError("kesildi", undefined, true, spent, "incomplete_max_output_tokens")),
        stubRanker("gemini", new OpenAIError("kesildi", undefined, true, spent, "incomplete_max_output_tokens")),
      ]),
    );
    expect(response.status).toBe(503);
    const body = (await response.json()) as { usage?: Array<Record<string, unknown>> };
    expect(body.usage).toHaveLength(2);
    for (const entry of body.usage ?? []) {
      expect(entry).toMatchObject({ purpose: "dark_map", outcome: "failure", billing: "measured" });
    }
  });

  /** A guard failure reached no model, so there is nothing to report. */
  it("omits the ledger from a failure that never called a model", async () => {
    const response = await handleDarkMapRequest(
      post({ coverage: COVERAGE }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    expect(response.status).toBe(400);
    expect((await response.json()) as Record<string, unknown>).not.toHaveProperty("usage");
  });

  it("prices failures that reported usage", async () => {
    const spent = { inputTokens: 1000, cachedInputTokens: 0, outputTokens: 16384, reasoningTokens: 16000 };
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", ranking([DERMA])),
        stubRanker(
          "gemini",
          new OpenAIError("kesildi", undefined, true, spent, "incomplete_max_output_tokens"),
        ),
      ]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    const failed = body.usage.find((entry) => entry.outcome === "failure");
    expect(failed).toMatchObject({
      billing: "measured",
      failureReason: "incomplete_max_output_tokens",
    });
    expect(failed?.usage.outputTokens).toBe(16384);
  });

  /** §7.3: counts and family names, never a topic name or a card front. */
  it("logs no topic name, reason or card front", async () => {
    const entries: Record<string, unknown>[] = [];
    await handleDarkMapRequest(
      post({
        requestId: "r1",
        coverage: [{ ...COVERAGE[0], sampleFronts: ["Gizli kart sorusu"] }],
      }),
      deps([stubRanker("openai", ranking([DERMA]))], { log: (entry) => entries.push(entry) }),
    );
    const serialized = JSON.stringify(entries);
    expect(serialized).not.toContain("Gizli kart sorusu");
    expect(serialized).not.toContain("Deri Hastalıkları");
    expect(serialized).not.toContain("gerekçesi");
    expect(entries[0]).toMatchObject({ event: "dark_map.ok", zoneCount: 1, confirmed: 0 });
  });
});

describe("parseCoverageInput", () => {
  it("skips rows without string subject and topic", () => {
    expect(
      parseCoverageInput([
        { subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 3 },
        { subject: 5, topic: "x" },
        { topic: "x" },
        null,
        "nope",
      ]),
    ).toEqual([
      {
        subject: "Patoloji",
        topic: "Deri Hastalıkları",
        cardCount: 3,
        weakCardCount: 0,
        sampleFronts: [],
      },
    ]);
  });

  it("returns nothing for a non-array", () => {
    expect(parseCoverageInput({ subject: "Patoloji" })).toEqual([]);
    expect(parseCoverageInput(undefined)).toEqual([]);
  });
});

describe("Gemini failure accounting (Codex, PR #49)", () => {
  /**
   * Gemini returns `usageMetadata` alongside a truncated generation, so the
   * most expensive failure in the system is also the one where the exact figure
   * is available. Before the fix the ledger recorded it as unmeasured with zero
   * tokens — under-reporting precisely where measurement existed.
   */
  it("records a truncated Gemini call as measured, with its real tokens", async () => {
    const spent = { inputTokens: 2500, cachedInputTokens: 0, outputTokens: 16384, reasoningTokens: 15900 };
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", ranking([DERMA])),
        stubRanker("gemini", new GeminiError("MAX_TOKENS", undefined, true, spent)),
      ]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    const failed = body.usage.find((entry) => entry.provider === "gemini");
    expect(failed).toMatchObject({ outcome: "failure", billing: "measured" });
    expect(failed?.usage.outputTokens).toBe(16384);
    expect(failed?.usage.reasoningTokens).toBe(15900);
  });

  /** A rejected key generated nothing, so it stays genuinely free. */
  it("still records a rejected Gemini call as free", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", ranking([DERMA])),
        stubRanker("gemini", new GeminiError("403", 403, false)),
      ]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.usage.find((e) => e.provider === "gemini")).toMatchObject({ billing: "none" });
  });

  /**
   * A Gemini timeout used to escape as a raw AbortError, which is neither
   * error type the all-failed path inspects — so a transient network failure
   * paired with a permanent OpenAI one produced `retryable: false` and the
   * phone offered no "Tekrar dene".
   */
  it("treats a transient Gemini failure as retryable even beside a permanent OpenAI one", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", new OpenAIError("şema", undefined, false, undefined, "schema_invalid")),
        stubRanker("gemini", new GeminiError("zaman aşımında kesildi", undefined, true)),
      ]),
    );
    expect(response.status).toBe(503);
    expect(((await response.json()) as { retryable: boolean }).retryable).toBe(true);
  });
});

describe("merged zone ceiling (Codex, PR #49)", () => {
  it("never returns more zones than the request allows", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE, maxZones: 1 }),
      deps([
        // Disjoint picks: two families, two different topics, ceiling of one.
        stubRanker("openai", ranking([DERMA], 5)),
        stubRanker("gemini", ranking([PHARM], 4)),
      ]),
    );
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.zones).toHaveLength(1);
    expect(body.zones[0]!.topicKey).toBe(DERMA);
  });
});

describe("deterministic half on the failure path (Codex, PR #49)", () => {
  /**
   * The module header promises `untouched` is "produced before any model is
   * called and returned even if both of them fail". The failure path was
   * throwing that already-computed arithmetic away with the error.
   */
  it("carries untouched and totals out with a both-failed error", async () => {
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: COVERAGE }),
      deps([
        stubRanker("openai", new OpenAIError("500", 500, true, undefined, "http_500")),
        stubRanker("gemini", new GeminiError("503", 503, true)),
      ]),
    );
    expect(response.status).toBe(503);
    const body = (await response.json()) as {
      untouched?: Array<{ subject: string; topic: string }>;
      totals?: Record<string, number>;
    };
    expect(body.totals).toMatchObject({
      canonicalTopics: 143,
      coveredTopics: 2,
      untouchedTopics: 141,
      totalCards: 9,
    });
    expect(body.untouched).toHaveLength(141);
    // The pair, not the bare name — same trap the success path guards.
    expect(body.untouched).toContainEqual({ subject: "Genel Cerrahi", topic: "Deri Hastalıkları" });
  });

  /** Success and failure must project the deterministic half identically. */
  it("shapes it the same way the success path does", async () => {
    const ok = (await (
      await handleDarkMapRequest(
        post({ requestId: "r1", coverage: COVERAGE }),
        deps([stubRanker("openai", ranking([DERMA]))]),
      )
    ).json()) as DarkMapSuccess;
    const failed = (await (
      await handleDarkMapRequest(
        post({ requestId: "r1", coverage: COVERAGE }),
        deps([stubRanker("openai", new GeminiError("503", 503, true))]),
      )
    ).json()) as { untouched: unknown; totals: unknown };
    expect(failed.totals).toEqual(ok.totals);
    expect(failed.untouched).toEqual(ok.untouched);
  });

  /** A guard failure built no coverage, so there is nothing honest to report. */
  it("omits it when the request never got as far as building coverage", async () => {
    const response = await handleDarkMapRequest(
      post({ coverage: COVERAGE }),
      deps([stubRanker("openai", ranking([DERMA]))]),
    );
    expect(response.status).toBe(400);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).not.toHaveProperty("untouched");
    expect(body).not.toHaveProperty("totals");
  });

  /**
   * An empty deck is a legitimate request, not an error: the server zero-fills
   * all 143 canonical topics and ranks by TUS weight alone. The phone used to
   * refuse to even ask (Codex, PR #49).
   */
  it("ranks a completely empty coverage list", async () => {
    const ranker = stubRanker("openai", ranking([DERMA]));
    const response = await handleDarkMapRequest(
      post({ requestId: "r1", coverage: [] }),
      deps([ranker]),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as DarkMapSuccess;
    expect(body.totals).toMatchObject({ coveredTopics: 0, untouchedTopics: 143, totalCards: 0 });
    expect(ranker.seen[0]!.coverage).toHaveLength(143);
  });
});
