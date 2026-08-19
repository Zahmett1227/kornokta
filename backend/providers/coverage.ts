/**
 * Coverage accounting (schema v2.3 — docs/PLAN-kapsama-sozlesmesi.md, Katman A).
 *
 * The one failure this project could never see: a mark the student made that
 * never became a card. A wrong card is visible — it carries `lowConfidence`, it
 * has a "Gözden geçir" bucket and a second-opinion button, and reading it once
 * is enough to notice. A missing card has none of that. It has no flag because
 * it has no card, and the page photo that could prove it is deleted from the
 * server after 60 days.
 *
 * Three prompt versions tried to fix this by asking (v2.6's counting step,
 * v2.7's three rounds of binding language) and none of them could be *measured*,
 * because nothing produced a number. This module is the measurement. The model
 * now writes down what it saw (`marks`) and which mark each card came from
 * (`markId`); the difference between those two lists is computed here, in plain
 * deterministic code, and no longer depends on the prompt's good intentions.
 * Judgement stays with the model, bookkeeping moves to the code (§0.8's spirit).
 *
 * Two lists come out, and both were invisible before:
 *   - `uncovered` — marks with no surviving card. The signal.
 *   - `unmarkedCardIds` — cards bound to no mark at all, which is prompt rule
 *     1's own violation ("işaretlenmemiş metin kart kaynağı değildir").
 *
 * Nothing here fails a job. A model that ignores the new fields produces
 * `reported: false` and the page behaves exactly as it did before v2.3 —
 * the same rule `sanitizeTopics` follows, for the same reason: a classification
 * nicety must never cost a paid capture.
 */

import { MARK_KINDS, type Card, type LlmOutput, type Mark, type MarkKind } from "../schemas/llmOutputTypes.js";

/**
 * How valuable a skipped mark is, low number first.
 *
 * Straight from prompt rule 3's ladder — handwriting, then the symbol tier,
 * then underline, then highlighter — so "en değerli atlanan işaret" is the
 * first row the owner sees rather than whatever happened to be topmost on the
 * page. `MARK_KINDS`'s own order is the single source of that ranking; an
 * unknown kind sorts last instead of throwing.
 */
export function markPriority(kind: string): number {
  const index = (MARK_KINDS as readonly string[]).indexOf(kind);
  return index < 0 ? MARK_KINDS.length : index;
}

export interface CoverageReport {
  /**
   * Whether the model reported a register at all.
   *
   * `false` means "no information", which is emphatically not the same as
   * "nothing uncovered": an older deployment, a model that ignored the field,
   * or a v2.2 payload all land here, and an empty `uncovered` list would
   * otherwise read as a clean bill of health.
   */
  reported: boolean;
  /** Every mark the model reported, sanitized and deduplicated. */
  marks: Mark[];
  /** Marks no surviving card claims, most valuable tier first. */
  uncovered: Mark[];
  /**
   * Ids of surviving cards bound to no mark. Ids only — card text is never
   * copied into a report that ends up in a log line (§7.3).
   */
  unmarkedCardIds: string[];
}

/** A mark with a usable id, a known tier and a non-empty quote, or `null`. */
function cleanMark(value: unknown): Mark | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as { id?: unknown; kind?: unknown; quote?: unknown };
  if (typeof record.id !== "string" || !record.id.trim()) return null;
  if (typeof record.quote !== "string" || !record.quote.trim()) return null;
  if (typeof record.kind !== "string" || !(MARK_KINDS as readonly string[]).includes(record.kind)) {
    return null;
  }
  return { id: record.id.trim(), kind: record.kind as MarkKind, quote: record.quote.trim() };
}

/**
 * Forces the v2.3 fields into a shape the rest of the server can trust, in
 * place, before validation — exactly where `sanitizeTopics` sits and for the
 * same reason.
 *
 * Drops malformed or duplicate-id marks and nulls any `markId` that does not
 * point at a surviving mark. A dangling reference is the one thing that would
 * make the whole layer lie: the card looks bound, so its mark is counted as
 * covered, so a skipped mark is reported as handled. Silent narrowing of the
 * signal is worse than the missing field, so it is resolved to `null` — which
 * shows up honestly as an unmarked card.
 */
export function sanitizeMarks(output: Record<string, unknown>): void {
  const rawMarks = output.marks;
  if (rawMarks !== undefined && !Array.isArray(rawMarks)) {
    // Not an array at all: the field is unusable, and leaving it would fail
    // schema validation for the whole page over an audit extra.
    delete output.marks;
  }

  let ids: Set<string> | null = null;
  if (Array.isArray(output.marks)) {
    const seen = new Set<string>();
    const marks: Mark[] = [];
    for (const candidate of output.marks) {
      const mark = cleanMark(candidate);
      if (!mark || seen.has(mark.id)) continue;
      seen.add(mark.id);
      marks.push(mark);
    }
    output.marks = marks;
    ids = seen;
  }

  if (!Array.isArray(output.cards)) return;
  for (const candidate of output.cards) {
    if (typeof candidate !== "object" || candidate === null || Array.isArray(candidate)) continue;
    const card = candidate as { markId?: unknown };
    if (card.markId === undefined || card.markId === null) continue;
    if (typeof card.markId !== "string" || !ids || !ids.has(card.markId.trim())) {
      card.markId = null;
      continue;
    }
    card.markId = card.markId.trim();
  }
}

export interface CoverageOptions {
  /**
   * Cards the gate rejected (the surplus over the per-page cap, a broken
   * card). They never reach the deck, so a mark they were the only claimant of
   * is *not* covered — counting them would hide precisely the case the card
   * ceiling creates, which is the one Tur A found on 18 of 18 pages.
   */
  rejectedCardIds?: readonly string[];
}

/**
 * Compares the model's mark register against the cards that will actually be
 * stored.
 *
 * Takes the two fields it needs rather than the whole output, so a caller
 * cannot accidentally make this depend on `usage` or `readText` and a test can
 * build the input by hand.
 */
export function deriveCoverage(
  output: Pick<LlmOutput, "cards"> & { marks?: readonly Mark[] },
  options: CoverageOptions = {},
): CoverageReport {
  const marks = [...(output.marks ?? [])];
  const rejected = new Set(options.rejectedCardIds ?? []);
  const surviving: Card[] = output.cards.filter((card) => !rejected.has(card.id));

  const claimed = new Set<string>();
  const unmarkedCardIds: string[] = [];
  for (const card of surviving) {
    const markId = typeof card.markId === "string" ? card.markId.trim() : "";
    if (markId) {
      claimed.add(markId);
    } else {
      unmarkedCardIds.push(card.id);
    }
  }

  const uncovered = marks
    .filter((mark) => !claimed.has(mark.id))
    // `map`+`sort`+`map` rather than a bare `sort`: `Array.prototype.sort` is
    // only guaranteed stable by index, and two marks of the same tier must keep
    // the order the model listed them in (roughly page order) instead of an
    // arbitrary one.
    .map((mark, index) => ({ mark, index }))
    .sort((a, b) => {
      const priority = markPriority(a.mark.kind) - markPriority(b.mark.kind);
      return priority !== 0 ? priority : a.index - b.index;
    })
    .map((entry) => entry.mark);

  return {
    reported: output.marks !== undefined,
    marks,
    uncovered,
    unmarkedCardIds,
  };
}

/**
 * The same derivation with "which cards survive" answered by the gate.
 *
 * Exists so the two endpoints that produce a result body (`/api/cards-vision`
 * and the `/api/jobs` worker) cannot answer that question differently. They
 * already build `output`/`gate` in lockstep; a second copy of "reject means it
 * does not count as coverage" is precisely the drift this repo keeps a
 * discipline against.
 */
export function coverageFromGate(
  output: Pick<LlmOutput, "cards"> & { marks?: readonly Mark[] },
  gate: { verdicts: ReadonlyArray<{ cardId: string; decision: string }> },
): CoverageReport {
  return deriveCoverage(output, {
    rejectedCardIds: gate.verdicts
      .filter((verdict) => verdict.decision === "reject")
      .map((verdict) => verdict.cardId),
  });
}
