/**
 * Deterministic coverage arithmetic for the Karanlık Harita (docs/ADR-009).
 *
 * This module owns everything about "what does the deck cover" that can be
 * *counted*, and nothing that has to be *judged*. That split is ANA-PLAN §0.8
 * applied to a new feature: the arithmetic (which canonical topics have how
 * many cards, which have none at all) is deterministic code, and the only
 * question left for a model is the one no counter can answer — among the
 * topics that are thin, which ones actually cost points on TUS.
 *
 * **The closed universe is the whole trick.** Coverage is only a meaningful
 * question because `schemas/subject_topics.json` is finite and canonical: 11
 * subjects, 143 topics. A deck covers some subset of those 143, so the
 * complement is *knowable* rather than a matter of opinion — and because the
 * complement is knowable, "what am I not studying?" becomes a query instead of
 * a guess. Every other design here follows from protecting that property:
 *
 * - The canonical list is the **starting point**, never the client's list. A
 *   topic the phone does not mention becomes a zero here, not an omission. A
 *   client that under-reports can therefore only make a topic look *darker*,
 *   which is the safe direction to be wrong in: it wastes attention, it does
 *   not hide a hole.
 * - A (subject, topic) pair the phone sends that is *not* canonical is dropped
 *   and counted, never merged in. Otherwise a stale client build could inject
 *   topics the model would then rank, and the ranking would no longer be over
 *   a closed set.
 * - Topic names are unique only within a subject (ANA-PLAN's note, and
 *   `subjectTopics.ts` repeats it: "İmmünoloji" lives under both Patoloji and
 *   Mikrobiyoloji), so the unit of identity here is always the *pair*, encoded
 *   as a `topicKey`.
 *
 * No content passes through this module — subject names, topic names and
 * counts only (§7.3). Card fronts travel separately and never get logged.
 */

import { SUBJECT_TOPIC_SCHEMA, isValidTopic } from "./subjectTopics.js";

/**
 * Separator for the `subject|topic` key.
 *
 * A pair has to reach the model as a *single* enum value — a schema cannot
 * express "this topic is only legal under that subject" across two independent
 * string fields, and splitting them would let the model pair Patoloji with a
 * Farmakoloji topic while satisfying every constraint we set. Joining them
 * makes the illegal combination unrepresentable.
 *
 * `tests/coverage.test.ts` fails if any canonical name ever contains this
 * character, which is the only thing that could make the encoding ambiguous.
 * It is checked rather than assumed because the schema is hand-synced from an
 * external project (`subjectTopics.ts`), so a future sync could introduce one
 * without anybody here noticing.
 */
export const TOPIC_KEY_SEPARATOR = "|";

export function topicKey(subject: string, topic: string): string {
  return `${subject}${TOPIC_KEY_SEPARATOR}${topic}`;
}

/**
 * Splits a key back into its pair, or `null` if it is not canonical.
 *
 * Validates rather than merely splitting: this is the gate every model-produced
 * key passes through, and "parsed successfully" must mean "names a real topic",
 * not "contained a separator". `indexOf` rather than `split` so a name that
 * somehow gained a separator fails validation instead of silently truncating.
 */
export function parseTopicKey(key: string): { subject: string; topic: string } | null {
  const index = key.indexOf(TOPIC_KEY_SEPARATOR);
  if (index <= 0 || index === key.length - 1) return null;
  const subject = key.slice(0, index);
  const topic = key.slice(index + 1);
  return isValidTopic(subject, topic) ? { subject, topic } : null;
}

/** Every canonical pair, in schema order. This is the model's entire universe. */
export const CANONICAL_TOPIC_KEYS: readonly string[] = Object.freeze(
  SUBJECT_TOPIC_SCHEMA.flatMap((entry) => entry.topics.map((topic) => topicKey(entry.name, topic))),
);

const CANONICAL_KEY_SET = new Set(CANONICAL_TOPIC_KEYS);

export function isCanonicalTopicKey(key: string): boolean {
  return CANONICAL_KEY_SET.has(key);
}

/**
 * What the phone reports about one topic it actually has cards under.
 *
 * `sampleFronts` is the one piece of card content in this whole feature, and it
 * is here for a specific reason: counts alone cannot distinguish "12 cards that
 * cover this topic properly" from "12 cards that all restate the same
 * definition". A handful of question texts lets the model see the difference.
 * The endpoint caps how many it forwards, and none of them ever reach a log
 * line (§7.3).
 */
export interface TopicCoverageInput {
  subject: string;
  topic: string;
  cardCount: number;
  /** Cards the deck itself already doubts (`lowConfidence`), a subset of `cardCount`. */
  weakCardCount?: number;
  sampleFronts?: string[];
}

export interface TopicCoverage {
  subject: string;
  topic: string;
  cardCount: number;
  weakCardCount: number;
  sampleFronts: readonly string[];
}

export interface CoverageBuild {
  /** All 143 canonical topics, in schema order, zero-filled. */
  coverage: readonly TopicCoverage[];
  /** Canonical topics with no card at all — the deterministic half of the answer. */
  untouched: readonly TopicCoverage[];
  /** Client-sent pairs that are not canonical. Counted so the phone can be told, never merged. */
  droppedUnknown: number;
  /** Sum of `cardCount` over canonical topics only. */
  totalCards: number;
}

export interface BuildCoverageOptions {
  /**
   * Restrict the universe to these subjects (the "yalnız Farmakoloji'ye bak"
   * case). Unknown names are ignored; an empty or absent list means all 11.
   *
   * Note this narrows the *canonical* list, not the client's: filtering to a
   * subject still zero-fills every topic under it, so the closed-set property
   * survives the filter.
   */
  subjects?: readonly string[];
  /** Sample fronts kept per topic. Beyond this the model gains nothing and the prompt grows. */
  maxSampleFronts?: number;
}

export const DEFAULT_MAX_SAMPLE_FRONTS = 4;

/**
 * Hard ceiling on one sampled question, in characters.
 *
 * The count ceiling alone was not enough. Four fronts × 143 topics reach both
 * paid prompts, and the phone deliberately samples the *longest* questions
 * (`DarkMapCoverage.samples` — the short ones are bare definitions and hide the
 * very shallowness rule 4 asks the model to notice). Those two choices
 * multiply: a handful of unusually long cards could push the request past a
 * provider's limit and fail the map for the whole deck, or quietly inflate the
 * cost of every run (Codex, PR #49).
 *
 * Generous for a question and small enough that 572 of them cannot matter. The
 * phone applies the same cap before sending, but this one is the guarantee: a
 * client is never trusted to bound what reaches a paid prompt (§21.3's rule
 * applied to length instead of count).
 */
export const MAX_SAMPLE_FRONT_LENGTH = 240;

/** Truncation is marked, so the model reads a cut sentence as cut. */
function clampFront(front: string): string {
  return front.length <= MAX_SAMPLE_FRONT_LENGTH
    ? front
    : `${front.slice(0, MAX_SAMPLE_FRONT_LENGTH).trimEnd()}…`;
}

/**
 * Folds the phone's counts onto the canonical list.
 *
 * Deliberately never throws and never rejects a whole request over one bad
 * entry: this feature's output is advisory, and a single malformed row from an
 * older client build must degrade to "that topic looks empty" rather than to no
 * map at all.
 *
 * Duplicate pairs are summed rather than last-wins. The phone groups by
 * (subject, topic) before sending, so a duplicate means the client split one
 * topic across two rows; summing preserves the total, and the total is what the
 * darkness judgement rests on.
 */
export function buildCoverage(
  inputs: readonly TopicCoverageInput[],
  options: BuildCoverageOptions = {},
): CoverageBuild {
  const maxSamples = Math.max(0, options.maxSampleFronts ?? DEFAULT_MAX_SAMPLE_FRONTS);
  const wanted = options.subjects?.length ? new Set(options.subjects) : null;

  const coverage: TopicCoverage[] = [];
  const byKey = new Map<string, TopicCoverage>();
  for (const entry of SUBJECT_TOPIC_SCHEMA) {
    if (wanted && !wanted.has(entry.name)) continue;
    for (const topic of entry.topics) {
      const row: TopicCoverage = {
        subject: entry.name,
        topic,
        cardCount: 0,
        weakCardCount: 0,
        sampleFronts: [],
      };
      coverage.push(row);
      byKey.set(topicKey(entry.name, topic), row);
    }
  }

  let droppedUnknown = 0;
  for (const input of inputs) {
    const subject = typeof input?.subject === "string" ? input.subject : "";
    const topic = typeof input?.topic === "string" ? input.topic : "";
    if (!isValidTopic(subject, topic)) {
      droppedUnknown += 1;
      continue;
    }
    const row = byKey.get(topicKey(subject, topic));
    // Canonical but filtered out by `subjects` — not an unknown topic, so it
    // must not inflate the "your client sent nonsense" counter.
    if (!row) continue;

    row.cardCount += nonNegative(input.cardCount);
    row.weakCardCount += nonNegative(input.weakCardCount);
    if (maxSamples > 0 && Array.isArray(input.sampleFronts)) {
      const room = maxSamples - row.sampleFronts.length;
      if (room > 0) {
        const additions = input.sampleFronts
          .filter((front): front is string => typeof front === "string" && front.trim().length > 0)
          .slice(0, room)
          .map((front) => clampFront(front.trim()));
        row.sampleFronts = [...row.sampleFronts, ...additions];
      }
    }
  }

  // A weak count larger than the total is a client bug, not a signal. Clamped
  // rather than rejected, for the same reason the whole function is tolerant:
  // the map is worth more than the strictness.
  for (const row of coverage) {
    if (row.weakCardCount > row.cardCount) row.weakCardCount = row.cardCount;
  }

  return {
    coverage,
    untouched: coverage.filter((row) => row.cardCount === 0),
    droppedUnknown,
    totalCards: coverage.reduce((sum, row) => sum + row.cardCount, 0),
  };
}

function nonNegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

/**
 * The coverage table as the model sees it.
 *
 * One line per canonical topic, *including the zeros* — the empty rows are the
 * entire point of the exercise, and a table that omitted them would be asking
 * the model to notice an absence rather than read a fact. Sorted by schema
 * order (subject, then topic) rather than by count, so the model reads a
 * curriculum rather than a leaderboard and cannot mistake the input ordering
 * for the answer it is being asked to produce.
 */
export function renderCoverageTable(coverage: readonly TopicCoverage[]): string {
  const lines: string[] = [];
  let currentSubject = "";
  for (const row of coverage) {
    if (row.subject !== currentSubject) {
      currentSubject = row.subject;
      lines.push(`## ${currentSubject}`);
    }
    const parts = [`- ${topicKey(row.subject, row.topic)} — ${row.cardCount} kart`];
    if (row.weakCardCount > 0) parts.push(`(${row.weakCardCount} şüpheli)`);
    if (row.sampleFronts.length > 0) {
      parts.push(`örnek: ${row.sampleFronts.map((front) => `"${front}"`).join("; ")}`);
    }
    lines.push(parts.join(" "));
  }
  return lines.join("\n");
}
