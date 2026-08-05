import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { ConfigError, loadConfig } from "../config.js";

const KEYS = [
  "GOOGLE_PROJECT_ID",
  "DOCUMENTAI_LOCATION",
  "DOCUMENTAI_PROCESSOR_ID",
  "DOCUMENTAI_LANGUAGE_HINTS",
  "DOCUMENTAI_TIMEOUT_MS",
  "DOCUMENTAI_USD_PER_1000_PAGES",
  "MAX_USD_PER_RUN",
  "OPENAI_MODEL",
  "OPENAI_REASONING_EFFORT",
  "OPENAI_MAX_OUTPUT_TOKENS",
  "OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT",
  "OPENAI_TIMEOUT_MS",
  "OPENAI_USD_PER_MILLION_INPUT_TOKENS",
  "OPENAI_USD_PER_MILLION_OUTPUT_TOKENS",
  "GEMINI_MODEL",
  "GEMINI_MAX_OUTPUT_TOKENS",
  "GEMINI_TIMEOUT_MS",
  "GEMINI_USD_PER_MILLION_INPUT_TOKENS",
  "GEMINI_USD_PER_MILLION_OUTPUT_TOKENS",
  "MAX_USD_PER_CARD_GENERATION",
];

/** Read directly at the composition root, never through `loadConfig()` (§0.7). */
const CREDENTIAL_KEYS = ["GOOGLE_APPLICATION_CREDENTIALS", "OPENAI_API_KEY", "GEMINI_API_KEY"];

let saved: Record<string, string | undefined> = {};

beforeEach(() => {
  saved = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
  for (const key of KEYS) delete process.env[key];
  process.env.GOOGLE_PROJECT_ID = "kornokta";
  process.env.DOCUMENTAI_PROCESSOR_ID = "6213367b4c106c7e";
});

afterEach(() => {
  for (const key of KEYS) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
});

describe("loadConfig", () => {
  it("reads the required values", () => {
    const config = loadConfig();
    expect(config.documentAI.projectId).toBe("kornokta");
    expect(config.documentAI.processorId).toBe("6213367b4c106c7e");
  });

  it("defaults the location to eu", () => {
    expect(loadConfig().documentAI.location).toBe("eu");
    process.env.DOCUMENTAI_LOCATION = "us";
    expect(loadConfig().documentAI.location).toBe("us");
  });

  it("puts Turkish first in the default language hints", () => {
    // Not cosmetic: it is the language the source material is in and the one
    // Apple Vision cannot do (docs/FAZ0-BULGULAR.md).
    expect(loadConfig().documentAI.languageHints[0]).toBe("tr");
  });

  it("splits and trims language hints", () => {
    process.env.DOCUMENTAI_LANGUAGE_HINTS = " tr , en ,, de ";
    expect(loadConfig().documentAI.languageHints).toEqual(["tr", "en", "de"]);
  });

  it("names the variable that is missing", () => {
    delete process.env.GOOGLE_PROJECT_ID;
    expect(() => loadConfig()).toThrow(ConfigError);
    expect(() => loadConfig()).toThrow(/GOOGLE_PROJECT_ID/);
  });

  it("treats a blank value as missing", () => {
    process.env.DOCUMENTAI_PROCESSOR_ID = "   ";
    expect(() => loadConfig()).toThrow(/DOCUMENTAI_PROCESSOR_ID/);
  });

  it("rejects a non-numeric number rather than silently using NaN", () => {
    process.env.DOCUMENTAI_TIMEOUT_MS = "çok";
    expect(() => loadConfig()).toThrow(/DOCUMENTAI_TIMEOUT_MS/);
  });

  it("carries the §10.2 price reference as a changeable default", () => {
    expect(loadConfig().cost.usdPer1000Pages).toBe(1.5);
    process.env.DOCUMENTAI_USD_PER_1000_PAGES = "2.25";
    expect(loadConfig().cost.usdPer1000Pages).toBe(2.25);
  });

  it("does not read credentials into config", () => {
    // §0.7: the key is resolved by the Google library from
    // GOOGLE_APPLICATION_CREDENTIALS and never passes through our own code,
    // so it cannot reach a log line or an error message.
    process.env.GOOGLE_APPLICATION_CREDENTIALS = "/gizli/key.json";
    const serialized = JSON.stringify(loadConfig());
    expect(serialized).not.toContain("gizli");
    expect(serialized).not.toContain("key.json");
  });

  it("defaults the OpenAI card-generation settings from §11.3", () => {
    const { openai } = loadConfig();
    expect(openai.model).toBe("gpt-5.6-sol");
    // Faz 6/B3: "low" reasoning (medium/high timed out past Vercel's 60 s) with
    // "high" image detail for reading handwriting (config.ts note).
    expect(openai.reasoningEffort).toBe("low");
    expect(openai.imageDetail).toBe("high");
    // Faz 6/B3: raised for the vision flow (config.ts notes) — 8192 output
    // headroom for a densely-marked page, 12 cards per page (was 4/4096).
    expect(openai.maxOutputTokens).toBe(8192);
    expect(openai.maxCardsPerKnowledgeUnit).toBe(12);
  });

  it("lets the OpenAI model be swapped without a code change (§0.6, §27)", () => {
    process.env.OPENAI_MODEL = "gpt-5.6-sol-2026-09-01";
    expect(loadConfig().openai.model).toBe("gpt-5.6-sol-2026-09-01");
  });

  it("defaults the Gemini handwriting fallback settings", () => {
    expect(loadConfig().gemini.model).toBe("gemini-3.5-flash");
    // Not 700: a live call at 700 hit MAX_TOKENS before producing any output
    // (the model spends part of its budget on internal reasoning), so the
    // default has headroom above what the visible §15.3 payload needs.
    expect(loadConfig().gemini.maxOutputTokens).toBe(4096);
  });

  it("defaults per-token cost to 0 rather than a guessed price", () => {
    // No verified OpenAI/Gemini price exists for a model ANA-PLAN names ahead
    // of its own release; a fabricated number would look authoritative in a
    // cost log (§20.3).
    const { cost } = loadConfig();
    expect(cost.openaiUsdPerMillionInputTokens).toBe(0);
    expect(cost.openaiUsdPerMillionOutputTokens).toBe(0);
    expect(cost.geminiUsdPerMillionInputTokens).toBe(0);
    expect(cost.geminiUsdPerMillionOutputTokens).toBe(0);
    expect(cost.maxUsdPerCardGeneration).toBe(0);
  });

  it("never reads OPENAI_API_KEY or GEMINI_API_KEY into config", () => {
    // Same rule as GOOGLE_APPLICATION_CREDENTIALS above (§0.7): a provider key
    // is read directly at the composition root, never through this module.
    process.env.OPENAI_API_KEY = "sk-gizli-openai";
    process.env.GEMINI_API_KEY = "gizli-gemini";
    const serialized = JSON.stringify(loadConfig());
    expect(serialized).not.toContain("gizli");
    delete process.env.OPENAI_API_KEY;
    delete process.env.GEMINI_API_KEY;
  });
});

describe(".env.example", () => {
  it("documents every variable loadConfig reads", async () => {
    // A variable that exists in code but not in the template is one nobody
    // knows to set; the failure then looks like a bug rather than a missing
    // setting.
    const { readFile } = await import("node:fs/promises");
    const { fileURLToPath } = await import("node:url");
    const template = await readFile(
      fileURLToPath(new URL("../.env.example", import.meta.url)),
      "utf-8",
    );
    for (const key of [...KEYS, ...CREDENTIAL_KEYS]) {
      expect(template, `${key} .env.example içinde yok`).toContain(key);
    }
  });

  it("carries no credential value", async () => {
    const { readFile } = await import("node:fs/promises");
    const { fileURLToPath } = await import("node:url");
    const template = await readFile(
      fileURLToPath(new URL("../.env.example", import.meta.url)),
      "utf-8",
    );
    for (const key of CREDENTIAL_KEYS) {
      const credentialLine = template.split("\n").find((line) => line.startsWith(`${key}=`));
      expect(credentialLine, `${key} boş bir şablon satırı olmalı`).toBe(`${key}=`);
    }
    expect(template).not.toContain("private_key");
    expect(template).not.toContain("BEGIN PRIVATE KEY");
    expect(template).not.toContain("sk-");
  });
});
