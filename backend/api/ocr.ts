/**
 * `POST /api/ocr` — the endpoint the phone calls to have a page read
 * (ANA-PLAN §7.2).
 *
 * Written as a plain `(Request) => Response` handler so it is not tied to one
 * host. Vercel Functions is the suggested target (§7.2), but the same function
 * runs under any fetch-based runtime and, importantly, under a unit test with
 * no server at all.
 *
 * What this endpoint does *not* do, on purpose:
 *   * it keeps no database — the phone is the source of truth (§7.2)
 *   * it writes no image, no OCR text and no handwriting to any log (§7.3)
 *   * it holds the uploaded bytes only for the duration of the call (§7.3)
 */

import { authorize } from "./auth.js";
import type { DocumentAIConfig } from "../config.js";
import { DocumentAIError } from "../providers/documentAI.js";
import type { OCRPage, TextRecognizer } from "../providers/ocrTypes.js";

/** Upload ceiling. A phone photo is ~2–5 MB; 20 MB is generous and bounded. */
export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

export const ACCEPTED_MIME_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/tiff",
  "image/webp",
  "application/pdf",
]);

export interface OcrRequestBody {
  /** Base64-encoded image bytes. */
  imageBase64?: unknown;
  mimeType?: unknown;
  /**
   * Client-generated job id, echoed back so a reply can be matched to its
   * request. Never used to look anything up — the backend stores nothing.
   */
  jobId?: unknown;
}

export interface OcrSuccess {
  jobId: string;
  page: OCRPage;
}

export interface OcrFailure {
  error: string;
  /** Whether the phone should queue a retry (§17). */
  retryable: boolean;
}

export interface Dependencies {
  recognizer: TextRecognizer;
  documentAI: Pick<DocumentAIConfig, "languageHints">;
  deviceToken: string | undefined;
  /**
   * Where request-level telemetry goes. Content never reaches it — only the
   * job id, a byte count and a duration (§7.3: "istek kimliği ve maliyet
   * metrikleri içerikten ayrı tutulur").
   */
  log?: (entry: Record<string, unknown>) => void;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(message: string, status: number, retryable: boolean): Response {
  return json({ error: message, retryable } satisfies OcrFailure, status);
}

/**
 * Decodes base64 strictly.
 *
 * `Buffer.from(x, "base64")` silently ignores anything that is not a base64
 * character, so a truncated or corrupted upload would decode to a shorter
 * image and be sent to a paid API as if it were fine. Re-encoding and
 * comparing catches that.
 */
export function decodeImage(base64: string): Uint8Array | null {
  const cleaned = base64.trim();
  if (!cleaned) return null;
  const bytes = Buffer.from(cleaned, "base64");
  if (bytes.length === 0) return null;
  // Compare against the input with padding normalized; a valid payload
  // round-trips exactly.
  const reencoded = bytes.toString("base64");
  const normalize = (value: string) => value.replace(/=+$/, "");
  if (normalize(reencoded) !== normalize(cleaned)) return null;
  return new Uint8Array(bytes);
}

export async function handleOcrRequest(
  request: Request,
  deps: Dependencies,
): Promise<Response> {
  if (request.method !== "POST") {
    return fail("Yalnızca POST.", 405, false);
  }

  const auth = authorize(request.headers.get("authorization"), deps.deviceToken);
  if (!auth.ok) {
    return fail(auth.message, auth.status, auth.status === 500);
  }

  let body: OcrRequestBody;
  try {
    body = (await request.json()) as OcrRequestBody;
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
  // Checked before decoding: a 4/3-larger base64 string would otherwise be
  // fully materialized in memory before being rejected.
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

  const started = Date.now();
  try {
    const page = await deps.recognizer.recognize(image, {
      imagePath: jobId,
      mimeType,
    });

    // Metrics only. No text, no bytes, no line contents (§7.3).
    deps.log?.({
      jobId,
      event: "ocr.ok",
      bytes: image.length,
      lineCount: page.lines.length,
      elapsedMs: Date.now() - started,
    });

    return json({ jobId, page } satisfies OcrSuccess, 200);
  } catch (error) {
    const documentAIError = error instanceof DocumentAIError ? error : null;

    // Decided once and used for both the log and the reply. Computing it
    // twice is how the log ended up saying `retryable: false` while the phone
    // was told `true` — a log that contradicts the client is worse than no
    // log, because it is trusted during debugging.
    const retryable = documentAIError ? documentAIError.transient : true;
    const status = documentAIError ? (retryable ? 503 : 502) : 500;

    deps.log?.({
      jobId,
      event: "ocr.fail",
      bytes: image.length,
      status: documentAIError?.status,
      retryable,
      elapsedMs: Date.now() - started,
    });

    // A `DocumentAIError` message is written by us and describes the call, so
    // it is safe to pass on and is what makes a misconfiguration diagnosable.
    // Anything else could carry content in its message, so only the shape is
    // reported (§7.3).
    //
    // The status is 502/503 rather than the provider's own: the phone must not
    // read a Google 403 as "your device token is wrong".
    return fail(
      documentAIError ? documentAIError.message : "OCR sırasında beklenmeyen hata.",
      status,
      retryable,
    );
  }
  // `image` goes out of scope here and is never written anywhere (§7.3).
}
