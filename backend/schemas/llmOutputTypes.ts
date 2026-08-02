/**
 * TypeScript shape of the canonical LLM output contract (ANA-PLAN §14).
 *
 * `RiskFlag` and `CardType` are exported as `as const` arrays rather than
 * plain union types so a value list actually exists at runtime — the same
 * reason `ios/CizgiCore/.../Enums.swift` uses raw-valued enums instead of a
 * bare Swift enum. `evals/tests/test_ts_contract_sync.py` reads this file as
 * text and checks both lists against `llm_output.schema.json`'s `$defs`, the
 * same way it already checks the Swift enums — this project has hit "one
 * behaviour, two places, only one updated" three times (docs/ADR-001), and a
 * third undefended copy of this particular list would be a fourth.
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

export interface UncertainSpan {
  text: string;
  alternatives: string[];
  reason: string;
  critical: boolean;
  requiresUserConfirmation: boolean;
}

export interface Transcription {
  exactText: string;
  cleanText: string;
  language: string;
  overallConfidence: number;
  isHandwritten: boolean;
  selectedLineIds: string[];
  uncertainSpans: UncertainSpan[];
}

export interface KnowledgeUnit {
  id: string;
  canonicalClaim: string;
  mechanism: string | null;
  tags: string[];
  sourceConcern: string | null;
  requiresUserApproval: boolean;
}

export interface Card {
  id: string;
  knowledgeUnitId: string;
  type: CardType;
  front: string;
  back: string;
  explanation: string;
  sourceQuote: string;
  sourceLineIds: string[];
  sourceFaithful: boolean;
  enriched: boolean;
  difficulty: number;
  riskFlags: RiskFlag[];
  requiresUserApproval: boolean;
}

export interface Quality {
  sourceCoverage: number;
  duplicateCardRisk: number;
  medicalMeaningChangeRisk: number;
  warnings: string[];
}

export interface Usage {
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  estimatedCostUSD: number;
}

export interface LlmOutput {
  schemaVersion: "1.0";
  requestId: string;
  transcription: Transcription;
  knowledgeUnits: KnowledgeUnit[];
  cards: Card[];
  quality: Quality;
  usage: Usage;
}
