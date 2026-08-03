import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  addedCriticalTokens,
  canonical,
  criticalTokenErrorRate,
  criticalTokenMismatches,
  runGate,
} from "../providers/gate.js";
import { detectCriticalTokens } from "../providers/criticalTokens.js";

interface GateCase {
  group: string;
  gold: string;
  reading: string;
  mismatches: string[];
  missingRate: number;
  added: string[];
  passes: boolean;
}

const cases: GateCase[] = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../evals/shared/gate-cases.json", import.meta.url)),
    "utf-8",
  ),
).cases;

/**
 * The verdicts are the contract. Detecting the same tokens is not the same as
 * reaching the same verdict — alignment, de-duplication and canonicalization
 * all sit in between, and each has already produced a real bug.
 */
describe("shared gate cases (Python reference)", () => {
  it("loads a non-trivial case list", () => {
    expect(cases.length).toBeGreaterThan(30);
    expect(cases.filter((entry) => entry.passes).length).toBeGreaterThan(5);
    expect(cases.filter((entry) => !entry.passes).length).toBeGreaterThan(20);
  });

  for (const entry of cases) {
    it(`[${entry.group}] ${JSON.stringify(entry.gold)} -> ${JSON.stringify(entry.reading)}`, () => {
      // These cases simulate OCR-vs-OCR reconciliation (evals/ocr_eval/
      // export_gate_cases.py generates them the same way), so `foldHypoHyper`
      // is on here — matching `reconcile.ts`'s own call, not `cardGate.ts`'s.
      const result = runGate(entry.gold, entry.reading, { foldHypoHyper: true });
      expect(result.mismatches).toEqual(entry.mismatches);
      expect(result.missingRate).toBeCloseTo(entry.missingRate, 10);
      expect(result.added).toEqual(entry.added);
      expect(result.passes).toBe(entry.passes);
    });
  }
});

describe("canonical", () => {
  it("folds every spelling of one route to its code", () => {
    expect(canonical("intravenöz", "route")).toBe(canonical("IV", "route"));
    expect(canonical("damar içi", "route")).toBe(canonical("iv", "route"));
    expect(canonical("kas içi", "route")).toBe(canonical("IM", "route"));
  });

  it("keeps different routes apart", () => {
    expect(canonical("IM", "route")).not.toBe(canonical("IV", "route"));
  });

  it("does not fold diacritics", () => {
    // The detector folds so a token is still *found* in ASCII-fied Turkish,
    // but the chosen OCR can write Turkish, so 'sağ' read as 'sag' is a real
    // transcription defect §24.3 requires to be reported.
    expect(canonical("sağ")).not.toBe(canonical("sag"));
  });

  it("ignores case and whitespace for ordinary tokens", () => {
    expect(canonical("  0,5  mg ")).toBe(canonical("0,5 MG"));
  });
});

describe("the three measures answer different questions", () => {
  it("recall alone would pass an invented value", () => {
    // Everything the source had survived, so recall is clean — but the
    // reading gained a dose the source never carried, and only the surplus
    // measure sees it.
    expect(criticalTokenErrorRate("IM adrenalin", "0,5 mg IM adrenalin")).toBe(0);
    expect(addedCriticalTokens("IM adrenalin", "0,5 mg IM adrenalin")).toEqual(["0,5", "mg"]);
  });

  it("surplus alone would pass a dropped value", () => {
    expect(addedCriticalTokens("0,5 mg IM", "IM")).toEqual([]);
    expect(criticalTokenErrorRate("0,5 mg IM", "IM")).toBeGreaterThan(0);
  });

  it("only the ordered comparison can say what became what", () => {
    const verdicts = criticalTokenMismatches("0,5 mg IM", "0,5 mg IV");
    expect(verdicts).toHaveLength(1);
    expect(verdicts[0]).toContain("replace");
    expect(verdicts[0]).toContain("IM");
    expect(verdicts[0]).toContain("IV");
  });
});

describe("hypo/hyper folding is opt-in, not a blanket default (PR #7 review)", () => {
  it("a changed diagnosis of the same polarity is a mismatch by default", () => {
    // This is exactly `cardGate.ts`'s call shape: checking generated content
    // against its own cited source, with no options — must stay strict.
    const gold = "Hasta hipokalemi geliştirdi";
    const hypothesis = "Hasta hiponatremi geliştirdi";
    expect(criticalTokenMismatches(gold, hypothesis)).not.toEqual([]);
    expect(addedCriticalTokens(gold, hypothesis)).not.toEqual([]);
  });

  it("an on-device suffix typo is only forgiven when reconciliation opts in", () => {
    const gold = "Tip 4 hipersensitivite örnekleri";
    const hypothesis = "Tip 4 hipersenstvite örnekleri";
    expect(addedCriticalTokens(gold, hypothesis)).not.toEqual([]);
    expect(addedCriticalTokens(gold, hypothesis, { foldHypoHyper: true })).toEqual([]);
  });

  it("a real polarity flip still mismatches even when folding is on", () => {
    const gold = "hipokalemi gelişti";
    const hypothesis = "hiperkalemi gelişti";
    expect(criticalTokenMismatches(gold, hypothesis, { foldHypoHyper: true })).not.toEqual([]);
  });
});

describe("repeated values are matched to distinct occurrences", () => {
  it("one surviving 5 does not satisfy two doses of 5", () => {
    // '5 mg sabah, 5 mg akşam' with the second misread as '50' must not score
    // clean just because a '5' is still present somewhere.
    const rate = criticalTokenErrorRate("5 mg sabah, 5 mg akşam", "5 mg sabah, 50 mg akşam");
    expect(rate).toBeGreaterThan(0);
  });
});

describe("degenerate inputs", () => {
  it("a source with no critical token cannot fail on recall", () => {
    // The wording matters: 'yok' is itself a negation token, and so is
    // 'bulunmuyor'. Two earlier versions of this test used one or the other
    // and were measuring the opposite of what they claimed, so the emptiness
    // is asserted rather than assumed.
    const source = "hasta ile ilgili genel bir açıklama";
    expect(detectCriticalTokens(source).map((t) => t.tokenClass)).toEqual([]);
    expect(criticalTokenErrorRate(source, "bambaşka bir cümle daha")).toBe(0);
  });

  it("an empty reading loses everything the source had", () => {
    expect(criticalTokenErrorRate("0,5 mg", "")).toBe(1);
  });

  it("handles two empty strings", () => {
    expect(runGate("", "").passes).toBe(true);
  });
});
