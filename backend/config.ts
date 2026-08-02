/**
 * Central configuration (ANA-PLAN §0.6).
 *
 * Everything that could reasonably change — provider ids, regions, language
 * hints, timeouts, cost ceilings — is read from the environment here and
 * nowhere else. No module reads `process.env` directly, so there is exactly
 * one place to look when a value needs changing and exactly one place that can
 * be wrong.
 *
 * Credentials are deliberately absent from this file's return value. They are
 * resolved by the Google auth library from `GOOGLE_APPLICATION_CREDENTIALS`,
 * so a key never passes through our own code and cannot end up in a log line
 * or an error message (§0.7, §7.3).
 */

export interface DocumentAIConfig {
  /** Google Cloud project id, e.g. 'kornokta'. Not a secret. */
  projectId: string;
  /** Processor location: 'eu', 'us', ... Decides which endpoint host is used. */
  location: string;
  /** Processor id from the Document AI console. Not a secret. */
  processorId: string;
  /**
   * Language hints passed to the OCR engine. Turkish is first because that is
   * what the source material is; Apple Vision cannot do Turkish at all, which
   * is why this provider exists (docs/ADR-002-birincil-ocr-secimi.md).
   */
  languageHints: string[];
  /** Per-request timeout in milliseconds. */
  timeoutMs: number;
}

export interface CostConfig {
  /**
   * Price reference from ANA-PLAN §10.2 (1 Aug 2026): ~1.50 USD per 1000
   * pages. Kept configurable because the number in the spec is explicitly a
   * reference, not a contract.
   */
  usdPer1000Pages: number;
  /** Refuse to start a run that would exceed this. 0 disables the check. */
  maxUsdPerRun: number;
}

export interface Config {
  documentAI: DocumentAIConfig;
  cost: CostConfig;
}

class ConfigError extends Error {}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new ConfigError(
      `Eksik ortam değişkeni: ${name}. backend/.env.example dosyasına bak.`,
    );
  }
  return value;
}

function optional(name: string, fallback: string): string {
  const value = process.env[name]?.trim();
  return value ? value : fallback;
}

function numeric(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new ConfigError(`${name} sayı olmalı, alınan: ${raw}`);
  }
  return value;
}

/**
 * Reads configuration from the environment.
 *
 * Called explicitly rather than evaluated at import time so that importing a
 * module — in a test, say — never fails on a missing variable.
 */
export function loadConfig(): Config {
  return {
    documentAI: {
      projectId: required("GOOGLE_PROJECT_ID"),
      location: optional("DOCUMENTAI_LOCATION", "eu"),
      processorId: required("DOCUMENTAI_PROCESSOR_ID"),
      languageHints: optional("DOCUMENTAI_LANGUAGE_HINTS", "tr,en")
        .split(",")
        .map((hint) => hint.trim())
        .filter(Boolean),
      timeoutMs: numeric("DOCUMENTAI_TIMEOUT_MS", 60_000),
    },
    cost: {
      usdPer1000Pages: numeric("DOCUMENTAI_USD_PER_1000_PAGES", 1.5),
      maxUsdPerRun: numeric("MAX_USD_PER_RUN", 0),
    },
  };
}

export { ConfigError };
