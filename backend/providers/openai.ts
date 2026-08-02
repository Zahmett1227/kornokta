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

import { CARD_GENERATION_SYSTEM_PROMPT } from "../prompts/cardGeneration.js";
import { LLM_OUTPUT_SCHEMA, validateLlmOutput } from "../schemas/validateLlmOutput.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";
import type { CostConfig, OpenAIConfig } from "../config.js";

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
  /** The marked-passage crop (§8.2) — not the full page, for cost control (§20.3). */
  image: Uint8Array;
  mimeType: string;
  /**
   * Text that has already passed OCR reconciliation (`providers/reconcile.ts`)
   * — either auto-accepted or user-confirmed. This call generates cards from
   * it; it is not asked to re-derive the transcription from scratch.
   */
  cleanText: string;
  selectedLineIds: string[];
  isHandwritten: boolean;
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

function buildUserInstruction(request: CardGenerationRequest): string {
  return [
    `requestId: ${request.requestId}`,
    "Aşağıdaki metin bu pasaj için zaten uzlaştırılmış/onaylanmış transkripsiyondur; " +
      "sessizce değiştirme (§0.5):",
    request.cleanText,
    "",
    `Seçili satır kimlikleri: ${request.selectedLineIds.join(", ") || "(yok)"}`,
    `El yazısı mı: ${request.isHandwritten ? "evet" : "hayır"}`,
    "",
    "transcription alanını bu metinle doldur (exactText ve cleanText olarak) ve selectedLineIds'i " +
      "yukarıdaki kimliklerle doldur; yalnız görüntüde açıkça gördüğün ve bu metinle çelişen bir " +
      "belirsizlik varsa uncertainSpans'a ekle. Ardından bu pasajdan kartlar üret.",
  ].join("\n");
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
            { type: "input_text", text: buildUserInstruction(request) },
            {
              type: "input_image",
              image_url: `data:${request.mimeType};base64,${Buffer.from(request.image).toString("base64")}`,
            },
          ],
        },
      ],
      text: {
        format: {
          type: "json_schema",
          name: "cizgi_llm_output",
          schema: buildModelResponseSchema(this.config.maxCardsPerKnowledgeUnit),
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
