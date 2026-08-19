/**
 * OpenAI card-generation provider (ANA-PLAN §11.2, §14, §25 Faz 3).
 *
 * Calls the Responses API with Structured Outputs (strict mode) so the model
 * is constrained to the §14 contract at generation time, then validates the
 * result independently anyway (`validateLlmOutput`) — a provider's own
 * strict-mode guarantee lives on the far side of an HTTP call and this
 * project's rule is that nothing reaches the deck unvalidated.
 *
 * Two fields the model is never asked to produce: `usage` and `requestId`.
 * The model cannot know its own real token cost while it is still generating
 * — that number only exists once the API call returns — and a request id is
 * ours to assign, not the model's to invent. Both are spliced in after the
 * call, from the same schema this endpoint validates against, so a client
 * never has to trust a self-reported cost figure (§16.8, §20.3).
 *
 * Privacy (§7.3): like `documentAI.ts`, no image bytes or recognized/generated
 * text are logged or put in an error message. Failures carry the HTTP status
 * and OpenAI's own error string, which describe the *call*, not the content.
 */

import { CARD_GENERATION_SYSTEM_PROMPT, multipleChoiceInstruction, topicInstruction } from "../prompts/cardGeneration.js";
import { LLM_OUTPUT_SCHEMA, validateLlmOutput } from "../schemas/validateLlmOutput.js";
import { sanitizeMarks } from "./coverage.js";
import { sanitizeTopics, topicsFor } from "./subjectTopics.js";
import {
  EMPTY_TOKEN_USAGE,
  estimateCostUSD,
  readOpenAIUsage,
  type TokenUsage,
} from "./tokenUsage.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";
import { MULTIPLE_CHOICE_MODES, type CostConfig, type MultipleChoiceMode, type OpenAIConfig } from "../config.js";

export class OpenAIError extends Error {
  constructor(
    message: string,
    readonly status: number | undefined,
    /** Transient failures are worth retrying; permanent ones are not (§17). */
    readonly transient: boolean,
    /**
     * What the call spent before it failed, when the provider said.
     *
     * Absent on the failures that cost nothing — a 429, a 401, a connection
     * that never opened — and present on the ones that cost full price and
     * returned nothing usable: a response truncated at `max_output_tokens`, a
     * body that failed schema validation, a refusal. Those are the expensive
     * failures, and without carrying the figure out with the error they were
     * invisible: the caller only ever saw a message.
     *
     * A short machine-readable `reason` travels with it so the ledger can say
     * *which* kind of failure burned the tokens without parsing Turkish prose.
     */
    readonly usage?: TokenUsage,
    readonly reason?: string,
  ) {
    super(message);
    this.name = "OpenAIError";
  }
}

/** The HTTP call, isolated so tests can drive the provider without a network or a key. */
export interface Transport {
  post(url: string, apiKey: string, body: unknown, timeoutMs: number): Promise<{
    status: number;
    body: unknown;
  }>;
}

export const fetchTransport: Transport = {
  async post(url, apiKey, body, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      // Parsed defensively: an error response may be HTML from a proxy rather
      // than the JSON the API promises.
      const text = await response.text();
      let parsed: unknown = undefined;
      try {
        parsed = text ? JSON.parse(text) : undefined;
      } catch {
        parsed = { error: { message: text.slice(0, 200) } };
      }
      return { status: response.status, body: parsed };
    } finally {
      clearTimeout(timer);
    }
  },
};

export interface CardGenerationRequest {
  /** Assigned by the caller, never invented by the model. Echoed into the final `usage`-adjacent output. */
  requestId: string;
  /**
   * The marked *full* page (Faz 6 — docs/FAZ6-PLAN.md §5.2), not a crop: the
   * model needs to see the highlighter, circles and margin notes itself to
   * decide what the student cared about. Cost/resolution tradeoff is handled on
   * the client (`UploadImage.swift`) and by the cost cap in `_cards.ts`.
   */
  image: Uint8Array;
  mimeType: string;
  /**
   * Per-request ceiling on cards, from the user's own setting (§6.7). Absent
   * means "use the configured default" — the config value stays the upper
   * bound, so this can only ever ask for fewer.
   */
  maxCards?: number;
  /**
   * Per-request five-option mode (§13.3), already clamped to the deployment's
   * ceiling by the endpoint. Absent means "use the configured mode".
   */
  multipleChoiceMode?: MultipleChoiceMode;
  /**
   * Optional free-text steer from the user (§5.1), e.g. "sadece sol sütun".
   * There is no pre-reconciled transcription any more: the model reads the
   * marked content off the image itself (v2 prompt).
   */
  hint?: string;
  /**
   * Canonical subject name (schema v2.2) the capture was made under. When it
   * matches `schemas/subject_topics.json`, that subject's topic list is
   * injected into the model-facing schema as an enum on the per-card `topic`
   * field. Absent or unknown means "no topic assignment" — never an error.
   */
  subject?: string;
}

export interface CardGenerationResult {
  output: LlmOutput;
  /**
   * As OpenAI reported it, before our own cost math — kept for audit (§16.8).
   *
   * Widened from a bare input/output pair to the full `TokenUsage` once it
   * turned out the two most expensive things in a call were both hidden inside
   * it: the cached share of the input, billed at a tenth of the price it was
   * being charged at, and the reasoning share of the output, billed at the
   * most expensive rate in the system and folded invisibly into `outputTokens`.
   */
  rawUsage: TokenUsage;
}

interface ResponsesApiContentPart {
  type?: string;
  text?: string;
  refusal?: string;
}

interface ResponsesApiOutputItem {
  type?: string;
  content?: ResponsesApiContentPart[];
}

interface ResponsesApiBody {
  /** "completed" | "incomplete" | "failed" | ... */
  status?: string;
  incomplete_details?: { reason?: string };
  output?: ResponsesApiOutputItem[];
  /** Read through `readOpenAIUsage`, which also unpacks the two `*_details` sub-objects. */
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    input_tokens_details?: { cached_tokens?: number };
    output_tokens_details?: { reasoning_tokens?: number };
  };
  error?: { message?: string };
}

/** Status codes worth another attempt (§17), same convention as `documentAI.ts`. */
function isTransientStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

/**
 * A per-request variant of the §14 schema: `usage` and `requestId` removed
 * (see file header), and `cards` capped at the configured per-passage limit
 * (§11.3, §13.2) so the constraint is enforced by the provider's own
 * constrained decoding, not only by the prompt text and the post-hoc
 * `cardGate` — three independent layers for the same rule, not one hoping to
 * hold.
 */
export function buildModelResponseSchema(
  maxCardsPerKnowledgeUnit: number,
  topicEnum?: readonly string[],
): Record<string, unknown> {
  const clone = structuredClone(LLM_OUTPUT_SCHEMA) as {
    required: string[];
    properties: Record<string, unknown>;
    $schema?: unknown;
    $id?: unknown;
  };
  clone.required = clone.required.filter((key) => key !== "usage" && key !== "requestId");
  delete clone.properties.usage;
  delete clone.properties.requestId;
  delete clone.$schema;
  delete clone.$id;
  (clone.properties.cards as { maxItems?: number }).maxItems = maxCardsPerKnowledgeUnit;

  // Structured Outputs strict mode has no optional properties: every key in
  // `properties` must also be in `required`, and "absent" is expressed as a
  // nullable type instead. `options`/`correctOption`/`topic` are optional in
  // the canonical §14 schema (a v2.0 payload predates them and is still
  // valid), so they have to be promoted here — otherwise OpenAI rejects the
  // schema for a `required` array that does not list every key in
  // `properties`.
  const card = (clone.properties.cards as {
    items: { required: string[]; properties: Record<string, unknown> };
  }).items;

  // With a known subject the per-card topic is constrained to that subject's
  // canonical list at decoding time — the cheapest of the three layers that
  // hold this field (schema enum, prompt, `sanitizeTopics`). Without one, the
  // canonical `["string","null"]` stays and the prompt says "leave it null".
  if (topicEnum && topicEnum.length > 0) {
    card.properties.topic = {
      anyOf: [{ type: "string", enum: [...topicEnum] }, { type: "null" }],
    };
  }

  for (const key of Object.keys(card.properties)) {
    if (!card.required.includes(key)) card.required.push(key);
  }

  // Schema v2.3's mark register. Optional in the canonical schema (a v2.0–v2.2
  // payload predates it) and therefore absent from `required` — but strict mode
  // has no optional properties, so asking for it means promoting it here, the
  // same move `options`/`topic` already needed.
  //
  // The cap is generous rather than tight: a register is only worth having if
  // it is complete, and a page really can carry more marks than it can carry
  // cards (that is the whole finding — Tur A hit the card ceiling on 18 of 18
  // pages). Three per card slot bounds a runaway list without narrowing the
  // signal; the model still answers inside `max_output_tokens` either way.
  if (!clone.required.includes("marks")) clone.required.push("marks");
  (clone.properties.marks as { maxItems?: number }).maxItems = maxCardsPerKnowledgeUnit * 3;

  // The model has nothing to choose here: what it produces is v2.3.
  clone.properties.schemaVersion = { type: "string", const: "2.3" };

  return clone as Record<string, unknown>;
}

/**
 * `usage` is threaded in rather than re-read from the body because both
 * failures here are billed ones: a refusal and a message-less response are
 * both generations the provider completed and charged for. Dropping the figure
 * on the way out is what used to make them look free.
 */
function extractOutputText(body: ResponsesApiBody, usage: TokenUsage | null): string {
  for (const item of body.output ?? []) {
    if (item.type !== "message") continue;
    for (const part of item.content ?? []) {
      if (part.type === "refusal") {
        throw new OpenAIError(
          `Model içerik üretmeyi reddetti: ${part.refusal ?? "sebep verilmedi"}`,
          undefined,
          false,
          usage ?? undefined,
          "refusal",
        );
      }
      if (part.type === "output_text" && typeof part.text === "string") {
        return part.text;
      }
    }
  }
  throw new OpenAIError(
    "Yanıtta üretilmiş metin bulunamadı.",
    undefined,
    false,
    usage ?? undefined,
    "no_output_text",
  );
}

export function buildUserInstruction(
  request: CardGenerationRequest,
  maxCards: number,
  multipleChoiceMode: MultipleChoiceMode,
  topicEnum: readonly string[] | null = null,
): string {
  const hint = request.hint?.trim();
  return [
    `requestId: ${request.requestId}`,
    "Ekteki fotoğraf, öğrencinin işaretlediği ders kitabı sayfasının tamamıdır. " +
      "Sistem yönergesindeki kurallara göre işaretli/vurgulanmış içeriği oku ve kartları üret.",
    `Bu sayfadan en fazla ${maxCards} kart üretebilirsin. Sayfadaki farklı işaretli/el yazısı ` +
      "noktalarının her birini kapsamaya çalış; el yazısı ve daire/yıldız ile işaretlenenleri önceliklendir. " +
      "Az sayıda temel kartla yetinme — işaretlenen tüm farklı noktalara ulaş.",
    multipleChoiceInstruction(multipleChoiceMode),
    topicInstruction(topicEnum ? request.subject ?? null : null, topicEnum),
    hint ? `Kullanıcı ipucu: ${hint}` : "Kullanıcı ipucu: (yok)",
  ].join("\n");
}

/**
 * The stricter of two modes on the `off < mixed < all` scale.
 *
 * The job row carries the mode chosen at submit time, and the worker may run
 * minutes later — on a deployment whose ceiling has since been lowered. Without
 * this, an old row would still talk the new deployment into producing
 * five-option cards it is no longer configured for. `maxCards` has always been
 * re-clamped here for the same reason; this closes the gap for the mode
 * (Codex, PR #29).
 */
export function stricterMode(a: MultipleChoiceMode, b: MultipleChoiceMode): MultipleChoiceMode {
  const rank = (mode: MultipleChoiceMode) => MULTIPLE_CHOICE_MODES.indexOf(mode);
  return rank(a) <= rank(b) ? a : b;
}

/** The three prices this provider is billed at, in the shape `estimateCostUSD` wants. */
export type OpenAICostConfig = Pick<
  CostConfig,
  | "openaiUsdPerMillionInputTokens"
  | "openaiUsdPerMillionCachedInputTokens"
  | "openaiUsdPerMillionOutputTokens"
>;

/**
 * The worst case §21.3's pre-flight budget check prices: the full output
 * ceiling and nothing else.
 *
 * A named function rather than an inline literal because the check is a
 * *refusal* — the one place that can stop a call before it costs anything —
 * and "which tokens does that ceiling actually cover?" should be answerable
 * without reading the caller. It covers output only: the input cost depends on
 * the image and cannot be known before the call.
 */
export function outputCeilingUsage(maxOutputTokens: number): TokenUsage {
  return { ...EMPTY_TOKEN_USAGE, outputTokens: maxOutputTokens };
}

/**
 * Estimated USD from real usage figures and the configured per-token price
 * (§20.3).
 *
 * Takes a whole `TokenUsage` rather than the old input/output pair: the cached
 * share of the input is billed at its own rate, and a function that cannot see
 * it cannot price the call. Callers that only know a token *ceiling* (the
 * pre-flight budget check) pass `outputCeilingUsage`, which prices the worst
 * case exactly as before.
 */
export function estimateOpenAICostUSD(usage: TokenUsage, cost: OpenAICostConfig): number {
  return estimateCostUSD(usage, {
    usdPerMillionInputTokens: cost.openaiUsdPerMillionInputTokens,
    usdPerMillionCachedInputTokens: cost.openaiUsdPerMillionCachedInputTokens,
    usdPerMillionOutputTokens: cost.openaiUsdPerMillionOutputTokens,
  });
}

export class OpenAICardGenerator {
  readonly name = "OpenAI";

  private static readonly ENDPOINT = "https://api.openai.com/v1/responses";

  constructor(
    private readonly config: OpenAIConfig,
    private readonly apiKey: string,
    private readonly cost: OpenAICostConfig,
    private readonly transport: Transport = fetchTransport,
  ) {}

  async generateCards(request: CardGenerationRequest): Promise<CardGenerationResult> {
    // The request may ask for fewer than the deployment allows, never more:
    // the config value is a cost ceiling, and a client is not trusted to raise
    // someone else's spending limit (§0.6, §21.3).
    const maxCards = Math.min(
      request.maxCards ?? this.config.maxCardsPerKnowledgeUnit,
      this.config.maxCardsPerKnowledgeUnit,
    );
    // An unknown subject degrades to "no topic assignment" rather than an
    // error: a stale job row or an older client must never lock a page out of
    // generation over a classification nicety.
    const topicEnum = request.subject ? topicsFor(request.subject) ?? null : null;
    const body = {
      model: this.config.model,
      reasoning: { effort: this.config.reasoningEffort },
      max_output_tokens: this.config.maxOutputTokens,
      input: [
        {
          role: "system",
          content: [{ type: "input_text", text: CARD_GENERATION_SYSTEM_PROMPT }],
        },
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: buildUserInstruction(
                request,
                maxCards,
                // Clamped again here, not just at submit: see `stricterMode`.
                stricterMode(
                  request.multipleChoiceMode ?? this.config.multipleChoiceMode,
                  this.config.multipleChoiceMode,
                ),
                topicEnum,
              ),
            },
            {
              type: "input_image",
              image_url: `data:${request.mimeType};base64,${Buffer.from(request.image).toString("base64")}`,
              // Faz 6/B3: without this the API tiles the page at low detail and
              // faint margin handwriting / thin highlighter strokes are lost —
              // exactly the marks this app must read (docs/FAZ6-PLAN.md §5.2,
              // §10.1). "high" forces full-resolution tiling. Costs more input
              // tokens; accepted for a single user (§0.6, env-overridable).
              detail: this.config.imageDetail,
            },
          ],
        },
      ],
      text: {
        format: {
          type: "json_schema",
          name: "cizgi_llm_output",
          schema: buildModelResponseSchema(maxCards, topicEnum ?? undefined),
          strict: true,
        },
      },
    };

    let response: { status: number; body: unknown };
    try {
      response = await this.transport.post(
        OpenAICardGenerator.ENDPOINT,
        this.apiKey,
        body,
        this.config.timeoutMs,
      );
    } catch (error) {
      // A raw throw from the transport used to leave this method as an
      // anonymous `Error`, which both the ledger and the phone then reported as
      // a generic "provider unreachable". The two causes deserve different
      // words and, more importantly, different billing verdicts: an aborted
      // call already made the model generate — OpenAI charges for it and never
      // tells us how much — while a connection that never opened costs
      // nothing. `reason` is what carries that distinction to `_jobs.ts`.
      const aborted = error instanceof Error && error.name === "AbortError";
      throw new OpenAIError(
        aborted
          ? `OpenAI çağrısı ${this.config.timeoutMs} ms zaman aşımında kesildi. Üretim sağlayıcı ` +
            "tarafında sürmüş ve ücretlendirilmiş olabilir; sonucu alınamadı."
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
      // OpenAI reports an exhausted balance as a bare 429 `insufficient_quota`
      // — the same status as an ordinary rate limit — and an undifferentiated
      // "OpenAI 429" reads as "the model is busy" while the real fix (topping
      // up) goes unfound (owner's requirement, 2026-08-11; the Gemini provider
      // does the same for its 429). Still transient on purpose: while the
      // balance is empty each retry fails fast and free, and the first retry
      // after a top-up succeeds without the `force` escape a permanent job
      // failure would demand (_jobs.ts re-submit guard).
      if (errorBody?.code === "insufficient_quota" || errorBody?.type === "insufficient_quota") {
        throw new OpenAIError(
          "OpenAI kredisi/kotası tükendi (insufficient_quota): platform.openai.com → Billing'den " +
            `bakiyeyi kontrol et. Sağlayıcı mesajı: ${detail}`,
          response.status,
          true,
          // No usage on purpose: a rejected request generated nothing, so this
          // failure is genuinely free and must not be counted as spend.
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

    // Read once, immediately, and reused by every path below including the
    // failing ones. Read late — after the checks — and the expensive failures
    // would each have to remember to fetch it, which is precisely how they all
    // came to report nothing.
    const usage = readOpenAIUsage(parsedBody);

    // The Responses API can answer 2xx with a body that still reports failure.
    // Without this check the flow falls through to `extractOutputText`, the
    // provider's own message is lost, and the caller sees a generic "no text"
    // error instead of the actual cause. Transient: a provider-side generation
    // failure says nothing about whether the *next* call would fail too.
    if (parsedBody.status === "failed") {
      throw new OpenAIError(
        `Sağlayıcı üretimi başarısız bildirdi: ${parsedBody.error?.message ?? "ayrıntı yok"}`,
        undefined,
        true,
        usage ?? undefined,
        "provider_failed",
      );
    }

    // Checked before parsing: an "incomplete" response's output_text is a
    // truncated JSON fragment, and parsing it would fail with a message that
    // does not say why. Confirmed live: a reasoning-capable model can spend
    // part of `max_output_tokens` on its own hidden reasoning before ever
    // emitting the JSON, so a token ceiling that looks generous for the
    // visible answer can still truncate the response (§20.3's cost cap
    // versus the model's actual token accounting is a real tension, not a
    // bug in this parsing step — see docs/FAZ3-PLAN.md).
    //
    // Transient, not permanent: how many tokens a run spends is stochastic
    // (reasoning tokens vary call to call), so the same page can comfortably
    // fit on a retry. With the job id fixed to the page id, a permanent
    // classification would lock that page out of `/api/jobs` forever — the
    // attempt ceiling on the phone is what stops an endless loop, not this
    // flag.
    // The single most expensive failure in the system: every token of
    // `max_output_tokens` is generated and billed, and the truncated JSON that
    // comes back is worth nothing. Carrying `usage` out with it is what finally
    // makes that visible in Ayarlar → Kullanım instead of only on the invoice.
    if (parsedBody.status === "incomplete") {
      const reason = parsedBody.incomplete_details?.reason ?? "bilinmeyen";
      throw new OpenAIError(
        `Model üretimi tamamlamadı: ${reason}. ` +
          (reason === "max_output_tokens"
            ? "OPENAI_MAX_OUTPUT_TOKENS bu model için yetersiz olabilir " +
              "(reasoning token'ları da bu bütçeden düşülüyor)."
            : ""),
        undefined,
        true,
        usage ?? undefined,
        `incomplete_${reason}`,
      );
    }

    const text = extractOutputText(parsedBody, usage);

    let modelJson: unknown;
    try {
      modelJson = JSON.parse(text);
    } catch {
      throw new OpenAIError(
        "Model yanıtı geçerli JSON değil.",
        undefined,
        false,
        usage ?? undefined,
        "json_parse",
      );
    }
    if (typeof modelJson !== "object" || modelJson === null || Array.isArray(modelJson)) {
      throw new OpenAIError(
        "Model yanıtı bir JSON nesnesi değil.",
        undefined,
        false,
        usage ?? undefined,
        "json_shape",
      );
    }

    // Third of the three layers holding the topic field (after the schema
    // enum and the prompt): anything off the subject's canonical list — or
    // any topic at all when the subject is unknown — is forced to null here,
    // never allowed to fail the job.
    const modelRecord = modelJson as Record<string, unknown>;
    if (Array.isArray(modelRecord.cards)) {
      modelRecord.cards = sanitizeTopics(
        modelRecord.cards as Array<{ topic?: string | null }>,
        request.subject ?? null,
      );
    }

    // Schema v2.3's register, held to the same rule as `topic`: a malformed
    // mark or a `markId` pointing at nothing is repaired, never allowed to fail
    // the page. A dangling reference is the one shape that would make the
    // coverage report *lie* — the card looks bound, so a skipped mark counts as
    // handled — so it is resolved to null, where it shows up honestly as an
    // unmarked card (`providers/coverage.ts`).
    sanitizeMarks(modelRecord);

    const rawUsage = usage ?? EMPTY_TOKEN_USAGE;

    const candidate: unknown = {
      ...(modelJson as Record<string, unknown>),
      requestId: request.requestId,
      usage: {
        provider: "openai",
        model: this.config.model,
        inputTokens: rawUsage.inputTokens,
        outputTokens: rawUsage.outputTokens,
        estimatedCostUSD: estimateOpenAICostUSD(rawUsage, this.cost),
      },
    };

    const validation = validateLlmOutput(candidate);
    if (!validation.valid) {
      // §14: "Şema doğrulanmayan cevap kaydedilmemelidir" — thrown, not
      // returned, so a caller cannot accidentally persist it. Fully billed,
      // like every other failure below the HTTP layer: the model generated the
      // whole response, it just generated the wrong shape.
      throw new OpenAIError(
        `Model çıktısı §14 şemasına uymuyor: ${validation.errors.join("; ")}`,
        undefined,
        false,
        usage ?? undefined,
        "schema_invalid",
      );
    }

    return { output: candidate as LlmOutput, rawUsage };
  }
}
