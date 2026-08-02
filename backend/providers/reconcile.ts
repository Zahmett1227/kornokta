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
    // look at, not at the page.
    const flags = second === null || agrees ? [] : runGate(second.text, first.text).mismatches;
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
  const gate = secondary ? runGate(secondaryText, primaryText) : runGate(primaryText, primaryText);

  const criticalLineIds = lines
    .filter((line) => line.criticalTokenFlags.length > 0)
    .map((line) => line.lineId);

  const decision = decide({
    lines,
    gate,
    hasSecondOpinion: secondary !== null,
    minConfidence,
    handwritten,
  });

  return { ...decision, text: primaryText, lines, criticalLineIds, gate };
}

function decide(input: {
  lines: LineReconciliation[];
  gate: GateResult;
  hasSecondOpinion: boolean;
  minConfidence: number;
  handwritten: Set<string>;
}): { decision: Decision; reason: string } {
  const { lines, gate, hasSecondOpinion, minConfidence, handwritten } = input;

  // §19.3: nothing legible means there is nothing to make a card from.
  if (lines.length === 0) {
    return { decision: "reject", reason: "Sayfada okunabilir satır yok." };
  }
  if (lines.every((line) => !line.primaryText.trim())) {
    return { decision: "reject", reason: "Tanınan satırların hepsi boş." };
  }

  // §10.5.1 and §19.2: a critical-token disagreement is never recorded
  // silently. Checked before confidence, because a high-confidence reading of
  // the wrong route is exactly the case this rule exists for.
  const critical = lines.filter((line) => line.criticalTokenFlags.length > 0);
  if (critical.length > 0) {
    return {
      decision: "quick_confirm",
      reason:
        `${critical.length} satırda kritik değer uyuşmazlığı: ` +
        critical[0]!.criticalTokenFlags[0],
    };
  }
  if (!gate.passes) {
    return {
      decision: "quick_confirm",
      reason: gate.mismatches[0] ?? "Sayfa genelinde kritik değer uyuşmazlığı.",
    };
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
    // Non-critical wording differences: the primary reading is kept and the
    // difference is recorded, not surfaced. §24.2 wants few interruptions,
    // and these do not change meaning.
    return {
      decision: "auto_accept",
      reason: `${disagreeing.length} satırda kritik olmayan fark var; birincil okuma alındı.`,
    };
  }

  return { decision: "auto_accept", reason: "İki motor da aynı metni okudu." };
}
