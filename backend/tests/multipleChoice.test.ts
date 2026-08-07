import { describe, expect, it } from "vitest";

import { optionKey, sanitizeMultipleChoice } from "../providers/multipleChoice.js";
import type { Card, CardOption } from "../schemas/llmOutputTypes.js";

function options(texts: string[], correctAt = 0): CardOption[] {
  return texts.map((text, index) => ({
    text,
    correct: index === correctAt,
    why: index === correctAt ? "" : `${text} yanlış çünkü …`,
  }));
}

function mcCard(overrides: Partial<Card> = {}): Card {
  const list = options(["Hipokalemi", "Hiperkalemi", "Hiponatremi", "Hipokalsemi", "Hipomagnezemi"]);
  return {
    id: "c1",
    type: "multiple_choice",
    front: "EKG'de U dalgası ve düz T ile giden elektrolit bozukluğu hangisidir?",
    back: "Hipokalemi",
    explanation: "Hücre içi potasyum kaybı repolarizasyonu uzatır.",
    difficulty: 3,
    tags: ["kardiyoloji"],
    lowConfidence: false,
    options: list,
    correctOption: 0,
    ...overrides,
  };
}

describe("sanitizeMultipleChoice", () => {
  it("leaves a sound five-option card alone", () => {
    const card = mcCard();
    const report = sanitizeMultipleChoice([card]);
    expect(report.cards[0]).toEqual(card);
    expect(report.notes).toEqual([]);
  });

  it("downgrades instead of rejecting — a paid-for card is not thrown away", () => {
    const report = sanitizeMultipleChoice([mcCard({ options: options(["A", "B", "C"]) })]);
    expect(report.cards[0]!.type).toBe("direct_recall");
    expect(report.cards[0]!.options).toBeNull();
    expect(report.cards[0]!.correctOption).toBeNull();
    // The card itself survives intact.
    expect(report.cards[0]!.front).toBe(mcCard().front);
    expect(report.cards[0]!.back).toBe("Hipokalemi");
    expect(report.notes[0]!.action).toBe("downgraded");
  });

  it("downgrades a card with no correct option", () => {
    const list = options(["A", "B", "C", "D", "E"]).map((option) => ({ ...option, correct: false }));
    const report = sanitizeMultipleChoice([mcCard({ options: list })]);
    expect(report.cards[0]!.type).toBe("direct_recall");
    expect(report.notes[0]!.reason).toContain("Hiçbir şık");
  });

  /// §13.3's "two correct answers" case, in the shape code can actually see.
  it("downgrades a card with two correct options", () => {
    const list = options(["A", "B", "C", "D", "E"]);
    list[2] = { ...list[2]!, correct: true };
    const report = sanitizeMultipleChoice([mcCard({ options: list })]);
    expect(report.cards[0]!.type).toBe("direct_recall");
    expect(report.notes[0]!.reason).toContain("2 şık");
  });

  it("downgrades when correctOption disagrees with the flagged option", () => {
    const report = sanitizeMultipleChoice([mcCard({ correctOption: 3 })]);
    expect(report.cards[0]!.type).toBe("direct_recall");
    expect(report.notes[0]!.reason).toContain("uyuşmuyor");
  });

  it("downgrades duplicate options, including across Turkish case and accents", () => {
    const report = sanitizeMultipleChoice([
      mcCard({ options: options(["İskemi", "iskemi", "C", "D", "E"]) }),
    ]);
    expect(report.cards[0]!.type).toBe("direct_recall");
    expect(report.notes[0]!.reason).toContain("İki şık aynı");
  });

  it("flags — but keeps — an option that contains another", () => {
    const report = sanitizeMultipleChoice([
      mcCard({ options: options(["Hipokalemi", "Ağır hipokalemi", "C", "D", "E"]) }),
    ]);
    expect(report.cards[0]!.type).toBe("multiple_choice");
    expect(report.cards[0]!.lowConfidence).toBe(true);
    expect(report.notes.map((note) => note.action)).toContain("flagged");
  });

  it("flags a distractor with no reason (§13.3 wants one per option)", () => {
    const list = options(["A", "B", "C", "D", "E"]);
    list[1] = { ...list[1]!, why: "  " };
    const report = sanitizeMultipleChoice([mcCard({ options: list })]);
    expect(report.cards[0]!.lowConfidence).toBe(true);
    expect(report.notes.some((note) => note.reason.includes("neden yanlış"))).toBe(true);
  });

  it("rewrites a back that disagrees with the answer key", () => {
    const report = sanitizeMultipleChoice([mcCard({ back: "Hiperkalemi" })]);
    expect(report.cards[0]!.back).toBe("Hipokalemi");
    expect(report.notes[0]!.action).toBe("back_rewritten");
  });

  it("does not rewrite a back that differs only in case or spacing", () => {
    const report = sanitizeMultipleChoice([mcCard({ back: "  hipokalemi " })]);
    expect(report.cards[0]!.back).toBe("  hipokalemi ");
    expect(report.notes).toEqual([]);
  });

  it("strips options from a card that did not claim to be multiple choice", () => {
    const report = sanitizeMultipleChoice([mcCard({ type: "direct_recall" })]);
    expect(report.cards[0]!.options).toBeNull();
    expect(report.cards[0]!.correctOption).toBeNull();
    expect(report.notes[0]!.action).toBe("options_stripped");
  });

  it("leaves ordinary cards completely untouched", () => {
    const plain: Card = {
      id: "p1",
      type: "direct_recall",
      front: "Soru",
      back: "Cevap",
      explanation: "",
      difficulty: 2,
      tags: [],
      lowConfidence: false,
      options: null,
      correctOption: null,
    };
    const report = sanitizeMultipleChoice([plain]);
    expect(report.cards[0]).toEqual(plain);
    expect(report.notes).toEqual([]);
  });

  it("handles a v2.0 card that has no option fields at all", () => {
    const legacy = {
      id: "l1",
      type: "cloze",
      front: "…",
      back: "…",
      explanation: "",
      difficulty: 1,
      tags: [],
      lowConfidence: false,
    } as Card;
    const report = sanitizeMultipleChoice([legacy]);
    expect(report.cards[0]).toEqual(legacy);
    expect(report.notes).toEqual([]);
  });
});

describe("optionKey", () => {
  it("folds Turkish case and diacritics", () => {
    expect(optionKey("İskemi")).toBe(optionKey("iskemi"));
    expect(optionKey("ŞOK")).toBe(optionKey("sok"));
    expect(optionKey("Sağ  ventrikül")).toBe(optionKey("sag ventrikul"));
  });

  it("keeps genuinely different terms apart", () => {
    expect(optionKey("hipokalemi")).not.toBe(optionKey("hiperkalemi"));
    expect(optionKey("hiponatremi")).not.toBe(optionKey("hipokalemi"));
  });
});
