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
  /** §13.3 — five options, exactly one correct. Schema v2.1. */
  "multiple_choice",
] as const;

export type CardType = (typeof CARD_TYPES)[number];

/**
 * Mark tiers (schema v2.3, docs/PLAN-kapsama-sozlesmesi.md Katman A).
 *
 * **Order is meaning here, not presentation.** It is prompt rule 3's priority
 * ladder — handwriting first, then the symbol tier, then underline, then
 * highlighter — and `providers/coverage.ts` sorts uncovered marks by it, so the
 * most valuable thing the model skipped is the first thing the owner sees.
 * Reordering this array silently reorders that list.
 *
 * `as const` for the same reason `CARD_TYPES` is: a runtime value list the
 * Python sync test can compare against the schema (and against the Swift
 * `MarkKind` enum), rather than a type that vanishes at compile time.
 */
export const MARK_KINDS = [
  "handwriting",
  "symbol",
  "underline",
  "highlight",
] as const;

export type MarkKind = (typeof MARK_KINDS)[number];

/**
 * One mark the model reports having seen (schema v2.3), card or no card.
 *
 * The whole point is the "no card" half: an ungenerated card carries no
 * `lowConfidence`, so before this list existed nothing downstream could tell a
 * page whose marks were all covered from one where half of them were skipped.
 */
export interface Mark {
  /** Model-assigned short id ("m1"); cards point at it via `markId`. */
  id: string;
  kind: MarkKind;
  /** The marked text, verbatim from the page. */
  quote: string;
}

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

/**
 * One of a multiple-choice card's five options (§13.3).
 *
 * `why` is a field of its own because §13.3 requires the model to say why each
 * distractor is wrong *separately* — folding those sentences into one
 * `explanation` blob would leave nothing able to say which reason belongs to
 * which option.
 */
export interface CardOption {
  text: string;
  correct: boolean;
  /** Why this option is wrong (one sentence). Empty on the correct option. */
  why: string;
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
  /**
   * Five options for a `multiple_choice` card, `null` otherwise (schema v2.1).
   *
   * Optional in the canonical §14 schema so a v2.0 payload stays valid; the
   * model-facing variant makes it required-and-nullable, because Structured
   * Outputs strict mode has no notion of an optional property.
   */
  options?: CardOption[] | null;
  /** Index of the correct option. See `options`. */
  correctOption?: number | null;
  /**
   * Canonical topic name from the subject's list in
   * `schemas/subject_topics.json` (schema v2.2), or null when the request
   * carried no subject or the model was unsure. The canonical schema accepts
   * any string here — the enum constraint lives only in the model-facing
   * variant, and `sanitizeTopics` nulls anything off-list afterwards.
   */
  topic?: string | null;
  /**
   * Which mark in `LlmOutput.marks` this card came from (schema v2.3), or
   * `null` when the model bound it to none — which is prompt rule 1's own
   * violation ("işaretlenmemiş metin kart kaynağı değildir") and is counted as
   * such in `providers/coverage.ts`.
   *
   * Optional in the canonical schema (a v2.0–v2.2 payload predates it);
   * required-and-nullable in the model-facing variant, like `topic`.
   */
  markId?: string | null;
}

export interface Usage {
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  estimatedCostUSD: number;
}

export interface LlmOutput {
  schemaVersion: "2.0" | "2.1" | "2.2" | "2.3";
  requestId: string;
  /** The raw text the model read off the marked content — audit only (§6.3). */
  readText: string;
  cards: Card[];
  /**
   * The model's own mark register (schema v2.3). Absent on an older payload;
   * an empty array means "I found no marks on this page", which is a real and
   * different answer from "I did not report".
   */
  marks?: Mark[];
  usage: Usage;
}
