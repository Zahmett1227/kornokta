/**
 * Google Document AI OCR provider (ANA-PLAN §10.2).
 *
 * This is the **primary** source of Turkish text. Apple Vision cannot produce
 * `ı ş ğ İ` at all — it does not support Turkish — so it is demoted to live
 * preview and line geometry (docs/ADR-002-birincil-ocr-secimi.md).
 *
 * Privacy (§7.3): this module never logs image bytes or recognized text, and
 * never puts either into an error message. Failures carry the HTTP status and
 * Google's own error string, which describe the *call*, not the content.
 */

import type { GoogleAuth } from "google-auth-library";
import type { DocumentAIConfig } from "../config.js";
import type {
  OCRLine,
  OCRPage,
  RecognizeOptions,
  TextRecognizer,
} from "./ocrTypes.js";

/** Minimal shape of the pieces of Document AI's response that we read. */
interface RawVertex {
  x?: number;
  y?: number;
}

interface RawLayout {
  textAnchor?: {
    textSegments?: Array<{ startIndex?: string | number; endIndex?: string | number }>;
  };
  confidence?: number;
  boundingPoly?: {
    normalizedVertices?: RawVertex[];
  };
}

interface RawBlock {
  layout?: RawLayout;
}

interface RawPage {
  dimension?: { width?: number; height?: number };
  lines?: RawBlock[];
  paragraphs?: RawBlock[];
  blocks?: RawBlock[];
}

interface RawDocument {
  text?: string;
  pages?: RawPage[];
}

export interface ProcessResponse {
  document?: RawDocument;
}

export class DocumentAIError extends Error {
  constructor(
    message: string,
    readonly status: number | undefined,
    /** Transient failures are worth retrying; permanent ones are not (§17). */
    readonly transient: boolean,
  ) {
    super(message);
    this.name = "DocumentAIError";
  }
}

/**
 * The HTTP call, isolated so tests can drive the provider without a network or
 * a credential.
 */
export interface Transport {
  post(url: string, token: string, body: unknown, timeoutMs: number): Promise<{
    status: number;
    body: unknown;
  }>;
}

export const fetchTransport: Transport = {
  async post(url, token, body, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
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

/** Supplies an OAuth access token. Kept behind an interface so no test needs a key. */
export interface TokenSource {
  getToken(): Promise<string>;
}

export function googleAuthTokenSource(auth: GoogleAuth): TokenSource {
  return {
    async getToken() {
      let token: string | null | undefined;
      try {
        const client = await auth.getClient();
        const accessToken = await client.getAccessToken();
        token = typeof accessToken === "string" ? accessToken : accessToken?.token;
      } catch (error) {
        // The auth library throws its own error type when it cannot find or
        // read a credential. Left unwrapped it surfaces as "unexpected error,
        // retryable" — but a missing key is a setup problem that no number of
        // retries fixes, and the caller needs to be told which one it is.
        throw new DocumentAIError(
          `Google kimlik doğrulaması başarısız: ${(error as Error).message}. ` +
            "GOOGLE_APPLICATION_CREDENTIALS doğru dosyayı gösteriyor mu?",
          undefined,
          false,
        );
      }
      if (!token) {
        throw new DocumentAIError(
          "Google erişim jetonu alınamadı. GOOGLE_APPLICATION_CREDENTIALS doğru mu?",
          undefined,
          false,
        );
      }
      return token;
    },
  };
}

/**
 * Document AI addresses text by offset into one big `document.text` string
 * rather than repeating it per line, so a line's text has to be sliced out.
 *
 * `startIndex` is **absent** when it is zero — proto3 omits default values in
 * JSON — so a missing field means 0, not "no segment". Treating it as missing
 * would drop the first line of every page.
 */
export function textForLayout(fullText: string, layout: RawLayout | undefined): string {
  const segments = layout?.textAnchor?.textSegments;
  if (!segments?.length) return "";
  let out = "";
  for (const segment of segments) {
    const start = Number(segment.startIndex ?? 0);
    const end = Number(segment.endIndex ?? 0);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue;
    out += fullText.slice(start, end);
  }
  // Document AI ends each line with a newline; it is a separator, not content.
  return out.replace(/\n+$/, "");
}

/**
 * Axis-aligned bounds of a polygon, normalized and top-left origin.
 *
 * Document AI already reports `normalizedVertices` top-left, unlike Vision's
 * bottom-left, so there is no flip here — adding one would silently mirror
 * every box.
 */
export function boundsOf(layout: RawLayout | undefined): Omit<OCRLine, "lineId" | "text" | "confidence"> {
  const vertices = layout?.boundingPoly?.normalizedVertices ?? [];
  const xs = vertices.map((v) => v.x ?? 0);
  const ys = vertices.map((v) => v.y ?? 0);
  if (!xs.length || !ys.length) return { x: 0, y: 0, width: 0, height: 0 };
  const minX = Math.min(...xs);
  const minY = Math.min(...ys);
  return {
    x: minX,
    y: minY,
    width: Math.max(...xs) - minX,
    height: Math.max(...ys) - minY,
  };
}

/**
 * Picks the finest-grained set of blocks the response actually carries.
 *
 * The OCR processor returns `lines`; some processor types return only
 * `paragraphs` or `blocks`. Falling back keeps a switch of processor from
 * silently yielding an empty page.
 */
export function blocksOf(page: RawPage): RawBlock[] {
  if (page.lines?.length) return page.lines;
  if (page.paragraphs?.length) return page.paragraphs;
  return page.blocks ?? [];
}

/** Height of one reading-order band, as a fraction of the page. */
export const READING_BAND = 0.01;

/** Status codes worth another attempt (§17). */
function isTransientStatus(status: number): boolean {
  return status === 408 || status === 429 || status >= 500;
}

export class DocumentAIRecognizer implements TextRecognizer {
  readonly name = "GoogleDocumentAI";

  constructor(
    private readonly config: DocumentAIConfig,
    private readonly tokens: TokenSource,
    private readonly transport: Transport = fetchTransport,
  ) {}

  /**
   * Regional endpoint. A processor created in `eu` is only reachable on the
   * `eu-` host; sending it to the global host fails with a confusing 404 that
   * reads like the processor does not exist.
   */
  get endpoint(): string {
    const { location, projectId, processorId } = this.config;
    return (
      `https://${location}-documentai.googleapis.com` +
      `/v1/projects/${projectId}/locations/${location}` +
      `/processors/${processorId}:process`
    );
  }

  async recognize(image: Uint8Array, options: RecognizeOptions): Promise<OCRPage> {
    const token = await this.tokens.getToken();
    const body = {
      rawDocument: {
        content: Buffer.from(image).toString("base64"),
        mimeType: options.mimeType,
      },
      processOptions: {
        ocrConfig: {
          hints: { languageHints: this.config.languageHints },
        },
      },
    };

    const started = Date.now();
    const response = await this.transport.post(
      this.endpoint,
      token,
      body,
      this.config.timeoutMs,
    );
    const elapsedMs = Date.now() - started;

    if (response.status < 200 || response.status >= 300) {
      const detail =
        (response.body as { error?: { message?: string } } | undefined)?.error?.message ??
        "ayrıntı yok";
      throw new DocumentAIError(
        `Document AI ${response.status}: ${detail}`,
        response.status,
        isTransientStatus(response.status),
      );
    }

    return this.toPage(response.body as ProcessResponse, options, elapsedMs);
  }

  private toPage(
    response: ProcessResponse,
    options: RecognizeOptions,
    elapsedMs: number,
  ): OCRPage {
    const document = response.document ?? {};
    const fullText = document.text ?? "";
    // One image in, one page out. A multi-page PDF would need the caller to
    // decide how to split it, so anything past the first page is not silently
    // merged into this one.
    const page = document.pages?.[0] ?? {};

    const lines: OCRLine[] = blocksOf(page)
      .map((block) => {
        const text = textForLayout(fullText, block.layout);
        return {
          text,
          confidence: block.layout?.confidence ?? 0,
          ...boundsOf(block.layout),
        };
      })
      .filter((line) => line.text.trim().length > 0)
      // Same reading order as the Vision path: top to bottom in bands, then
      // left to right. Banding rather than a float tolerance, because a
      // tolerance comparison is not a strict weak ordering and produces an
      // arbitrary permutation on a dense page.
      .sort((a, b) => {
        const bandA = Math.round(a.y / READING_BAND);
        const bandB = Math.round(b.y / READING_BAND);
        if (bandA !== bandB) return bandA - bandB;
        return a.x - b.x;
      })
      .map((line, index) => ({
        lineId: `line_${String(index).padStart(2, "0")}`,
        ...line,
      }));

    return {
      imagePath: options.imagePath,
      imageWidth: Math.round(page.dimension?.width ?? 0),
      imageHeight: Math.round(page.dimension?.height ?? 0),
      recognitionLanguages: this.config.languageHints,
      usesLanguageCorrection: false,
      engineVersion: this.name,
      elapsedMs,
      lines,
    };
  }
}

