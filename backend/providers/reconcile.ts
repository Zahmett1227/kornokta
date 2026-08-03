/**
 * OCR reconciliation (ANA-PLAN §10.3).
 *
 * Two engines read the same page. Where they agree, confidence rises; where
 * they disagree, the disagreement is reported *at the token level* rather than
 * as "these two lines differ", so the user is asked about the one value that
 * changed instead of the whole passage.
 *
 * The decision this produces is deliberately narrow — accept, ask, or reject.
 * §19.2 lists what must be confirmed and §19.3 what must be rejected outright;
 * nothing here silently corrects anything (§0.5).
 */

import { runGate, type GateResult } from "./gate.js";
import type { OCRLine, OCRPage } from "./ocrTypes.js";
import { normalizeForCompare } from "./turkish.js";

export type Decision = "auto_accept" | "quick_confirm" | "reject";

export interface LineReconciliation {
  lineId: string;
  /** The engine we treat as primary — Google, which can write Turkish. */
  primaryText: string;
  /** The secondary engine's reading of the same line, if it had one. */
  secondaryText: string | null;
  primaryConfidence: number;
  secondaryConfidence: number | null;
  /** True when the two engines produced the same normalized text (§10.3). */
  agrees: boolean;
  /** Empty when the engines agree on every critical value. */
  criticalTokenFlags: string[];
}

export interface Reconciliation {
  decision: Decision;
  /** Why, in one line, for the confirmation screen and the log. */
  reason: string;
  /** The text to carry forward. Always the primary engine's, never a blend. */
  text: string;
  lines: LineReconciliation[];
  /** Lines whose disagreement involves a critical token (§10.5). */
  criticalLineIds: string[];
  gate: GateResult;
}

export interface ReconcileOptions {
  /**
   * Below this, the primary engine's own reading is not trusted enough to
   * auto-accept even when the two agree. Configurable rather than hardcoded
   * (§0.6).
   */
  minPrimaryConfidence?: number;
  /** Treated as handwriting, which never auto-accepts (§10.4). */
  handwrittenLineIds?: readonly string[];
}

const DEFAULT_MIN_PRIMARY_CONFIDENCE = 0.5;

/**
 * Minimum box overlap for two lines to be considered the same line.
 *
 * Intersection over union, so a short line inside a long one does not pair
 * just because it is contained.
 */
export const MIN_LINE_OVERLAP = 0.3;

function overlap(a: OCRLine, b: OCRLine): number {
  const left = Math.max(a.x, b.x);
  const right = Math.min(a.x + a.width, b.x + b.width);
  const top = Math.max(a.y, b.y);
  const bottom = Math.min(a.y + a.height, b.y + b.height);
  if (right <= left || bottom <= top) return 0;

  const intersection = (right - left) * (bottom - top);
  const union = a.width * a.height + b.width * b.height - intersection;
  return union > 0 ? intersection / union : 0;
}

function hasGeometry(lines: readonly OCRLine[]): boolean {
  return lines.some((line) => line.width > 0 && line.height > 0);
}

/**
 * Pairs each primary line with the secondary line covering the same part of
 * the page.
 *
 * **Not by `lineId`.** Each engine numbers its own lines in reading order and
 * they do not find the same number of them — on the Faz 0 test page Google
 * found 156 where Apple Vision found 148, so `line_07` is a different physical
 * line in each. Pairing by id would compare unrelated lines and report
 * critical-token disagreements that do not exist, flooding quick_confirm with
 * noise (§24.2).
 *
 * Falls back to id-matching only when neither side carries geometry, which is
 * the case for a caller that sends text alone.
 */
function pairLines(primary: OCRPage, secondary: OCRPage | null): Array<[OCRLine, OCRLine | null]> {
  const candidates = secondary?.lines ?? [];
  if (candidates.length === 0) return primary.lines.map((line) => [line, null]);

  if (!hasGeometry(primary.lines) || !hasGeometry(candidates)) {
    const byId = new Map<string, OCRLine>();
    for (const line of candidates) byId.set(line.lineId, line);
    return primary.lines.map((line) => [line, byId.get(line.lineId) ?? null]);
  }

  // Greedy best-overlap, each secondary line used at most once so two primary
  // lines cannot both claim the same reading.
  const taken = new Set<string>();
  return primary.lines.map((line): [OCRLine, OCRLine | null] => {
    let best: OCRLine | null = null;
    let bestScore = MIN_LINE_OVERLAP;
    for (const candidate of candidates) {
      if (taken.has(candidate.lineId)) continue;
      const score = overlap(line, candidate);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    if (best) taken.add(best.lineId);
    return [line, best];
  });
}

/**
 * Compares two readings of one page.
 *
 * `secondary` may be null — the on-device engine cannot read Turkish, so there
 * are pages where only the primary result exists. That is not an error, but it
 * does mean there is no second opinion, and the result says so rather than
 * implying agreement.
 */
export function reconcile(
  primary: OCRPage,
  secondary: OCRPage | null,
  options: ReconcileOptions = {},
): Reconciliation {
  const minConfidence = options.minPrimaryConfidence ?? DEFAULT_MIN_PRIMARY_CONFIDENCE;
  const handwritten = new Set(options.handwrittenLineIds ?? []);

  const lines: LineReconciliation[] = pairLines(primary, secondary).map(([first, second]) => {
    const agrees =
      second !== null && normalizeForCompare(first.text) === normalizeForCompare(second.text);
    // The gate runs per line so a flag points at the line the user has to
    // look at, not at the page. `first` (primary/Google) is `gold` here —
    // it is "the engine we treat as primary" per this file's own docstring
    // above — and `second` (secondary/Apple) is `hypothesis`, so a verdict
    // string's "kaynak" names the trustworthy reading and "okuma" names the
    // one that cannot write Turkish, not the other way around. This is
    // informational only now (see `decide`, below): it no longer gates.
    // `foldHypoHyper: true` — this is OCR-vs-OCR reconciliation, where an
    // on-device suffix typo on an otherwise correctly-read word ('hipersen-
    // sitivite' -> 'hipersenstvite') should not read as a critical
    // disagreement. `cardGate.ts` deliberately does NOT set this when
    // checking a card's own content against its source (docs/ADR-003).
    const flags =
      second === null || agrees
        ? []
        : runGate(first.text, second.text, { foldHypoHyper: true }).mismatches;
    return {
      lineId: first.lineId,
      primaryText: first.text,
      secondaryText: second?.text ?? null,
      primaryConfidence: first.confidence,
      secondaryConfidence: second?.confidence ?? null,
      agrees,
      criticalTokenFlags: flags,
    };
  });

  const primaryText = primary.lines.map((line) => line.text).join("\n");
  const secondaryText = secondary?.lines.map((line) => line.text).join("\n") ?? "";
  // Page-level gate, so a value that moved between lines is still counted.
  // `primaryText` (Google) is `gold`, `secondaryText` (Apple) is `hypothesis` —
  // same direction as the per-line gate above, and same caveat: recorded on
  // the result for audit, no longer a `decide` input (§10.2, §10.3).
  const gate = secondary
    ? runGate(primaryText, secondaryText, { foldHypoHyper: true })
    : runGate(primaryText, primaryText, { foldHypoHyper: true });

  const criticalLineIds = lines
    .filter((line) => line.criticalTokenFlags.length > 0)
    .map((line) => line.lineId);

  const decision = decide({
    lines,
    hasSecondOpinion: secondary !== null,
    minConfidence,
    handwritten,
  });

  return { ...decision, text: primaryText, lines, criticalLineIds, gate };
}

/**
 * What gates and what doesn't, now that Google is the only engine that can
 * write Turkish (ADR-002).
 *
 * Apple Vision's disagreement with Google — critical-token or not — used to
 * force `quick_confirm` on its own. That treated a known-broken-for-Turkish
 * reading as a second opinion worth interrupting the user for, which is
 * backwards: Apple cannot corroborate *or* contradict Google in any way that
 * should change what gets recorded. Its disagreement is still detected and
 * carried on the result (`lines[].criticalTokenFlags`, `criticalLineIds`,
 * `gate`) for audit, but it no longer blocks — the safety net for what
 * actually reaches a card is `cardGate` checking each card's own
 * `sourceQuote` (§19), not a fallible second engine here.
 *
 * What still gates, because it is about Google's *own* reading rather than
 * Apple's: an illegible page, handwriting (§10.4 — two engines can be
 * confidently wrong about the same scrawl, but Google is the only one either
 * way), and Google's own low confidence.
 */
function decide(input: {
  lines: LineReconciliation[];
  hasSecondOpinion: boolean;
  minConfidence: number;
  handwritten: Set<string>;
}): { decision: Decision; reason: string } {
  const { lines, hasSecondOpinion, minConfidence, handwritten } = input;

  // §19.3: nothing legible means there is nothing to make a card from.
  if (lines.length === 0) {
    return { decision: "reject", reason: "Sayfada okunabilir satır yok." };
  }
  if (lines.every((line) => !line.primaryText.trim())) {
    return { decision: "reject", reason: "Tanınan satırların hepsi boş." };
  }

  // §10.4: handwriting never auto-accepts, even when both engines agree —
  // two engines can be confidently wrong about the same scrawl.
  const handwrittenLines = lines.filter((line) => handwritten.has(line.lineId));
  if (handwrittenLines.length > 0) {
    return {
      decision: "quick_confirm",
      reason: `${handwrittenLines.length} satır el yazısı; onay gerekiyor.`,
    };
  }

  const lowConfidence = lines.filter(
    (line) => line.primaryText.trim() && line.primaryConfidence < minConfidence,
  );
  if (lowConfidence.length > 0) {
    return {
      decision: "quick_confirm",
      reason: `${lowConfidence.length} satırın tanıma güveni düşük.`,
    };
  }

  if (!hasSecondOpinion) {
    // Not an error, but not agreement either. Saying so keeps a single-engine
    // read from being recorded as if it had been corroborated (§10.3).
    return {
      decision: "auto_accept",
      reason: "Tek motor okudu; ikinci görüş yok.",
    };
  }

  const disagreeing = lines.filter((line) => !line.agrees);
  if (disagreeing.length > 0) {
    // The primary (Google) reading is kept either way — Apple cannot write
    // Turkish, so its disagreement, critical-looking or not, is recorded
    // (`criticalTokenFlags` above) rather than surfaced. §24.2 wants few
    // interruptions; a fallible second engine disagreeing is not new
    // information about whether Google's reading is right.
    return {
      decision: "auto_accept",
      reason: `${disagreeing.length} satırda ikincil (Apple) okumadan fark var; birincil (Google) okuma alındı.`,
    };
  }

  return { decision: "auto_accept", reason: "İki motor da aynı metni okudu." };
}
