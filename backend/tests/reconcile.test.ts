import { describe, expect, it } from "vitest";

import { reconcile } from "../providers/reconcile.js";
import type { OCRLine, OCRPage } from "../providers/ocrTypes.js";

/**
 * Each line gets a distinct vertical band derived from its index, so pairing
 * has real geometry to work with. An earlier version gave every line the same
 * box, which left the pairing tests unable to tell a correct pairing from a
 * wrong one.
 */
function page(lines: Array<[string, string, number?]>): OCRPage {
  return {
    imagePath: "job",
    imageWidth: 1600,
    imageHeight: 1200,
    recognitionLanguages: ["tr"],
    usesLanguageCorrection: false,
    engineVersion: "test",
    elapsedMs: 1,
    lines: lines.map(([lineId, text, confidence], index): OCRLine => ({
      lineId,
      text,
      confidence: confidence ?? 0.97,
      x: 0.1,
      y: 0.1 + index * 0.1,
      width: 0.8,
      height: 0.05,
    })),
  };
}

/** A page whose lines sit exactly where the third element says. */
function positioned(entries: Array<[string, string, number]>): OCRPage {
  const base = page(entries.map(([id, text]) => [id, text] as [string, string]));
  return {
    ...base,
    lines: base.lines.map((line, index) => ({ ...line, y: entries[index]![2] })),
  };
}

/** A page with no geometry at all, as a text-only caller would send. */
function flat(lines: Array<[string, string]>): OCRPage {
  const base = page(lines);
  return {
    ...base,
    lines: base.lines.map((line) => ({ ...line, x: 0, y: 0, width: 0, height: 0 })),
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

  describe("Apple-vs-Google disagreements no longer gate (ADR-002)", () => {
    // Apple Vision cannot write Turkish, so it is not a second opinion worth
    // interrupting the user for — the on-screen "kaynak"/"okuma" wording used
    // to name Apple's reading as "kaynak" (gold) and Google's as "okuma"
    // (hypothesis), exactly backwards from which engine is trustworthy, and
    // *any* disagreement (critical-looking or not) blocked the page. Both are
    // fixed here: the direction is corrected (asserted below) and disagreeing
    // no longer blocks — it is recorded (`criticalLineIds`,
    // `lines[].criticalTokenFlags`) for audit, and the real safety net for a
    // card's actual content is `cardGate` checking each card's own
    // `sourceQuote` (§19), independent of this OCR-level comparison.

    it("records a route disagreement but still accepts", () => {
      const apple = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,3–0,5 mg IV adrenalindir."],
      ]);
      const result = reconcile(GOOGLE, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.criticalLineIds).toEqual(["line_01"]);
      // "kaynak" names Google's (primary, trustworthy) reading, "okuma"
      // names Apple's — not the other way around.
      expect(result.lines[1]!.criticalTokenFlags[0]).toContain("kaynak [IM");
      expect(result.lines[1]!.criticalTokenFlags[0]).toContain("okuma [IV");
      // The passage carried forward is still Google's, regardless.
      expect(result.text).toContain("IM adrenalindir");
    });

    it("records a dose disagreement but still accepts", () => {
      const apple = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,3–0,5 mg IM adrenalindir."],
      ]);
      const google = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,03–0,5 mg IM adrenalindir."],
      ]);
      const result = reconcile(google, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.criticalLineIds).toContain("line_01");
    });

    it("records a negation disagreement but still accepts", () => {
      const a = page([["line_00", "bu ilaç kullanılmalıdır"]]);
      const b = page([["line_00", "bu ilaç kullanılmamalıdır"]]);
      const result = reconcile(a, b);
      expect(result.decision).toBe("auto_accept");
      expect(result.criticalLineIds).toEqual(["line_00"]);
    });

    it("does not gate on a suffix OCR typo of the same hipo/hiper polarity", () => {
      // Regression for the exact production case: Apple dropping a letter in
      // "hipersensitivite" must not read as a hipo<->hiper flip.
      const google = page([["line_00", "Tip 4 hipersensitivite örnekleri"]]);
      const apple = page([["line_00", "Tip 4 hipersenstvite örnekleri"]]);
      const result = reconcile(google, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.criticalLineIds).toEqual([]);
    });

    it("names the line, not just the page", () => {
      const apple = page([
        ["line_00", "Anafilakside ilk seçenek tedavi"],
        ["line_01", "0,3–0,5 mg IV adrenalindir."],
      ]);
      const result = reconcile(GOOGLE, apple);
      // Still pointed at one line for audit, even though it no longer blocks.
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
    it("pairs by where a line sits, not by its id", () => {
      // The engines number their own lines independently and do not find the
      // same number of them — on the Faz 0 test page Google found 156 where
      // Vision found 148. Here the ids are deliberately wrong relative to
      // position: pairing by id would compare the dose line against the
      // heading and report a disagreement that does not exist.
      const apple = positioned([
        ["line_99", "Anafilakside ilk seçenek tedavi", 0.1],
        ["line_00", "0,3–0,5 mg IM adrenalindir.", 0.2],
      ]);
      const result = reconcile(GOOGLE, apple);
      expect(result.decision).toBe("auto_accept");
      expect(result.lines.every((line) => line.agrees)).toBe(true);
      expect(result.criticalLineIds).toEqual([]);
    });

    it("does not pair lines that sit in different places", () => {
      const elsewhere = positioned([["line_00", "bambaşka bir satır", 0.8]]);
      const result = reconcile(GOOGLE, elsewhere);
      // Nothing overlaps, so nothing pairs — and an unpaired line has no
      // second opinion rather than a disagreement.
      expect(result.lines.every((line) => line.secondaryText === null)).toBe(true);
      expect(result.criticalLineIds).toEqual([]);
    });

    it("gives each secondary line to at most one primary line", () => {
      const google = positioned([
        ["line_00", "birinci satır", 0.10],
        ["line_01", "ikinci satır", 0.16],
      ]);
      const apple = positioned([["a", "birinci satır", 0.11]]);
      const result = reconcile(google, apple);
      const paired = result.lines.filter((line) => line.secondaryText !== null);
      expect(paired).toHaveLength(1);
    });

    it("falls back to ids when neither side carries geometry", () => {
      const result = reconcile(flat([["line_00", "0,5 mg IM"]]), flat([["line_00", "0,5 mg IV"]]));
      // Pairing still finds the disagreement (recorded in criticalLineIds);
      // it no longer blocks (ADR-002 — Apple is not a second opinion).
      expect(result.decision).toBe("auto_accept");
      expect(result.criticalLineIds).toEqual(["line_00"]);
    });

    it("handles a line the secondary engine did not find", () => {
      const apple = page([["line_00", "Anafilakside ilk seçenek tedavi"]]);
      const result = reconcile(GOOGLE, apple);
      expect(result.lines[1]!.secondaryText).toBeNull();
      expect(result.lines[1]!.agrees).toBe(false);
    });
  });
});
