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
  OCRColor,
  OCRLayoutRegion,
  OCRLine,
  OCRPage,
  OCRToken,
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

interface RawColor {
  red?: number;
  green?: number;
  blue?: number;
  alpha?: number;
}

interface RawStyleInfo {
  handwritten?: boolean;
  underlined?: boolean;
  backgroundColor?: RawColor;
}

interface RawBlock {
  layout?: RawLayout;
}

interface RawToken extends RawBlock {
  styleInfo?: RawStyleInfo;
}

interface RawPage {
  dimension?: { width?: number; height?: number };
  lines?: RawBlock[];
  paragraphs?: RawBlock[];
  blocks?: RawBlock[];
  tokens?: RawToken[];
  tables?: RawBlock[];
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
            "Yerelde GOOGLE_APPLICATION_CREDENTIALS doğru dosyayı gösteriyor mu, " +
            "sunucuda GOOGLE_CREDENTIALS_JSON tanımlı mı?",
          undefined,
          false,
        );
      }
      if (!token) {
        throw new DocumentAIError(
          "Google erişim jetonu alınamadı. Kimlik bilgisi doğru mu " +
            "(GOOGLE_APPLICATION_CREDENTIALS ya da GOOGLE_CREDENTIALS_JSON)?",
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

/** Geometry-only correspondence between a line and a Document AI token. */
function overlapOfSmallerArea(a: Positioned, b: Positioned): number {
  const left = Math.max(a.x, b.x);
  const top = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.width, b.x + b.width);
  const bottom = Math.min(a.y + a.height, b.y + b.height);
  const intersection = Math.max(0, right - left) * Math.max(0, bottom - top);
  const smaller = Math.min(a.width * a.height, b.width * b.height);
  return smaller > 0 ? intersection / smaller : 0;
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

function colorOf(color: RawColor | undefined): OCRColor | undefined {
  if (!color) return undefined;
  const red = color.red ?? 0;
  const green = color.green ?? 0;
  const blue = color.blue ?? 0;
  const alpha = color.alpha ?? 1;
  return [red, green, blue, alpha].every(Number.isFinite)
    ? { red, green, blue, alpha }
    : undefined;
}

function layoutRegions(
  fullText: string,
  blocks: RawBlock[] | undefined,
  kind: OCRLayoutRegion["kind"],
): OCRLayoutRegion[] {
  return (blocks ?? []).map((block, index) => ({
    id: `${kind}_${String(index).padStart(2, "0")}`,
    kind,
    text: textForLayout(fullText, block.layout),
    confidence: block.layout?.confidence ?? 0,
    ...boundsOf(block.layout),
  }));
}

/** Height of one reading-order band, as a fraction of the page. */
export const READING_BAND = 0.01;

/** A positioned item this module can put in reading order. */
export interface Positioned {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Buckets used to scan for column gutters in `columnBoundaries`. */
const COLUMN_BUCKETS = 100;
/** A gutter narrower than this fraction of the page width is ordinary word
 * spacing, not a column break. */
const MIN_GUTTER_WIDTH = 0.02;
/** A gutter this close to either edge is a margin, not a break between
 * columns of text. */
const COLUMN_EDGE_MARGIN = 0.08;
/** Every column a detected gutter implies must end up with at least this many
 * lines, or the "gutter" was probably one short/indented line, not a layout. */
const MIN_LINES_PER_COLUMN = 2;
/** Two candidate columns must have at least this fraction of each side's
 * lines vertically near a line on the other side, or they are not side by
 * side — they are two horizontally-separated but vertically-stacked regions
 * (e.g. a right-aligned header above unrelated left-aligned body text), and
 * reading them column by column would reorder the page instead of fixing it. */
const MIN_VERTICAL_OVERLAP = 0.5;
/** How far apart two lines' vertical extents may be and still count as "the
 * same row" for `overlapsVertically` — roughly one line height, so two
 * independently-typeset columns with staggered baselines (never pixel-aligned
 * between columns in practice) still read as coexisting, while regions that
 * are genuinely stacked with a real gap between them do not. */
const MAX_BASELINE_STAGGER = 0.03;
/** An item wider than this fraction of the page cannot fit inside a single
 * column next to another — it is a page-spanning element (a header, footer,
 * or page number), not evidence of a column's own text. Excluded from the gap
 * scan below so any number of them, however many, never hide a real gutter. */
const MAX_COLUMN_ITEM_WIDTH = 0.5;

/** True if `item`'s span crosses one of `boundaries` rather than sitting
 * entirely inside one column — a header or footer spanning the gutter. */
function spansAGutter(item: Positioned, boundaries: number[]): boolean {
  return boundaries.some((b) => item.x < b && item.x + item.width > b);
}

function columnOf(item: Positioned, boundaries: number[]): number {
  const center = item.x + item.width / 2;
  return boundaries.filter((b) => b < center).length;
}

/** Whether `a` and `b` sit close enough vertically to count as the same row,
 * within `MAX_BASELINE_STAGGER` of slack in either direction. */
function coexist(a: Positioned, b: Positioned): boolean {
  return a.y - MAX_BASELINE_STAGGER < b.y + b.height && b.y - MAX_BASELINE_STAGGER < a.y + a.height;
}

/** Whether two non-empty groups of items coexist over a meaningful shared
 * vertical range, rather than one sitting entirely above the other. Measured
 * per line — does *this* line have a neighbor on the other side nearby? —
 * rather than by each group's overall envelope or occupied-band set, which
 * would call two groups "overlapping" whenever one's total span happens to
 * enclose the other's, even with a real gap between them and no line ever
 * actually beside another; or would reject two ordinary columns whenever
 * their (never pixel-aligned) baselines happen to land in different bands.
 *
 * Checked against the *shorter* side only: genuine comparison columns are
 * routinely unequal length (six Nekroz bullets beside two Apoptoz ones), and
 * the longer column's lines past where the shorter one ends are not evidence
 * against coexistence — they are simply where it keeps going alone. */
function overlapsVertically(a: Positioned[], b: Positioned[]): boolean {
  const [shorter, longer] = a.length <= b.length ? [a, b] : [b, a];
  const matched = shorter.filter((item) => longer.some((other) => coexist(item, other))).length;
  return matched / shorter.length >= MIN_VERTICAL_OVERLAP;
}

/**
 * Finds x-positions of vertical whitespace gutters wide and central enough to
 * be column breaks — e.g. a Nekroz/Apoptoz comparison list — rather than
 * ordinary margins, so `orderByReadingPosition` can read column by column
 * instead of interleaving both columns' text row by row.
 *
 * Page-spanning elements (a header, footer, page number — anything wider than
 * `MAX_COLUMN_ITEM_WIDTH`) are excluded up front rather than merely tolerated:
 * a page can have any number of them (a title *and* a footer) without hiding
 * the real gutter between them.
 */
export function columnBoundaries(items: Positioned[]): number[] {
  if (items.length < 2 * MIN_LINES_PER_COLUMN) return [];

  const columnScoped = items.filter((item) => item.width <= MAX_COLUMN_ITEM_WIDTH);

  const coverage = new Array<number>(COLUMN_BUCKETS).fill(0);
  for (const item of columnScoped) {
    const start = Math.max(0, Math.floor(item.x * COLUMN_BUCKETS));
    const end = Math.min(COLUMN_BUCKETS, Math.ceil((item.x + item.width) * COLUMN_BUCKETS));
    for (let bucket = start; bucket < end; bucket++) coverage[bucket]!++;
  }

  const boundaries: number[] = [];
  let index = 0;
  while (index < COLUMN_BUCKETS) {
    if (coverage[index]! > 0) {
      index++;
      continue;
    }
    const start = index;
    while (index < COLUMN_BUCKETS && coverage[index]! === 0) index++;
    // A run reaching all the way to either edge is the page's own outer
    // margin, however wide — not a gap *between* two columns of text, which
    // has content on both sides by definition. The center check alone can
    // miss this: a wide trailing margin (e.g. a short right column ending at
    // x=0.84) can have its center fall outside `COLUMN_EDGE_MARGIN` even
    // though it never separates two things.
    const touchesEdge = start === 0 || index === COLUMN_BUCKETS;
    const width = (index - start) / COLUMN_BUCKETS;
    const center = (start + index) / 2 / COLUMN_BUCKETS;
    if (
      !touchesEdge &&
      width >= MIN_GUTTER_WIDTH &&
      center >= COLUMN_EDGE_MARGIN &&
      center <= 1 - COLUMN_EDGE_MARGIN
    ) {
      boundaries.push(center);
    }
  }

  if (!boundaries.length) return [];

  const perColumn: Positioned[][] = Array.from({ length: boundaries.length + 1 }, () => []);
  for (const item of items) {
    if (!spansAGutter(item, boundaries)) perColumn[columnOf(item, boundaries)]!.push(item);
  }
  if (perColumn.some((column) => column.length < MIN_LINES_PER_COLUMN)) return [];
  for (let i = 0; i < perColumn.length - 1; i++) {
    if (!overlapsVertically(perColumn[i]!, perColumn[i + 1]!)) return [];
  }

  return boundaries;
}

/**
 * Reading order: top to bottom in bands, left to right within a band — except
 * a page split into columns (detected via `columnBoundaries`) reads column by
 * column, each column top to bottom, rather than interleaving both columns'
 * lines row by row. Row-by-row reading of a comparison table merges two
 * unrelated sentences into one garbled line.
 *
 * Banding rather than a float tolerance, because a tolerance comparison is
 * not a strict weak ordering and produces an arbitrary permutation on a dense
 * page.
 *
 * A line spanning the gutter (a header or footer) is not assigned to either
 * column: it is placed in the overall top-to-bottom sequence, flushing
 * whatever each column has accumulated so far (in column order) immediately
 * before it. That puts a header before both columns, a footer after both, and
 * a mid-page divider between whatever came above it and below it — instead of
 * always sorting into one column by its center, which could otherwise strand
 * a footer between the columns it actually follows.
 */
export function orderByReadingPosition<T extends Positioned>(items: T[]): T[] {
  const withinColumn = (a: Positioned, b: Positioned): number => {
    const bandA = Math.round(a.y / READING_BAND);
    const bandB = Math.round(b.y / READING_BAND);
    if (bandA !== bandB) return bandA - bandB;
    return a.x - b.x;
  };

  const ordered = [...items].sort(withinColumn);
  const boundaries = columnBoundaries(items);
  if (!boundaries.length) return ordered;

  const buffers: T[][] = Array.from({ length: boundaries.length + 1 }, () => []);
  const result: T[] = [];
  for (const item of ordered) {
    if (spansAGutter(item, boundaries)) {
      for (const buffer of buffers) result.push(...buffer);
      buffers.forEach((buffer) => (buffer.length = 0));
      result.push(item);
    } else {
      buffers[columnOf(item, boundaries)]!.push(item);
    }
  }
  for (const buffer of buffers) result.push(...buffer);
  return result;
}

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
    const ocrConfig = {
      hints: { languageHints: this.config.languageHints },
      ...(this.config.computeStyleInfo
        ? { premiumFeatures: { computeStyleInfo: true } }
        : {}),
    };
    const body = {
      rawDocument: {
        content: Buffer.from(image).toString("base64"),
        mimeType: options.mimeType,
      },
      processOptions: {
        ocrConfig,
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

    const tokens: OCRToken[] = (page.tokens ?? [])
      .map((token, index) => ({
        tokenId: `token_${String(index).padStart(3, "0")}`,
        text: textForLayout(fullText, token.layout),
        confidence: token.layout?.confidence ?? 0,
        ...boundsOf(token.layout),
        isHandwritten: token.styleInfo?.handwritten === true,
        isUnderlined: token.styleInfo?.underlined === true,
        ...(colorOf(token.styleInfo?.backgroundColor)
          ? { backgroundColor: colorOf(token.styleInfo?.backgroundColor) }
          : {}),
      }))
      .filter((token) => token.text.trim().length > 0);

    const unordered = blocksOf(page)
      .map((block) => {
        const text = textForLayout(fullText, block.layout);
        return {
          text,
          confidence: block.layout?.confidence ?? 0,
          ...boundsOf(block.layout),
        };
      })
      .filter((line) => line.text.trim().length > 0);

    // Same reading order as the Vision path (§10.1): column by column when
    // the page splits into columns, top-to-bottom-then-left-to-right
    // otherwise — see `orderByReadingPosition`.
    const lines: OCRLine[] = orderByReadingPosition(unordered).map((line, index) => {
      const lineId = `line_${String(index).padStart(2, "0")}`;
      const lineBox = { x: line.x, y: line.y, width: line.width, height: line.height };
      return {
        lineId,
        ...line,
        tokenIds: tokens
          .filter((token) => overlapOfSmallerArea(lineBox, token) >= 0.3)
          .map((token) => token.tokenId),
      };
    });

    return {
      imagePath: options.imagePath,
      imageWidth: Math.round(page.dimension?.width ?? 0),
      imageHeight: Math.round(page.dimension?.height ?? 0),
      recognitionLanguages: this.config.languageHints,
      usesLanguageCorrection: false,
      engineVersion: this.name,
      elapsedMs,
      lines,
      tokens,
      paragraphs: layoutRegions(fullText, page.paragraphs, "paragraph"),
      blocks: layoutRegions(fullText, page.blocks, "block"),
      tables: layoutRegions(fullText, page.tables, "table_candidate"),
    };
  }
}
