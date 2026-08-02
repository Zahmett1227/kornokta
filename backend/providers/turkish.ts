/**
 * Turkish-aware text handling, mirroring `evals/ocr_eval/normalize.py`.
 *
 * Small enough to keep as a hand-written port rather than generating it; the
 * shared behaviour cases in `evals/shared/critical-token-cases.json` are what
 * hold the two implementations together.
 */

/**
 * Length-preserving lowercase using Turkish rules.
 *
 * `String.prototype.toLowerCase()` applies English rules: `I` becomes `i`
 * (Turkish wants dotless `ı`) and `İ` becomes `i` plus a combining dot — two
 * code points where there was one. Spans are reported back to the caller as
 * offsets, so a length change here would shift every following span.
 */
export function turkishLower(text: string): string {
  let out = "";
  for (const character of text) {
    let lowered: string;
    if (character === "I") lowered = "ı";
    else if (character === "İ") lowered = "i";
    else lowered = character.toLowerCase();
    // Any other character whose lowercase expands keeps its original form
    // rather than corrupting the offsets.
    out += lowered.length === character.length ? lowered : character;
  }
  return out;
}

/** Turkish-only letters and their ASCII twins. Strictly one character to one. */
const DIACRITIC_MAP: Record<string, string> = {
  "ı": "i", "İ": "I",
  "ş": "s", "Ş": "S",
  "ğ": "g", "Ğ": "G",
  "ç": "c", "Ç": "C",
  "ö": "o", "Ö": "O",
  "ü": "u", "Ü": "U",
};

/**
 * Maps Turkish diacritics onto ASCII, preserving length.
 *
 * For matching and comparison only, never to produce text a human reads or
 * that gets stored (§0.5). Exists because an OCR engine may be unable to emit
 * these letters at all — Apple Vision produced `ı ş ğ İ` zero times across 148
 * lines of Turkish medical text (docs/FAZ0-BULGULAR.md), so `görülmemiştir`
 * arrives as `gorulmemistir` and `sağ` as `sag`. Without folding, negation and
 * laterality stop being detected on that output.
 */
export function foldDiacritics(text: string): string {
  let out = "";
  for (const character of text) {
    out += DIACRITIC_MAP[character] ?? character;
  }
  return out;
}

/** Canonical Unicode composition, so `i` + combining dot equals `i̇`. */
export function nfc(text: string): string {
  return text.normalize("NFC");
}

export function collapseWhitespace(text: string): string {
  return text.replace(/\s+/gu, " ").trim();
}

/**
 * Normalization applied before comparing two OCR hypotheses.
 *
 * Deliberately conservative: casing, Unicode form and whitespace only. Decimal
 * separators, dashes, symbols and units are left untouched because differences
 * there are medically meaningful (§10.5).
 */
export function normalizeForCompare(text: string): string {
  return collapseWhitespace(turkishLower(nfc(text)));
}
