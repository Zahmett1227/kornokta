/**
 * TypeScript shape of the canonical LLM output contract (ANA-PLAN §14),
 * simplified to v2 in Faz 6 (docs/FAZ6-PLAN.md §6).
 *
 * The v2 card drops the source-fidelity accounting (`sourceQuote`,
 * `sourceLineIds`, `sourceFaithful`, `enriched`, `riskFlags`) and the separate
 * `transcription`/`knowledgeUnits`/`quality` blocks: the model now reads a
 * marked page and emits enriched cards directly (§4), so there is nothing to
 * reconcile a card back against on the server.
 *
 * `RISK_FLAGS` and `CARD_TYPES` are still exported as `as const` arrays so a
 * value list exists at runtime — the same reason `ios/CizgiCore/.../Enums.swift`
 * uses raw-valued enums. `evals/tests/test_ts_contract_sync.py` reads this file
 * as text and checks both lists against `llm_output.schema.json`'s `$defs`, the
 * same way it checks the Swift enums. `RISK_FLAGS` is retained (though the v2
 * `Card` no longer carries a `riskFlags` array — it uses the single boolean
 * `lowConfidence` instead) both for ADR-005's rollback/SAFE_MODE path and to
 * keep that anti-drift guard on a single source across TS/Swift/Python without
 * churning `Enums.swift`.
 */

export const RISK_FLAGS = [
  "ocr_disagreement",
  "handwriting_uncertain",
  "critical_number",
  "critical_unit",
  "negation_risk",
  "symbol_risk",
  "drug_name_risk",
  "organism_name_risk",
  "source_insufficient",
  "source_possible_error",
  "model_added_information",
  "duplicate_card",
  "ambiguous_question",
  "multiple_possible_answers",
] as const;

export type RiskFlag = (typeof RISK_FLAGS)[number];

export const CARD_TYPES = [
  "direct_recall",
  "cloze",
  "mechanism",
  "distinction",
  "exception_trap",
] as const;

export type CardType = (typeof CARD_TYPES)[number];

/**
 * Not part of the v2 `LlmOutput`. Retained because the handwriting
 * second-opinion path (`providers/gemini.ts`, kept on disk for ADR-005's
 * rollback) reuses this shape for its uncertain-span payload.
 */
export interface UncertainSpan {
  text: string;
  alternatives: string[];
  reason: string;
  critical: boolean;
  requiresUserConfirmation: boolean;
}

export interface Card {
  id: string;
  type: CardType;
  front: string;
  back: string;
  /** May carry non-source context (mechanism, clinical relevance); may be empty (§4, §6). */
  explanation: string;
  difficulty: number;
  tags: string[];
  /** The model's own "I am unsure" signal (§6). Does not trigger approval. */
  lowConfidence: boolean;
}

export interface Usage {
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  estimatedCostUSD: number;
}

export interface LlmOutput {
  schemaVersion: "2.0";
  requestId: string;
  /** The raw text the model read off the marked content — audit only (§6.3). */
  readText: string;
  cards: Card[];
  usage: Usage;
}
