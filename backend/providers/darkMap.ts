/**
 * Karanlık Harita rankers and the consensus gate (docs/ADR-009).
 *
 * Two model families rank the same coverage table against the same prompt,
 * neither one seeing the other's answer, and this module keeps what they agree
 * on. That arrangement is the whole safety story for a feature whose output has
 * no page photo behind it: card generation is grounded by an image the user
 * marked themselves, but "TUS asks a lot about this topic" is grounded by
 * nothing except the model's own training. Cross-family agreement is the only
 * check available, and it is the same instrument `/api/second-opinion` already
 * proved on device — an independent family sees what the first one is blind to.
 *
 * What the gate does and does not buy:
 *
 * - It catches a **single model's idiosyncrasy** — one family over-weighting a
 *   topic because of how its training data happened to be distributed.
 * - It does **not** catch a shared error. Both families learned Turkish medical
 *   curricula from overlapping public sources, so a widely repeated wrong
 *   belief survives agreement intact. That is why a confirmed zone is presented
 *   as a *suggestion to look at*, never as a fact, and why the deterministic
 *   half (`untouched`) is reported separately and prominently: a topic with
 *   zero cards is arithmetic and needs no model's blessing at all (§0.8).
 *
 * Disagreement is preserved, not hidden. A zone only one family flagged comes
 * back labelled `disputed`, because "the two readers split on this" is real
 * information about how sure to be, and dropping it would quietly convert a
 * 50/50 call into a silence indistinguishable from "neither one flagged it".
 *
 * Privacy (§7.3): subject names, topic names, counts and the model's own
 * reasons pass through. Sample card fronts reach the prompt but never a log
 * line, exactly as page text never does in `openai.ts`.
 */

import { DARK_MAP_PROMPT, DARK_MAP_PROMPT_VERSION } from "../prompts/darkMap.js";
import {
  CANONICAL_TOPIC_KEYS,
  isCanonicalTopicKey,
  parseTopicKey,
  renderCoverageTable,
  type TopicCoverage,
} from "./coverage.js";
import { GeminiError, estimateGeminiCostUSD, type GeminiCostConfig, type GeminiTransport, geminiFetchTransport } from "./gemini.js";
import {
  OpenAIError,
  estimateOpenAICostUSD,
  extractOutputText,
  isTransientStatus,
  type OpenAICostConfig,
  type ResponsesApiBody,
  type Transport,
  fetchTransport,
} from "./openai.js";
import {
  EMPTY_TOKEN_USAGE,
  readGeminiUsage,
  readOpenAIUsage,
  type TokenUsage,
} from "./tokenUsage.js";
import type { DarkMapConfig, GeminiConfig, OpenAIConfig } from "../config.js";

export { DARK_MAP_PROMPT_VERSION };

export const TUS_YIELDS = ["high", "medium", "low"] as const;
export type TusYield = (typeof TUS_YIELDS)[number];

/** One family's opinion about one canonical topic. */
export interface DarkZoneRating {
  /** Always canonical by the time it leaves this module — see `sanitizeRatings`. */
  topicKey: string;
  /** 1–5, clamped. How costly this gap is for *this* deck. */
  darkness: number;
  /** How heavily TUS itself leans on the topic, independent of the deck. */
  tusYield: TusYield;
  /** Concrete headings the model says are missing. Capped, trimmed, de-duplicated. */
  missingConcepts: string[];
  reason: string;
}

export interface DarkMapRanking {
  ratings: DarkZoneRating[];
  rawUsage: TokenUsage;
  /** Ratings the model produced for a topic outside the canonical schema. */
  droppedUnknown: number;
}

export interface DarkMapRankRequest {
  requestId: string;
  coverage: readonly TopicCoverage[];
  maxZones: number;
}

/**
 * Structural, so the endpoint can be driven in a test without a key or a
 * network — the same role `SecondOpinionProviderLike` plays for
 * `_secondOpinion.ts`.
 */
export interface DarkMapRankerLike {
  readonly family: string;
  readonly model: string;
  rank(request: DarkMapRankRequest): Promise<DarkMapRanking>;
}

/**
 * The user-facing message wrapped around the coverage table.
 *
 * Identical for both families, like the system prompt, and for the same
 * reason: a consensus between two readers who were handed different tables
 * would measure our own formatting, not their judgement.
 */
export function buildRankInstruction(request: DarkMapRankRequest): string {
  const withCards = request.coverage.filter((row) => row.cardCount > 0).length;
  const empty = request.coverage.length - withCards;
  return [
    `requestId: ${request.requestId}`,
    `Kanonik şablonda ${request.coverage.length} konu var. ${withCards} konuda kart var, ` +
      `${empty} konu tamamen boş.`,
    `En fazla ${request.maxZones} konu döndür. Daha azını döndürmek serbesttir (Kural 5).`,
    "",
    "# Kapsama tablosu",
    renderCoverageTable(request.coverage),
  ].join("\n");
}

/**
 * Trims a family's raw answer down to something the merge step can trust.
 *
 * Every field is repaired rather than rejected where repair is unambiguous
 * (a darkness of 9 becomes 5, a missing concept list is truncated), and the
 * whole rating is dropped only when its *identity* is wrong — a `topicKey`
 * outside the canonical set. That asymmetry is deliberate: a mangled score
 * still points at a real topic the user can look at, while a mangled key points
 * at nothing and would put a hallucinated topic name on screen, which is the
 * one failure this feature must not have.
 *
 * Duplicates are collapsed keeping the *highest* darkness. A model that names
 * the same topic twice has, if anything, argued harder for it.
 */
export function sanitizeRatings(
  raw: unknown,
  maxZones: number,
): { ratings: DarkZoneRating[]; droppedUnknown: number } {
  const zones = Array.isArray((raw as { zones?: unknown })?.zones)
    ? ((raw as { zones: unknown[] }).zones as unknown[])
    : [];

  let droppedUnknown = 0;
  const byKey = new Map<string, DarkZoneRating>();

  for (const entry of zones) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    const topicKey = typeof record.topicKey === "string" ? record.topicKey.trim() : "";
    if (!isCanonicalTopicKey(topicKey)) {
      droppedUnknown += 1;
      continue;
    }

    const rating: DarkZoneRating = {
      topicKey,
      darkness: clampDarkness(record.darkness),
      tusYield: readYield(record.tusYield),
      missingConcepts: readConcepts(record.missingConcepts),
      reason: typeof record.reason === "string" ? record.reason.trim() : "",
    };

    const existing = byKey.get(topicKey);
    if (!existing || rating.darkness > existing.darkness) byKey.set(topicKey, rating);
  }

  const ratings = [...byKey.values()]
    .sort((a, b) => b.darkness - a.darkness)
    .slice(0, Math.max(0, maxZones));

  return { ratings, droppedUnknown };
}

function clampDarkness(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 1;
  return Math.min(5, Math.max(1, Math.round(value)));
}

function readYield(value: unknown): TusYield {
  return typeof value === "string" && (TUS_YIELDS as readonly string[]).includes(value)
    ? (value as TusYield)
    : "medium";
}

const MAX_CONCEPTS = 5;
const MAX_CONCEPT_LENGTH = 120;

function readConcepts(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") continue;
    const trimmed = item.trim().slice(0, MAX_CONCEPT_LENGTH);
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    out.push(trimmed);
    if (out.length >= MAX_CONCEPTS) break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Response schemas
// ---------------------------------------------------------------------------

/**
 * The canonical topic list as a constrained-decoding enum.
 *
 * This is the layer that makes "the model may only choose from the user's own
 * template" structural rather than hopeful. It mirrors exactly what
 * `buildModelResponseSchema` does for a card's `topic` field, and it earns the
 * same three-layer treatment the topic field already gets: the enum here, Kural
 * 1 in the prompt, and `sanitizeRatings` on the way out. Any one of the three
 * can fail without a hallucinated topic reaching the screen.
 */
export function buildOpenAIResponseSchema(maxZones: number): Record<string, unknown> {
  return {
    type: "object",
    additionalProperties: false,
    required: ["zones"],
    properties: {
      zones: {
        type: "array",
        maxItems: Math.max(1, maxZones),
        items: {
          type: "object",
          additionalProperties: false,
          // `strict: true` requires every declared property to be listed here,
          // so nothing is optional; emptiness is expressed by an empty array,
          // never by an absent key.
          required: ["topicKey", "darkness", "tusYield", "missingConcepts", "reason"],
          properties: {
            topicKey: { type: "string", enum: [...CANONICAL_TOPIC_KEYS] },
            darkness: { type: "integer", minimum: 1, maximum: 5 },
            tusYield: { type: "string", enum: [...TUS_YIELDS] },
            missingConcepts: {
              type: "array",
              maxItems: MAX_CONCEPTS,
              items: { type: "string" },
            },
            reason: { type: "string" },
          },
        },
      },
    },
  };
}

/** Same contract in Gemini's OpenAPI dialect (uppercase type names). */
export function buildGeminiResponseSchema(maxZones: number): Record<string, unknown> {
  return {
    type: "OBJECT",
    properties: {
      zones: {
        type: "ARRAY",
        maxItems: Math.max(1, maxZones),
        items: {
          type: "OBJECT",
          properties: {
            topicKey: { type: "STRING", enum: [...CANONICAL_TOPIC_KEYS] },
            darkness: { type: "INTEGER" },
            tusYield: { type: "STRING", enum: [...TUS_YIELDS] },
            missingConcepts: { type: "ARRAY", items: { type: "STRING" } },
            reason: { type: "STRING" },
          },
          required: ["topicKey", "darkness", "tusYield", "reason"],
        },
      },
    },
    required: ["zones"],
  };
}

// ---------------------------------------------------------------------------
// OpenAI ranker
// ---------------------------------------------------------------------------

export class OpenAIDarkMapRanker implements DarkMapRankerLike {
  readonly family = "openai";
  private static readonly ENDPOINT = "https://api.openai.com/v1/responses";

  constructor(
    private readonly config: OpenAIConfig,
    private readonly darkMap: DarkMapConfig,
    private readonly apiKey: string,
    private readonly cost: OpenAICostConfig,
    private readonly transport: Transport = fetchTransport,
  ) {}

  get model(): string {
    return this.config.model;
  }

  async rank(request: DarkMapRankRequest): Promise<DarkMapRanking> {
    const body = {
      model: this.config.model,
      reasoning: { effort: this.darkMap.reasoningEffort },
      max_output_tokens: this.darkMap.maxOutputTokens,
      input: [
        { role: "system", content: [{ type: "input_text", text: DARK_MAP_PROMPT }] },
        { role: "user", content: [{ type: "input_text", text: buildRankInstruction(request) }] },
      ],
      text: {
        format: {
          type: "json_schema",
          name: "cizgi_dark_map",
          schema: buildOpenAIResponseSchema(request.maxZones),
          strict: true,
        },
      },
    };

    let response: { status: number; body: unknown };
    try {
      response = await this.transport.post(
        OpenAIDarkMapRanker.ENDPOINT,
        this.apiKey,
        body,
        this.darkMap.timeoutMs,
      );
    } catch (error) {
      const aborted = error instanceof Error && error.name === "AbortError";
      throw new OpenAIError(
        aborted
          ? `Karanlık harita çağrısı ${this.darkMap.timeoutMs} ms zaman aşımında kesildi. ` +
            "Üretim sağlayıcı tarafında sürmüş ve ücretlendirilmiş olabilir."
          : `OpenAI'ye ulaşılamadı: ${error instanceof Error ? error.message : "bilinmeyen ağ hatası"}`,
        undefined,
        true,
        undefined,
        aborted ? "timeout" : "transport",
      );
    }

    if (response.status < 200 || response.status >= 300) {
      const errorBody = (
        response.body as { error?: { message?: string; code?: string; type?: string } } | undefined
      )?.error;
      const detail = errorBody?.message ?? "ayrıntı yok";
      if (errorBody?.code === "insufficient_quota" || errorBody?.type === "insufficient_quota") {
        throw new OpenAIError(
          "OpenAI kredisi/kotası tükendi (insufficient_quota): platform.openai.com → Billing'den " +
            `bakiyeyi kontrol et. Sağlayıcı mesajı: ${detail}`,
          response.status,
          true,
          undefined,
          "insufficient_quota",
        );
      }
      throw new OpenAIError(
        `OpenAI ${response.status}: ${detail}`,
        response.status,
        isTransientStatus(response.status),
        undefined,
        `http_${response.status}`,
      );
    }

    const parsedBody = response.body as ResponsesApiBody;
    const usage = readOpenAIUsage(parsedBody);

    if (parsedBody.status === "failed") {
      throw new OpenAIError(
        `Sağlayıcı üretimi başarısız bildirdi: ${parsedBody.error?.message ?? "ayrıntı yok"}`,
        undefined,
        true,
        usage ?? undefined,
        "provider_failed",
      );
    }
    if (parsedBody.status === "incomplete") {
      const reason = parsedBody.incomplete_details?.reason ?? "bilinmeyen";
      throw new OpenAIError(
        `Model üretimi tamamlamadı: ${reason}. ` +
          (reason === "max_output_tokens"
            ? "DARK_MAP_MAX_OUTPUT_TOKENS bu model/effort için yetersiz olabilir " +
              "(reasoning token'ları da bu bütçeden düşülüyor)."
            : ""),
        undefined,
        true,
        usage ?? undefined,
        `incomplete_${reason}`,
      );
    }

    const text = extractOutputText(parsedBody, usage);
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new OpenAIError(
        "Model yanıtı geçerli JSON değil.",
        undefined,
        false,
        usage ?? undefined,
        "json_parse",
      );
    }

    const { ratings, droppedUnknown } = sanitizeRatings(parsed, request.maxZones);
    return { ratings, droppedUnknown, rawUsage: usage ?? EMPTY_TOKEN_USAGE };
  }

  estimateCostUSD(usage: TokenUsage): number {
    return estimateOpenAICostUSD(usage, this.cost);
  }
}

// ---------------------------------------------------------------------------
// Gemini ranker
// ---------------------------------------------------------------------------

interface GeminiGenerateBody {
  candidates?: Array<{ content?: { parts?: Array<{ text?: string }> }; finishReason?: string }>;
  promptFeedback?: { blockReason?: string };
  error?: { message?: string };
}

export class GeminiDarkMapRanker implements DarkMapRankerLike {
  readonly family = "gemini";

  constructor(
    private readonly config: GeminiConfig,
    private readonly darkMap: DarkMapConfig,
    private readonly apiKey: string,
    private readonly cost: GeminiCostConfig,
    private readonly transport: GeminiTransport = geminiFetchTransport,
  ) {}

  get model(): string {
    return this.config.model;
  }

  private endpoint(): string {
    return `https://generativelanguage.googleapis.com/v1beta/models/${this.config.model}:generateContent`;
  }

  async rank(request: DarkMapRankRequest): Promise<DarkMapRanking> {
    const body = {
      systemInstruction: { parts: [{ text: DARK_MAP_PROMPT }] },
      contents: [{ role: "user", parts: [{ text: buildRankInstruction(request) }] }],
      generationConfig: {
        // Not 0, unlike the second opinion. That call transcribes something
        // that is either on the page or is not, where any creativity is noise.
        // This one is a judgement over a curriculum, and pinning it to greedy
        // decoding buys determinism we have no use for while narrowing the very
        // independence the consensus gate is built to exploit.
        temperature: 0.2,
        maxOutputTokens: this.darkMap.maxOutputTokens,
        responseMimeType: "application/json",
        responseSchema: buildGeminiResponseSchema(request.maxZones),
      },
    };

    const response = await this.transport.post(
      this.endpoint(),
      this.apiKey,
      body,
      this.darkMap.timeoutMs,
    );
    const parsedBody = response.body as GeminiGenerateBody | undefined;

    if (response.status < 200 || response.status >= 300) {
      const detail = parsedBody?.error?.message ?? "ayrıntı yok";
      if (response.status === 429) {
        throw new GeminiError(
          "Gemini kotası/kredisi tükenmiş görünüyor (429 RESOURCE_EXHAUSTED). " +
            `Sağlayıcı mesajı: ${detail}`,
          response.status,
          true,
        );
      }
      if (response.status === 401 || response.status === 403) {
        throw new GeminiError(
          `Gemini API anahtarı reddedildi (${response.status}). Sağlayıcı mesajı: ${detail}`,
          response.status,
          false,
        );
      }
      throw new GeminiError(
        `Gemini ${response.status}: ${detail}`,
        response.status,
        response.status === 408 || response.status >= 500,
      );
    }

    if (parsedBody?.promptFeedback?.blockReason) {
      throw new GeminiError(
        `Gemini istemi engelledi: ${parsedBody.promptFeedback.blockReason}`,
        undefined,
        false,
      );
    }

    const candidate = parsedBody?.candidates?.[0];
    if (!candidate) throw new GeminiError("Yanıtta aday (candidate) yok.", undefined, true);
    if (candidate.finishReason === "MAX_TOKENS") {
      throw new GeminiError(
        "Model yanıtı tamamlayamadı (MAX_TOKENS): DARK_MAP_MAX_OUTPUT_TOKENS yetersiz olabilir " +
          "(düşünme token'ları da bu bütçeden düşülüyor).",
        undefined,
        true,
      );
    }
    if (candidate.finishReason && candidate.finishReason !== "STOP") {
      // Same rule as the second opinion: a policy-terminated generation can
      // still be schema-valid, and presenting its fragment as a ranking would
      // dress a truncated answer as a considered one.
      throw new GeminiError(
        `Model üretimi temiz bitmedi (finishReason: ${candidate.finishReason}); içerik güvenilmez sayıldı.`,
        undefined,
        false,
      );
    }

    const text = candidate.content?.parts?.map((part) => part.text ?? "").join("") ?? "";
    if (!text.trim()) {
      throw new GeminiError("Yanıtta üretilmiş metin yok.", undefined, false);
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new GeminiError("Model yanıtı geçerli JSON değil.", undefined, false);
    }

    const { ratings, droppedUnknown } = sanitizeRatings(parsed, request.maxZones);
    const usage = readGeminiUsage(parsedBody) ?? EMPTY_TOKEN_USAGE;
    return { ratings, droppedUnknown, rawUsage: usage };
  }

  estimateCostUSD(usage: TokenUsage): number {
    return estimateGeminiCostUSD(usage, this.cost);
  }
}

// ---------------------------------------------------------------------------
// Consensus
// ---------------------------------------------------------------------------

export const CONSENSUS_LEVELS = ["confirmed", "disputed"] as const;
export type ConsensusLevel = (typeof CONSENSUS_LEVELS)[number];

export interface DarkZone {
  subject: string;
  topic: string;
  topicKey: string;
  /** The deterministic fact, straight from the deck — never the model's guess. */
  cardCount: number;
  weakCardCount: number;
  /** `confirmed` = both families flagged it. `disputed` = exactly one did. */
  consensus: ConsensusLevel;
  /** Which families flagged it, for the phone to name them. */
  raters: string[];
  /** Mean darkness across the families that flagged it, rounded to one decimal. */
  darkness: number;
  /** Highest yield claimed by any rater — the cautious direction on a study list. */
  tusYield: TusYield;
  /** Union of both families' concepts, first-seen order, capped. */
  missingConcepts: string[];
  /** One reason per rating family, so a disagreement can be read rather than averaged away. */
  reasons: Array<{ family: string; reason: string }>;
}

const YIELD_RANK: Record<TusYield, number> = { high: 3, medium: 2, low: 1 };

/**
 * Merges the families' rankings into one ordered list.
 *
 * Ordering is deterministic and total, so the same two rankings always produce
 * the same screen: consensus first (confirmed above disputed), then darkness,
 * then TUS yield, then the emptier topic, then the canonical schema order as
 * the final tie-break. That last key is what stops the list from reshuffling
 * between two runs that scored identically — without it the order would fall
 * back to map-insertion order, which depends on which family answered first.
 *
 * `cardCount` is taken from `coverage`, never from a rating: the count is the
 * one number in this feature that is *known*, and letting a model's echo of it
 * through would put a hallucinated figure next to a real topic name.
 */
export function mergeRankings(
  rankings: ReadonlyArray<{ family: string; ratings: readonly DarkZoneRating[] }>,
  coverage: readonly TopicCoverage[],
): DarkZone[] {
  const byKey = new Map<string, TopicCoverage>();
  for (const row of coverage) byKey.set(`${row.subject}|${row.topic}`, row);

  const order = new Map<string, number>();
  CANONICAL_TOPIC_KEYS.forEach((key, index) => order.set(key, index));

  const grouped = new Map<string, Array<{ family: string; rating: DarkZoneRating }>>();
  for (const ranking of rankings) {
    for (const rating of ranking.ratings) {
      const list = grouped.get(rating.topicKey) ?? [];
      list.push({ family: ranking.family, rating });
      grouped.set(rating.topicKey, list);
    }
  }

  const zones: DarkZone[] = [];
  for (const [topicKey, entries] of grouped) {
    const parsed = parseTopicKey(topicKey);
    // Unreachable through `sanitizeRatings`, kept because this function is
    // exported and a future caller could hand it unfiltered ratings.
    if (!parsed) continue;
    const row = byKey.get(topicKey);

    const darkness =
      Math.round((entries.reduce((sum, e) => sum + e.rating.darkness, 0) / entries.length) * 10) /
      10;
    const tusYield = entries
      .map((e) => e.rating.tusYield)
      .reduce((best, current) => (YIELD_RANK[current] > YIELD_RANK[best] ? current : best), "low" as TusYield);

    const concepts: string[] = [];
    const seen = new Set<string>();
    for (const entry of entries) {
      for (const concept of entry.rating.missingConcepts) {
        if (seen.has(concept)) continue;
        seen.add(concept);
        concepts.push(concept);
        if (concepts.length >= MAX_CONCEPTS * 2) break;
      }
    }

    zones.push({
      subject: parsed.subject,
      topic: parsed.topic,
      topicKey,
      cardCount: row?.cardCount ?? 0,
      weakCardCount: row?.weakCardCount ?? 0,
      consensus: entries.length >= 2 ? "confirmed" : "disputed",
      raters: entries.map((e) => e.family),
      darkness,
      tusYield,
      missingConcepts: concepts,
      reasons: entries
        .filter((e) => e.rating.reason.length > 0)
        .map((e) => ({ family: e.family, reason: e.rating.reason })),
    });
  }

  zones.sort((a, b) => {
    if (a.consensus !== b.consensus) return a.consensus === "confirmed" ? -1 : 1;
    if (b.darkness !== a.darkness) return b.darkness - a.darkness;
    const yieldDelta = YIELD_RANK[b.tusYield] - YIELD_RANK[a.tusYield];
    if (yieldDelta !== 0) return yieldDelta;
    if (a.cardCount !== b.cardCount) return a.cardCount - b.cardCount;
    return (order.get(a.topicKey) ?? 0) - (order.get(b.topicKey) ?? 0);
  });

  return zones;
}
