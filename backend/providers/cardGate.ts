/**
 * Deterministic post-generation quality gate for cards (ANA-PLAN §19).
 *
 * Card generation (§17: `card_generation`) is followed by a separate
 * `quality_validation` step before a card can reach `ready`. This module is
 * that step. It runs on output that has already passed
 * `validateLlmOutput` — schema conformance is necessary but not sufficient,
 * because §19's rules are business rules a JSON Schema cannot express:
 * `riskFlags` implies a decision, a passage caps at N cards, and a card must
 * not introduce a critical value its own cited quote does not have.
 *
 * ADR-001's rule for the OCR reconciliation gate (`providers/gate.ts`)
 * applies here unchanged: the model's own `requiresUserApproval` is a floor,
 * never a ceiling. This module can turn a model-reported `false` into
 * `quick_confirm` or `reject`; it never turns a model-reported `true` into
 * `auto_accept` (§0.5, §19.2).
 */

import { addedCriticalTokens } from "./gate.js";
import type { Card, LlmOutput, RiskFlag } from "../schemas/llmOutputTypes.js";

export type CardDecision = "auto_accept" | "quick_confirm" | "reject";

export interface CardVerdict {
  cardId: string;
  decision: CardDecision;
  reasons: string[];
}

export interface CardGateOptions {
  /** §11.3, §13.2, §24.4 — enforced here because asking the prompt nicely is not a limit. */
  maxCardsPerKnowledgeUnit: number;
  /** Page-wide `quality.duplicateCardRisk` above this adds a warning (§24.4). Default 0.5. */
  maxDuplicateCardRisk?: number;
  /** Page-wide `quality.medicalMeaningChangeRisk` above this forces confirmation on every card (§19.2). Default 0.05. */
  maxMedicalMeaningChangeRisk?: number;
}

export interface CardGateReport {
  /** One verdict per input card, same order as `output.cards`. */
  verdicts: CardVerdict[];
  /** Card ids rejected solely for exceeding the per-passage limit (§24.4). */
  droppedForLimit: string[];
  /** Page-level concerns not attributable to one specific card. */
  warnings: string[];
}

const DEFAULT_MAX_DUPLICATE_CARD_RISK = 0.5;
const DEFAULT_MAX_MEDICAL_MEANING_CHANGE_RISK = 0.05;

/** §19.2 — the model flagging one of these is itself sufficient grounds to ask the user. */
const ALWAYS_CONFIRM_FLAGS: ReadonlySet<RiskFlag> = new Set([
  "ocr_disagreement",
  "handwriting_uncertain",
  "critical_number",
  "critical_unit",
  "negation_risk",
  "symbol_risk",
  "drug_name_risk",
  "organism_name_risk",
  "source_possible_error",
  "model_added_information",
  "ambiguous_question",
  "multiple_possible_answers",
]);

/** §19.1/§19.3/§24.4 — these mean the card should not have reached the deck at all. */
const ALWAYS_REJECT_FLAGS: ReadonlySet<RiskFlag> = new Set(["source_insufficient", "duplicate_card"]);

function worseOf(a: CardDecision, b: CardDecision): CardDecision {
  const rank: Record<CardDecision, number> = { auto_accept: 0, quick_confirm: 1, reject: 2 };
  return rank[a] >= rank[b] ? a : b;
}

/**
 * Checks one card's front/back against its own cited `sourceQuote` for an
 * invented critical value — a dose, unit, route, or negation that appears in
 * the answer but not in the quote it claims to come from.
 *
 * Reuses the detector the OCR reconciliation gate uses
 * (`addedCriticalTokens` in `providers/gate.ts`) rather than writing a second
 * implementation: "does this critical value actually appear in the cited
 * source" is the same question in both places, and this project has already
 * paid once for treating it as two (docs/ADR-001).
 */
export function cardIntroducesUnsourcedCriticalToken(
  card: Pick<Card, "front" | "back" | "sourceQuote">,
): string[] {
  return addedCriticalTokens(card.sourceQuote, `${card.front}\n${card.back}`);
}

/**
 * Checks whether the card's own `explanation` introduces a critical value not
 * backed by its cited `sourceQuote`.
 *
 * The card prompt (v1.1, §12.2) lets `explanation` carry non-source context
 * (mechanism, clinical relevance) specifically so `front`/`back` don't have
 * to — but that content still must not silently carry an invented dose,
 * route, or diagnosis past the user. This does **not** trust the model's own
 * `enriched` flag as the signal: ADR-001's rule ("a self-reported flag is a
 * floor, never a ceiling") applies here too. Without this, a model that adds
 * such content but returns `enriched=false` — by mistake or otherwise —
 * would pass both this check and the enriched-card rule below with nothing
 * catching it (PR #7 review, docs/ADR-003).
 */
export function explanationIntroducesUnsourcedCriticalToken(
  card: Pick<Card, "explanation" | "sourceQuote">,
): string[] {
  if (!card.explanation.trim()) return [];
  return addedCriticalTokens(card.sourceQuote, card.explanation);
}

function verdictForCard(card: Card): CardVerdict {
  const reasons: string[] = [];
  let decision: CardDecision = "auto_accept";

  if (!card.sourceQuote.trim()) {
    decision = worseOf(decision, "reject");
    reasons.push("sourceQuote boş: kart kaynağa geri bağlanamıyor (§24.4).");
  }

  const invented = cardIntroducesUnsourcedCriticalToken(card);
  if (invented.length > 0) {
    if (card.enriched) {
      decision = worseOf(decision, "quick_confirm");
      reasons.push(
        `Zenginleştirilmiş kart kaynakta olmayan kritik değer içeriyor: ${invented.join(", ")} (§12.2).`,
      );
    } else {
      decision = worseOf(decision, "reject");
      reasons.push(
        `Kaynağa sadık kart, kaynakta olmayan kritik değer içeriyor: ${invented.join(", ")} (§0.5, §19.3).`,
      );
    }
  }

  // Independent of `card.enriched` — see the function's own docstring for why.
  const explanationInvented = explanationIntroducesUnsourcedCriticalToken(card);
  if (explanationInvented.length > 0) {
    decision = worseOf(decision, "quick_confirm");
    reasons.push(
      `Açıklama kaynakta olmayan kritik değer içeriyor: ${explanationInvented.join(", ")} (§12.2, §19.2).`,
    );
  }

  if (!card.sourceFaithful && !card.enriched) {
    decision = worseOf(decision, "reject");
    reasons.push("sourceFaithful=false ve enriched=false: cevabın kaynağı belirsiz.");
  }

  for (const flag of card.riskFlags) {
    if (ALWAYS_REJECT_FLAGS.has(flag)) {
      decision = worseOf(decision, "reject");
      reasons.push(`riskFlag=${flag} (§19.1, §19.3, §24.4).`);
    } else if (ALWAYS_CONFIRM_FLAGS.has(flag)) {
      decision = worseOf(decision, "quick_confirm");
      reasons.push(`riskFlag=${flag} (§19.2).`);
    }
  }

  if (card.enriched) {
    decision = worseOf(decision, "quick_confirm");
    reasons.push("enriched=true kartlar onaysız aktif desteye eklenmez (§12.2, §19.2).");
  }

  if (card.requiresUserApproval) {
    // ADR-001: a model-set `true` is a floor. It is never overridden downward
    // by anything in this function — only ever confirmed or escalated.
    decision = worseOf(decision, "quick_confirm");
    reasons.push("Model requiresUserApproval=true işaretledi.");
  }

  return { cardId: card.id, decision, reasons };
}

/**
 * Runs the full §19 gate over a validated LLM output's cards.
 *
 * Takes `Pick<LlmOutput, "cards" | "quality">` rather than the whole output:
 * this module has no use for the transcription or knowledge-unit fields, and
 * a narrower input type is easier to construct in a test and cannot silently
 * start depending on a field it should not.
 */
export function runCardGate(
  output: Pick<LlmOutput, "cards" | "quality">,
  options: CardGateOptions,
): CardGateReport {
  const maxDuplicateCardRisk = options.maxDuplicateCardRisk ?? DEFAULT_MAX_DUPLICATE_CARD_RISK;
  const maxMedicalMeaningChangeRisk =
    options.maxMedicalMeaningChangeRisk ?? DEFAULT_MAX_MEDICAL_MEANING_CHANGE_RISK;

  const warnings: string[] = [];
  const droppedForLimit = output.cards.slice(options.maxCardsPerKnowledgeUnit).map((card) => card.id);
  if (droppedForLimit.length > 0) {
    warnings.push(
      `${droppedForLimit.length} kart pasaj limitini (${options.maxCardsPerKnowledgeUnit}) aştığı için reddedildi (§13.2, §24.4).`,
    );
  }
  const droppedIds = new Set(droppedForLimit);

  const medicalRiskTooHigh = output.quality.medicalMeaningChangeRisk > maxMedicalMeaningChangeRisk;
  if (medicalRiskTooHigh) {
    warnings.push(
      `Sayfa geneli tıbbi anlam değişikliği riski yüksek: ${output.quality.medicalMeaningChangeRisk} > ${maxMedicalMeaningChangeRisk} (§19.2).`,
    );
  }
  if (output.quality.duplicateCardRisk > maxDuplicateCardRisk) {
    warnings.push(
      `Sayfa geneli duplicate kart riski yüksek: ${output.quality.duplicateCardRisk} > ${maxDuplicateCardRisk} (§24.4). ` +
        "Hangi kartın kopya olduğu ayrıca kartın kendi riskFlags alanıyla işaretlenmeli.",
    );
  }

  const verdicts = output.cards.map((card): CardVerdict => {
    if (droppedIds.has(card.id)) {
      return {
        cardId: card.id,
        decision: "reject",
        reasons: [`Pasaj başına en fazla ${options.maxCardsPerKnowledgeUnit} kart kabul edilir (§13.2, §24.4).`],
      };
    }
    const verdict = verdictForCard(card);
    if (medicalRiskTooHigh) {
      verdict.decision = worseOf(verdict.decision, "quick_confirm");
      verdict.reasons.push("Sayfa geneli tıbbi anlam değişikliği riski yüksek (§19.2).");
    }
    return verdict;
  });

  return { verdicts, droppedForLimit, warnings };
}
