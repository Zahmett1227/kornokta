/**
 * Canonical ders → konu template used to constrain the model's per-card
 * `topic` field (schema v2.2).
 *
 * **The names are not written here.** They live in
 * `schemas/subject_topics.json`, hand-synced from the tusoskop project's
 * `src/data/subjectTopicSchema.js` (an external repo, so no generator can
 * reach it — the sync date is recorded in the JSON's `_comment`). The iOS
 * bundle carries a byte-identical copy; `tests/subjectTopics.test.ts` fails
 * if the two drift apart, the same arrangement the marker-detection config
 * already uses.
 *
 * Topic names are unique only within a subject ("İmmünoloji" exists under
 * both Patoloji and Mikrobiyoloji), so validity is always a (subject, topic)
 * pair — never a bare topic lookup.
 */

import { createRequire } from "node:module";

// JSON import assertions are still unstable across runtimes; `createRequire`
// works the same under tsx, vitest and a bundled deployment.
const require = createRequire(import.meta.url);
const schemaData = require("../schemas/subject_topics.json") as SubjectTopicFile;

interface SubjectTopicFile {
  version: number;
  subjects: Array<{ name: string; topics: string[] }>;
}

export interface SubjectEntry {
  name: string;
  topics: readonly string[];
}

export const SUBJECT_TOPIC_SCHEMA: readonly SubjectEntry[] = Object.freeze(
  schemaData.subjects.map((entry) =>
    Object.freeze({ name: entry.name, topics: Object.freeze([...entry.topics]) }),
  ),
);

export const SUBJECTS: readonly string[] = Object.freeze(
  SUBJECT_TOPIC_SCHEMA.map((entry) => entry.name),
);

const TOPICS_BY_SUBJECT = new Map(
  SUBJECT_TOPIC_SCHEMA.map((entry) => [entry.name, entry.topics]),
);

export function topicsFor(subject: string): readonly string[] | undefined {
  return TOPICS_BY_SUBJECT.get(subject);
}

export function isValidTopic(subject: string, topic: string): boolean {
  return TOPICS_BY_SUBJECT.get(subject)?.includes(topic) ?? false;
}

/**
 * Forces every card's `topic` onto the subject's canonical list, or to null.
 *
 * The dynamic response schema already constrains the model to the list, but
 * that constraint only exists when the request carried a known subject — and
 * a schema bug or provider change must degrade to "no topic", never to a
 * failed (and therefore permanently locked) job. Deliberately never throws.
 */
export function sanitizeTopics<T extends { topic?: string | null }>(
  cards: T[],
  subject: string | null | undefined,
): T[] {
  const topics = subject ? TOPICS_BY_SUBJECT.get(subject) : undefined;
  return cards.map((card) => {
    const topic = card.topic ?? null;
    const valid = topic !== null && topics !== undefined && topics.includes(topic);
    return { ...card, topic: valid ? topic : null };
  });
}
