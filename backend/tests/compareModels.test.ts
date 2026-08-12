import { describe, expect, it } from "vitest";

import { labelOrder, parseModelSpec } from "../scripts/compareModels.js";

const FALLBACK = {
  openaiUsdPerMillionInputTokens: 5,
  openaiUsdPerMillionCachedInputTokens: 0.5,
  openaiUsdPerMillionOutputTokens: 30,
};

const MODELS = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"];

describe("labelOrder — kör puanlamanın kendisi", () => {
  it("permutes the labels independently per page", () => {
    // The property the whole blinding rests on. With one fixed order the sheet
    // is blind for exactly one page: the tiers produce visibly different card
    // counts, so by the third page the reader has worked out which letter is
    // the expensive model and every judgement after that is unblinded — without
    // them noticing, which is the worst kind.
    const pages = ["s01.jpg", "s02.jpg", "s03.jpg", "s04.jpg", "s05.jpg", "s06.jpg"];
    const positions = pages.map(
      (page) => labelOrder(page, MODELS).find((entry) => entry.model === "gpt-5.6-sol")!.label,
    );
    expect(new Set(positions).size).toBeGreaterThan(1);
  });

  it("is stable for the same page, so a re-run is the same experiment", () => {
    // Re-reading a sheet after a crash has to be the same experiment, not a new
    // one — otherwise half-finished scoring silently mixes two blindings.
    expect(labelOrder("s01.jpg", MODELS)).toEqual(labelOrder("s01.jpg", MODELS));
  });

  it("gives every model exactly one label, and every label exactly one model", () => {
    const order = labelOrder("s01.jpg", MODELS);
    expect(order.map((entry) => entry.label)).toEqual(["A", "B", "C"]);
    expect(new Set(order.map((entry) => entry.model))).toEqual(new Set(MODELS));
  });

  it("does not depend on the order the models were listed on the command line", () => {
    // Otherwise `--models "sol,terra"` and `--models "terra,sol"` would be
    // different experiments, and the label would leak the argument order.
    const forward = labelOrder("s01.jpg", MODELS);
    const backward = labelOrder("s01.jpg", [...MODELS].reverse());
    expect(backward).toEqual(forward);
  });
});

describe("parseModelSpec — fiyatlar", () => {
  it("reads per-model prices", () => {
    const spec = parseModelSpec("gpt-5.6-terra:2/0.2/12", FALLBACK);
    expect(spec.model).toBe("gpt-5.6-terra");
    expect(spec.pricesInherited).toBe(false);
    expect(spec.prices).toEqual({
      openaiUsdPerMillionInputTokens: 2,
      openaiUsdPerMillionCachedInputTokens: 0.2,
      openaiUsdPerMillionOutputTokens: 12,
    });
  });

  it("flags a model that fell back to the deployment's single price set", () => {
    // Silently inheriting would produce a report saying the cheap tier costs
    // the same as the expensive one — worse than no report at all.
    const spec = parseModelSpec("gpt-5.6-luna", FALLBACK);
    expect(spec.pricesInherited).toBe(true);
    expect(spec.prices).toEqual(FALLBACK);
  });

  it("refuses a malformed or negative price rather than guessing", () => {
    expect(() => parseModelSpec("gpt-5.6-terra:2/12", FALLBACK)).toThrow(/girdi\/önbellek\/çıktı/);
    expect(() => parseModelSpec("gpt-5.6-terra:2/x/12", FALLBACK)).toThrow();
    expect(() => parseModelSpec("gpt-5.6-terra:2/-1/12", FALLBACK)).toThrow();
    expect(() => parseModelSpec(":5/0.5/30", FALLBACK)).toThrow(/Model adı boş/);
  });
});
