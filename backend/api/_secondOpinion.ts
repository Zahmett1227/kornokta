/**
 * `POST /api/second-opinion` — the phone sends one `lowConfidence` card plus
 * its source page photo, and Gemini answers with an independent reading and a
 * verdict ("supports" / "contradicts" / "unclear").
 *
 * User-initiated only: a button in "Gözden geçir", pressed while the human is
 * already looking at the doubtful card. Deliberately not part of the capture
 * pipeline — no job row, no queue, no automatic spend — so this whole route
 * can be down without card generation noticing (variant chosen 2026-08-11
 * over an automatic in-job pass, whose smoother UX was not worth paying for
 * opinions nobody would read).
 *
 * Same privacy discipline as `_cards.ts`: no database, no image/text in a log
 * line, bytes held only for the duration of the call (§7.3).
 */

import { authorize } from "./_auth.js";
import { MAX_IMAGE_BYTES, decodeImage } from "./_image.js";
import { VISION_MIME_TYPES } from "./_cards.js";
import {
  GeminiError,
  HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
  type SecondOpinionCard,
  type SecondOpinionRequest,
  type SecondOpinionResult,
} from "../providers/gemini.js";

export interface SecondOpinionRequestBody {
  /** Client-generated id, echoed back — same convention as `jobId` on `_cards.ts`. */
  requestId?: unknown;
  /** The card's source page (the phone still holds it; the server's copy is long deleted). */
  imageBase64?: unknown;
  mimeType?: unknown;
  /** `{ front, back, explanation? }` of the doubtful card, verbatim. */
  card?: unknown;
}

export interface SecondOpinionSuccess extends SecondOpinionResult {
  requestId: string;
  /** For the phone's own records, same role as `cardPromptVersion` on `_cards.ts`. */
  promptVersion: string;
}

export interface SecondOpinionFailure {
  error: string;
  /** Whether the phone may usefully offer "tekrar dene" (§17). */
  retryable: boolean;
}

/**
 * Structural, not a class reference, so a test can drive the endpoint without
 * an API key or network — the same role `CardGeneratorLike` plays for
 * `_cards.ts`.
 */
export interface SecondOpinionProviderLike {
  secondOpinion(request: SecondOpinionRequest): Promise<SecondOpinionResult>;
}

export interface SecondOpinionDependencies {
  provider: SecondOpinionProviderLike;
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
  return json({ error: message, retryable } satisfies SecondOpinionFailure, status);
}

/**
 * Reads the card fields defensively.
 *
 * `front` and `back` are what the verdict is *about*, so they are required;
 * `explanation` is context and may be absent. Returns `null` for anything
 * malformed rather than guessing — a verdict computed against a half-parsed
 * card would look authoritative and be about nothing.
 */
export function parseCard(value: unknown): SecondOpinionCard | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as { front?: unknown; back?: unknown; explanation?: unknown };
  if (typeof record.front !== "string" || !record.front.trim()) return null;
  if (typeof record.back !== "string" || !record.back.trim()) return null;
  if (record.explanation !== undefined && typeof record.explanation !== "string") return null;
  const explanation = typeof record.explanation === "string" ? record.explanation.trim() : "";
  return {
    front: record.front.trim(),
    back: record.back.trim(),
    ...(explanation ? { explanation } : {}),
  };
}

export async function handleSecondOpinionRequest(
  request: Request,
  deps: SecondOpinionDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return fail("Yalnızca POST.", 405, false);
  }

  const auth = authorize(request.headers.get("authorization"), deps.deviceToken);
  if (!auth.ok) {
    return fail(auth.message, auth.status, auth.status === 500);
  }

  let body: SecondOpinionRequestBody;
  try {
    body = (await request.json()) as SecondOpinionRequestBody;
  } catch {
    return fail("Gövde geçerli JSON değil.", 400, false);
  }

  const requestId =
    typeof body.requestId === "string" && body.requestId.trim() ? body.requestId.trim() : null;
  if (!requestId) {
    return fail("requestId zorunlu.", 400, false);
  }

  const mimeType = typeof body.mimeType === "string" ? body.mimeType.trim() : "";
  if (!VISION_MIME_TYPES.has(mimeType)) {
    return fail(
      `Desteklenmeyen tür: ${mimeType || "(boş)"}. Kabul edilenler: ` +
        `${[...VISION_MIME_TYPES].join(", ")}.`,
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

  const card = parseCard(body.card);
  if (!card) {
    return fail("card { front, back } zorunlu (explanation isteğe bağlı metin).", 400, false);
  }

  const started = Date.now();
  try {
    const result = await deps.provider.secondOpinion({ requestId, image, mimeType, card });

    // Metrics only. The verdict is a three-way enum — the same class of
    // metadata as `_cards.ts`'s decision counts — but the reading/note never
    // appear here (§7.3).
    deps.log?.({
      requestId,
      event: "second_opinion.ok",
      bytes: image.length,
      verdict: result.verdict,
      inputTokens: result.usage.inputTokens,
      cachedInputTokens: result.usage.cachedInputTokens,
      outputTokens: result.usage.outputTokens,
      reasoningTokens: result.usage.reasoningTokens,
      estimatedCostUSD: result.usage.estimatedCostUSD,
      promptVersion: HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
      elapsedMs: Date.now() - started,
    });

    return json(
      {
        requestId,
        ...result,
        promptVersion: HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
      } satisfies SecondOpinionSuccess,
      200,
    );
  } catch (error) {
    const geminiError = error instanceof GeminiError ? error : null;
    const retryable = geminiError ? geminiError.transient : true;
    const status = geminiError ? (retryable ? 503 : 502) : 500;

    deps.log?.({
      requestId,
      event: "second_opinion.fail",
      bytes: image.length,
      status: geminiError?.status,
      retryable,
      // Same three-way verdict the job ledger uses (`tokenUsage.ts`). Gemini
      // answers a rejected request with a status and no generation, so a call
      // that got one cost nothing; anything else reached the model and may
      // have been billed without ever reporting how much.
      billing: geminiError?.status === undefined ? "unmeasured" : "none",
      elapsedMs: Date.now() - started,
    });

    return fail(
      geminiError ? geminiError.message : "İkinci görüş sırasında beklenmeyen hata.",
      status,
      retryable,
    );
  }
  // `image` goes out of scope here and is never written anywhere (§7.3).
}
