/**
 * Gemini second-opinion provider (`/api/second-opinion`, ANA-PLAN §10.4's
 * surviving idea in its Faz 6 form).
 *
 * One job: given a marked page photo and one card the vision model flagged
 * `lowConfidence`, independently re-read the relevant region and say whether
 * the page supports the card. Deliberately a different provider *family* than
 * the card generator — asking OpenAI to check OpenAI shares one vision
 * stack's failure modes, and independence is the entire value of a second
 * opinion. Never generates cards; the prompt forbids it and the schema has
 * nowhere to put one.
 *
 * Privacy (§7.3): same discipline as `openai.ts` — no image bytes, no
 * transcription and no card text in a log line or an error message. Failures
 * carry the HTTP status and the provider's own error string, which describe
 * the *call*, not the content.
 */

import {
  HANDWRITING_SECOND_OPINION_PROMPT,
  HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
} from "../prompts/handwritingSecondOpinion.js";
import {
  EMPTY_TOKEN_USAGE,
  estimateCostUSD,
  readGeminiUsage,
  type TokenUsage,
} from "./tokenUsage.js";
import type { CostConfig, GeminiConfig } from "../config.js";

export { HANDWRITING_SECOND_OPINION_PROMPT_VERSION };

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
export interface GeminiTransport {
  post(url: string, apiKey: string, body: unknown, timeoutMs: number): Promise<{
    status: number;
    body: unknown;
  }>;
}

export const geminiFetchTransport: GeminiTransport = {
  async post(url, apiKey, body, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          // Header, never a `?key=` query parameter: URLs end up in access
          // logs and error messages, headers do not (§0.7).
          "x-goog-api-key": apiKey,
          "Content-Type": "application/json",
        },
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

export const SECOND_OPINION_VERDICTS = ["supports", "contradicts", "unclear"] as const;
export type SecondOpinionVerdict = (typeof SECOND_OPINION_VERDICTS)[number];

export interface SecondOpinionCard {
  front: string;
  back: string;
  explanation?: string;
}

export interface SecondOpinionRequest {
  /** Assigned by the caller, echoed back — same rule as card generation. */
  requestId: string;
  /**
   * The full marked page, not a crop: the deterministic crop pipeline is gone
   * (ADR-005) and the second reader locates the card's region itself, exactly
   * like the first reader did.
   */
  image: Uint8Array;
  mimeType: string;
  /** The doubtful card, verbatim as the deck stores it. */
  card: SecondOpinionCard;
}

export interface SecondOpinionResult {
  verdict: SecondOpinionVerdict;
  /** The independent transcription of the region (≤3 candidates per unclear spot). */
  reading: string;
  /** One-sentence explanation, mainly for `contradicts`. */
  note?: string;
  /**
   * Same shape as card generation's `usage` block on purpose: the phone's
   * `ModelRun` accounting (§16.8, Ayarlar → Kullanım) records provider and
   * model per call, and this call must count like every other paid one
   * (Codex, PR #39).
   */
  usage: {
    provider: "gemini";
    model: string;
    inputTokens: number;
    /** Subset of `inputTokens` served from Gemini's context cache, billed cheaper. */
    cachedInputTokens: number;
    outputTokens: number;
    /** Subset of `outputTokens` Gemini reports as `thoughtsTokenCount`. */
    reasoningTokens: number;
    estimatedCostUSD: number;
  };
}

/** The three prices this provider is billed at, in the shape `estimateCostUSD` wants. */
export type GeminiCostConfig = Pick<
  CostConfig,
  | "geminiUsdPerMillionInputTokens"
  | "geminiUsdPerMillionCachedInputTokens"
  | "geminiUsdPerMillionOutputTokens"
>;

/**
 * Estimated USD from real usage figures and the configured per-token price
 * (§20.3). Same widening as `estimateOpenAICostUSD`, for the same reason: the
 * cached share of the input has its own rate and pricing it as uncached
 * overstates every repeated call.
 */
export function estimateGeminiCostUSD(usage: TokenUsage, cost: GeminiCostConfig): number {
  return estimateCostUSD(usage, {
    usdPerMillionInputTokens: cost.geminiUsdPerMillionInputTokens,
    usdPerMillionCachedInputTokens: cost.geminiUsdPerMillionCachedInputTokens,
    usdPerMillionOutputTokens: cost.geminiUsdPerMillionOutputTokens,
  });
}

export function buildSecondOpinionInstruction(request: SecondOpinionRequest): string {
  const explanation = request.card.explanation?.trim();
  return [
    `requestId: ${request.requestId}`,
    "Ekteki fotoğraf, kartın üretildiği işaretli sayfanın tamamıdır.",
    "Değerlendirilecek kart:",
    `Soru: ${request.card.front}`,
    `Cevap: ${request.card.back}`,
    explanation ? `Açıklama: ${explanation}` : "Açıklama: (yok)",
  ].join("\n");
}

/**
 * What the model must return. Gemini's `responseSchema` speaks the OpenAPI
 * subset (uppercase type names), not JSON Schema.
 */
const RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    verdict: { type: "STRING", enum: [...SECOND_OPINION_VERDICTS] },
    reading: { type: "STRING" },
    note: { type: "STRING" },
  },
  required: ["verdict", "reading"],
} as const;

interface GenerateContentBody {
  candidates?: Array<{
    content?: { parts?: Array<{ text?: string }> };
    finishReason?: string;
  }>;
  promptFeedback?: { blockReason?: string };
  /** Read through `readGeminiUsage`, which also folds in `thoughtsTokenCount`. */
  usageMetadata?: {
    promptTokenCount?: number;
    candidatesTokenCount?: number;
    cachedContentTokenCount?: number;
    thoughtsTokenCount?: number;
  };
  error?: { message?: string; status?: string };
}

/** Status codes worth another attempt (§17), same convention as `openai.ts`. */
function isTransientStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

/**
 * Turns a non-2xx answer into an error that names the actual problem.
 *
 * The owner's explicit requirement: an exhausted quota/credit must say so in
 * as many words, because Google reports it as a bare 429 — the same status as
 * a per-minute rate limit — and an undifferentiated "429" reads as "the model
 * is busy, try later" while the real fix (checking billing) goes unfound.
 */
function describeHttpFailure(status: number, body: GenerateContentBody | undefined): GeminiError {
  const detail = body?.error?.message ?? "ayrıntı yok";
  if (status === 429) {
    return new GeminiError(
      "Gemini kotası/kredisi tükenmiş görünüyor (429 RESOURCE_EXHAUSTED). Bu, dakikalık hız " +
        "sınırı da olabilir, biten kota/kredi de — birkaç denemede geçmiyorsa " +
        "aistudio.google.com üzerinden kota ve faturalandırmayı kontrol et. " +
        `Sağlayıcı mesajı: ${detail}`,
      status,
      // Transient on purpose: while the quota is empty each retry fails fast
      // and free, and the first retry after it refills succeeds on its own.
      true,
    );
  }
  if (status === 401 || status === 403) {
    return new GeminiError(
      `Gemini API anahtarı reddedildi (${status}): anahtar geçersiz/iptal edilmiş olabilir ya da ` +
        "projede faturalandırma sorunu var. aistudio.google.com → API keys'ten kontrol et. " +
        `Sağlayıcı mesajı: ${detail}`,
      status,
      false,
    );
  }
  return new GeminiError(`Gemini ${status}: ${detail}`, status, isTransientStatus(status));
}

export class GeminiSecondOpinion {
  readonly name = "Gemini";

  constructor(
    private readonly config: GeminiConfig,
    private readonly apiKey: string,
    private readonly cost: GeminiCostConfig,
    private readonly transport: GeminiTransport = geminiFetchTransport,
  ) {}

  private endpoint(): string {
    return `https://generativelanguage.googleapis.com/v1beta/models/${this.config.model}:generateContent`;
  }

  async secondOpinion(request: SecondOpinionRequest): Promise<SecondOpinionResult> {
    const body = {
      systemInstruction: {
        parts: [{ text: HANDWRITING_SECOND_OPINION_PROMPT }],
      },
      contents: [
        {
          role: "user",
          parts: [
            { text: buildSecondOpinionInstruction(request) },
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
        // A transcription verdict wants fidelity, not creativity.
        temperature: 0,
        maxOutputTokens: this.config.maxOutputTokens,
        responseMimeType: "application/json",
        responseSchema: RESPONSE_SCHEMA,
      },
    };

    const response = await this.transport.post(
      this.endpoint(),
      this.apiKey,
      body,
      this.config.timeoutMs,
    );
    const parsedBody = response.body as GenerateContentBody | undefined;

    if (response.status < 200 || response.status >= 300) {
      throw describeHttpFailure(response.status, parsedBody);
    }

    if (parsedBody?.promptFeedback?.blockReason) {
      throw new GeminiError(
        `Gemini istemi engelledi: ${parsedBody.promptFeedback.blockReason}`,
        undefined,
        false,
      );
    }

    const candidate = parsedBody?.candidates?.[0];
    if (!candidate) {
      throw new GeminiError("Yanıtta aday (candidate) yok.", undefined, true);
    }
    if (candidate.finishReason === "MAX_TOKENS") {
      // Same lesson as OpenAI's `status:"incomplete"`: a thinking-capable
      // model spends hidden tokens from this budget, so the truncation names
      // the knob rather than surfacing as a JSON parse error below.
      throw new GeminiError(
        "Model yanıtı tamamlayamadı (MAX_TOKENS): GEMINI_MAX_OUTPUT_TOKENS bu model için " +
          "yetersiz olabilir (düşünme token'ları da bu bütçeden düşülüyor).",
        undefined,
        true,
      );
    }

    if (candidate.finishReason && candidate.finishReason !== "STOP") {
      // SAFETY, RECITATION, BLOCKLIST… can leave schema-valid JSON behind, and
      // parsing it would present a policy-terminated fragment as a trustworthy
      // medical verdict (Codex, PR #39). Anything that did not stop cleanly is
      // an unsuccessful call, not content. Permanent: the same page and card
      // would trip the same filter again.
      throw new GeminiError(
        `Model üretimi temiz bitmedi (finishReason: ${candidate.finishReason}); içerik güvenilmez sayıldı.`,
        undefined,
        false,
      );
    }

    const text = candidate.content?.parts?.map((part) => part.text ?? "").join("") ?? "";
    if (!text.trim()) {
      throw new GeminiError(
        `Yanıtta üretilmiş metin yok (finishReason: ${candidate.finishReason ?? "bilinmiyor"}).`,
        undefined,
        false,
      );
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new GeminiError("Model yanıtı geçerli JSON değil.", undefined, false);
    }
    const record = parsed as { verdict?: unknown; reading?: unknown; note?: unknown };
    const verdict = record.verdict;
    if (
      typeof verdict !== "string" ||
      !(SECOND_OPINION_VERDICTS as readonly string[]).includes(verdict)
    ) {
      throw new GeminiError(
        `Model yanıtındaki verdict geçersiz: ${typeof verdict === "string" ? verdict : typeof verdict}.`,
        undefined,
        false,
      );
    }
    if (typeof record.reading !== "string" || !record.reading.trim()) {
      throw new GeminiError("Model yanıtında reading alanı yok.", undefined, false);
    }

    const tokens = readGeminiUsage(parsedBody) ?? EMPTY_TOKEN_USAGE;
    const note = typeof record.note === "string" && record.note.trim() ? record.note.trim() : undefined;

    return {
      verdict: verdict as SecondOpinionVerdict,
      reading: record.reading,
      ...(note ? { note } : {}),
      usage: {
        provider: "gemini",
        model: this.config.model,
        inputTokens: tokens.inputTokens,
        cachedInputTokens: tokens.cachedInputTokens,
        outputTokens: tokens.outputTokens,
        reasoningTokens: tokens.reasoningTokens,
        estimatedCostUSD: estimateGeminiCostUSD(tokens, this.cost),
      },
    };
  }
}
