import { describe, expect, it } from "vitest";

import { runCardGate } from "../providers/cardGate.js";
import type { Card } from "../schemas/llmOutputTypes.js";

function baseCard(overrides: Partial<Card> = {}): Card {
  return {
    id: "card_1",
    type: "direct_recall",
    front: "Anafilakside ilk seçenek tedavi nedir?",
    back: "0,3–0,5 mg IM adrenalin.",
    explanation: "",
    difficulty: 2,
    tags: [],
    lowConfidence: false,
    ...overrides,
  };
}

// Faz 6 (docs/FAZ6-PLAN.md §5.3): the gate is now a health check, not a
// source-fidelity gate. Every structurally-sound card is auto_accept; approval
// only happens later on the user's own initiative (edit/delete in Bilgilerim).
describe("runCardGate", () => {
  it("auto-accepts a healthy card", () => {
    const report = runCardGate({ cards: [baseCard()] }, { maxCardsPerKnowledgeUnit: 4 });
    expect(report.verdicts).toEqual([{ cardId: "card_1", decision: "auto_accept", reasons: [] }]);
    expect(report.droppedForLimit).toEqual([]);
    expect(report.warnings).toEqual([]);
  });

  it("auto-accepts an enriched card — enrichment no longer triggers approval (§4, §5.3)", () => {
    const card = baseCard({ explanation: "Adrenalin mast hücresi degranülasyonunu baskılar." });
    const report = runCardGate({ cards: [card] }, { maxCardsPerKnowledgeUnit: 4 });
    expect(report.verdicts[0]!.decision).toBe("auto_accept");
  });

  it("auto-accepts a card the model marked lowConfidence — it does not stop the flow (§6)", () => {
    const report = runCardGate({ cards: [baseCard({ lowConfidence: true })] }, { maxCardsPerKnowledgeUnit: 4 });
    expect(report.verdicts[0]!.decision).toBe("auto_accept");
  });

  it("rejects a card with an empty front", () => {
    const report = runCardGate({ cards: [baseCard({ front: "   " })] }, { maxCardsPerKnowledgeUnit: 4 });
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it("rejects a card with an empty back", () => {
    const report = runCardGate({ cards: [baseCard({ back: "" })] }, { maxCardsPerKnowledgeUnit: 4 });
    expect(report.verdicts[0]!.decision).toBe("reject");
  });

  it("drops cards beyond the per-passage limit and gives every card exactly one verdict (§13.2, §24.4)", () => {
    const cards = [
      baseCard({ id: "card_1" }),
      baseCard({ id: "card_2" }),
      baseCard({ id: "card_3" }),
      baseCard({ id: "card_4" }),
      baseCard({ id: "card_5" }),
    ];
    const report = runCardGate({ cards }, { maxCardsPerKnowledgeUnit: 4 });

    expect(report.verdicts).toHaveLength(5);
    expect(report.verdicts.map((v) => v.cardId)).toEqual(["card_1", "card_2", "card_3", "card_4", "card_5"]);
    expect(report.verdicts.slice(0, 4).every((v) => v.decision === "auto_accept")).toBe(true);
    expect(report.verdicts[4]!.decision).toBe("reject");
    expect(report.droppedForLimit).toEqual(["card_5"]);
    expect(report.warnings.join(" ")).toContain("pasaj limitini");
  });

  it("respects a configured maxCardsPerKnowledgeUnit rather than a hardcoded 4 (§0.6)", () => {
    const cards = [baseCard({ id: "card_1" }), baseCard({ id: "card_2" })];
    const report = runCardGate({ cards }, { maxCardsPerKnowledgeUnit: 1 });
    expect(report.droppedForLimit).toEqual(["card_2"]);
  });
});
