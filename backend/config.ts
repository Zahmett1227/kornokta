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
  /**
   * Requests Document AI's paid font-style add-on. Disabled by default until
   * the configured Enterprise OCR processor version and billing impact have
   * been verified in the owning Google project.
   */
  computeStyleInfo?: boolean;
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
  /**
   * Per-token pricing for cost estimation (§20.3, §16.8 `estimatedCostUSD`).
   * Default 0 rather than a guessed figure: no verified price exists for a
   * model this spec names ahead of its own release, and a fabricated number
   * would look authoritative in a cost log. Fill in from the provider's own
   * pricing page once known — same "reference, not contract" caveat as
   * `usdPer1000Pages` above.
   */
  openaiUsdPerMillionInputTokens: number;
  openaiUsdPerMillionOutputTokens: number;
  geminiUsdPerMillionInputTokens: number;
  geminiUsdPerMillionOutputTokens: number;
  /** Refuse to start a card-generation call that would exceed this. 0 disables the check. */
  maxUsdPerCardGeneration: number;
}

export interface OpenAIConfig {
  /** Model id (§11.3). Never hardcoded at the call site (§0.6). */
  model: string;
  /** Passed through to the Responses API verbatim; not validated here. */
  reasoningEffort: string;
  /**
   * `input_image` detail: "low" | "high" | "auto". Faz 6/B3 needs "high" so the
   * model tiles the full page at resolution and can actually read faint margin
   * handwriting and thin highlighter strokes (docs/FAZ6-PLAN.md §5.2). Costs
   * more input tokens; env-overridable (§0.6).
   */
  imageDetail: string;
  /**
   * §20.3's reference number (700) is the visible-card budget; it does not
   * cover a reasoning-capable model's own hidden reasoning tokens, which are
   * spent from the same ceiling. Confirmed live: a real call failed with
   * `status: "incomplete"` at 700 and produced one real card comfortably
   * (571 output tokens used) at 4096. Kept configurable, not baked in
   * (§0.6) — this is a cost/product tradeoff, not just an implementation
   * default, and should be revisited once real per-token pricing is filled
   * in (`OPENAI_USD_PER_MILLION_*`, currently 0).
   */
  maxOutputTokens: number;
  /**
   * §11.3 names this per generation call; §13.2 states the same number as
   * "en fazla dört kartı, pasaj başına" — one passage produces the knowledge
   * units and cards of one request, so the two readings are the same cap.
   */
  maxCardsPerKnowledgeUnit: number;
  timeoutMs: number;
}

export interface GeminiConfig {
  /** Handwriting second-opinion model (§11.1); only called for uncertain spans (§10.4). */
  model: string;
  /**
   * Higher than the visible §15.3 payload (text + a few uncertain spans)
   * would suggest on its own. Confirmed live: at 700 a real call hit
   * `MAX_TOKENS` before producing any output — this model spends part of its
   * output budget on its own internal reasoning before the JSON, so the
   * ceiling has to cover that too, not just the answer.
   */
  maxOutputTokens: number;
  timeoutMs: number;
}

export interface Config {
  documentAI: DocumentAIConfig;
  openai: OpenAIConfig;
  gemini: GeminiConfig;
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

function boolean(name: string, fallback: boolean): boolean {
  const raw = process.env[name]?.trim().toLowerCase();
  if (!raw) return fallback;
  if (["1", "true", "yes", "on"].includes(raw)) return true;
  if (["0", "false", "no", "off"].includes(raw)) return false;
  throw new ConfigError(`${name} true/false olmalı, alınan: ${raw}`);
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
      computeStyleInfo: boolean("DOCUMENTAI_COMPUTE_STYLE_INFO", false),
    },
    openai: {
      model: optional("OPENAI_MODEL", "gpt-5.6-sol"),
      // Faz 6/B3 (docs/FAZ6-PLAN.md §5.4). The vision call has a hard 60 s
      // ceiling (vercel.json maxDuration = 60, OPENAI_TIMEOUT_MS = 60_000).
      // "high" then "medium" both blew it on a dense marked page → the phone got
      // `providerUnavailable` and no cards. Generation/reasoning tokens are the
      // dominant latency cost, so reasoning is dropped to "low". The
      // handwriting-reading lever (`imageDetail: "high"`) is cheap on latency and
      // stays; mark discrimination lives in the prompt (v2.2). All
      // env-overridable (§0.6) — raise reasoning again only if the call
      // comfortably fits the budget (e.g. behind an async job, B4).
      reasoningEffort: optional("OPENAI_REASONING_EFFORT", "low"),
      // Kept "high": lets the model tile the full page at resolution and read
      // faint margin handwriting / thin highlighter strokes. Adds input tokens
      // but little latency next to reasoning.
      imageDetail: optional("OPENAI_IMAGE_DETAIL", "high"),
      // Faz 6/B3: raised 4096→8192 so a densely-marked full page's cards (up to
      // maxCardsPerKnowledgeUnit below) are not truncated to a `status:
      // "incomplete"` failure. A ceiling, not a target — at reasoning "low" the
      // model emits only what the cards need.
      maxOutputTokens: numeric("OPENAI_MAX_OUTPUT_TOKENS", 8192),
      // Faz 6/B3: this was 4 for the old "one reconciled passage → ≤4 cards"
      // flow. In the vision flow one full page carries many distinct marks and
      // handwritten notes; capping at 4 made the model spend its whole budget on
      // the first, most basic printed facts and drop every handwritten insight
      // (second device test). Raised to 12 so a marked page's distinct points
      // each get a card. Now really "max cards per page"; env-overridable (§0.6).
      maxCardsPerKnowledgeUnit: numeric("OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT", 12),
      timeoutMs: numeric("OPENAI_TIMEOUT_MS", 60_000),
    },
    gemini: {
      model: optional("GEMINI_MODEL", "gemini-3.5-flash"),
      maxOutputTokens: numeric("GEMINI_MAX_OUTPUT_TOKENS", 4096),
      timeoutMs: numeric("GEMINI_TIMEOUT_MS", 60_000),
    },
    cost: {
      usdPer1000Pages: numeric("DOCUMENTAI_USD_PER_1000_PAGES", 1.5),
      maxUsdPerRun: numeric("MAX_USD_PER_RUN", 0),
      openaiUsdPerMillionInputTokens: numeric("OPENAI_USD_PER_MILLION_INPUT_TOKENS", 0),
      openaiUsdPerMillionOutputTokens: numeric("OPENAI_USD_PER_MILLION_OUTPUT_TOKENS", 0),
      geminiUsdPerMillionInputTokens: numeric("GEMINI_USD_PER_MILLION_INPUT_TOKENS", 0),
      geminiUsdPerMillionOutputTokens: numeric("GEMINI_USD_PER_MILLION_OUTPUT_TOKENS", 0),
      maxUsdPerCardGeneration: numeric("MAX_USD_PER_CARD_GENERATION", 0),
    },
  };
}

export { ConfigError };
