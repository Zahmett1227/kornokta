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

  it("drops malformed marks instead of failing the page", () => {
    const output: Record<string, unknown> = {
      marks: [
        mark("m1", "handwriting"),
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

  it("keeps both marks when the model reuses an id, and credits neither", () => {
    // Codex, PR #47. Dropping the second one deleted a mark that is physically
    // on the page — the loss this whole layer exists to end — and the card
    // naming the reused id then credited whichever passage came first.
    const output: Record<string, unknown> = {
      marks: [
        { id: "m1", kind: "handwriting", quote: "ilk pasaj" },
        { id: "m1", kind: "symbol", quote: "bambaşka bir pasaj" },
        { id: "m2", kind: "underline", quote: "tekil kimlik" },
      ],
      cards: [card("c1", "m1"), card("c2", "m2")],
    };
    sanitizeMarks(output);

    const marks = output.marks as Mark[];
    expect(marks.map((entry) => entry.quote)).toEqual([
      "ilk pasaj",
      "bambaşka bir pasaj",
      "tekil kimlik",
    ]);
    // Re-keyed rather than dropped, and the ids stay unique so the register can
    // still be joined against.
    expect(new Set(marks.map((entry) => entry.id)).size).toBe(3);

    const cards = output.cards as Array<{ markId?: unknown }>;
    // The ambiguous reference resolves to nothing: which of the two passages
    // the card came from is genuinely unknown, and picking one would invent it.
    expect(cards[0]?.markId).toBeNull();
    // An unambiguous reference is untouched.
    expect(cards[1]?.markId).toBe("m2");

    const report = deriveCoverage(output as never);
    // Both physical marks stay visible; only the truly covered one drops out.
    expect(report.uncovered.map((entry) => entry.quote)).toEqual(["ilk pasaj", "bambaşka bir pasaj"]);
    expect(report.unmarkedCardIds).toEqual(["c1"]);
  });

  it("never lets a card resolve to a synthetic id", () => {
    // The re-keyed id is ours, not the model's: a card naming `m1~2` named
    // nothing. Resolving it would attach that card to a mark the model never
    // referenced and hide the mark from `uncovered` (Codex, PR #47) — the same
    // silent narrowing the re-keying exists to prevent.
    const output: Record<string, unknown> = {
      marks: [
        { id: "m1", kind: "symbol", quote: "ilk pasaj" },
        { id: "m1", kind: "symbol", quote: "ikinci pasaj" },
      ],
      cards: [card("c1", "m1~2")],
    };
    sanitizeMarks(output);

    expect((output.marks as Mark[]).map((entry) => entry.id)).toEqual(["m1", "m1~2"]);
    expect((output.cards as Array<{ markId?: unknown }>)[0]?.markId).toBeNull();

    const report = deriveCoverage(output as never);
    expect(report.uncovered).toHaveLength(2);
  });

  it("does not collide with an id the model itself emitted", () => {
    const output: Record<string, unknown> = {
      marks: [
        { id: "m1", kind: "symbol", quote: "bir" },
        { id: "m1~2", kind: "symbol", quote: "iki" },
        { id: "m1", kind: "symbol", quote: "üç" },
      ],
      cards: [],
    };
    sanitizeMarks(output);

    const ids = (output.marks as Mark[]).map((entry) => entry.id);
    expect(new Set(ids).size).toBe(3);
    expect(ids).toContain("m1~3");
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
