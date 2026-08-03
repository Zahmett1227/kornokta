/**
 * The OCR result shape shared by every engine.
 *
 * Deliberately identical to what `ios/spikes/AppleVisionSpike` writes, so the
 * existing Python scorer (`python -m evals.ocr_eval.vision_report`) can score
 * Google output with no changes and the two engines can be compared on the
 * same gold set (ANA-PLAN §23.2, §27).
 *
 * Coordinates are normalized to the page (0–1) with a **top-left** origin.
 */

export interface OCRLine {
  /** Stable within a page: `line_00`, `line_01`, ... in reading order. */
  lineId: string;
  text: string;
  /** 0–1. Engines quantize this differently; treat it as a rough signal. */
  confidence: number;
  x: number;
  y: number;
  width: number;
  height: number;
  /** Token ids which geometrically belong to this line, when available. */
  tokenIds?: string[];
}

export interface OCRColor {
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

/** Word-level primary OCR geometry and style information. */
export interface OCRToken {
  tokenId: string;
  text: string;
  confidence: number;
  x: number;
  y: number;
  width: number;
  height: number;
  isHandwritten: boolean;
  isUnderlined: boolean;
  backgroundColor?: OCRColor;
}

/** Kept distinct from text lines so tables remain source regions, not prose. */
export interface OCRLayoutRegion {
  id: string;
  kind: "paragraph" | "block" | "table_candidate";
  text: string;
  confidence: number;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface OCRPage {
  imagePath: string;
  imageWidth: number;
  imageHeight: number;
  recognitionLanguages: string[];
  /**
   * Always false for this provider. ANA-PLAN §0.5 forbids silently rewriting
   * text towards ordinary vocabulary; the field is carried so a report says so
   * out loud rather than leaving it to be assumed.
   */
  usesLanguageCorrection: boolean;
  /** Engine build identifier, for reproducing a measurement later. */
  engineVersion: string;
  elapsedMs: number;
  lines: OCRLine[];
  tokens?: OCRToken[];
  paragraphs?: OCRLayoutRegion[];
  blocks?: OCRLayoutRegion[];
  tables?: OCRLayoutRegion[];
}

export interface OCRRun {
  generatedBy: string;
  requestedLanguages: string[];
  /**
   * Languages requested but unavailable. Apple Vision silently drops these,
   * which is how the Turkish problem stayed invisible; the field exists so any
   * engine has to state it (docs/FAZ0-BULGULAR.md).
   */
  unsupportedLanguages: string[];
  pages: OCRPage[];
}

/** What every OCR engine must provide, so callers can swap one for another. */
export interface TextRecognizer {
  readonly name: string;
  recognize(image: Uint8Array, options: RecognizeOptions): Promise<OCRPage>;
}

export interface RecognizeOptions {
  /** Recorded in the result so a page can be matched back to its source. */
  imagePath: string;
  mimeType: string;
}
