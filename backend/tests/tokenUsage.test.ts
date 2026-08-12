import { describe, expect, it } from "vitest";

import {
  EMPTY_TOKEN_USAGE,
  estimateCostUSD,
  readGeminiUsage,
  readOpenAIUsage,
  type TokenPrices,
} from "../providers/tokenUsage.js";

/** Deliberately distinct per field so a swapped price shows up as a wrong total. */
const PRICES: TokenPrices = {
  usdPerMillionInputTokens: 10,
  usdPerMillionCachedInputTokens: 1,
  usdPerMillionOutputTokens: 100,
};

describe("estimateCostUSD", () => {
  it("bills the cached share at the cached rate and the rest at the full one", () => {
    // The bug this whole module exists for: `cachedInputTokens` is a *subset*
    // of `inputTokens`, so pricing the total at the uncached rate charges the
    // cached tokens ten times over.
    const usage = {
      inputTokens: 1_000_000,
      cachedInputTokens: 800_000,
      outputTokens: 0,
      reasoningTokens: 0,
    };
    // 200k @ $10/M + 800k @ $1/M = 2.00 + 0.80
    expect(estimateCostUSD(usage, PRICES)).toBeCloseTo(2.8);
    // What the old arithmetic would have said, for contrast.
    expect(estimateCostUSD({ ...usage, cachedInputTokens: 0 }, PRICES)).toBeCloseTo(10);
  });

  it("does not double-count reasoning tokens on top of output tokens", () => {
    // Both providers report reasoning as a share of output, not in addition to
    // it. Adding them would inflate every reasoning-capable call.
    const usage = {
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 1_000_000,
      reasoningTokens: 700_000,
    };
    expect(estimateCostUSD(usage, PRICES)).toBeCloseTo(100);
  });

  it("never returns a negative cost when a provider reports more cached than input", () => {
    // Untrusted JSON: a nonsense pair must produce a small wrong number, not a
    // refund that quietly drags the Kullanım total down.
    const usage = {
      inputTokens: 100,
      cachedInputTokens: 5_000,
      outputTokens: 0,
      reasoningTokens: 0,
    };
    expect(estimateCostUSD(usage, PRICES)).toBeGreaterThanOrEqual(0);
    // Everything it has is priced as cached; nothing is priced twice.
    expect(estimateCostUSD(usage, PRICES)).toBeCloseTo((100 / 1_000_000) * 1);
  });

  it("is zero for an empty usage", () => {
    expect(estimateCostUSD(EMPTY_TOKEN_USAGE, PRICES)).toBe(0);
  });
});

describe("readOpenAIUsage", () => {
  it("unpacks both nested detail objects", () => {
    expect(
      readOpenAIUsage({
        usage: {
          input_tokens: 4200,
          output_tokens: 2600,
          input_tokens_details: { cached_tokens: 3072 },
          output_tokens_details: { reasoning_tokens: 1900 },
        },
      }),
    ).toEqual({
      inputTokens: 4200,
      cachedInputTokens: 3072,
      outputTokens: 2600,
      reasoningTokens: 1900,
    });
  });

  it("treats missing detail objects as zero rather than failing", () => {
    // An older model, or a response shape that changes under us, must degrade
    // to "we know the totals, not the split" — never to a thrown TypeError on
    // the error path, where this also runs.
    expect(readOpenAIUsage({ usage: { input_tokens: 10, output_tokens: 20 } })).toEqual({
      inputTokens: 10,
      cachedInputTokens: 0,
      outputTokens: 20,
      reasoningTokens: 0,
    });
  });

  it("returns null when there is no usage block at all", () => {
    // The distinction the ledger's `billing` field rests on: null means the
    // provider never told us, which is not the same as telling us zero.
    expect(readOpenAIUsage({ error: { message: "rate limited" } })).toBeNull();
    expect(readOpenAIUsage(undefined)).toBeNull();
    expect(readOpenAIUsage("<html>proxy error</html>")).toBeNull();
  });

  it("ignores negative and non-numeric counts", () => {
    expect(
      readOpenAIUsage({ usage: { input_tokens: -5, output_tokens: "many" } }),
    ).toEqual(EMPTY_TOKEN_USAGE);
  });
});

describe("readGeminiUsage", () => {
  it("folds thoughts tokens into the output total, unlike OpenAI's shape", () => {
    // Gemini reports thinking *alongside* `candidatesTokenCount`, not inside
    // it, and both are billed at the output rate. Reading it like OpenAI's
    // would under-report every thinking call.
    expect(
      readGeminiUsage({
        usageMetadata: {
          promptTokenCount: 800,
          candidatesTokenCount: 90,
          cachedContentTokenCount: 512,
          thoughtsTokenCount: 250,
        },
      }),
    ).toEqual({
      inputTokens: 800,
      cachedInputTokens: 512,
      outputTokens: 340,
      reasoningTokens: 250,
    });
  });

  it("returns null when the response carries no usageMetadata", () => {
    expect(readGeminiUsage({ candidates: [] })).toBeNull();
  });
});
