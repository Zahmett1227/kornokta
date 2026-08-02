/**
 * Deterministic critical-token detector (ANA-PLAN §10.5, §23.4).
 *
 * Flags spans whose OCR disagreement must never be auto-accepted: numbers,
 * units, doses, routes, negations, laterality, ion charges, and so on. It
 * over-flags rather than under-flags by design — a false positive costs one
 * confirmation tap, a false negative can store a wrong dose.
 *
 * **The patterns are not written here.** They are generated from
 * `evals/ocr_eval/critical_tokens.py`, which stays the single definition, into
 * `criticalTokenPatterns.json`. Regenerate with
 * `python -m evals.ocr_eval.export_patterns`; a CI check fails if the file
 * drifts from its source. Behaviour is pinned on both sides by the shared
 * cases in `evals/shared/critical-token-cases.json`.
 */

import { createRequire } from "node:module";

import { foldDiacritics, nfc } from "./turkish.js";

// JSON import assertions are still unstable across runtimes; `createRequire`
// works the same under tsx, vitest and a bundled deployment.
const require = createRequire(import.meta.url);
const patternData = require("./criticalTokenPatterns.json") as PatternFile;

interface PatternFile {
  tokenClasses: string[];
  units: string[];
  routeSynonyms: Record<string, string[]>;
  patterns: Array<{ tokenClass: string; source: string; flags: string }>;
}

export const TOKEN_CLASSES: readonly string[] = Object.freeze([...patternData.tokenClasses]);
export const ROUTE_SYNONYMS: Readonly<Record<string, readonly string[]>> = patternData.routeSynonyms;

export interface CriticalToken {
  text: string;
  tokenClass: string;
  start: number;
  end: number;
}

/**
 * Compiled with the global flag so `matchAll` can walk every occurrence.
 * `lastIndex` is stateful on a global regex, so a fresh one is built per pass
 * rather than shared — reusing a global regex across calls is a classic source
 * of matches being skipped.
 */
function compile(source: string, flags: string): RegExp {
  return new RegExp(source, flags.includes("g") ? flags : `${flags}g`);
}

const PATTERNS = patternData.patterns.map((entry) => ({
  tokenClass: entry.tokenClass,
  source: entry.source,
  flags: entry.flags,
}));

/**
 * The same patterns with their Turkish letters folded to ASCII.
 *
 * Derived rather than written out again, so a pattern added upstream is
 * covered automatically instead of silently escaping the second pass.
 */
const FOLDED_PATTERNS = PATTERNS.map((entry) => ({
  tokenClass: entry.tokenClass,
  source: foldDiacritics(entry.source),
  flags: entry.flags,
}));

/** surface (folded, lowercased, single-spaced) -> canonical route code */
const ROUTE_LOOKUP = new Map<string, string>();
for (const [code, surfaces] of Object.entries(patternData.routeSynonyms)) {
  for (const surface of surfaces) {
    ROUTE_LOOKUP.set(routeKey(surface), code);
  }
}

function routeKey(surface: string): string {
  // `toLowerCase`, not the Turkish-aware variant: this mirrors Python's
  // `str.casefold()`, which is what builds the lookup on the reference side.
  // Turkish lowercasing here would map 'IV' to 'ıv' and stop it matching.
  return nfc(surface).toLowerCase().replace(/\s+/gu, " ").trim();
}

/**
 * Maps any accepted spelling of a route to its canonical code.
 *
 * Unknown text folds to its own uppercase form, so an unrecognised value is
 * never silently merged with a known route.
 */
export function canonicalRoute(surface: string): string {
  const key = routeKey(surface);
  return ROUTE_LOOKUP.get(key) ?? key.toUpperCase();
}

export function isRouteSurface(text: string): boolean {
  return ROUTE_LOOKUP.has(routeKey(text));
}

/**
 * Returns every critical span in `text`, sorted by position.
 *
 * Overlapping spans are kept — `0,5 mg/kg` yields dose_frequency,
 * number_decimal and unit hits — because each class carries its own
 * confirmation rule downstream.
 *
 * Two passes: the patterns as written over the text as written, then the
 * diacritic-folded patterns over the diacritic-folded text. Folding only the
 * text would not help, because the *patterns* are what carry the diacritics.
 * Folding is one character to one, so the offsets still address the original
 * string, and each reported surface is sliced from it — the detector reports
 * what was written and never rewrites it (§0.5).
 */
export function detectCriticalTokens(rawText: string): CriticalToken[] {
  const text = nfc(rawText);
  const passes: Array<[string, typeof PATTERNS]> = [
    [text, PATTERNS],
    [foldDiacritics(text), FOLDED_PATTERNS],
  ];

  // Keyed by start:end:class so the two passes cannot report the same span
  // twice, matching the reference implementation's de-duplication.
  const found = new Map<string, CriticalToken>();

  for (const [haystack, patterns] of passes) {
    for (const entry of patterns) {
      const regex = compile(entry.source, entry.flags);
      for (const match of haystack.matchAll(regex)) {
        const start = match.index ?? 0;
        const end = start + match[0].length;
        if (!match[0].trim()) continue;
        found.set(`${start}:${end}:${entry.tokenClass}`, {
          text: text.slice(start, end),
          tokenClass: entry.tokenClass,
          start,
          end,
        });
      }
    }
  }

  return [...found.values()].sort(
    (a, b) =>
      a.start - b.start ||
      a.end - b.end ||
      (a.tokenClass < b.tokenClass ? -1 : a.tokenClass > b.tokenClass ? 1 : 0),
  );
}

export function containsCriticalToken(text: string): boolean {
  return detectCriticalTokens(text).length > 0;
}
