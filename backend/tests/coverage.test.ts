import { describe, expect, it } from "vitest";

import {
  coverageFromGate,
  deriveCoverage,
  markPriority,
  sanitizeMarks,
} from "../providers/coverage.js";
import { MARK_KINDS, type Card, type Mark } from "../schemas/llmOutputTypes.js";

/** A card with only the fields coverage accounting reads. */
function card(id: string, markId?: string | null): Card {
  return {
    id,
    type: "direct_recall",
    front: `soru ${id}`,
    back: `cevap ${id}`,
    explanation: "",
    difficulty: 2,
    tags: [],
    lowConfidence: false,
    ...(markId === undefined ? {} : { markId }),
  };
}

function mark(id: string, kind: Mark["kind"], quote = `alıntı ${id}`): Mark {
  return { id, kind, quote };
}

describe("markPriority", () => {
  it("ranks the tiers the way prompt rule 3 does", () => {
    // Handwriting first, then the symbol tier, then underline, then
    // highlighter. This is not presentation: it decides which skipped mark the
    // owner is shown first, and the prompt's own ladder is the only reason it
    // is in this order.
    const ordered = [...MARK_KINDS].sort((left, right) => markPriority(left) - markPriority(right));
    expect(ordered).toEqual(["handwriting", "symbol", "underline", "highlight"]);
  });

  it("sorts an unknown tier last rather than throwing", () => {
    // A newer server (or a hand-edited payload) must not crash the sort.
    expect(markPriority("scribble")).toBeGreaterThan(markPriority("highlight"));
  });
});

describe("deriveCoverage", () => {
  it("reports the marks no card claims, most valuable first", () => {
    const report = deriveCoverage({
      marks: [
        mark("m1", "highlight"),
        mark("m2", "handwriting"),
        mark("m3", "symbol"),
        mark("m4", "underline"),
      ],
      cards: [card("c1", "m4")],
    });

    expect(report.reported).toBe(true);
    expect(report.uncovered.map((entry) => entry.id)).toEqual(["m2", "m3", "m1"]);
    expect(report.unmarkedCardIds).toEqual([]);
  });

  it("keeps the model's own order inside one tier", () => {
    // Same tier means same priority, and the register is written roughly in
    // page order — so a sort that reshuffles equals would hand the owner a
    // list in an order nothing produced.
    const report = deriveCoverage({
      marks: [mark("m1", "symbol"), mark("m2", "symbol"), mark("m3", "symbol")],
      cards: [],
    });
    expect(report.uncovered.map((entry) => entry.id)).toEqual(["m1", "m2", "m3"]);
  });

  it("counts a card bound to no mark as rule 1's violation", () => {
    const report = deriveCoverage({
      marks: [mark("m1", "handwriting")],
      cards: [card("c1", "m1"), card("c2", null), card("c3")],
    });
    // Both shapes of "no mark" — an explicit null and an absent field — are
    // the same thing: a card the model could not tie to anything the student
    // marked.
    expect(report.unmarkedCardIds).toEqual(["c2", "c3"]);
    expect(report.uncovered).toEqual([]);
  });

  it("does not let a rejected card cover a mark", () => {
    // The case that actually happens: the page carries more marks than the
    // ceiling allows cards, the gate drops the surplus, and the mark whose
    // only card was dropped is *not* covered. Counting it would hide exactly
    // the failure the ceiling creates (Tur A: 18 of 18 pages hit it).
    const report = deriveCoverage(
      {
        marks: [mark("m1", "handwriting"), mark("m2", "symbol")],
        cards: [card("c1", "m1"), card("c2", "m2")],
      },
      { rejectedCardIds: ["c2"] },
    );
    expect(report.uncovered.map((entry) => entry.id)).toEqual(["m2"]);
  });

  it("tells 'no register' apart from 'nothing uncovered'", () => {
    // An older deployment, or a model that ignored the field, has no
    // information to give — and an empty `uncovered` list would otherwise read
    // as a clean bill of health for a page nobody checked.
    const silent = deriveCoverage({ cards: [card("c1")] });
    expect(silent.reported).toBe(false);
    expect(silent.uncovered).toEqual([]);

    const clean = deriveCoverage({ marks: [], cards: [card("c1", null)] });
    expect(clean.reported).toBe(true);
  });
});

describe("coverageFromGate", () => {
  it("treats every rejected verdict as a card that never reaches the deck", () => {
    const report = coverageFromGate(
      {
        marks: [mark("m1", "underline"), mark("m2", "highlight")],
        cards: [card("c1", "m1"), card("c2", "m2")],
      },
      {
        verdicts: [
          { cardId: "c1", decision: "auto_accept" },
          { cardId: "c2", decision: "reject" },
        ],
      },
    );
    expect(report.uncovered.map((entry) => entry.id)).toEqual(["m2"]);
  });
});

describe("sanitizeMarks", () => {
  it("nulls a markId that points at nothing", () => {
    // The one shape that would make the report lie: the card looks bound, so
    // its mark counts as covered, so a skipped mark is reported as handled.
    const output: Record<string, unknown> = {
      marks: [mark("m1", "handwriting")],
      cards: [card("c1", "m9"), card("c2", "m1")],
    };
    sanitizeMarks(output);

    const cards = output.cards as Array<{ markId?: unknown }>;
    expect(cards[0]?.markId).toBeNull();
    expect(cards[1]?.markId).toBe("m1");

    const report = deriveCoverage(output as never);
    expect(report.uncovered).toEqual([]);
    expect(report.unmarkedCardIds).toEqual(["c1"]);
  });

  it("drops malformed and duplicate marks instead of failing the page", () => {
    const output: Record<string, unknown> = {
      marks: [
        mark("m1", "handwriting"),
        { id: "m1", kind: "symbol", quote: "kopya kimlik" },
        { id: "m2", kind: "scribble", quote: "bilinmeyen kademe" },
        { id: "  ", kind: "symbol", quote: "boş kimlik" },
        { id: "m3", kind: "symbol", quote: "   " },
        "bir metin",
      ],
      cards: [card("c1", "m2")],
    };
    sanitizeMarks(output);

    expect((output.marks as Mark[]).map((entry) => entry.id)).toEqual(["m1"]);
    // `m2` was dropped, so the card that pointed at it is now honestly unbound
    // rather than silently covering a mark that no longer exists.
    expect((output.cards as Array<{ markId?: unknown }>)[0]?.markId).toBeNull();
  });

  it("trims ids on both sides so whitespace cannot break the join", () => {
    const output: Record<string, unknown> = {
      marks: [{ id: " m1 ", kind: "underline", quote: " alıntı " }],
      cards: [card("c1", "m1 ")],
    };
    sanitizeMarks(output);

    expect(output.marks).toEqual([{ id: "m1", kind: "underline", quote: "alıntı" }]);
    expect((output.cards as Array<{ markId?: unknown }>)[0]?.markId).toBe("m1");
  });

  it("removes a non-array register rather than letting it fail validation", () => {
    // Schema validation would reject the whole page over an audit extra —
    // a paid capture must never be lost to the field that was added to make
    // captures better.
    const output: Record<string, unknown> = { marks: "yok", cards: [card("c1", "m1")] };
    sanitizeMarks(output);

    expect(output.marks).toBeUndefined();
    expect((output.cards as Array<{ markId?: unknown }>)[0]?.markId).toBeNull();
  });

  it("leaves a payload without the v2.3 fields untouched", () => {
    const output: Record<string, unknown> = { cards: [card("c1")] };
    sanitizeMarks(output);

    expect(output.marks).toBeUndefined();
    expect((output.cards as Array<{ markId?: unknown }>)[0]?.markId).toBeUndefined();
  });
});
