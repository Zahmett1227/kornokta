import { describe, expect, it } from "vitest";

import { experimentCardCeiling, labelOrder, parseModelSpec } from "../scripts/compareModels.js";

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
      (page) => labelOrder(page, MODELS).find((entry) => entry.id === "gpt-5.6-sol")!.label,
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
    expect(new Set(order.map((entry) => entry.id))).toEqual(new Set(MODELS));
  });

  it("does not depend on the order the models were listed on the command line", () => {
    // Otherwise `--models "sol,terra"` and `--models "terra,sol"` would be
    // different experiments, and the label would leak the argument order.
    const forward = labelOrder("s01.jpg", MODELS);
    const backward = labelOrder("s01.jpg", [...MODELS].reverse());
    expect(backward).toEqual(forward);
  });
});

describe("parseModelSpec — @effort kolları", () => {
  it("gives an effort arm its own identity while sending the plain model id", () => {
    // The two halves that must not be confused: `id` is what the blind sheet,
    // the key and the report rows key off; `model` is what actually goes to
    // the provider. Sending "gpt-5.6-luna@high" as a model id would 404.
    const spec = parseModelSpec("gpt-5.6-luna@high:0.2/0.02/1.2", FALLBACK);
    expect(spec.id).toBe("gpt-5.6-luna@high");
    expect(spec.model).toBe("gpt-5.6-luna");
    expect(spec.effort).toBe("high");
  });

  it("leaves effort undefined when none is given, so the deployment's own is used", () => {
    const spec = parseModelSpec("gpt-5.6-luna:0.2/0.02/1.2", FALLBACK);
    expect(spec.effort).toBeUndefined();
    expect(spec.id).toBe("gpt-5.6-luna");
  });

  it("rejects an empty effort rather than silently dropping the @", () => {
    expect(() => parseModelSpec("gpt-5.6-luna@:0.2/0.02/1.2", FALLBACK)).toThrow(/effort boş/);
  });

  it("keeps two efforts of one model on separate labels", () => {
    // The failure this guards: with identity keyed on the model name, both
    // arms hash to the same value, the key maps every letter to one name and
    // the blind sheet becomes unreadable — while still looking perfectly fine.
    const ids = ["gpt-5.6-luna@low", "gpt-5.6-luna@high"];
    const order = labelOrder("s01.jpg", ids);
    expect(order.map((entry) => entry.label)).toEqual(["A", "B"]);
    expect(new Set(order.map((entry) => entry.id))).toEqual(new Set(ids));
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

describe("experimentCardCeiling", () => {
  it("honours a ceiling above the deployment's own", () => {
    // The generator clamps a *request* down to the deployment's configured
    // ceiling, so `--max-cards 20` against a deployment set to 12 would have
    // run at 12 while the report claimed 20. Silent, and exactly the shape of
    // the bug that left "sayfa başına kart" doing nothing for two phases.
    expect(experimentCardCeiling(20, 12)).toBe(20);
  });

  it("falls back to the deployment's ceiling when none was asked for", () => {
    expect(experimentCardCeiling(undefined, 12)).toBe(12);
  });

  it("allows a lower ceiling too", () => {
    expect(experimentCardCeiling(4, 12)).toBe(4);
  });
});
