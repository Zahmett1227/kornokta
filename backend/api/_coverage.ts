/**
 * `POST /api/coverage` — the phone sends a page photo plus the cards that page
 * produced, and an independent reader answers with the marks it can see and
 * which of them no card covers (docs/PLAN-kapsama-sozlesmesi.md, Katman B).
 *
 * The fourth door, and independent like the other three: a missing
 * `GEMINI_API_KEY` refuses here by name and card generation never notices,
 * exactly as `/api/jobs` behaves without Supabase. Nothing in the capture
 * pipeline waits on this route.
 *
 * Why a second reader when schema v2.3 already has the generator keep its own
 * register: a register cannot hold a mark its author never saw. Layer A catches
 * "read it and did not card it"; only an independent pair of eyes catches
 * "never saw it" — and only if it is a *different* provider family, since two
 * models from one stack share their blind spots (§10.4).
 *
 * Same privacy discipline as the neighbouring endpoints: no database, no image
 * or card text in a log line, bytes held only for the duration of the call
 * (§7.3). The audit's own findings are not stored server-side at all; the phone
 * keeps them, like it keeps everything else.
 */

import { authorize } from "./_auth.js";
import { MAX_IMAGE_BYTES, decodeImage } from "./_image.js";
import { VISION_MIME_TYPES } from "./_cards.js";
import {
  COVERAGE_AUDIT_PROMPT_VERSION,
  GeminiError,
  type CoverageAuditRequest,
  type CoverageAuditResult,
} from "../providers/gemini.js";

/**
 * More cards than any page can produce (the ceiling is 18 and clamped
 * server-side), so this only ever stops a malformed or hostile body from
 * turning into a huge prompt.
 */
export const MAX_AUDITED_CARDS = 64;

export interface CoverageRequestBody {
  requestId?: unknown;
  /** The page the cards came from (the server's own copy is long deleted). */
  imageBase64?: unknown;
  mimeType?: unknown;
  /** `[{ front, back }]`, in the order the phone stores them. */
  cards?: unknown;
}

export interface CoverageSuccess extends CoverageAuditResult {
  requestId: string;
  /** For the phone's `ModelRun` record, same role as `cardPromptVersion`. */
  promptVersion: string;
}

export interface CoverageFailure {
  error: string;
  retryable: boolean;
}

/** Structural, so a test can drive the endpoint without a key or a network. */
export interface CoverageAuditorLike {
  audit(request: CoverageAuditRequest): Promise<CoverageAuditResult>;
}

export interface CoverageDependencies {
  auditor: CoverageAuditorLike;
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
  return json({ error: message, retryable } satisfies CoverageFailure, status);
}

/**
 * Reads the card list defensively.
 *
 * An empty array is legitimate and meaningful — a page that produced no cards
 * at all is the one where every mark is uncovered — so `[]` passes while a
 * malformed entry fails the request. Returning `null` rather than skipping bad
 * entries is deliberate: `coveredByCardIndex` is an index into this array, and
 * silently dropping one entry would shift every index after it, turning a
 * covered mark into an uncovered one.
 */
export function parseAuditCards(value: unknown): Array<{ front: string; back: string }> | null {
  if (!Array.isArray(value)) return null;
  if (value.length > MAX_AUDITED_CARDS) return null;

  const cards: Array<{ front: string; back: string }> = [];
  for (const entry of value) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) return null;
    const record = entry as { front?: unknown; back?: unknown };
    if (typeof record.front !== "string" || !record.front.trim()) return null;
    if (typeof record.back !== "string" || !record.back.trim()) return null;
    cards.push({ front: record.front.trim(), back: record.back.trim() });
  }
  return cards;
}

export async function handleCoverageRequest(
  request: Request,
  deps: CoverageDependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return fail("Yalnızca POST.", 405, false);
  }

  const auth = authorize(request.headers.get("authorization"), deps.deviceToken);
  if (!auth.ok) {
    return fail(auth.message, auth.status, auth.status === 500);
  }

  let body: CoverageRequestBody;
  try {
    body = (await request.json()) as CoverageRequestBody;
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

  const cards = parseAuditCards(body.cards);
  if (!cards) {
    return fail(
      `cards, her biri { front, back } olan bir dizi olmalı (en fazla ${MAX_AUDITED_CARDS}).`,
      400,
      false,
    );
  }

  const started = Date.now();
  try {
    const result = await deps.auditor.audit({ requestId, image, mimeType, cards });

    // Counts only. A mark's `quote` is page content and never reaches a log
    // line (§7.3) — these three numbers are what the measurement needs, and
    // they are exactly what the plan asks for after 30 pages.
    deps.log?.({
      requestId,
      event: "coverage.ok",
      bytes: image.length,
      cardCount: cards.length,
      markCount: result.marks.length,
      uncoveredMarkCount: result.uncovered.length,
      discardedMarkCount: result.discarded,
      inputTokens: result.usage.inputTokens,
      cachedInputTokens: result.usage.cachedInputTokens,
      outputTokens: result.usage.outputTokens,
      reasoningTokens: result.usage.reasoningTokens,
      estimatedCostUSD: result.usage.estimatedCostUSD,
      promptVersion: COVERAGE_AUDIT_PROMPT_VERSION,
      elapsedMs: Date.now() - started,
    });

    return json(
      { requestId, ...result, promptVersion: COVERAGE_AUDIT_PROMPT_VERSION } satisfies CoverageSuccess,
      200,
    );
  } catch (error) {
    const geminiError = error instanceof GeminiError ? error : null;
    const retryable = geminiError ? geminiError.transient : true;
    const status = geminiError ? (retryable ? 503 : 502) : 500;

    deps.log?.({
      requestId,
      event: "coverage.fail",
      bytes: image.length,
      status: geminiError?.status,
      retryable,
      // Same three-way verdict the job ledger uses: a request Gemini rejected
      // with a status generated nothing and cost nothing; anything else
      // reached the model and may have been billed without saying how much.
      billing: geminiError?.status === undefined ? "unmeasured" : "none",
      elapsedMs: Date.now() - started,
    });

    return fail(
      geminiError ? geminiError.message : "Kapsama denetimi sırasında beklenmeyen hata.",
      status,
      retryable,
    );
  }
  // `image` goes out of scope here and is never written anywhere (§7.3).
}
