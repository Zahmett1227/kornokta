/**
 * Gemini handwriting second-opinion provider (ANA-PLAN §10.4, §11.1, §15.3).
 *
 * Called only when the primary handwriting read disagrees critically with
 * itself or with OCR (§5.2 step 5) — never for card generation, and never for
 * printed text that already passed OCR reconciliation cleanly. The prompt
 * text itself enforces the same boundary ("Kart veya açıklama üretme").
 *
 * Deliberately a narrower contract than the §14 canonical schema: §15.3 asks
 * for transcription and uncertainty only, so `HandwritingSecondOpinion`
 * reuses `UncertainSpan` from `schemas/llmOutputTypes.ts` rather than
 * inventing a second "list of uncertain spans" shape next to the one that
 * already exists for the same concept.
 *
 * Privacy (§7.3): same discipline as `documentAI.ts`/`openai.ts` — no image
 * bytes or transcribed text reach a log line or an error message.
 */

import { Ajv2020 } from "ajv/dist/2020.js";

import {
  HANDWRITING_SECOND_OPINION_PROMPT,
  HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
} from "../prompts/handwritingSecondOpinion.js";
import type { UncertainSpan } from "../schemas/llmOutputTypes.js";
import type { CostConfig, GeminiConfig } from "../config.js";

export class GeminiError extends Error {
  constructor(
    message: string,
    readonly status: number | undefined,
    /** Transient failures are worth retrying; permanent ones are not (§17). */
    readonly transient: boolean,
  ) {
    super(message);
    this.name = "GeminiError";
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
      // Gemini's public API takes the key as a query parameter, not a bearer
      // header — a different convention from OpenAI/Document AI, kept local
      // to this transport rather than leaking into the provider above it.
      const withKey = `${url}${url.includes("?") ? "&" : "?"}key=${encodeURIComponent(apiKey)}`;
      const response = await fetch(withKey, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
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

export interface HandwritingSecondOpinionRequest {
  /** The handwriting crop only (§8.2) — never the full page. */
  image: Uint8Array;
  mimeType: string;
  /** The primary reading, given for comparison — not asserted as correct. */
  primaryReading: string;
}

export interface HandwritingSecondOpinion {
  text: string;
  uncertainSpans: UncertainSpan[];
}

export interface HandwritingSecondOpinionResult {
  opinion: HandwritingSecondOpinion;
  /** As Gemini reported it, before our own cost math — kept for audit (§16.8). */
  rawUsage: { inputTokens: number; outputTokens: number };
}

/**
 * The §15.3 contract as a JSON Schema, deliberately separate from and smaller
 * than `llm_output.schema.json`: this call never produces cards, knowledge
 * units, or a cost estimate, so asking for the full §14 shape would let a
 * bug silently smuggle card content in through the "second opinion" path.
 *
 * No `additionalProperties` here — confirmed with a real (fake-key) call
 * against the live API: Gemini's `responseSchema` is a constrained subset of
 * JSON Schema and rejects that keyword outright (`Unknown name
 * "additionalProperties" ... Cannot find field.`, HTTP 400). This is the
 * object sent to Gemini; `LOCAL_VALIDATION_SCHEMA` below adds the keyword
 * back for our own independent check, since the constraint we actually want
 * (no unannounced extra field, e.g. a smuggled "cards") is not a request-shape
 * concern and does not need to survive the trip to Google's validator.
 */
const RESPONSE_SCHEMA = {
  type: "object",
  required: ["text", "uncertainSpans"],
  properties: {
    text: { type: "string" },
    uncertainSpans: {
      type: "array",
      items: {
        type: "object",
        required: ["text", "alternatives", "reason", "critical", "requiresUserConfirmation"],
        properties: {
          text: { type: "string" },
          alternatives: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 3 },
          reason: { type: "string" },
          critical: { type: "boolean" },
          requiresUserConfirmation: { type: "boolean" },
        },
      },
    },
  },
};

function localValidationSchema(): Record<string, unknown> {
  const clone = structuredClone(RESPONSE_SCHEMA) as {
    additionalProperties?: boolean;
    properties: { uncertainSpans: { items: { additionalProperties?: boolean } } };
  };
  clone.additionalProperties = false;
  clone.properties.uncertainSpans.items.additionalProperties = false;
  return clone as Record<string, unknown>;
}

const ajv = new Ajv2020({ allErrors: true, strict: true });
const validateShape = ajv.compile(localValidationSchema());

/** Status codes worth another attempt (§17), same convention as `documentAI.ts`/`openai.ts`. */
function isTransientStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

/** Estimated USD from real usage figures and the configured per-token price (§20.3). */
export function estimateGeminiCostUSD(
  inputTokens: number,
  outputTokens: number,
  cost: Pick<CostConfig, "geminiUsdPerMillionInputTokens" | "geminiUsdPerMillionOutputTokens">,
): number {
  return (
    (inputTokens / 1_000_000) * cost.geminiUsdPerMillionInputTokens +
    (outputTokens / 1_000_000) * cost.geminiUsdPerMillionOutputTokens
  );
}

interface GeminiResponseBody {
  candidates?: Array<{
    content?: { parts?: Array<{ text?: string }> };
    finishReason?: string;
  }>;
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
  error?: { message?: string };
}

function extractResponseText(body: GeminiResponseBody): string {
  const candidate = body.candidates?.[0];
  if (!candidate) {
    throw new GeminiError("Yanıtta aday üretim bulunamadı.", undefined, false);
  }
  // SAFETY, MAX_TOKENS, RECITATION, ... — anything but a clean stop means the
  // JSON that follows (if any) is not a complete, trustworthy answer.
  if (candidate.finishReason && candidate.finishReason !== "STOP") {
    throw new GeminiError(`Model üretimi tamamlamadı: ${candidate.finishReason}`, undefined, false);
  }
  for (const part of candidate.content?.parts ?? []) {
    if (typeof part.text === "string") return part.text;
  }
  throw new GeminiError("Yanıtta metin bulunamadı.", undefined, false);
}

export class GeminiHandwritingSecondOpinion {
  readonly name = "Gemini";

  constructor(
    private readonly config: GeminiConfig,
    private readonly apiKey: string,
    private readonly cost: Pick<CostConfig, "geminiUsdPerMillionInputTokens" | "geminiUsdPerMillionOutputTokens">,
    private readonly transport: Transport = fetchTransport,
  ) {}

  private get endpoint(): string {
    return `https://generativelanguage.googleapis.com/v1beta/models/${this.config.model}:generateContent`;
  }

  async getSecondOpinion(
    request: HandwritingSecondOpinionRequest,
  ): Promise<HandwritingSecondOpinionResult> {
    const body = {
      systemInstruction: { parts: [{ text: HANDWRITING_SECOND_OPINION_PROMPT }] },
      contents: [
        {
          role: "user",
          parts: [
            {
              text:
                "Birincil okumanın ürettiği aday metin (karşılaştırma için verildi, doğru kabul etme):\n" +
                request.primaryReading,
            },
            {
              inlineData: {
                mimeType: request.mimeType,
                data: Buffer.from(request.image).toString("base64"),
              },
            },
          ],
        },
      ],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: RESPONSE_SCHEMA,
        maxOutputTokens: this.config.maxOutputTokens,
      },
    };

    const response = await this.transport.post(this.endpoint, this.apiKey, body, this.config.timeoutMs);

    if (response.status < 200 || response.status >= 300) {
      const detail =
        (response.body as { error?: { message?: string } } | undefined)?.error?.message ?? "ayrıntı yok";
      throw new GeminiError(`Gemini ${response.status}: ${detail}`, response.status, isTransientStatus(response.status));
    }

    const parsedBody = response.body as GeminiResponseBody;
    const text = extractResponseText(parsedBody);

    let candidate: unknown;
    try {
      candidate = JSON.parse(text);
    } catch {
      throw new GeminiError("Model yanıtı geçerli JSON değil.", undefined, false);
    }

    if (!validateShape(candidate)) {
      const detail = (validateShape.errors ?? [])
        .map((error) => `${error.instancePath || "(kök)"} ${error.message ?? "geçersiz"}`)
        .join("; ");
      throw new GeminiError(`Model yanıtı §15.3 sözleşmesine uymuyor: ${detail}`, undefined, false);
    }

    const usage = parsedBody.usageMetadata ?? {};
    const rawUsage = {
      inputTokens: usage.promptTokenCount ?? 0,
      outputTokens: usage.candidatesTokenCount ?? 0,
    };

    return { opinion: candidate as unknown as HandwritingSecondOpinion, rawUsage };
  }
}

export { HANDWRITING_SECOND_OPINION_PROMPT_VERSION };
