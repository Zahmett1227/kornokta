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
];

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
    for (const key of [...KEYS, "GOOGLE_APPLICATION_CREDENTIALS"]) {
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
    const credentialLine = template
      .split("\n")
      .find((line) => line.startsWith("GOOGLE_APPLICATION_CREDENTIALS="));
    expect(credentialLine).toBe("GOOGLE_APPLICATION_CREDENTIALS=");
    expect(template).not.toContain("private_key");
    expect(template).not.toContain("BEGIN PRIVATE KEY");
  });
});
