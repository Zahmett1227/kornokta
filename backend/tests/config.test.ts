import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { ConfigError, loadConfig } from "../config.js";

const KEYS = [
  "OPENAI_MODEL",
  "OPENAI_REASONING_EFFORT",
  "OPENAI_IMAGE_DETAIL",
  "OPENAI_MAX_OUTPUT_TOKENS",
  "OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT",
  "OPENAI_TIMEOUT_MS",
  "OPENAI_USD_PER_MILLION_INPUT_TOKENS",
  "OPENAI_USD_PER_MILLION_OUTPUT_TOKENS",
  "OPENAI_USD_PER_MILLION_CACHED_INPUT_TOKENS",
  "MAX_USD_PER_CARD_GENERATION",
  "GEMINI_MODEL",
  "GEMINI_MAX_OUTPUT_TOKENS",
  "GEMINI_COVERAGE_MAX_OUTPUT_TOKENS",
  "GEMINI_TIMEOUT_MS",
  "GEMINI_USD_PER_MILLION_INPUT_TOKENS",
  "GEMINI_USD_PER_MILLION_OUTPUT_TOKENS",
  "GEMINI_USD_PER_MILLION_CACHED_INPUT_TOKENS",
  "DARK_MAP_MAX_ZONES",
  "DARK_MAP_MAX_SAMPLE_FRONTS",
  "DARK_MAP_REASONING_EFFORT",
  "DARK_MAP_MAX_OUTPUT_TOKENS",
  "DARK_MAP_TIMEOUT_MS",
  "SUPABASE_URL",
  "SUPABASE_BUCKET",
  "SUPABASE_TIMEOUT_MS",
  "SUPABASE_JOB_STALE_AFTER_MS",
  "SUPABASE_RESULT_RETENTION_MS",
];

/** Read directly at the composition root, never through `loadConfig()` (§0.7). */
const CREDENTIAL_KEYS = ["OPENAI_API_KEY", "GEMINI_API_KEY", "SUPABASE_SERVICE_ROLE_KEY"];

let saved: Record<string, string | undefined> = {};

beforeEach(() => {
  saved = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
  for (const key of KEYS) delete process.env[key];
});

afterEach(() => {
  for (const key of KEYS) {
    if (saved[key] === undefined) delete process.env[key];
    else process.env[key] = saved[key];
  }
});

describe("loadConfig", () => {
  it("rejects a non-numeric number rather than silently using NaN", () => {
    process.env.OPENAI_TIMEOUT_MS = "çok";
    expect(() => loadConfig()).toThrow(ConfigError);
    expect(() => loadConfig()).toThrow(/OPENAI_TIMEOUT_MS/);
  });

  it("refuses a zero or negative staleness window instead of reclaiming live workers", () => {
    // The worst of the non-positive typos: at 0 every `processing` row looks
    // dead the instant it is claimed, so each poll hands the page to a second
    // paid generation racing the first.
    for (const bad of ["0", "-1"]) {
      process.env.SUPABASE_JOB_STALE_AFTER_MS = bad;
      expect(() => loadConfig(), bad).toThrow(/SUPABASE_JOB_STALE_AFTER_MS/);
    }
  });

  it("refuses a non-positive timeout or token ceiling", () => {
    process.env.OPENAI_TIMEOUT_MS = "0";
    expect(() => loadConfig()).toThrow(/OPENAI_TIMEOUT_MS/);
    delete process.env.OPENAI_TIMEOUT_MS;

    process.env.OPENAI_MAX_OUTPUT_TOKENS = "0";
    expect(() => loadConfig()).toThrow(/OPENAI_MAX_OUTPUT_TOKENS/);
  });

  it("refuses a non-positive result retention window", () => {
    // At 0 every finished row would be eligible for deletion the moment it was
    // written, racing the phone that was about to collect it.
    process.env.SUPABASE_RESULT_RETENTION_MS = "0";
    expect(() => loadConfig()).toThrow(/SUPABASE_RESULT_RETENTION_MS/);
  });

  it("still allows 0 for the cost ceilings, where it documents 'disabled'", () => {
    process.env.MAX_USD_PER_CARD_GENERATION = "0";
    expect(loadConfig().cost.maxUsdPerCardGeneration).toBe(0);
    // Negative is still a typo, not a setting.
    process.env.MAX_USD_PER_CARD_GENERATION = "-1";
    expect(() => loadConfig()).toThrow(/MAX_USD_PER_CARD_GENERATION/);
  });

  it("defaults the OpenAI card-generation settings from §11.3", () => {
    const { openai } = loadConfig();
    expect(openai.model).toBe("gpt-5.6-sol");
    // Faz 6/B3: "low" reasoning (medium/high timed out past Vercel's 60 s) with
    // "high" image detail for reading handwriting (config.ts note).
    expect(openai.reasoningEffort).toBe("low");
    expect(openai.imageDetail).toBe("high");
    // Faz 6/B3: raised for the vision flow (config.ts notes) — 12288 output
    // headroom for a densely-marked page, 18 cards per page (was 4/4096, then 12/8192).
    expect(openai.maxOutputTokens).toBe(12288);
    expect(openai.maxCardsPerKnowledgeUnit).toBe(18);
  });

  it("lets the OpenAI model be swapped without a code change (§0.6, §27)", () => {
    process.env.OPENAI_MODEL = "gpt-5.6-sol-2026-09-01";
    expect(loadConfig().openai.model).toBe("gpt-5.6-sol-2026-09-01");
  });

  it("defaults per-token cost to 0 rather than a guessed price", () => {
    // No verified OpenAI price exists for a model ANA-PLAN names ahead of its
    // own release; a fabricated number would look authoritative in a cost log
    // (§20.3).
    const { cost } = loadConfig();
    expect(cost.openaiUsdPerMillionInputTokens).toBe(0);
    expect(cost.openaiUsdPerMillionOutputTokens).toBe(0);
    expect(cost.maxUsdPerCardGeneration).toBe(0);
  });

  it("leaves the job queue off until SUPABASE_URL is set (docs/ADR-006)", () => {
    // Optional on purpose: with no URL, `/api/cards-vision` must keep working
    // exactly as before and only `/api/jobs` refuse. A `required()` here would
    // make `loadConfig()` throw for endpoints that have nothing to do with the
    // queue.
    expect(loadConfig().supabase.url).toBe("");
    process.env.SUPABASE_URL = "https://abcd.supabase.co";
    expect(loadConfig().supabase.url).toBe("https://abcd.supabase.co");
  });

  it("holds a job open longer than the platform's own function ceiling", () => {
    // `vercel.json` allows 300 s. Reclaiming below that would kill a worker
    // that was merely slow and was still going to answer.
    expect(loadConfig().supabase.staleAfterMs).toBeGreaterThan(300_000);
    expect(loadConfig().supabase.bucket).toBe("page-uploads");
  });

  it("keeps finished results for 60 days by default (docs/PRIVACY.md)", () => {
    expect(loadConfig().supabase.resultRetentionMs).toBe(60 * 24 * 60 * 60 * 1000);
  });

  it("never reads SUPABASE_SERVICE_ROLE_KEY into config", () => {
    // Same rule as every other credential (§0.7). This one matters most: it
    // bypasses row-level security entirely.
    process.env.SUPABASE_SERVICE_ROLE_KEY = "gizli-service-role";
    const serialized = JSON.stringify(loadConfig());
    expect(serialized).not.toContain("gizli");
    delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  });

  it("never reads OPENAI_API_KEY into config", () => {
    // A provider key is read directly at the composition root, never through
    // this module (§0.7).
    process.env.OPENAI_API_KEY = "sk-gizli-openai";
    const serialized = JSON.stringify(loadConfig());
    expect(serialized).not.toContain("gizli");
    delete process.env.OPENAI_API_KEY;
  });

  it("never reads GEMINI_API_KEY into config", () => {
    process.env.GEMINI_API_KEY = "g-gizli-gemini";
    const serialized = JSON.stringify(loadConfig());
    expect(serialized).not.toContain("gizli");
    delete process.env.GEMINI_API_KEY;
  });

  it("defaults the Gemini second-opinion settings (2026-08-11)", () => {
    const { gemini, cost } = loadConfig();
    // Flash tier on purpose: one region's transcription+comparison, not card
    // generation (config.ts notes).
    expect(gemini.model).toBe("gemini-3.5-flash");
    // Generous next to the short visible answer — hidden thinking tokens are
    // spent from this same budget (the status:"incomplete" lesson).
    expect(gemini.maxOutputTokens).toBe(4096);
    // The coverage audit has its own, bigger ceiling: a register of every mark
    // on a dense page with a verbatim quote each is a far longer answer than a
    // verdict plus one reading (docs/PLAN-kapsama-sozlesmesi.md, Katman B).
    expect(gemini.coverageMaxOutputTokens).toBe(8192);
    expect(gemini.timeoutMs).toBe(60_000);
    // Same rule as the OpenAI pair: 0 until a verified price is filled in.
    expect(cost.geminiUsdPerMillionInputTokens).toBe(0);
    expect(cost.geminiUsdPerMillionOutputTokens).toBe(0);
  });

  it("lets the Gemini model be swapped without a code change (§0.6)", () => {
    process.env.GEMINI_MODEL = "gemini-3.5-pro";
    expect(loadConfig().gemini.model).toBe("gemini-3.5-pro");
  });

  it("defaults the Karanlık Harita settings (docs/ADR-009)", () => {
    const { darkMap } = loadConfig();
    // A study order, not an inventory: a ranking long enough to include every
    // thin topic is the coverage table again, and two model calls should buy
    // *fewer* rows than the table has.
    expect(darkMap.maxZones).toBe(12);
    expect(darkMap.maxSampleFronts).toBe(4);
    expect(darkMap.reasoningEffort).toBe("medium");
    expect(darkMap.maxOutputTokens).toBe(16384);
    expect(darkMap.timeoutMs).toBe(120_000);
  });

  /**
   * The block exists precisely so a capture-pipeline retune cannot silently
   * retune a call that shares nothing with it but the vendor. If these ever
   * start reading the OPENAI_* variables, that separation is gone.
   */
  it("keeps the dark map's budget independent of the capture pipeline's", () => {
    process.env.OPENAI_MAX_OUTPUT_TOKENS = "48000";
    process.env.OPENAI_REASONING_EFFORT = "high";
    const { darkMap, openai } = loadConfig();
    expect(openai.maxOutputTokens).toBe(48_000);
    expect(darkMap.maxOutputTokens).toBe(16384);
    expect(darkMap.reasoningEffort).toBe("medium");
  });

  it("lets sampling be turned off entirely, leaving a pure counts table", () => {
    process.env.DARK_MAP_MAX_SAMPLE_FRONTS = "0";
    expect(loadConfig().darkMap.maxSampleFronts).toBe(0);
  });

  it("refuses a zero zone ceiling, which would ask for a ranking of nothing", () => {
    process.env.DARK_MAP_MAX_ZONES = "0";
    expect(() => loadConfig()).toThrow(/DARK_MAP_MAX_ZONES/);
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

  it("pins the OpenAI runtime values to the code defaults (no silent drift)", async () => {
    // Codex (PR #22) caught this: the template pinned OPENAI_TIMEOUT_MS=60000
    // while the code default had moved to 290000. Because the value is an env
    // *override*, every setup seeded from this template — a local `.env`, the
    // Vercel deployment — silently kept the old 60 s ceiling and the timeout
    // fix never took effect. These are values a reader copies verbatim, so the
    // template must equal loadConfig()'s default; lock them together so the
    // next drift breaks here instead of in production.
    const { readFile } = await import("node:fs/promises");
    const { fileURLToPath } = await import("node:url");
    const template = await readFile(
      fileURLToPath(new URL("../.env.example", import.meta.url)),
      "utf-8",
    );
    const { openai, gemini } = loadConfig();
    const pinned: Record<string, string | number> = {
      OPENAI_MODEL: openai.model,
      OPENAI_REASONING_EFFORT: openai.reasoningEffort,
      OPENAI_IMAGE_DETAIL: openai.imageDetail,
      OPENAI_MAX_OUTPUT_TOKENS: openai.maxOutputTokens,
      OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT: openai.maxCardsPerKnowledgeUnit,
      OPENAI_TIMEOUT_MS: openai.timeoutMs,
      // Same drift risk for the Gemini block: these are values a reader
      // copies verbatim into a real .env / Vercel.
      GEMINI_MODEL: gemini.model,
      GEMINI_MAX_OUTPUT_TOKENS: gemini.maxOutputTokens,
      GEMINI_COVERAGE_MAX_OUTPUT_TOKENS: gemini.coverageMaxOutputTokens,
      GEMINI_TIMEOUT_MS: gemini.timeoutMs,
    };
    const lines = template.split("\n");
    for (const [key, value] of Object.entries(pinned)) {
      const line = lines.find((l) => l.startsWith(`${key}=`));
      expect(line, `${key} .env.example içinde yok`).toBeDefined();
      expect(line, `${key} şablonda kod varsayılanından farklı`).toBe(`${key}=${value}`);
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

describe("cached-input pricing", () => {
  it("falls back to the uncached input price, not to zero", () => {
    // Every other price here defaults to 0 under §0.6 ("never invent a
    // number"). This one must not: a large share of a repeated prompt is
    // served from cache, so a 0 default would make most of the input free in
    // our books and put the Kullanım total well under the real invoice — the
    // exact under-reporting the per-call ledger exists to end. Erring high is
    // the safe direction.
    process.env.OPENAI_USD_PER_MILLION_INPUT_TOKENS = "5";
    process.env.GEMINI_USD_PER_MILLION_INPUT_TOKENS = "1.25";

    const config = loadConfig();

    expect(config.cost.openaiUsdPerMillionCachedInputTokens).toBe(5);
    expect(config.cost.geminiUsdPerMillionCachedInputTokens).toBe(1.25);
  });

  it("uses the configured cached price when one is given", () => {
    process.env.OPENAI_USD_PER_MILLION_INPUT_TOKENS = "5";
    process.env.OPENAI_USD_PER_MILLION_CACHED_INPUT_TOKENS = "0.5";

    expect(loadConfig().cost.openaiUsdPerMillionCachedInputTokens).toBe(0.5);
  });

  it("still rejects a negative cached price like every other one", () => {
    process.env.OPENAI_USD_PER_MILLION_CACHED_INPUT_TOKENS = "-1";
    expect(() => loadConfig()).toThrow(ConfigError);
  });
});
