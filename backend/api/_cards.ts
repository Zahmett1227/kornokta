/**
 * `POST /api/cards-vision` (also reachable at the legacy `/api/cards`) — the
 * endpoint the phone calls with a marked *full-page* photo to have enriched
 * study cards generated directly from it (Faz 6 — docs/FAZ6-PLAN.md §5.1).
 *
 * The Faz 6 pivot (docs/ADR-005) removed the deterministic OCR-reconcile +
 * approval machine from the main flow: this endpoint no longer takes a
 * pre-reconciled `cleanText`, and does not wait on Google OCR. It hands the
 * marked page straight to the vision model, which reads what the student
 * highlighted/underlined/circled/annotated and emits cards (v2 prompt, v2
 * schema). An optional `hint` lets the user steer ("sadece sol sütun").
 *
 * Same privacy discipline as `_ocr.ts`: no database, no image/text in a log
 * line, bytes held only for the duration of the call (§7.3).
 */

import { authorize } from "./_auth.js";
import { ACCEPTED_MIME_TYPES, MAX_IMAGE_BYTES, decodeImage } from "./_ocr.js";
import type { CostConfig, OpenAIConfig } from "../config.js";
import { CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";
import {
  OpenAIError,
  estimateOpenAICostUSD,
  type CardGenerationRequest,
  type CardGenerationResult,
} from "../providers/openai.js";
import { runCardGate, type CardDecision, type CardGateReport, type CardVerdict } from "../providers/cardGate.js";
import { sanitizeMultipleChoice } from "../providers/multipleChoice.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";

export interface CardsRequestBody {
  /** Client-generated job id; doubles as the generated output's `requestId` (§14). */
  jobId?: unknown;
  /** The marked full page (§5.2), not a crop. */
  imageBase64?: unknown;
  mimeType?: unknown;
  /** Optional free-text steer from the user (§5.1), e.g. "sadece sol sütun". */
  hint?: unknown;
  /** The user's "sayfa başına kart" setting (§6.7). Clamped to the deployment's own ceiling. */
  maxCards?: unknown;
}

/**
 * Reads a client-supplied card ceiling.
 *
 * `undefined` for an absent value (use the configured default) and `null` for a
 * malformed one, which the caller reports rather than silently ignoring — a
 * setting that is quietly dropped is exactly how this one came to do nothing at
 * all for two phases.
 */
export function parseMaxCards(value: unknown, ceiling: number): number | undefined | null {
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) return null;
  // Only ever downwards: the config value is a cost ceiling and a client must
  // not be able to raise it (§21.3).
  return Math.min(value, ceiling);
}

export interface CardsSuccess {
  jobId: string;
  output: LlmOutput;
  gate: CardGateReport;
  /**
   * Not part of the §14 canonical schema (`output` stays exactly what §14
   * defines), but the iOS `ModelRun` record (§16.8) has its own
   * `promptVersion` field and needs a real value to put there. Sourced from
   * the same constant the log line already used, so there is exactly one
   * place this string is defined, not two synced by hand.
   */
  cardPromptVersion: string;
}

export interface CardsFailure {
  error: string;
  /** Whether the phone should queue a retry (§17). */
  retryable: boolean;
}

/**
 * Structural, not a class reference: any object with this one method can
 * stand in, so a test can drive the endpoint without an API key or network,
 * the same role `TextRecognizer` plays for `_ocr.ts`.
 */
export interface CardGeneratorLike {
  generateCards(request: CardGenerationRequest): Promise<CardGenerationResult>;
}

export interface CardsDependencies {
  generator: CardGeneratorLike;
  openai: Pick<OpenAIConfig, "maxCardsPerKnowledgeUnit" | "maxOutputTokens">;
  cost: Pick<CostConfig, "openaiUsdPerMillionInputTokens" | "openaiUsdPerMillionOutputTokens" | "maxUsdPerCardGeneration">;
  deviceToken: string | undefined;
  /** Content never reaches this — only ids, counts and durations (§7.3). */
  log?: (entry: Record<string, unknown>) => void;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(message: string, status: number, retryable: boolean): Response {
  return json({ error: message, retryable } satisfies CardsFailure, status);
}

function summarizeDecisions(verdicts: CardVerdict[]): Record<CardDecision, number> {
  const counts: Record<CardDecision, number> = { auto_accept: 0, quick_confirm: 0, reject: 0 };
  for (const verdict of verdicts) counts[verdict.decision] += 1;
  return counts;
}

export async function handleCardsRequest(
  request: Request,
  deps: CardsDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return fail("Yalnızca POST.", 405, false);
  }

  const auth = authorize(request.headers.get("authorization"), deps.deviceToken);
  if (!auth.ok) {
    return fail(auth.message, auth.status, auth.status === 500);
  }

  let body: CardsRequestBody;
  try {
    body = (await request.json()) as CardsRequestBody;
  } catch {
    return fail("Gövde geçerli JSON değil.", 400, false);
  }

  const jobId = typeof body.jobId === "string" && body.jobId.trim() ? body.jobId.trim() : null;
  if (!jobId) {
    return fail("jobId zorunlu.", 400, false);
  }

  const mimeType = typeof body.mimeType === "string" ? body.mimeType.trim() : "";
  if (!ACCEPTED_MIME_TYPES.has(mimeType)) {
    return fail(
      `Desteklenmeyen tür: ${mimeType || "(boş)"}. Kabul edilenler: ` +
        `${[...ACCEPTED_MIME_TYPES].join(", ")}.`,
      415,
      false,
    );
  }

  if (typeof body.imageBase64 !== "string") {
    return fail("imageBase64 zorunlu.", 400, false);
  }
  if (body.imageBase64.length > Math.ceil(MAX_IMAGE_BYTES * 1.4)) {
    return fail(`Görüntü çok büyük (en fazla ${MAX_IMAGE_BYTES} bayt).`, 413, false);
  }
  const image = decodeImage(body.imageBase64);
  if (!image) {
    return fail("imageBase64 çözülemedi; yükleme bozuk olabilir.", 400, false);
  }
  if (image.length > MAX_IMAGE_BYTES) {
    return fail(`Görüntü çok büyük (en fazla ${MAX_IMAGE_BYTES} bayt).`, 413, false);
  }

  // Optional free-text steer (§5.1). Absent/blank is normal; a non-string is
  // a malformed body, not something to silently ignore.
  if (body.hint !== undefined && typeof body.hint !== "string") {
    return fail("hint bir metin (string) olmalı.", 400, false);
  }
  const hint = typeof body.hint === "string" ? body.hint.trim() : undefined;

  const maxCards = parseMaxCards(body.maxCards, deps.openai.maxCardsPerKnowledgeUnit);
  if (maxCards === null) {
    return fail("maxCards 1 veya daha büyük bir tam sayı olmalı.", 400, false);
  }

  // §21.3: refuse before spending, using the only bound knowable before the
  // call — the output-token ceiling. Input-token cost depends on the image
  // and prompt and is not estimated here; it is still recorded for real
  // after the call returns (§16.8, §20.3).
  if (deps.cost.maxUsdPerCardGeneration > 0) {
    const upperBound = estimateOpenAICostUSD(0, deps.openai.maxOutputTokens, deps.cost);
    if (upperBound > deps.cost.maxUsdPerCardGeneration) {
      return fail(
        `Tahmini üst sınır maliyet (${upperBound.toFixed(4)} USD) yapılandırılan sınırı ` +
          `(${deps.cost.maxUsdPerCardGeneration} USD) aşıyor; çağrı yapılmadı (§21.3).`,
        402,
        false,
      );
    }
  }

  const started = Date.now();
  try {
    const { output, rawUsage } = await deps.generator.generateCards({
      requestId: jobId,
      image,
      mimeType,
      hint,
      maxCards,
    });

    // §13.3's structural check runs before the health gate, so the gate — and
    // the client — see the cards exactly as they will be stored: a broken
    // five-option card comes out of it as a sound plain card.
    const checked = sanitizeMultipleChoice(output.cards);
    const sanitized = { ...output, cards: checked.cards };
    const gate = runCardGate(sanitized, {
      maxCardsPerKnowledgeUnit: maxCards ?? deps.openai.maxCardsPerKnowledgeUnit,
    });

    // Metrics only. No card text, no transcription (§7.3) — counts and a
    // decision breakdown are what make "why was I asked to confirm?"
    // answerable later without ever having logged the answer itself.
    deps.log?.({
      jobId,
      event: "cards.ok",
      bytes: image.length,
      cardCount: sanitized.cards.length,
      decisions: summarizeDecisions(gate.verdicts),
      // Counts only, never option text (§7.3).
      multipleChoiceNotes: checked.notes.length,
      inputTokens: rawUsage.inputTokens,
      outputTokens: rawUsage.outputTokens,
      estimatedCostUSD: output.usage.estimatedCostUSD,
      cardPromptVersion: CARD_PROMPT_VERSION,
      elapsedMs: Date.now() - started,
    });

    return json(
      { jobId, output: sanitized, gate, cardPromptVersion: CARD_PROMPT_VERSION } satisfies CardsSuccess,
      200,
    );
  } catch (error) {
    const openAIError = error instanceof OpenAIError ? error : null;

    // Decided once, used for both the log and the reply — computing it twice
    // is exactly how `_ocr.ts` once ended up logging one value while telling
    // the phone another.
    const retryable = openAIError ? openAIError.transient : true;
    const status = openAIError ? (retryable ? 503 : 502) : 500;

    deps.log?.({
      jobId,
      event: "cards.fail",
      bytes: image.length,
      status: openAIError?.status,
      retryable,
      elapsedMs: Date.now() - started,
    });

    return fail(
      openAIError ? openAIError.message : "Kart üretimi sırasında beklenmeyen hata.",
      status,
      retryable,
    );
  }
  // `image` goes out of scope here and is never written anywhere (§7.3).
}
