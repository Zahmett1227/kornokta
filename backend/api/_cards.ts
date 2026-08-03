/**
 * `POST /api/cards` — the endpoint the phone calls once a passage's
 * transcription has already been reconciled, to have source-faithful cards
 * generated from it (ANA-PLAN §7.2, §14, §25 Faz 3).
 *
 * Deliberately takes `cleanText`, not a raw image to OCR: reconciliation
 * (`providers/reconcile.ts`) has already run by the time this is called —
 * either it auto-accepted or the user confirmed it — so this endpoint is not
 * asked to re-derive the transcription, only to generate cards from a text
 * that is already trusted (§17: `card_generation` is a distinct pipeline step
 * after `transcription_reconciliation`, not a replacement for it).
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
import type { LlmOutput } from "../schemas/llmOutputTypes.js";

export interface CardsRequestBody {
  /** Client-generated job id; doubles as the generated output's `requestId` (§14). */
  jobId?: unknown;
  imageBase64?: unknown;
  mimeType?: unknown;
  /** Text that has already passed OCR reconciliation — see file header. */
  cleanText?: unknown;
  selectedLineIds?: unknown;
  isHandwritten?: unknown;
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

/** `undefined` for an absent field, `[]`/array for a valid one, `null` for a malformed one. */
export function parseSelectedLineIds(value: unknown): string[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) return null;
  return value as string[];
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

  const cleanText = typeof body.cleanText === "string" ? body.cleanText.trim() : "";
  if (!cleanText) {
    return fail(
      "cleanText zorunlu: bu uç nokta zaten uzlaştırılmış metin bekler, ham OCR yapmaz (§17).",
      400,
      false,
    );
  }

  const selectedLineIds = parseSelectedLineIds(body.selectedLineIds);
  if (selectedLineIds === null) {
    return fail("selectedLineIds bir metin (string) dizisi olmalı.", 400, false);
  }

  const isHandwritten = body.isHandwritten === true;

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
      cleanText,
      selectedLineIds,
      isHandwritten,
    });

    const gate = runCardGate(output, { maxCardsPerKnowledgeUnit: deps.openai.maxCardsPerKnowledgeUnit });

    // Metrics only. No card text, no transcription (§7.3) — counts and a
    // decision breakdown are what make "why was I asked to confirm?"
    // answerable later without ever having logged the answer itself.
    deps.log?.({
      jobId,
      event: "cards.ok",
      bytes: image.length,
      cardCount: output.cards.length,
      decisions: summarizeDecisions(gate.verdicts),
      inputTokens: rawUsage.inputTokens,
      outputTokens: rawUsage.outputTokens,
      estimatedCostUSD: output.usage.estimatedCostUSD,
      cardPromptVersion: CARD_PROMPT_VERSION,
      elapsedMs: Date.now() - started,
    });

    return json({ jobId, output, gate, cardPromptVersion: CARD_PROMPT_VERSION } satisfies CardsSuccess, 200);
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
  // `image` and `cleanText` go out of scope here and are never written anywhere (§7.3).
}
