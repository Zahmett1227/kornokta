import { describe, expect, it } from "vitest";

import { cardIntroducesUnsourcedCriticalToken, runCardGate } from "../providers/cardGate.js";
import type { Card, LlmOutput } from "../schemas/llmOutputTypes.js";

function baseCard(overrides: Partial<Card> = {}): Card {
  return {
    id: "card_1",
    knowledgeUnitId: "ku_1",
    type: "direct_recall",
    front: "Anafilakside ilk seçenek tedavi nedir?",
    back: "0,3–0,5 mg IM adrenalin.",
    explanation: "",
    sourceQuote: "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
    sourceLineIds: ["line_04"],
    sourceFaithful: true,
    enriched: false,
    difficulty: 2,
    riskFlags: [],
    requiresUserApproval: false,
    ...overrides,
  };
}

function quality(overrides: Partial<LlmOutput["quality"]> = {}): LlmOutput["quality"] {
  return { sourceCoverage: 0.98, duplicateCardRisk: 0.05, medicalMeaningChangeRisk: 0.01, warnings: [], ...overrides };
}

describe("cardIntroducesUnsourcedCriticalToken", () => {
  it("is clean when the answer only restates the quoted dose", () => {
    expect(cardIntroducesUnsourcedCriticalToken(baseCard())).toEqual([]);
  });

  it("flags a dose the card invented relative to its own cited quote", () => {
    const card = baseCard({ back: "1 mg IV adrenalin." });
    expect(cardIntroducesUnsourcedCriticalToken(card)).not.toEqual([]);
  });

  it("flags a same-polarity hipo/hyper diagnosis swap (PR #7 review, docs/ADR-003)", () => {
    // `addedCriticalTokens` here must NOT fold hipo/hiper to just its prefix —
    // that folding exists for OCR-vs-OCR reconciliation (reconcile.ts) and
    // would otherwise let a card silently turn a sourced 'hipokalemi' into
    // 'hiponatremi', a different diagnosis entirely, into an auto-accept.
    const card = baseCard({
      sourceQuote: "Hastada hipokalemi saptandı.",
      back: "Hastada hiponatremi saptandı.",
    });
    expect(cardIntroducesUnsourcedCriticalToken(card)).not.toEqual([]);
  });
});

describe("runCardGate", () => {
  it("auto-accepts a clean, source-faithful card with no risk flags", () => {
    const report = runCardGate(
      { cards: [baseCard()], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts).toEqual([{ cardId: "card_1", decision: "auto_accept", reasons: [] }]);
    expect(report.droppedForLimit).toEqual([]);
    expect(report.warnings).toEqual([]);
  });

  it("rejects a card with an empty sourceQuote (§24.4: cannot link back to source)", () => {
    const report = runCardGate(
      { cards: [baseCard({ sourceQuote: "" })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it("rejects a source-faithful card whose answer invents a critical value not in its own quote", () => {
    // §0.5/§19.3: the exact failure mode the rule exists for — a card that
    // cites a real passage but silently changes the dose in its own answer.
    const report = runCardGate(
      { cards: [baseCard({ back: "1 mg IV adrenalin." })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it("only asks for confirmation, not rejection, when the same invented value is on an enriched card (§12.2)", () => {
    const report = runCardGate(
      {
        cards: [baseCard({ back: "1 mg IV adrenalin.", enriched: true, sourceFaithful: false })],
        quality: quality(),
      },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("quick_confirm");
  });

  it("rejects sourceFaithful=false paired with enriched=false as an unsupported answer", () => {
    const report = runCardGate(
      { cards: [baseCard({ sourceFaithful: false, enriched: false })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it("rejects source_insufficient outright — the card should not have been produced (§19.1, §19.3)", () => {
    const report = runCardGate(
      { cards: [baseCard({ riskFlags: ["source_insufficient"] })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it("rejects duplicate_card outright rather than letting it reach the active deck (§24.4)", () => {
    const report = runCardGate(
      { cards: [baseCard({ riskFlags: ["duplicate_card"] })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it.each([
    "critical_number",
    "critical_unit",
    "negation_risk",
    "symbol_risk",
    "drug_name_risk",
    "organism_name_risk",
    "ocr_disagreement",
    "handwriting_uncertain",
    "source_possible_error",
    "model_added_information",
    "ambiguous_question",
    "multiple_possible_answers",
  ] as const)("requires confirmation, not auto-accept, for riskFlag=%s (§19.2)", (flag) => {
    const report = runCardGate(
      { cards: [baseCard({ riskFlags: [flag] })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("quick_confirm");
  });

  it("requires confirmation for every enriched card regardless of riskFlags (§12.2, §19.2)", () => {
    const report = runCardGate(
      { cards: [baseCard({ enriched: true })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("quick_confirm");
  });

  it("never downgrades a model-set requiresUserApproval=true (ADR-001: AI is a floor, not a ceiling)", () => {
    const report = runCardGate(
      { cards: [baseCard({ requiresUserApproval: true })], quality: quality() },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("quick_confirm");
  });

  it("drops cards beyond the per-passage limit and gives every card exactly one verdict (§13.2, §24.4)", () => {
    const cards = [
      baseCard({ id: "card_1" }),
      baseCard({ id: "card_2" }),
      baseCard({ id: "card_3" }),
      baseCard({ id: "card_4" }),
      baseCard({ id: "card_5" }),
    ];
    const report = runCardGate({ cards, quality: quality() }, { maxCardsPerKnowledgeUnit: 4 });

    expect(report.verdicts).toHaveLength(5);
    expect(report.verdicts.map((v) => v.cardId)).toEqual(["card_1", "card_2", "card_3", "card_4", "card_5"]);
    expect(report.verdicts.slice(0, 4).every((v) => v.decision === "auto_accept")).toBe(true);
    expect(report.verdicts[4]!.decision).toBe("reject");
    expect(report.droppedForLimit).toEqual(["card_5"]);
    expect(report.warnings.join(" ")).toContain("pasaj limitini");
  });

  it("escalates every card to quick_confirm when page-wide medical meaning change risk is high (§19.2)", () => {
    const report = runCardGate(
      { cards: [baseCard()], quality: quality({ medicalMeaningChangeRisk: 0.5 }) },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("quick_confirm");
    expect(report.warnings.join(" ")).toContain("tıbbi anlam değişikliği riski yüksek");
  });

  it("warns but does not fail closed on high page-wide duplicate risk with no flagged card", () => {
    // The page-level number alone does not say *which* card is the
    // duplicate; a specific card only rejects when it carries duplicate_card
    // itself. The report still has to surface the aggregate concern.
    const report = runCardGate(
      { cards: [baseCard()], quality: quality({ duplicateCardRisk: 0.9 }) },
      { maxCardsPerKnowledgeUnit: 4 },
    );
    expect(report.verdicts[0]!.decision).toBe("auto_accept");
    expect(report.warnings.join(" ")).toContain("duplicate kart riski yüksek");
  });

  it("respects a configured maxCardsPerKnowledgeUnit rather than a hardcoded 4 (§0.6)", () => {
    const cards = [baseCard({ id: "card_1" }), baseCard({ id: "card_2" })];
    const report = runCardGate({ cards, quality: quality() }, { maxCardsPerKnowledgeUnit: 1 });
    expect(report.droppedForLimit).toEqual(["card_2"]);
  });
});
