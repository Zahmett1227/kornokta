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

import { CARD_GENERATION_SYSTEM_PROMPT, multipleChoiceInstruction } from "../prompts/cardGeneration.js";
import { LLM_OUTPUT_SCHEMA, validateLlmOutput } from "../schemas/validateLlmOutput.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";
import { MULTIPLE_CHOICE_MODES, type CostConfig, type MultipleChoiceMode, type OpenAIConfig } from "../config.js";

export class OpenAIError extends Error {
  constructor(
    message: string,
    readonly status: number | undefined,
    /** Transient failures are worth retrying; permanent ones are not (§17). */
    readonly transient: boolean,
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
}

export interface CardGenerationResult {
  output: LlmOutput;
  /** As OpenAI reported it, before our own cost math — kept for audit (§16.8). */
  rawUsage: { inputTokens: number; outputTokens: number };
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
  usage?: { input_tokens?: number; output_tokens?: number };
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
export function buildModelResponseSchema(maxCardsPerKnowledgeUnit: number): Record<string, unknown> {
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
  // nullable type instead. `options`/`correctOption` are optional in the
  // canonical §14 schema (a v2.0 payload predates them and is still valid), so
  // they have to be promoted here — otherwise OpenAI rejects the schema for a
  // `required` array that does not list every key in `properties`.
  const card = (clone.properties.cards as {
    items: { required: string[]; properties: Record<string, unknown> };
  }).items;
  for (const key of Object.keys(card.properties)) {
    if (!card.required.includes(key)) card.required.push(key);
  }
  // The model has nothing to choose here: what it produces is v2.1.
  clone.properties.schemaVersion = { type: "string", const: "2.1" };

  return clone as Record<string, unknown>;
}

function extractOutputText(body: ResponsesApiBody): string {
  for (const item of body.output ?? []) {
    if (item.type !== "message") continue;
    for (const part of item.content ?? []) {
      if (part.type === "refusal") {
        throw new OpenAIError(
          `Model içerik üretmeyi reddetti: ${part.refusal ?? "sebep verilmedi"}`,
          undefined,
          false,
        );
      }
      if (part.type === "output_text" && typeof part.text === "string") {
        return part.text;
      }
    }
  }
  throw new OpenAIError("Yanıtta üretilmiş metin bulunamadı.", undefined, false);
}

export function buildUserInstruction(
  request: CardGenerationRequest,
  maxCards: number,
  multipleChoiceMode: MultipleChoiceMode,
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

/** Estimated USD from real usage figures and the configured per-token price (§20.3). */
export function estimateOpenAICostUSD(
  inputTokens: number,
  outputTokens: number,
  cost: Pick<CostConfig, "openaiUsdPerMillionInputTokens" | "openaiUsdPerMillionOutputTokens">,
): number {
  return (
    (inputTokens / 1_000_000) * cost.openaiUsdPerMillionInputTokens +
    (outputTokens / 1_000_000) * cost.openaiUsdPerMillionOutputTokens
  );
}

export class OpenAICardGenerator {
  readonly name = "OpenAI";

  private static readonly ENDPOINT = "https://api.openai.com/v1/responses";

  constructor(
    private readonly config: OpenAIConfig,
    private readonly apiKey: string,
    private readonly cost: Pick<CostConfig, "openaiUsdPerMillionInputTokens" | "openaiUsdPerMillionOutputTokens">,
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
          schema: buildModelResponseSchema(maxCards),
          strict: true,
        },
      },
    };

    const response = await this.transport.post(
      OpenAICardGenerator.ENDPOINT,
      this.apiKey,
      body,
      this.config.timeoutMs,
    );

    if (response.status < 200 || response.status >= 300) {
      const detail =
        (response.body as { error?: { message?: string } } | undefined)?.error?.message ?? "ayrıntı yok";
      throw new OpenAIError(`OpenAI ${response.status}: ${detail}`, response.status, isTransientStatus(response.status));
    }

    const parsedBody = response.body as ResponsesApiBody;

    // Checked before parsing: an "incomplete" response's output_text is a
    // truncated JSON fragment, and parsing it would fail with a message that
    // does not say why. Confirmed live: a reasoning-capable model can spend
    // part of `max_output_tokens` on its own hidden reasoning before ever
    // emitting the JSON, so a token ceiling that looks generous for the
    // visible answer can still truncate the response (§20.3's cost cap
    // versus the model's actual token accounting is a real tension, not a
    // bug in this parsing step — see docs/FAZ3-PLAN.md).
    if (parsedBody.status === "incomplete") {
      const reason = parsedBody.incomplete_details?.reason ?? "bilinmeyen";
      throw new OpenAIError(
        `Model üretimi tamamlamadı: ${reason}. ` +
          (reason === "max_output_tokens"
            ? "OPENAI_MAX_OUTPUT_TOKENS bu model için yetersiz olabilir " +
              "(reasoning token'ları da bu bütçeden düşülüyor)."
            : ""),
        undefined,
        false,
      );
    }

    const text = extractOutputText(parsedBody);

    let modelJson: unknown;
    try {
      modelJson = JSON.parse(text);
    } catch {
      throw new OpenAIError("Model yanıtı geçerli JSON değil.", undefined, false);
    }
    if (typeof modelJson !== "object" || modelJson === null || Array.isArray(modelJson)) {
      throw new OpenAIError("Model yanıtı bir JSON nesnesi değil.", undefined, false);
    }

    const rawUsage = {
      inputTokens: parsedBody.usage?.input_tokens ?? 0,
      outputTokens: parsedBody.usage?.output_tokens ?? 0,
    };

    const candidate: unknown = {
      ...(modelJson as Record<string, unknown>),
      requestId: request.requestId,
      usage: {
        provider: "openai",
        model: this.config.model,
        inputTokens: rawUsage.inputTokens,
        outputTokens: rawUsage.outputTokens,
        estimatedCostUSD: estimateOpenAICostUSD(rawUsage.inputTokens, rawUsage.outputTokens, this.cost),
      },
    };

    const validation = validateLlmOutput(candidate);
    if (!validation.valid) {
      // §14: "Şema doğrulanmayan cevap kaydedilmemelidir" — thrown, not
      // returned, so a caller cannot accidentally persist it.
      throw new OpenAIError(
        `Model çıktısı §14 şemasına uymuyor: ${validation.errors.join("; ")}`,
        undefined,
        false,
      );
    }

    return { output: candidate as LlmOutput, rawUsage };
  }
}
