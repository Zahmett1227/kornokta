import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  SUBJECTS,
  SUBJECT_TOPIC_SCHEMA,
  isValidTopic,
  sanitizeTopics,
  topicsFor,
} from "../providers/subjectTopics.js";

describe("subject/topic template", () => {
  it("carries the tusoskop counts: 11 subjects, 143 topics", () => {
    expect(SUBJECTS).toHaveLength(11);
    const total = SUBJECT_TOPIC_SCHEMA.reduce((sum, entry) => sum + entry.topics.length, 0);
    expect(total).toBe(143);
  });

  it("keeps the known per-subject sizes", () => {
    expect(topicsFor("Patoloji")).toHaveLength(24);
    expect(topicsFor("Genel Cerrahi")).toHaveLength(29);
    expect(topicsFor("Kadın Hastalıkları ve Doğum")).toHaveLength(4);
  });

  it("has no duplicate topic within a subject", () => {
    for (const entry of SUBJECT_TOPIC_SCHEMA) {
      expect(new Set(entry.topics).size).toBe(entry.topics.length);
    }
  });

  it("validates only (subject, topic) pairs, never bare topics", () => {
    // "İmmünoloji" exists under two subjects — the reason validity is a pair.
    expect(isValidTopic("Patoloji", "İmmünoloji")).toBe(true);
    expect(isValidTopic("Mikrobiyoloji", "İmmünoloji")).toBe(true);
    expect(isValidTopic("Anatomi", "İmmünoloji")).toBe(false);
    expect(isValidTopic("Patoloji", "Bakteriyoloji")).toBe(false);
    expect(isValidTopic("Bilinmeyen Ders", "İmmünoloji")).toBe(false);
  });
});

describe("iOS copy stays byte-identical", () => {
  // The same anti-drift arrangement the marker-detection config uses: the
  // phone validates topics against its bundled copy, so the two files must
  // never diverge. tusoskop itself is outside this repo — its sync is manual
  // and dated in the JSON's _comment.
  it("backend and CizgiCore bundle carry the same bytes", () => {
    const backend = readFileSync(
      fileURLToPath(new URL("../schemas/subject_topics.json", import.meta.url)),
    );
    const ios = readFileSync(
      fileURLToPath(
        new URL(
          "../../ios/CizgiCore/Sources/CizgiCore/Resources/subject_topics.json",
          import.meta.url,
        ),
      ),
    );
    expect(backend.equals(ios)).toBe(true);
  });
});

describe("sanitizeTopics", () => {
  const cards = [
    { front: "a", topic: "İnflamasyon" },
    { front: "b", topic: "Bakteriyoloji" }, // valid elsewhere, not in Patoloji
    { front: "c", topic: null },
    { front: "d" }, // v2.1 payloads carry no topic key at all
  ];

  it("keeps valid topics and nulls invalid ones for a known subject", () => {
    const out = sanitizeTopics(cards, "Patoloji");
    expect(out.map((card) => card.topic)).toEqual(["İnflamasyon", null, null, null]);
  });

  it("nulls every topic when the subject is unknown or absent", () => {
    expect(sanitizeTopics(cards, "Uydurma Ders").every((card) => card.topic === null)).toBe(true);
    expect(sanitizeTopics(cards, null).every((card) => card.topic === null)).toBe(true);
    expect(sanitizeTopics(cards, undefined).every((card) => card.topic === null)).toBe(true);
  });

  it("does not mutate its input", () => {
    sanitizeTopics(cards, "Patoloji");
    expect(cards[1]?.topic).toBe("Bakteriyoloji");
  });
});
