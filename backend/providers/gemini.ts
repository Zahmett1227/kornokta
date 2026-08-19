/**
 * Gemini readers. Two of them, one provider, one shared rule: they read a page
 * the *other* model already read, and they never write cards.
 *
 * `GeminiSecondOpinion` (`/api/second-opinion`, ANA-PLAN §10.4's surviving idea
 * in its Faz 6 form) takes one card the vision model flagged `lowConfidence`
 * and says whether the page supports it.
 *
 * `GeminiCoverageAudit` (`/api/coverage`, docs/PLAN-kapsama-sozlesmesi.md
 * Katman B) takes the page and *all* its cards and says which marks no card
 * covers. Schema v2.3 already has the generator keep its own register, which
 * catches "read it and did not card it"; this catches the class that register
 * structurally cannot hold — a mark its author never saw.
 *
 * Both are deliberately a different provider *family* than the card generator.
 * Asking OpenAI to check OpenAI shares one vision stack's failure modes, and
 * independence is the entire value of a second reading. Neither generates
 * cards: the prompts forbid it and the schemas have nowhere to put one.
 *
 * Privacy (§7.3): same discipline as `openai.ts` — no image bytes, no
 * transcription and no card text in a log line or an error message. Failures
 * carry the HTTP status and the provider's own error string, which describe
 * the *call*, not the content.
 */

import {
  COVERAGE_AUDIT_PROMPT,
  COVERAGE_AUDIT_PROMPT_VERSION,
  buildCoverageAuditInstruction,
} from "../prompts/coverageAudit.js";
import {
  HANDWRITING_SECOND_OPINION_PROMPT,
  HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
} from "../prompts/handwritingSecondOpinion.js";
import { markPriority } from "./coverage.js";
import { MARK_KINDS, type MarkKind } from "../schemas/llmOutputTypes.js";
import {
  EMPTY_TOKEN_USAGE,
  estimateCostUSD,
  readGeminiUsage,
  type TokenUsage,
} from "./tokenUsage.js";
import type { CostConfig, GeminiConfig } from "../config.js";

export { COVERAGE_AUDIT_PROMPT_VERSION, HANDWRITING_SECOND_OPINION_PROMPT_VERSION };

export class GeminiError extends Error {
  constructor(
    message: string,
    readonly status: number | undefined,
    /** Transient failures are worth retrying; permanent ones are not (§17). */
    readonly transient: boolean,
    /**
     * What the call spent before it failed, when Gemini reported it.
     *
     * The same field `OpenAIError` carries, added for the same reason: the most
     * expensive failure in the system is a generation that runs to the output
     * ceiling and then truncates, and Gemini *does* return `usageMetadata`
     * alongside `finishReason: "MAX_TOKENS"`. Without somewhere to put it, that
     * fully-billed call reached the ledger as zero tokens — under-reporting
     * exactly where the provider had handed us the exact figure (Codex, PR #49).
     *
     * Absent on the failures that genuinely cost nothing (a rejected key, an
     * exhausted quota) and on those where no usage block ever arrived.
     */
    readonly usage?: TokenUsage,
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

/**
 * One `generateContent` call: build the body, make the request, and turn
 * everything that is not a clean JSON answer into a `GeminiError`.
 *
 * Shared by both readers this file exposes. Extracted when the coverage audit
 * arrived rather than copied, because what lives here is not boilerplate — it
 * is a list of ways a 2xx response can still be worthless (a `blockReason`, a
 * `MAX_TOKENS` truncation, a `finishReason` that is not `STOP`, schema-valid
 * JSON left behind by a policy stop). Each one was learned once; a second copy
 * would be a second chance to forget one.
 */
async function generateContent(
  transport: GeminiTransport,
  apiKey: string,
  request: {
    model: string;
    maxOutputTokens: number;
    /**
     * Which environment variable set `maxOutputTokens`, so a truncation names
     * the knob the reader must actually turn.
     *
     * Threaded through rather than hardcoded because the two callers have two
     * different ceilings: a shared message saying "GEMINI_MAX_OUTPUT_TOKENS"
     * would send someone to raise a variable that has no effect on the call
     * that failed — the same class of wasted hunt the owner's "name the real
     * suspect" rule exists to prevent.
     */
    budgetVariable: string;
    timeoutMs: number;
    systemPrompt: string;
    instruction: string;
    image: Uint8Array;
    mimeType: string;
    responseSchema: unknown;
  },
): Promise<{ payload: unknown; tokens: TokenUsage }> {
  const response = await transport.post(
    `https://generativelanguage.googleapis.com/v1beta/models/${request.model}:generateContent`,
    apiKey,
    {
      systemInstruction: { parts: [{ text: request.systemPrompt }] },
      contents: [
        {
          role: "user",
          parts: [
            { text: request.instruction },
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
        // Reading a page wants fidelity, not creativity — true for a
        // transcription verdict and for a mark register alike.
        temperature: 0,
        maxOutputTokens: request.maxOutputTokens,
        responseMimeType: "application/json",
        responseSchema: request.responseSchema,
      },
    },
    request.timeoutMs,
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
      `Model yanıtı tamamlayamadı (MAX_TOKENS): ${request.budgetVariable} bu model için ` +
        "yetersiz olabilir (düşünme token'ları da bu bütçeden düşülüyor).",
      undefined,
      true,
    );
  }
  if (candidate.finishReason && candidate.finishReason !== "STOP") {
    // SAFETY, RECITATION, BLOCKLIST… can leave schema-valid JSON behind, and
    // parsing it would present a policy-terminated fragment as a trustworthy
    // answer (Codex, PR #39). Anything that did not stop cleanly is an
    // unsuccessful call, not content. Permanent: the same page would trip the
    // same filter again.
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

  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch {
    throw new GeminiError("Model yanıtı geçerli JSON değil.", undefined, false);
  }

  return { payload, tokens: readGeminiUsage(parsedBody) ?? EMPTY_TOKEN_USAGE };
}

export class GeminiSecondOpinion {
  readonly name = "Gemini";

  constructor(
    private readonly config: GeminiConfig,
    private readonly apiKey: string,
    private readonly cost: GeminiCostConfig,
    private readonly transport: GeminiTransport = geminiFetchTransport,
  ) {}

  async secondOpinion(request: SecondOpinionRequest): Promise<SecondOpinionResult> {
    const { payload, tokens } = await generateContent(this.transport, this.apiKey, {
      model: this.config.model,
      maxOutputTokens: this.config.maxOutputTokens,
      budgetVariable: "GEMINI_MAX_OUTPUT_TOKENS",
      timeoutMs: this.config.timeoutMs,
      systemPrompt: HANDWRITING_SECOND_OPINION_PROMPT,
      instruction: buildSecondOpinionInstruction(request),
      image: request.image,
      mimeType: request.mimeType,
      responseSchema: RESPONSE_SCHEMA,
    });

    const record = payload as { verdict?: unknown; reading?: unknown; note?: unknown };
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

export interface CoverageAuditRequest {
  /** Assigned by the caller, echoed back — same rule as everywhere else here. */
  requestId: string;
  /** The full marked page; the auditor locates the marks itself. */
  image: Uint8Array;
  mimeType: string;
  /**
   * The cards this page produced, in order — `coveredByCardIndex` refers to
   * this array. Only question and answer travel: the auditor is asked what is
   * *missing*, not whether a card is right, so it has no use for the rest.
   */
  cards: ReadonlyArray<{ front: string; back: string }>;
}

/** One mark the independent reader saw, and the card (if any) it says covers it. */
export interface AuditedMark {
  kind: MarkKind;
  /** Verbatim page text, as the auditor read it. */
  quote: string;
  /** Index into `CoverageAuditRequest.cards`, or `null` for "no card covers this". */
  coveredByCardIndex: number | null;
}

export interface CoverageAuditResult {
  /** Every mark the auditor reported, malformed rows removed. */
  marks: AuditedMark[];
  /**
   * The answer this endpoint exists for: marks with no covering card, ordered
   * by the same tier ranking the generator's own register uses
   * (`providers/coverage.ts`), so the most valuable omission is first.
   */
  uncovered: AuditedMark[];
  /**
   * How many rows were dropped as unusable (unknown tier, empty quote, an
   * index pointing at no card).
   *
   * Counted rather than silently discarded, and *not* folded into `uncovered`:
   * a malformed row is the auditor being confused about one mark, and turning
   * that into "this mark was skipped" would manufacture the very false
   * positive the prompt spends a rule avoiding. It is reported so a systematic
   * problem shows up as a number instead of as quiet under-reporting.
   */
  discarded: number;
  /** Same shape as the second opinion's, so the phone's ledger decoder is the same one. */
  usage: SecondOpinionResult["usage"];
}

/**
 * What the auditor must return. Gemini's `responseSchema` speaks the OpenAPI
 * subset (uppercase type names), not JSON Schema.
 *
 * `kind` is constrained to `MARK_KINDS` — the generator's own four tiers, the
 * same list the canonical schema and the Swift enum hold. Two readers of one
 * page describing marks in two vocabularies would make the two registers
 * impossible to merge on the phone, which is the entire point of running both.
 */
const COVERAGE_RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    marks: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          kind: { type: "STRING", enum: [...MARK_KINDS] },
          quote: { type: "STRING" },
          coveredByCardIndex: { type: "INTEGER", nullable: true },
        },
        // `coveredByCardIndex` is required-and-nullable, not optional, and the
        // difference is the whole answer: leaving it out let a schema-valid row
        // arrive with only `kind` and `quote`, which read exactly like an
        // explicit `null` and reported a covered mark as uncovered (Codex,
        // PR #47). A false "you skipped this" costs the owner a decision every
        // time, which is the one thing this endpoint must not manufacture — so
        // the model has to say `null` deliberately rather than by omission.
        required: ["kind", "quote", "coveredByCardIndex"],
      },
    },
  },
  required: ["marks"],
} as const;

/**
 * The independent coverage audit (`/api/coverage`, docs/PLAN-kapsama-sozlesmesi.md
 * Katman B).
 *
 * A second class rather than a second method on `GeminiSecondOpinion`, for the
 * reason that file header gives about the second opinion itself: each of these
 * has exactly one job, and the two jobs are different questions about the same
 * photo — "is this card supported?" versus "what did the first reader miss?".
 * They share a provider and a transport, not a purpose.
 */
export class GeminiCoverageAudit {
  readonly name = "Gemini";

  constructor(
    private readonly config: GeminiConfig,
    private readonly apiKey: string,
    private readonly cost: GeminiCostConfig,
    private readonly transport: GeminiTransport = geminiFetchTransport,
  ) {}

  async audit(request: CoverageAuditRequest): Promise<CoverageAuditResult> {
    const { payload, tokens } = await generateContent(this.transport, this.apiKey, {
      model: this.config.model,
      // Its own ceiling: a register of twenty marks with verbatim quotes is a
      // much longer answer than a one-line verdict, and the thinking tokens
      // come out of the same budget (config.ts's `coverageMaxOutputTokens`).
      maxOutputTokens: this.config.coverageMaxOutputTokens,
      budgetVariable: "GEMINI_COVERAGE_MAX_OUTPUT_TOKENS",
      timeoutMs: this.config.timeoutMs,
      systemPrompt: COVERAGE_AUDIT_PROMPT,
      instruction: buildCoverageAuditInstruction(request.requestId, request.cards),
      image: request.image,
      mimeType: request.mimeType,
      responseSchema: COVERAGE_RESPONSE_SCHEMA,
    });

    const rows = (payload as { marks?: unknown }).marks;
    if (!Array.isArray(rows)) {
      throw new GeminiError("Model yanıtında marks listesi yok.", undefined, false);
    }

    const marks: AuditedMark[] = [];
    let discarded = 0;
    for (const row of rows) {
      const mark = readAuditedMark(row, request.cards.length);
      if (mark) marks.push(mark);
      else discarded += 1;
    }

    return {
      marks,
      uncovered: sortByTier(marks.filter((mark) => mark.coveredByCardIndex === null)),
      discarded,
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

/** One row of the auditor's answer, or `null` when it cannot be trusted. */
function readAuditedMark(value: unknown, cardCount: number): AuditedMark | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as { kind?: unknown; quote?: unknown; coveredByCardIndex?: unknown };
  if (typeof record.kind !== "string" || !(MARK_KINDS as readonly string[]).includes(record.kind)) {
    return null;
  }
  if (typeof record.quote !== "string" || !record.quote.trim()) return null;

  const index = record.coveredByCardIndex;
  // An explicit `null` is the auditor saying "no card covers this" — the
  // finding. A *missing* field is not the same statement: the schema requires
  // it, so its absence means the row is malformed, and reading that as
  // "uncovered" would invent a finding out of a formatting slip. Dropped and
  // counted instead, like every other unusable row.
  if (index === undefined) return null;
  if (index === null) {
    return { kind: record.kind as MarkKind, quote: record.quote.trim(), coveredByCardIndex: null };
  }
  // An index pointing at no card is the auditor losing track of the list, not
  // evidence about the mark — see `CoverageAuditResult.discarded` for why that
  // is dropped rather than read as "uncovered".
  if (typeof index !== "number" || !Number.isInteger(index) || index < 0 || index >= cardCount) {
    return null;
  }
  return { kind: record.kind as MarkKind, quote: record.quote.trim(), coveredByCardIndex: index };
}

/** Most valuable tier first, order within a tier preserved (`markPriority`). */
function sortByTier(marks: AuditedMark[]): AuditedMark[] {
  return marks
    .map((mark, index) => ({ mark, index }))
    .sort((a, b) => {
      const priority = markPriority(a.mark.kind) - markPriority(b.mark.kind);
      return priority !== 0 ? priority : a.index - b.index;
    })
    .map((entry) => entry.mark);
}
