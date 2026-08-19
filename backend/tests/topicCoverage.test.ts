import { describe, expect, it } from "vitest";

import {
  CANONICAL_TOPIC_KEYS,
  MAX_SAMPLE_FRONT_LENGTH,
  TOPIC_KEY_SEPARATOR,
  buildCoverage,
  isCanonicalTopicKey,
  parseTopicKey,
  renderCoverageTable,
  topicKey,
} from "../providers/topicCoverage.js";
import { SUBJECT_TOPIC_SCHEMA } from "../providers/subjectTopics.js";

describe("topicKey encoding", () => {
  /**
   * The lock the encoding rests on. The schema is hand-synced from an external
   * project (`subjectTopics.ts`), so a future sync could introduce a name
   * containing the separator and make every key ambiguous — silently, since a
   * mis-split key simply fails validation and the topic quietly disappears from
   * the model's universe.
   */
  it("no canonical name contains the separator", () => {
    for (const subject of SUBJECT_TOPIC_SCHEMA) {
      expect(subject.name).not.toContain(TOPIC_KEY_SEPARATOR);
      for (const topic of subject.topics) {
        expect(topic).not.toContain(TOPIC_KEY_SEPARATOR);
      }
    }
  });

  it("covers every (subject, topic) pair exactly once", () => {
    const expected = SUBJECT_TOPIC_SCHEMA.reduce((sum, s) => sum + s.topics.length, 0);
    expect(CANONICAL_TOPIC_KEYS).toHaveLength(expected);
    expect(new Set(CANONICAL_TOPIC_KEYS).size).toBe(expected);
  });

  it("round-trips a canonical pair", () => {
    const key = topicKey("Patoloji", "Deri Hastalıkları");
    expect(parseTopicKey(key)).toEqual({ subject: "Patoloji", topic: "Deri Hastalıkları" });
    expect(isCanonicalTopicKey(key)).toBe(true);
  });

  /**
   * The pairing rule, not just the spelling. Both halves exist in the schema;
   * only their combination is wrong. A validator that checked the two names
   * independently would pass this and let the model attach a Farmakoloji topic
   * to Patoloji — which is exactly why the key is one enum value rather than
   * two fields.
   */
  it("rejects a real subject paired with another subject's real topic", () => {
    const key = topicKey("Patoloji", "Genel Farmakoloji");
    expect(parseTopicKey(key)).toBeNull();
    expect(isCanonicalTopicKey(key)).toBe(false);
  });

  it("rejects malformed keys", () => {
    expect(parseTopicKey("Patoloji")).toBeNull();
    expect(parseTopicKey("|Deri Hastalıkları")).toBeNull();
    expect(parseTopicKey("Patoloji|")).toBeNull();
    expect(parseTopicKey("Uydurma Ders|Uydurma Konu")).toBeNull();
  });
});

describe("buildCoverage", () => {
  it("starts from the canonical list, not the client's", () => {
    const built = buildCoverage([{ subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 3 }]);
    expect(built.coverage).toHaveLength(CANONICAL_TOPIC_KEYS.length);
    expect(built.untouched).toHaveLength(CANONICAL_TOPIC_KEYS.length - 1);
    expect(built.totalCards).toBe(3);
  });

  /**
   * The safe direction to be wrong in. A client that forgets a topic makes it
   * look empty (wasted attention); a client that could *add* topics would move
   * the ranking outside the closed set, which is the property the whole feature
   * rests on.
   */
  it("drops non-canonical pairs and counts them rather than merging", () => {
    const built = buildCoverage([
      { subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 2 },
      { subject: "Kardiyoloji", topic: "Aritmiler", cardCount: 40 },
      { subject: "Patoloji", topic: "Genel Farmakoloji", cardCount: 40 },
    ]);
    expect(built.droppedUnknown).toBe(2);
    expect(built.totalCards).toBe(2);
    expect(built.coverage.some((row) => row.subject === "Kardiyoloji")).toBe(false);
  });

  it("sums duplicate rows instead of last-wins", () => {
    const built = buildCoverage([
      { subject: "Anatomi", topic: "Anatomiye Giriş ve Terminoloji", cardCount: 2 },
      { subject: "Anatomi", topic: "Anatomiye Giriş ve Terminoloji", cardCount: 5 },
    ]);
    const row = built.coverage.find((entry) => entry.subject === "Anatomi" && entry.cardCount > 0);
    expect(row?.cardCount).toBe(7);
  });

  it("clamps a weak count that exceeds the total", () => {
    const built = buildCoverage([
      { subject: "Biyokimya", topic: "Aminoasitler", cardCount: 2, weakCardCount: 9 },
    ]);
    const row = built.coverage.find((entry) => entry.cardCount > 0);
    expect(row?.weakCardCount).toBe(2);
  });

  it("narrows the canonical universe when subjects are given, still zero-filling", () => {
    const built = buildCoverage([{ subject: "Farmakoloji", topic: "Genel Farmakoloji", cardCount: 4 }], {
      subjects: ["Farmakoloji"],
    });
    expect(built.coverage).toHaveLength(8);
    expect(built.coverage.every((row) => row.subject === "Farmakoloji")).toBe(true);
    expect(built.untouched).toHaveLength(7);
  });

  /** A filtered-out canonical topic is not the client sending nonsense. */
  it("does not count filtered-out canonical rows as unknown", () => {
    const built = buildCoverage([{ subject: "Patoloji", topic: "Deri Hastalıkları", cardCount: 3 }], {
      subjects: ["Farmakoloji"],
    });
    expect(built.droppedUnknown).toBe(0);
    expect(built.totalCards).toBe(0);
  });

  it("caps sample fronts per topic", () => {
    const built = buildCoverage(
      [
        {
          subject: "Farmakoloji",
          topic: "Genel Farmakoloji",
          cardCount: 9,
          sampleFronts: ["a", "b", "c", "d", "e", "f"],
        },
      ],
      { maxSampleFronts: 2 },
    );
    const row = built.coverage.find((entry) => entry.cardCount > 0);
    expect(row?.sampleFronts).toEqual(["a", "b"]);
  });

  it("ignores negative and non-numeric counts", () => {
    const built = buildCoverage([
      { subject: "Anatomi", topic: "Anatomiye Giriş ve Terminoloji", cardCount: -5 },
      {
        subject: "Anatomi",
        topic: "Dolaşım",
        cardCount: "12" as unknown as number,
      },
    ]);
    expect(built.totalCards).toBe(0);
  });
});

describe("renderCoverageTable", () => {
  /**
   * The zeros are the answer, so they have to be in the question. A table that
   * only listed covered topics would be asking the model to notice an absence
   * rather than read a fact.
   */
  it("includes zero-card topics", () => {
    const built = buildCoverage([], { subjects: ["Farmakoloji"] });
    const table = renderCoverageTable(built.coverage);
    expect(table).toContain("Farmakoloji|Genel Farmakoloji — 0 kart");
    expect(table.split("\n").filter((line) => line.startsWith("- "))).toHaveLength(8);
  });

  it("groups by subject and annotates weak counts and samples", () => {
    const built = buildCoverage(
      [
        {
          subject: "Farmakoloji",
          topic: "Genel Farmakoloji",
          cardCount: 5,
          weakCardCount: 2,
          sampleFronts: ["Yarılanma ömrü nedir?"],
        },
      ],
      { subjects: ["Farmakoloji"] },
    );
    const table = renderCoverageTable(built.coverage);
    expect(table).toContain("## Farmakoloji");
    expect(table).toContain("Farmakoloji|Genel Farmakoloji — 5 kart (2 şüpheli)");
    expect(table).toContain('örnek: "Yarılanma ömrü nedir?"');
  });
});

describe("sample front length ceiling (Codex, PR #49)", () => {
  /**
   * The count ceiling alone was not enough: four fronts × 143 topics reach both
   * paid prompts, and the phone deliberately samples the *longest* questions —
   * so the two choices multiply. A handful of very long cards could push the
   * request past a provider's limit and fail the map for the whole deck.
   */
  it("truncates an over-long front and marks the cut", () => {
    const long = "a".repeat(MAX_SAMPLE_FRONT_LENGTH + 500);
    const built = buildCoverage([
      { subject: "Farmakoloji", topic: "Genel Farmakoloji", cardCount: 1, sampleFronts: [long] },
    ]);
    const front = built.coverage.find((row) => row.cardCount > 0)!.sampleFronts[0]!;
    expect(front).toHaveLength(MAX_SAMPLE_FRONT_LENGTH + 1);
    expect(front.endsWith("…")).toBe(true);
  });

  it("leaves a front at the limit untouched", () => {
    const exact = "b".repeat(MAX_SAMPLE_FRONT_LENGTH);
    const built = buildCoverage([
      { subject: "Farmakoloji", topic: "Genel Farmakoloji", cardCount: 1, sampleFronts: [exact] },
    ]);
    expect(built.coverage.find((row) => row.cardCount > 0)!.sampleFronts[0]).toBe(exact);
  });

  /** The whole point: the prompt table cannot grow without bound. */
  it("bounds the rendered table even when every front is huge", () => {
    const long = "c".repeat(10_000);
    const built = buildCoverage(
      [
        {
          subject: "Farmakoloji",
          topic: "Genel Farmakoloji",
          cardCount: 4,
          sampleFronts: [long, long, long, long],
        },
      ],
      { subjects: ["Farmakoloji"] },
    );
    const table = renderCoverageTable(built.coverage);
    expect(table.length).toBeLessThan(4 * (MAX_SAMPLE_FRONT_LENGTH + 16) + 600);
  });
});
