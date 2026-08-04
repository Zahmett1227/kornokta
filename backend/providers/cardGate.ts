/**
 * Deterministic post-generation health check for cards, simplified for Faz 6
 * (docs/FAZ6-PLAN.md §5.3).
 *
 * Before the pivot this module ran ANA-PLAN §19's full source-fidelity gate:
 * critical-token reconciliation against each card's cited quote, `enriched`/
 * `explanation` escalations to `quick_confirm`, risk-flag rules. Faz 6 removes
 * all of that from the main flow — the student accepted the error risk (ADR-005)
 * and cards go to the active deck without an approval step. What remains is only
 * the couple of checks that keep a *broken* card out of the deck:
 *
 *   - empty `front`/`back` → `reject` (schema already enforces minLength 1, so
 *     this is defence-in-depth, not the only guard);
 *   - more than `maxCardsPerKnowledgeUnit` cards from one page → the surplus is
 *     rejected (§11.3, §13.2 — still a real limit, still not left to the prompt).
 *
 * Every other healthy card is `auto_accept`. Approval only ever happens later,
 * on the user's own initiative (edit/delete in Bilgilerim).
 *
 * The critical-token *engine* it used to call (`gate.ts` / `criticalTokens.ts`)
 * is not deleted — it still backs `reconcile.ts`, and ADR-005's rollback path
 * (`SAFE_MODE`) can rewire this gate back to it. This file just no longer wires
 * a v2 card (which has no `sourceQuote`) into it.
 */

import type { LlmOutput } from "../schemas/llmOutputTypes.js";

export type CardDecision = "auto_accept" | "quick_confirm" | "reject";

export interface CardVerdict {
  cardId: string;
  decision: CardDecision;
  reasons: string[];
}

export interface CardGateOptions {
  /** §11.3, §13.2, §24.4 — enforced here because asking the prompt nicely is not a limit. */
  maxCardsPerKnowledgeUnit: number;
}

export interface CardGateReport {
  /** One verdict per input card, same order as `output.cards`. */
  verdicts: CardVerdict[];
  /** Card ids rejected solely for exceeding the per-passage limit (§24.4). */
  droppedForLimit: string[];
  /** Page-level concerns not attributable to one specific card. */
  warnings: string[];
}

/** A single card's health verdict: `auto_accept` unless it is structurally broken. */
function verdictForCard(card: Pick<LlmOutput["cards"][number], "id" | "front" | "back">): CardVerdict {
  const reasons: string[] = [];
  let decision: CardDecision = "auto_accept";

  if (!card.front.trim() || !card.back.trim()) {
    decision = "reject";
    reasons.push("Boş front/back: bozuk kart aktif desteye giremez (§5.3).");
  }

  return { cardId: card.id, decision, reasons };
}

/**
 * Runs the simplified Faz 6 gate over a validated LLM output's cards.
 *
 * Takes `Pick<LlmOutput, "cards">` rather than the whole output: this module
 * has no use for the other fields, and a narrower input type is easier to
 * construct in a test and cannot silently start depending on a field it should
 * not.
 */
export function runCardGate(
  output: Pick<LlmOutput, "cards">,
  options: CardGateOptions,
): CardGateReport {
  const warnings: string[] = [];
  const droppedForLimit = output.cards.slice(options.maxCardsPerKnowledgeUnit).map((card) => card.id);
  if (droppedForLimit.length > 0) {
    warnings.push(
      `${droppedForLimit.length} kart pasaj limitini (${options.maxCardsPerKnowledgeUnit}) aştığı için reddedildi (§13.2, §24.4).`,
    );
  }
  const droppedIds = new Set(droppedForLimit);

  const verdicts = output.cards.map((card): CardVerdict => {
    if (droppedIds.has(card.id)) {
      return {
        cardId: card.id,
        decision: "reject",
        reasons: [`Pasaj başına en fazla ${options.maxCardsPerKnowledgeUnit} kart kabul edilir (§13.2, §24.4).`],
      };
    }
    return verdictForCard(card);
  });

  return { verdicts, droppedForLimit, warnings };
}
