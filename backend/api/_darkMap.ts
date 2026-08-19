/**
 * `POST /api/dark-map` — the Karanlık Harita (docs/ADR-009).
 *
 * The phone sends how many cards it holds under each canonical (ders, konu)
 * pair; the server answers with two things that are deliberately different in
 * kind:
 *
 * 1. `untouched` — every canonical topic with zero cards. Pure arithmetic over
 *    `schemas/subject_topics.json`, produced before any model is called and
 *    returned even if both of them fail. §0.8's line: counting is deterministic
 *    code's job.
 * 2. `zones` — a *ranking* among the thin topics, which is the part no counter
 *    can produce, because it depends on what TUS actually asks. Two model
 *    families answer it independently and the server labels what they agreed
 *    on.
 *
 * Synchronous, not a job row. Unlike card generation this call carries no
 * image, produces nothing persistent, and finishes in seconds — the ADR-006
 * queue exists for work that outlives a request, and this does not. It is
 * user-initiated in the same spirit as `/api/second-opinion`: nothing spends
 * money unless the owner pressed something.
 *
 * Privacy (§7.3): no database, nothing written anywhere. Subject names, topic
 * names and counts are the payload; the sample card fronts that ride along to
 * the model never reach a log line, exactly as page text never does.
 */

import { authorize } from "./_auth.js";
import {
  DEFAULT_MAX_SAMPLE_FRONTS,
  buildCoverage,
  type CoverageBuild,
  type TopicCoverageInput,
} from "../providers/coverage.js";
import {
  DARK_MAP_PROMPT_VERSION,
  mergeRankings,
  type DarkMapRankerLike,
  type DarkZone,
  type DarkZoneRating,
} from "../providers/darkMap.js";
import { GeminiError } from "../providers/gemini.js";
import { OpenAIError } from "../providers/openai.js";
import { EMPTY_TOKEN_USAGE, type CallAccounting, type TokenUsage } from "../providers/tokenUsage.js";
import type { DarkMapConfig } from "../config.js";

export interface DarkMapRequestBody {
  requestId?: unknown;
  /** `[{ subject, topic, cardCount, weakCardCount?, sampleFronts? }]`. */
  coverage?: unknown;
  /** Optional canonical subject names to restrict the analysis to. */
  subjects?: unknown;
  /** Client-side ceiling on returned zones; may only ever ask for fewer than the config allows. */
  maxZones?: unknown;
}

/** One family's outcome, success or failure, as the response reports it. */
export interface RaterReport {
  family: string;
  model: string;
  ok: boolean;
  /** Present when `ok` is false — the provider's own message, verbatim. */
  error?: string;
  zoneCount: number;
  /** Ratings this family produced for a topic outside the canonical schema. */
  droppedUnknown: number;
}

export interface DarkMapSuccess {
  requestId: string;
  promptVersion: string;
  /** Canonical topics with no card at all, in schema order. Model-independent. */
  untouched: Array<{ subject: string; topic: string }>;
  zones: DarkZone[];
  /** How many canonical topics were considered, and how many the deck actually covers. */
  totals: {
    canonicalTopics: number;
    coveredTopics: number;
    untouchedTopics: number;
    totalCards: number;
  };
  raters: RaterReport[];
  /**
   * True when fewer than two families answered.
   *
   * The phone must say so out loud: every zone is then labelled `disputed`
   * because nothing could confirm it, and a screen that looked identical to a
   * two-family run would silently present one model's opinion as agreement —
   * the exact failure the gate exists to prevent.
   */
  singleRater: boolean;
  /** Client-sent (ders, konu) pairs that are not canonical. Counted, never merged. */
  droppedUnknownFromClient: number;
  usage: CallAccounting[];
}

export interface DarkMapFailure {
  error: string;
  retryable: boolean;
}

export interface DarkMapDependencies {
  /**
   * The families that will rank, in the order their reports appear.
   *
   * A list rather than two named fields so a deployment missing
   * `GEMINI_API_KEY` composes one ranker instead of the endpoint growing an
   * `if (gemini)` branch — and so a third family could be added without
   * touching this file. Fewer than two means `singleRater`, never an error.
   */
  rankers: DarkMapRankerLike[];
  darkMap: DarkMapConfig;
  deviceToken: string | undefined;
  /** Content never reaches this — ids, counts and durations only (§7.3). */
  log?: (entry: Record<string, unknown>) => void;
  now?: () => Date;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(message: string, status: number, retryable: boolean): Response {
  return json({ error: message, retryable } satisfies DarkMapFailure, status);
}

/**
 * Reads the client's coverage rows defensively.
 *
 * Never rejects the request over a bad row — `buildCoverage` counts unknown
 * pairs and zero-fills anything missing, so the worst a malformed payload can
 * do is make some topic look darker than it is. Refusing the whole map instead
 * would trade a slightly wrong list for no list.
 */
export function parseCoverageInput(value: unknown): TopicCoverageInput[] {
  if (!Array.isArray(value)) return [];
  const rows: TopicCoverageInput[] = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    if (typeof record.subject !== "string" || typeof record.topic !== "string") continue;
    rows.push({
      subject: record.subject,
      topic: record.topic,
      cardCount: typeof record.cardCount === "number" ? record.cardCount : 0,
      weakCardCount: typeof record.weakCardCount === "number" ? record.weakCardCount : 0,
      sampleFronts: Array.isArray(record.sampleFronts)
        ? record.sampleFronts.filter((front): front is string => typeof front === "string")
        : [],
    });
  }
  return rows;
}

function parseSubjects(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((name): name is string => typeof name === "string") : [];
}

function accountingFor(
  family: string,
  model: string,
  outcome: "success" | "failure",
  usage: TokenUsage,
  estimatedCostUSD: number,
  billing: CallAccounting["billing"],
  latencyMs: number,
  at: string,
  failureReason?: string,
): CallAccounting {
  return {
    // Always 1: this endpoint has no job row and never retries server-side, so
    // there is no attempt sequence to number. The phone's ledger dedupes on
    // (jobId, purpose, attempt) and gives each map its own request id.
    attempt: 1,
    provider: family,
    model,
    purpose: "dark_map",
    promptVersion: DARK_MAP_PROMPT_VERSION,
    outcome,
    ...(failureReason ? { failureReason } : {}),
    billing,
    usage,
    estimatedCostUSD,
    latencyMs,
    at,
  };
}

/**
 * Decides what a failed call cost.
 *
 * Same three-way judgement the job ledger makes, and it matters here for the
 * same reason: a call rejected at the door (bad key, exhausted quota) is
 * genuinely free, while one that reached the model and then timed out was
 * generated and billed with nobody able to say how much. Collapsing those into
 * "failed" is what made spend invisible before `tokenUsage.ts` existed.
 */
function billingFor(error: unknown): { billing: CallAccounting["billing"]; reason: string } {
  if (error instanceof OpenAIError) {
    if (error.usage) return { billing: "measured", reason: error.reason ?? "openai" };
    // A status means the provider answered before generating; no status means
    // the connection or our own timeout cut in mid-flight.
    return {
      billing: error.status === undefined ? "unmeasured" : "none",
      reason: error.reason ?? "openai",
    };
  }
  if (error instanceof GeminiError) {
    return { billing: error.status === undefined ? "unmeasured" : "none", reason: "gemini" };
  }
  return { billing: "unmeasured", reason: "unknown" };
}

export async function handleDarkMapRequest(
  request: Request,
  deps: DarkMapDependencies,
): Promise<Response> {
  if (request.method !== "POST") return fail("Yalnızca POST.", 405, false);

  const auth = authorize(request.headers.get("authorization"), deps.deviceToken);
  if (!auth.ok) return fail(auth.message, auth.status, auth.status === 500);

  let body: DarkMapRequestBody;
  try {
    body = (await request.json()) as DarkMapRequestBody;
  } catch {
    return fail("Gövde geçerli JSON değil.", 400, false);
  }

  const requestId =
    typeof body.requestId === "string" && body.requestId.trim() ? body.requestId.trim() : null;
  if (!requestId) return fail("requestId zorunlu.", 400, false);

  // The client may ask for fewer zones, never more: the config value is a cost
  // and attention ceiling, and a client is not trusted to raise it (§0.6,
  // §21.3 — the same rule `generateCards` applies to `maxCards`).
  const maxZones = Math.min(
    typeof body.maxZones === "number" && Number.isFinite(body.maxZones) && body.maxZones > 0
      ? Math.floor(body.maxZones)
      : deps.darkMap.maxZones,
    deps.darkMap.maxZones,
  );

  const built: CoverageBuild = buildCoverage(parseCoverageInput(body.coverage), {
    subjects: parseSubjects(body.subjects),
    maxSampleFronts: deps.darkMap.maxSampleFronts ?? DEFAULT_MAX_SAMPLE_FRONTS,
  });

  // Nothing to rank. Answered before spending anything: with no canonical topic
  // in scope every model call would be asked to choose from an empty enum,
  // which is a request that costs money and cannot succeed.
  if (built.coverage.length === 0) {
    return fail(
      "Seçilen derslerde kanonik konu yok; ders adları şablonla eşleşmiyor olabilir.",
      400,
      false,
    );
  }

  const started = Date.now();
  const now = deps.now ?? (() => new Date());

  // Both families in flight at once. Sequential would double the wait for an
  // answer neither half depends on — and independence is a property of the
  // prompts, not of the ordering.
  const settled = await Promise.all(
    deps.rankers.map(async (ranker) => {
      const callStarted = Date.now();
      try {
        const ranking = await ranker.rank({
          requestId,
          coverage: built.coverage,
          maxZones,
        });
        return { ranker, ranking, error: null as unknown, latencyMs: Date.now() - callStarted };
      } catch (error) {
        return { ranker, ranking: null, error, latencyMs: Date.now() - callStarted };
      }
    }),
  );

  const at = now().toISOString();
  const usage: CallAccounting[] = [];
  const raters: RaterReport[] = [];
  const successful: Array<{ family: string; ratings: readonly DarkZoneRating[] }> = [];

  for (const outcome of settled) {
    const { ranker, ranking, error, latencyMs } = outcome;
    if (ranking) {
      successful.push({ family: ranker.family, ratings: ranking.ratings });
      raters.push({
        family: ranker.family,
        model: ranker.model,
        ok: true,
        zoneCount: ranking.ratings.length,
        droppedUnknown: ranking.droppedUnknown,
      });
      usage.push(
        accountingFor(
          ranker.family,
          ranker.model,
          "success",
          ranking.rawUsage,
          estimate(ranker, ranking.rawUsage),
          "measured",
          latencyMs,
          at,
        ),
      );
      continue;
    }

    const { billing, reason } = billingFor(error);
    const message =
      error instanceof Error ? error.message : "Sıralama sırasında beklenmeyen hata.";
    const spent = error instanceof OpenAIError && error.usage ? error.usage : EMPTY_TOKEN_USAGE;
    raters.push({
      family: ranker.family,
      model: ranker.model,
      ok: false,
      error: message,
      zoneCount: 0,
      droppedUnknown: 0,
    });
    usage.push(
      accountingFor(
        ranker.family,
        ranker.model,
        "failure",
        spent,
        billing === "measured" ? estimate(ranker, spent) : 0,
        billing,
        latencyMs,
        at,
        reason,
      ),
    );
  }

  // Every family failed. The deterministic half is still real and still useful,
  // but returning 200 with an empty ranking would read as "nothing is dark" —
  // the one answer this feature must never give by accident. The phone shows
  // the provider's own message and offers a retry.
  if (successful.length === 0) {
    const retryable = settled.some(
      ({ error }) =>
        (error instanceof OpenAIError || error instanceof GeminiError) && error.transient,
    );
    deps.log?.({
      requestId,
      event: "dark_map.fail",
      raters: raters.map((rater) => ({ family: rater.family, error: rater.error })),
      elapsedMs: Date.now() - started,
    });
    return fail(
      raters.map((rater) => `${rater.family}: ${rater.error ?? "bilinmeyen hata"}`).join(" · "),
      retryable ? 503 : 502,
      retryable,
    );
  }

  const zones = mergeRankings(successful, built.coverage);

  deps.log?.({
    requestId,
    event: "dark_map.ok",
    // Counts and family names only; not one topic name, reason or card front
    // (§7.3). A topic list is a study profile, and this log is not the place
    // for it.
    canonicalTopics: built.coverage.length,
    untouchedTopics: built.untouched.length,
    zoneCount: zones.length,
    confirmed: zones.filter((zone) => zone.consensus === "confirmed").length,
    raters: raters.map((rater) => ({ family: rater.family, ok: rater.ok })),
    droppedUnknownFromClient: built.droppedUnknown,
    estimatedCostUSD: usage.reduce((sum, entry) => sum + entry.estimatedCostUSD, 0),
    elapsedMs: Date.now() - started,
  });

  return json(
    {
      requestId,
      promptVersion: DARK_MAP_PROMPT_VERSION,
      untouched: built.untouched.map(({ subject, topic }) => ({ subject, topic })),
      zones,
      totals: {
        canonicalTopics: built.coverage.length,
        coveredTopics: built.coverage.length - built.untouched.length,
        untouchedTopics: built.untouched.length,
        totalCards: built.totalCards,
      },
      raters,
      singleRater: successful.length < 2,
      droppedUnknownFromClient: built.droppedUnknown,
      usage,
    } satisfies DarkMapSuccess,
    200,
  );
}

/**
 * Prices one call through whichever ranker made it.
 *
 * `estimateCostUSD` is on the concrete rankers rather than on
 * `DarkMapRankerLike`, so a test double can stay a two-line object. A double
 * without it prices at 0, which is correct: a fake call costs nothing.
 */
function estimate(ranker: DarkMapRankerLike, usage: TokenUsage): number {
  const priced = ranker as { estimateCostUSD?: (usage: TokenUsage) => number };
  return typeof priced.estimateCostUSD === "function" ? priced.estimateCostUSD(usage) : 0;
}
