import { describe, expect, it } from "vitest";

import { buildCoverage, topicKey } from "../providers/coverage.js";
import {
  buildGeminiResponseSchema,
  buildOpenAIResponseSchema,
  buildRankInstruction,
  mergeRankings,
  sanitizeRatings,
  type DarkZoneRating,
} from "../providers/darkMap.js";

const DERMA = topicKey("Patoloji", "Deri Hastalıkları");
const PHARM = topicKey("Farmakoloji", "Genel Farmakoloji");

function rating(overrides: Partial<DarkZoneRating> & { topicKey: string }): DarkZoneRating {
  return {
    darkness: 3,
    tusYield: "medium",
    missingConcepts: [],
    reason: "",
    ...overrides,
  };
}

describe("sanitizeRatings", () => {
  /**
   * The layer that makes the closed-set promise survive a model that ignores
   * the enum. A hallucinated topic name on a study screen is the one failure
   * this feature must not have, so identity errors drop the whole rating while
   * score errors are repaired.
   */
  it("drops a non-canonical topicKey and counts it", () => {
    const result = sanitizeRatings(
      {
        zones: [
          { topicKey: DERMA, darkness: 4, tusYield: "high", missingConcepts: [], reason: "x" },
          { topicKey: "Kardiyoloji|Aritmiler", darkness: 5, tusYield: "high", reason: "y" },
          { topicKey: "Patoloji|Genel Farmakoloji", darkness: 5, tusYield: "high", reason: "z" },
        ],
      },
      10,
    );
    expect(result.droppedUnknown).toBe(2);
    expect(result.ratings.map((r) => r.topicKey)).toEqual([DERMA]);
  });

  it("repairs rather than drops a bad score", () => {
    const result = sanitizeRatings(
      { zones: [{ topicKey: DERMA, darkness: 99, tusYield: "çok", reason: "  x  " }] },
      10,
    );
    expect(result.ratings[0]).toMatchObject({ darkness: 5, tusYield: "medium", reason: "x" });
  });

  it("floors darkness at 1 and defaults a missing one", () => {
    const result = sanitizeRatings(
      { zones: [{ topicKey: DERMA, darkness: -3 }, { topicKey: PHARM }] },
      10,
    );
    expect(result.ratings.map((r) => r.darkness)).toEqual([1, 1]);
  });

  it("collapses a repeated topic keeping the higher darkness", () => {
    const result = sanitizeRatings(
      { zones: [{ topicKey: DERMA, darkness: 2 }, { topicKey: DERMA, darkness: 5 }] },
      10,
    );
    expect(result.ratings).toHaveLength(1);
    expect(result.ratings[0]!.darkness).toBe(5);
  });

  it("de-duplicates and caps missingConcepts", () => {
    const result = sanitizeRatings(
      {
        zones: [
          {
            topicKey: DERMA,
            missingConcepts: ["a", "a", " b ", "c", "d", "e", "f", "g", 7],
          },
        ],
      },
      10,
    );
    expect(result.ratings[0]!.missingConcepts).toEqual(["a", "b", "c", "d", "e"]);
  });

  it("honours maxZones, keeping the darkest", () => {
    const result = sanitizeRatings(
      {
        zones: [
          { topicKey: DERMA, darkness: 2 },
          { topicKey: PHARM, darkness: 5 },
          { topicKey: topicKey("Anatomi", "Nöroanatomi"), darkness: 4 },
        ],
      },
      2,
    );
    expect(result.ratings.map((r) => r.topicKey)).toEqual([
      PHARM,
      topicKey("Anatomi", "Nöroanatomi"),
    ]);
  });

  it("survives a shapeless answer", () => {
    expect(sanitizeRatings(null, 5).ratings).toEqual([]);
    expect(sanitizeRatings({ zones: "nope" }, 5).ratings).toEqual([]);
    expect(sanitizeRatings({ zones: [null, 3, "x"] }, 5).ratings).toEqual([]);
  });
});

describe("response schemas", () => {
  /**
   * The constrained-decoding layer. If the enum ever stops carrying the full
   * canonical list, the model regains the ability to invent a topic and only
   * `sanitizeRatings` would be left holding the line.
   */
  it("constrains topicKey to the canonical list in both dialects", () => {
    const openai = buildOpenAIResponseSchema(5) as Record<string, any>;
    const openaiEnum = openai.properties.zones.items.properties.topicKey.enum as string[];
    expect(openaiEnum).toContain(DERMA);
    expect(openaiEnum).not.toContain("Kardiyoloji|Aritmiler");

    const gemini = buildGeminiResponseSchema(5) as Record<string, any>;
    const geminiEnum = gemini.properties.zones.items.properties.topicKey.enum as string[];
    expect(geminiEnum).toEqual(openaiEnum);
  });

  /** `strict: true` rejects a schema with an unlisted property. */
  it("lists every OpenAI property as required", () => {
    const schema = buildOpenAIResponseSchema(5) as Record<string, any>;
    const item = schema.properties.zones.items;
    expect(new Set(item.required)).toEqual(new Set(Object.keys(item.properties)));
    expect(item.additionalProperties).toBe(false);
  });
});

describe("buildRankInstruction", () => {
  it("states the closed universe and the empty count", () => {
    const built = buildCoverage([{ subject: "Farmakoloji", topic: "Genel Farmakoloji", cardCount: 3 }], {
      subjects: ["Farmakoloji"],
    });
    const text = buildRankInstruction({ requestId: "r1", coverage: built.coverage, maxZones: 6 });
    expect(text).toContain("Kanonik şablonda 8 konu var. 1 konuda kart var, 7 konu tamamen boş.");
    expect(text).toContain("En fazla 6 konu döndür");
    expect(text).toContain("Farmakoloji|Genel Farmakoloji — 3 kart");
  });
});

describe("mergeRankings", () => {
  const coverage = buildCoverage([
    { subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 7, weakCardCount: 2 },
  ]).coverage;

  it("marks a topic both families flagged as confirmed", () => {
    const zones = mergeRankings(
      [
        { family: "openai", ratings: [rating({ topicKey: DERMA, darkness: 4, reason: "o" })] },
        { family: "gemini", ratings: [rating({ topicKey: DERMA, darkness: 5, reason: "g" })] },
      ],
      coverage,
    );
    expect(zones).toHaveLength(1);
    expect(zones[0]).toMatchObject({
      consensus: "confirmed",
      raters: ["openai", "gemini"],
      darkness: 4.5,
      subject: "Patoloji",
      topic: "Deri Hastalıkları",
    });
    expect(zones[0]!.reasons).toEqual([
      { family: "openai", reason: "o" },
      { family: "gemini", reason: "g" },
    ]);
  });

  /**
   * Disagreement is information. Dropping a single-family zone would turn a
   * 50/50 call into a silence indistinguishable from "neither flagged it".
   */
  it("keeps a single-family zone, labelled disputed", () => {
    const zones = mergeRankings(
      [{ family: "openai", ratings: [rating({ topicKey: DERMA })] }],
      coverage,
    );
    expect(zones[0]!.consensus).toBe("disputed");
    expect(zones[0]!.raters).toEqual(["openai"]);
  });

  /**
   * The count is the one number in this feature that is *known*. Letting a
   * model's echo of it through would print a fabricated figure beside a real
   * topic name.
   */
  it("takes cardCount from the deck, never from a rating", () => {
    const zones = mergeRankings(
      [
        {
          family: "openai",
          ratings: [{ ...rating({ topicKey: DERMA }), cardCount: 999 } as DarkZoneRating],
        },
      ],
      coverage,
    );
    expect(zones[0]!.cardCount).toBe(7);
    expect(zones[0]!.weakCardCount).toBe(2);
  });

  it("orders confirmed above disputed regardless of darkness", () => {
    const zones = mergeRankings(
      [
        {
          family: "openai",
          ratings: [rating({ topicKey: DERMA, darkness: 1 }), rating({ topicKey: PHARM, darkness: 5 })],
        },
        { family: "gemini", ratings: [rating({ topicKey: DERMA, darkness: 1 })] },
      ],
      buildCoverage([]).coverage,
    );
    expect(zones.map((z) => [z.topicKey, z.consensus])).toEqual([
      [DERMA, "confirmed"],
      [PHARM, "disputed"],
    ]);
  });

  /** Cautious direction: a study list should not be talked down by the milder rater. */
  it("keeps the highest claimed TUS yield", () => {
    const zones = mergeRankings(
      [
        { family: "openai", ratings: [rating({ topicKey: DERMA, tusYield: "low" })] },
        { family: "gemini", ratings: [rating({ topicKey: DERMA, tusYield: "high" })] },
      ],
      coverage,
    );
    expect(zones[0]!.tusYield).toBe("high");
  });

  it("unions missing concepts in first-seen order", () => {
    const zones = mergeRankings(
      [
        { family: "openai", ratings: [rating({ topicKey: DERMA, missingConcepts: ["a", "b"] })] },
        { family: "gemini", ratings: [rating({ topicKey: DERMA, missingConcepts: ["b", "c"] })] },
      ],
      coverage,
    );
    expect(zones[0]!.missingConcepts).toEqual(["a", "b", "c"]);
  });

  /**
   * Without a total order the tail of the list reshuffles between two runs that
   * scored identically, and the screen looks like it changed its mind.
   */
  it("breaks exact ties by canonical schema order, not answer order", () => {
    const tied = [rating({ topicKey: PHARM }), rating({ topicKey: DERMA })];
    const forward = mergeRankings([{ family: "openai", ratings: tied }], buildCoverage([]).coverage);
    const reversed = mergeRankings(
      [{ family: "openai", ratings: [...tied].reverse() }],
      buildCoverage([]).coverage,
    );
    expect(forward.map((z) => z.topicKey)).toEqual(reversed.map((z) => z.topicKey));
    // Patoloji precedes Farmakoloji in the schema.
    expect(forward.map((z) => z.topicKey)).toEqual([DERMA, PHARM]);
  });

  it("prefers the emptier topic when consensus, darkness and yield all tie", () => {
    const coverageTwo = buildCoverage([
      { subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 9 },
      { subject: "Farmakoloji", topic: "Genel Farmakoloji", cardCount: 1 },
    ]).coverage;
    const zones = mergeRankings(
      [{ family: "openai", ratings: [rating({ topicKey: DERMA }), rating({ topicKey: PHARM })] }],
      coverageTwo,
    );
    expect(zones.map((z) => z.topicKey)).toEqual([PHARM, DERMA]);
  });
});
