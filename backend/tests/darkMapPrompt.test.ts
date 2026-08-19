import { describe, expect, it } from "vitest";

import { DARK_MAP_PROMPT, DARK_MAP_PROMPT_VERSION } from "../prompts/darkMap.js";

/**
 * Locks the rules that were argued for, the way `prompts.test.ts` locks the
 * card-generation prompt's.
 *
 * The project learned twice that an unlocked prompt rule silently disappears —
 * once when a rename left rule 1's marker list partial, once when the tier
 * members drifted across three places. The same lock is cheap here and the
 * failure mode would be identical: a rule quietly stops being in the prompt and
 * nothing goes red, it just gets slowly worse answers.
 *
 * Each block is sliced out before searching, for the reason CLAUDE.md records:
 * a check that searches the *whole* prompt for a phrase protects nothing once
 * that phrase appears in two rules.
 */
function block(heading: string): string {
  const start = DARK_MAP_PROMPT.indexOf(heading);
  expect(start, `"${heading}" başlığı prompt'ta yok`).toBeGreaterThanOrEqual(0);
  const next = DARK_MAP_PROMPT.indexOf("\n## ", start + heading.length);
  return DARK_MAP_PROMPT.slice(start, next === -1 ? undefined : next);
}

describe("dark map prompt", () => {
  it("has a version", () => {
    expect(DARK_MAP_PROMPT_VERSION).toMatch(/^\d+\.\d+$/);
  });

  /**
   * Rule 1 is the prompt half of the closed-universe guarantee. The schema enum
   * and `sanitizeRatings` are the other two; this is the layer that stops the
   * model wasting a whole rating on a topic that will be discarded.
   */
  it("keeps the verbatim-copy rule in the binding form", () => {
    const rule = block("## Kural 1");
    expect(rule).toContain("topicKey");
    expect(rule).toContain("BİREBİR");
    // Names the consequence, not just the preference — the shape that moved
    // kural 8 from 82/360 to 0/239 while a preference-only rule did nothing.
    expect(rule).toContain("sessizce atılır");
    expect(rule).toContain("YANLIŞ:");
    expect(rule).toContain("DOĞRU:");
  });

  /**
   * Rule 2 exists because the obvious failure is a reason that restates the
   * count. The user can already see the count; a "reason" that says "you have
   * no cards here" is the input echoed back with a verb.
   */
  it("forbids restating the count as a reason, with a wrong/right pair", () => {
    const rule = block("## Kural 2");
    expect(rule).toMatch(/gerekçe.*sayıyı tekrar etmek/i);
    expect(rule).toContain("YANLIŞ:");
    expect(rule).toContain("DOĞRU:");
    // The replacement has to be nameable content, not a better adjective.
    expect(rule).toMatch(/mekanizma|sendrom|ayırıcı tanı/);
  });

  /**
   * Rule 3 is what makes the two model calls worth their price. Ranking by
   * emptiness alone is something `buildCoverage` already does for free, so a
   * model that only does that has been paid to reproduce a sort.
   */
  it("requires yield × gap rather than emptiness alone", () => {
    const rule = block("## Kural 3");
    expect(rule).toContain("ÇARPIMI");
    expect(rule).toMatch(/TUS'un o konuya verdiği ağırlık/);
    expect(rule).toContain("YANLIŞ: sıfır kartlı bütün konuları listenin başına koymak.");
  });

  /** Rule 4 is the only reason sample fronts are sent at all. */
  it("explains that a high card count can still be dark", () => {
    const rule = block("## Kural 4");
    expect(rule).toMatch(/aynı tanımın etrafında/);
    expect(rule).toContain("DOĞRU:");
  });

  /** Rule 5: a padded study list costs more than a short one. */
  it("tells the model to return fewer rather than invent", () => {
    const rule = block("## Kural 5");
    expect(rule).toMatch(/daha az döndür|Daha azını/i);
    expect(rule).toMatch(/uydur/i);
  });

  it("documents every schema field it asks for", () => {
    const fields = block("## Alanlar");
    for (const field of ["topicKey", "darkness", "tusYield", "missingConcepts", "reason"]) {
      expect(fields).toContain(`\`${field}\``);
    }
    // The yield is a claim about the exam, not about the deck — the merge step
    // relies on that separation when it keeps the highest yield across raters.
    expect(fields).toContain("BAĞIMSIZ");
  });

  /** It ranks; it must never quietly become a second card generator. */
  it("forbids generating cards", () => {
    expect(DARK_MAP_PROMPT).toContain("kart üretme");
  });
});

describe("scope framing (Codex, PR #49)", () => {
  /**
   * A `subjects`-narrowed request shows the rankers a subset. The system
   * message used to assert the table held every topic in the canonical schema,
   * which is then false — and false in the direction that matters, since an
   * omitted subject reads as "not in the curriculum" rather than "deliberately
   * out of scope", and that skews the very subject-only ranking that was asked
   * for. This is the higher-priority text, so `buildRankInstruction` wording
   * alone was not enough.
   */
  it("describes the table as the evaluation's scope, not the whole schema", () => {
    expect(DARK_MAP_PROMPT).toContain("KAPSAMINDAKİ her konuyu içerir");
    expect(DARK_MAP_PROMPT).not.toContain("şablonundaki HER konuyu içerir");
  });

  it("says an absent topic is out of scope rather than absent from the curriculum", () => {
    expect(DARK_MAP_PROMPT).toMatch(/müfredatta yok" demek DEĞİLDİR/);
    expect(DARK_MAP_PROMPT).toMatch(/dışında bırakıldı/);
  });

  /** The closed-set framing must survive the rewording: the table is the universe. */
  it("still tells the model to rank only over the rows it was given", () => {
    expect(DARK_MAP_PROMPT).toMatch(/sıralamanı tablodaki satırlar üzerinden/);
  });
});
