import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  ROUTE_SYNONYMS,
  TOKEN_CLASSES,
  canonicalRoute,
  containsCriticalToken,
  detectCriticalTokens,
  isRouteSurface,
} from "../providers/criticalTokens.js";
import { foldDiacritics, normalizeForCompare, turkishLower } from "../providers/turkish.js";

interface SharedCase {
  group: string;
  text: string;
  expected: Array<{ text: string; tokenClass: string; start: number; end: number }>;
}

const cases: SharedCase[] = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../evals/shared/critical-token-cases.json", import.meta.url)),
    "utf-8",
  ),
).cases;

/**
 * The contract that holds the two implementations together.
 *
 * Expected values are produced by the Python detector — the reference, with
 * the accumulated test suite behind it. Any divergence here means the port
 * drifted, which is the failure this whole generated-patterns arrangement
 * exists to prevent.
 */
describe("shared cases (Python reference)", () => {
  it("loads a non-trivial case list", () => {
    // Guards the guard: an empty or unparsed file would make every case below
    // pass vacuously.
    expect(cases.length).toBeGreaterThan(50);
    expect(cases.filter((entry) => entry.expected.length > 0).length).toBeGreaterThan(30);
  });

  for (const entry of cases) {
    it(`[${entry.group}] ${JSON.stringify(entry.text)}`, () => {
      const actual = detectCriticalTokens(entry.text).map((token) => ({
        text: token.text,
        tokenClass: token.tokenClass,
        start: token.start,
        end: token.end,
      }));
      expect(actual).toEqual(entry.expected);
    });
  }
});

describe("detectCriticalTokens", () => {
  it("reports spans sliced from the original text, never rewritten (§0.5)", () => {
    const text = "Sağ böbrekte 0,5 mg IM adrenalin görülmemiştir";
    for (const token of detectCriticalTokens(text)) {
      expect(token.text).toBe(text.slice(token.start, token.end));
    }
  });

  it("finds the negation in ASCII-fied Turkish", () => {
    // The safety hole: an undetected negation cannot be compared at all, so
    // the passage reads as one that simply contains no negation.
    expect(containsCriticalToken("ilac kullanilmamalidir")).toBe(true);
  });

  it("does not match a route inside an ordinary word", () => {
    // JavaScript's \b is ASCII-based, so a naive port would find 'sağ' inside
    // 'kısağ' where Python does not. The generated boundary is Unicode-aware.
    for (const text of ["evim", "resim", "birim", "tedavim", "kısağ"]) {
      const classes = detectCriticalTokens(text).map((token) => token.tokenClass);
      expect(classes, text).not.toContain("route");
      expect(classes, text).not.toContain("laterality");
    }
  });

  it("keeps overlapping spans from different classes", () => {
    const classes = new Set(detectCriticalTokens("0,5 mg/kg").map((t) => t.tokenClass));
    expect(classes.has("number_decimal")).toBe(true);
    expect(classes.has("dose_frequency")).toBe(true);
  });

  it("returns nothing for empty input", () => {
    expect(detectCriticalTokens("")).toEqual([]);
    expect(detectCriticalTokens("   ")).toEqual([]);
  });

  it("is stable across repeated calls", () => {
    // A global regex carries `lastIndex`; sharing one between calls silently
    // skips matches on the second run.
    const text = "0,5 mg IM sağ";
    const first = detectCriticalTokens(text);
    const second = detectCriticalTokens(text);
    expect(second).toEqual(first);
    expect(first.length).toBeGreaterThan(0);
  });
});

describe("canonicalRoute", () => {
  it("folds every spelling of one route together", () => {
    for (const [code, surfaces] of Object.entries(ROUTE_SYNONYMS)) {
      for (const surface of surfaces) {
        expect(canonicalRoute(surface), `${surface} -> ${code}`).toBe(code);
      }
    }
  });

  it("never folds two different routes together", () => {
    const codes = Object.keys(ROUTE_SYNONYMS);
    const canonical = codes.map((code) => canonicalRoute(ROUTE_SYNONYMS[code]![0]!));
    expect(new Set(canonical).size).toBe(codes.length);
    // The pair that matters most.
    expect(canonicalRoute("IM")).not.toBe(canonicalRoute("IV"));
    expect(canonicalRoute("kas içi")).not.toBe(canonicalRoute("damar içi"));
  });

  it("matches case-insensitively", () => {
    expect(canonicalRoute("im")).toBe("IM");
    expect(canonicalRoute("Iv")).toBe("IV");
  });

  it("tolerates any run of whitespace inside a multi-word route", () => {
    expect(canonicalRoute("damar  içi")).toBe("IV");
    expect(canonicalRoute("  kas içi  ")).toBe("IM");
  });

  it("leaves an unknown value alone rather than merging it with a known route", () => {
    expect(canonicalRoute("epidural")).toBe("EPIDURAL");
    expect(isRouteSurface("epidural")).toBe(false);
  });
});

describe("turkish helpers", () => {
  it("lowercases with Turkish rules without changing length", () => {
    expect(turkishLower("İLAÇ")).toBe("ilaç");
    expect(turkishLower("IŞIK")).toBe("ışık");
    for (const text of ["İLAÇ", "IŞIK", "Sağ", "ÖĞÜN"]) {
      expect(turkishLower(text).length, text).toBe(text.length);
    }
  });

  it("folds diacritics one character to one", () => {
    expect(foldDiacritics("sağ")).toBe("sag");
    expect(foldDiacritics("görülmemiştir")).toBe("gorulmemistir");
    for (const text of ["sağ", "görülmemiştir", "İLAÇ", "ÖĞÜN"]) {
      expect(foldDiacritics(text).length, text).toBe(text.length);
    }
  });

  it("keeps left and right distinct after folding", () => {
    expect(foldDiacritics("sağ")).not.toBe(foldDiacritics("sol"));
  });

  it("normalizes only case, form and whitespace", () => {
    // Decimal separators and dashes survive: differences there are medically
    // meaningful (§10.5).
    expect(normalizeForCompare("  0,5  mg  ")).toBe("0,5 mg");
    expect(normalizeForCompare("0,5")).not.toBe(normalizeForCompare("0.5"));
  });
});

describe("generated pattern file", () => {
  it("carries every token class the reference declares", () => {
    expect(TOKEN_CLASSES).toContain("route");
    expect(TOKEN_CLASSES).toContain("negation_pair");
    expect(TOKEN_CLASSES.length).toBe(17);
  });

  it("has no leftover ASCII-only \\w or \\b", () => {
    // These are exactly the two constructs that mean something different in
    // JavaScript; if one survived the export, Turkish text would stop
    // matching and the detector would go quiet.
    const raw = readFileSync(
      fileURLToPath(new URL("../providers/criticalTokenPatterns.json", import.meta.url)),
      "utf-8",
    );
    const { patterns } = JSON.parse(raw) as { patterns: Array<{ source: string }> };
    for (const { source } of patterns) {
      expect(source).not.toMatch(/\\w/);
      expect(source).not.toMatch(/\\b/);
    }
  });
});
