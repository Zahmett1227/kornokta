import { describe, expect, it } from "vitest";

import { reconcile } from "../providers/reconcile.js";
import type { OCRLine, OCRPage } from "../providers/ocrTypes.js";

function page(lines: Array<[string, string, number?]>): OCRPage {
  return {
    imagePath: "job",
    imageWidth: 1600,
    imageHeight: 1200,
    recognitionLanguages: ["tr"],
    usesLanguageCorrection: false,
    engineVersion: "test",
    elapsedMs: 1,
    lines: lines.map(([lineId, text, confidence]): OCRLine => ({
      lineId,
      text,
      confidence: confidence ?? 0.97,
      x: 0.1,
      y: 0.1,
      width: 0.8,
      height: 0.04,
    })),
  };
}

const GOOGLE = page([
  ["line_00", "Anafilakside ilk seçenek tedavi"],
  ["line_01", "0,3–0,5 mg IM adrenalindir."],
]);

describe("reconcile", () => {
  it("auto-accepts when both engines read the same text", () => {
    const result = reconcile(GOOGLE, GOOGLE);
    expect(result.decision).toBe("auto_accept");
    expect(result.criticalLineIds).toEqual([]);
    expect(result.lines.every((line) => line.agrees)).toBe(true);
  });

  it("carries the primary engine's text forward, never a blend", () => {
    // §0.5: no silent merging. The stored text is one engine's reading.
    const apple = page([
      ["line_00", "Anafilakside ilk secenek tedavi"],
      ["line_01", "0,3–0,5 mg IM adrenalindir."],
    ]);
    const result = reconcile(GOOGLE, apple);
    expect(result.text).toBe("Anafilakside ilk seçenek tedavi\n0,3–0,5 mg IM adrenalindir.");
    expect(result.text).not.toContain("secenek");
  });

  describe("critical disagreements (§10.5, §19.2)", () => {
    it("asks about a route disagreement instead of recording it", () => {
      const apple = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,3–0,5 mg IV adrenalindir."],
      ]);
      const result = reconcile(GOOGLE, apple);
      expect(result.decision).toBe("quick_confirm");
      expect(result.criticalLineIds).toEqual(["line_01"]);
      expect(result.reason).toContain("IM");
      expect(result.reason).toContain("IV");
    });

    it("asks about a dose disagreement", () => {
      const apple = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,3–0,5 mg IM adrenalindir."],
      ]);
      const google = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,03–0,5 mg IM adrenalindir."],
      ]);
      const result = reconcile(google, apple);
      expect(result.decision).toBe("quick_confirm");
      expect(result.criticalLineIds).toContain("line_01");
    });

    it("asks about a negation disagreement", () => {
      const a = page([["line_00", "bu ilaç kullanılmalıdır"]]);
      const b = page([["line_00", "bu ilaç kullanılmamalıdır"]]);
      expect(reconcile(a, b).decision).toBe("quick_confirm");
    });

    it("asks even when the primary engine is confident", () => {
      // A confident reading of the wrong route is exactly the case the rule
      // exists for, so confidence must not short-circuit it.
      const apple = page([["line_00", "5 mg IV verilir", 0.99]]);
      const google = page([["line_00", "5 mg IM verilir", 0.99]]);
      const result = reconcile(google, apple);
      expect(result.decision).toBe("quick_confirm");
    });

    it("names the line, not just the page", () => {
      const apple = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,3–0,5 mg IV adrenalindir."],
      ]);
      const result = reconcile(GOOGLE, apple);
      // The user has to be pointed at one line, not asked to re-read the page.
      expect(result.criticalLineIds).toHaveLength(1);
      expect(result.lines.find((l) => l.lineId === "line_00")!.criticalTokenFlags).toEqual([]);
    });
  });

  describe("non-critical differences", () => {
    it("accepts a wording difference without interrupting", () => {
      // §24.2: few interruptions. A difference that changes no critical value
      // is recorded, not surfaced.
      const apple = page([
        ["line_00", "Anafilakside ilk secenek tedavi"],
        ["line_01", "0,3–0,5 mg IM adrenalindir."],
      ]);
      const result = reconcile(GOOGLE, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.lines[0]!.agrees).toBe(false);
      expect(result.lines[0]!.criticalTokenFlags).toEqual([]);
    });

    it("treats casing and spacing as agreement", () => {
      const apple = page([
        ["line_00", "ANAFILAKSIDE İLK SEÇENEK TEDAVİ"],
        ["line_01", "0,3–0,5  mg  IM  adrenalindir."],
      ]);
      const result = reconcile(GOOGLE, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.lines[1]!.agrees).toBe(true);
    });
  });

  describe("handwriting (§10.4)", () => {
    it("never auto-accepts, even when both engines agree", () => {
      // Two engines can be confidently wrong about the same scrawl.
      const result = reconcile(GOOGLE, GOOGLE, { handwrittenLineIds: ["line_01"] });
      expect(result.decision).toBe("quick_confirm");
      expect(result.reason).toContain("el yazısı");
    });
  });

  describe("confidence", () => {
    it("asks when the primary engine is unsure", () => {
      const low = page([["line_00", "belirsiz metin", 0.2]]);
      const result = reconcile(low, low);
      expect(result.decision).toBe("quick_confirm");
      expect(result.reason).toContain("güven");
    });

    it("uses the configured threshold, not a hardcoded one (§0.6)", () => {
      const line = page([["line_00", "orta güvenli metin", 0.6]]);
      expect(reconcile(line, line, { minPrimaryConfidence: 0.5 }).decision).toBe("auto_accept");
      expect(reconcile(line, line, { minPrimaryConfidence: 0.9 }).decision).toBe("quick_confirm");
    });
  });

  describe("no second opinion", () => {
    it("accepts but says the reading was not corroborated", () => {
      const result = reconcile(GOOGLE, null);
      expect(result.decision).toBe("auto_accept");
      expect(result.reason).toContain("ikinci görüş yok");
      expect(result.lines.every((line) => line.secondaryText === null)).toBe(true);
      expect(result.lines.every((line) => line.agrees === false)).toBe(true);
    });

    it("does not invent a disagreement with itself", () => {
      expect(reconcile(GOOGLE, null).criticalLineIds).toEqual([]);
    });
  });

  describe("rejection (§19.3)", () => {
    it("rejects a page with no lines", () => {
      const result = reconcile(page([]), null);
      expect(result.decision).toBe("reject");
    });

    it("rejects a page whose lines are all blank", () => {
      const result = reconcile(page([["line_00", "   "]]), null);
      expect(result.decision).toBe("reject");
    });
  });

  describe("line pairing", () => {
    it("pairs by lineId, not by position", () => {
      const apple = page([
        ["line_01", "0,3–0,5 mg IM adrenalindir."],
        ["line_00", "Anafilakside ilk seçenek tedavi"],
      ]);
      const result = reconcile(GOOGLE, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.lines.every((line) => line.agrees)).toBe(true);
    });

    it("handles a line the secondary engine did not find", () => {
      const apple = page([["line_00", "Anafilakside ilk seçenek tedavi"]]);
      const result = reconcile(GOOGLE, apple);
      expect(result.lines[1]!.secondaryText).toBeNull();
      expect(result.lines[1]!.agrees).toBe(false);
    });
  });
});
