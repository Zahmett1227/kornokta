/**
 * Token accounting shared by every paid provider call (§16.8, §20.3).
 *
 * Written because the project could not answer a question it should always
 * have been able to answer: "what did that call cost?". Three separate holes
 * made it unanswerable.
 *
 * 1. **Cached input was priced as uncached.** Providers bill a prompt prefix
 *    they have already seen at roughly a tenth of the normal rate, and report
 *    the cached share in `usage`. Multiplying the *total* input by the full
 *    price overstates a cached call several-fold.
 * 2. **Reasoning tokens were invisible.** A reasoning-capable model spends
 *    hidden thinking tokens that are billed as output, at the output price —
 *    the most expensive tokens in the whole system. They were folded into one
 *    `outputTokens` number, so "is the money going to cards or to thinking?"
 *    had no answer.
 * 3. **Failed calls were not recorded at all.** A generation that burns its
 *    whole output budget and then fails schema validation costs exactly as
 *    much as one that succeeds. Only successes were written down, so the
 *    ledger was guaranteed to read low, and by an unknown amount.
 *
 * This module owns the shape and the arithmetic; the providers own only the
 * extraction of their own wire format. No content ever passes through here —
 * counts, prices and durations only (§7.3).
 */

/**
 * One call's token counts, as the provider reported them.
 *
 * `cachedInputTokens` is a *subset* of `inputTokens`, and `reasoningTokens` is
 * a *subset* of `outputTokens` — that is how both OpenAI and Gemini report
 * them, and re-deriving totals by addition here would double-count. The cost
 * function subtracts rather than adds for exactly this reason.
 */
export interface TokenUsage {
  /** Every input token, cached ones included. */
  inputTokens: number;
  /** The share of `inputTokens` served from the provider's prompt cache. */
  cachedInputTokens: number;
  /** Every output token, hidden reasoning included. */
  outputTokens: number;
  /** The share of `outputTokens` the model spent thinking rather than answering. */
  reasoningTokens: number;
}

export const EMPTY_TOKEN_USAGE: TokenUsage = {
  inputTokens: 0,
  cachedInputTokens: 0,
  outputTokens: 0,
  reasoningTokens: 0,
};

/**
 * Per-million prices for one provider.
 *
 * `usdPerMillionCachedInputTokens` deliberately has no independent default:
 * `config.ts` falls back to the uncached input price. A zero default would
 * make every cached token free in our own books and quietly under-report
 * spend — the precise failure this module exists to end. Overstating a cached
 * call by the size of the discount is the safe direction to be wrong in.
 */
export interface TokenPrices {
  usdPerMillionInputTokens: number;
  usdPerMillionCachedInputTokens: number;
  usdPerMillionOutputTokens: number;
}

/**
 * Estimated USD for one call (§20.3).
 *
 * `Math.max(0, …)` guards the subtraction rather than trusting it: the counts
 * come from a provider's JSON, and a response claiming more cached tokens than
 * input tokens must produce a small wrong number, not a negative one that
 * silently pays the user back on the totals screen.
 */
export function estimateCostUSD(usage: TokenUsage, prices: TokenPrices): number {
  const cached = Math.max(0, Math.min(usage.cachedInputTokens, usage.inputTokens));
  const uncached = Math.max(0, usage.inputTokens - cached);
  return (
    (uncached / 1_000_000) * prices.usdPerMillionInputTokens +
    (cached / 1_000_000) * prices.usdPerMillionCachedInputTokens +
    (usage.outputTokens / 1_000_000) * prices.usdPerMillionOutputTokens
  );
}

/** Every provider call this system can make. Kept narrow so the phone can switch on it. */
export type CallPurpose = "card_generation" | "second_opinion";

/**
 * One line of the ledger: a single provider call, priced, whatever became of it.
 *
 * Deliberately produced on *both* the success and the failure path. A failed
 * call is not a non-event — it is the case the whole feature was built to make
 * visible, because it is the one that spends money and returns nothing.
 */
export interface CallAccounting {
  /**
   * Which attempt at this job this was, 1-based, as the job row counts them.
   * The phone's ledger is keyed on (jobId, purpose, attempt), so a page polled
   * twice records one entry rather than two.
   */
  attempt: number;
  provider: string;
  model: string;
  purpose: CallPurpose;
  promptVersion: string;
  outcome: "success" | "failure";
  /**
   * Why it failed, in a handful of words, or absent on success. Describes the
   * *call*, never the content (§7.3) — "max_output_tokens", "schema", "timeout".
   */
  failureReason?: string;
  /**
   * What is actually known about this call's billing.
   *
   * Three states, not a boolean, because zeros are ambiguous in a way that
   * matters more than anything else in this ledger:
   *
   * - `measured` — the provider reported usage. The figures below are real.
   * - `unmeasured` — the request reached the model but no usage block ever
   *   came back: our own timeout aborted the connection, or the serverless
   *   instance was killed mid-generation. The provider generated and billed
   *   anyway; we simply cannot say how much. **This is the leak worth
   *   finding**, and as a boolean it was indistinguishable from the next case.
   * - `none` — rejected before any generation happened (auth, quota, a rate
   *   limit, a malformed request). Genuinely free.
   *
   * A totals screen must add up `measured` costs, and separately *count* the
   * `unmeasured` ones — averaging them into money would invent a number, and
   * dropping them would hide the failure mode.
   */
  billing: "measured" | "unmeasured" | "none";
  usage: TokenUsage;
  estimatedCostUSD: number;
  latencyMs: number;
  /** ISO 8601, stamped by the server that made the call. */
  at: string;
}

/**
 * Reads OpenAI's Responses API `usage` block.
 *
 * Tolerant by design: this runs on the error path too, where the body may be a
 * proxy's HTML or a truncated response, and a thrown `TypeError` here would
 * replace a useful provider error with a useless parsing one.
 */
export function readOpenAIUsage(body: unknown): TokenUsage | null {
  const usage = (body as { usage?: Record<string, unknown> } | undefined)?.usage;
  if (!usage || typeof usage !== "object") return null;
  const inputDetails = usage.input_tokens_details as { cached_tokens?: unknown } | undefined;
  const outputDetails = usage.output_tokens_details as { reasoning_tokens?: unknown } | undefined;
  return {
    inputTokens: count(usage.input_tokens),
    cachedInputTokens: count(inputDetails?.cached_tokens),
    outputTokens: count(usage.output_tokens),
    reasoningTokens: count(outputDetails?.reasoning_tokens),
  };
}

/**
 * Reads Gemini's `usageMetadata` block.
 *
 * `thoughtsTokenCount` is Gemini's name for what OpenAI calls reasoning
 * tokens, and like OpenAI's it is billed at the output rate. Gemini reports it
 * *alongside* `candidatesTokenCount` rather than inside it, so it is added
 * here — the opposite of the OpenAI case, and the reason these two readers are
 * separate functions rather than one with a flag.
 */
export function readGeminiUsage(body: unknown): TokenUsage | null {
  const usage = (body as { usageMetadata?: Record<string, unknown> } | undefined)?.usageMetadata;
  if (!usage || typeof usage !== "object") return null;
  const thoughts = count(usage.thoughtsTokenCount);
  return {
    inputTokens: count(usage.promptTokenCount),
    cachedInputTokens: count(usage.cachedContentTokenCount),
    outputTokens: count(usage.candidatesTokenCount) + thoughts,
    reasoningTokens: thoughts,
  };
}

/** A non-negative integer, or 0 for anything else a provider might send. */
function count(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}
