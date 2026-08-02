/**
 * Runtime guard for the canonical LLM output contract (ANA-PLAN §14: "Şema
 * doğrulanmayan cevap kaydedilmemelidir").
 *
 * OpenAI's Structured Outputs (strict mode) already constrains what the model
 * can emit, but that guarantee lives on the far side of an HTTP call — a
 * network hiccup, a provider bug, a schema/version drift, or the Gemini
 * fallback (a different provider, no shared strict-mode guarantee) all reach
 * this module the same way: as an unverified `unknown`. Validating here means
 * every call site fails the same way instead of trusting each provider's own
 * claim about its output.
 *
 * The schema file is the single source of truth (also read by
 * `evals/tests/test_swift_contract_sync.py` and the Swift side); this module
 * only compiles it once and exposes a typed pass/fail result.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
// Named import, not default: under `moduleResolution: NodeNext` without
// `esModuleInterop`, ajv's CJS default export type-checks as a non-callable
// namespace object. The named class export resolves to the same constructor.
import { Ajv2020 } from "ajv/dist/2020.js";

import type { LlmOutput } from "./llmOutputTypes.js";

const schema: Record<string, unknown> = JSON.parse(
  readFileSync(fileURLToPath(new URL("./llm_output.schema.json", import.meta.url)), "utf-8"),
);

/**
 * The parsed schema, exported so a provider can derive a request-time variant
 * from it (`providers/openai.ts` strips `usage`/`requestId` — fields the
 * model has no business inventing — and caps `cards` at the configured
 * per-passage limit) without a second `readFileSync` of the same file.
 */
export const LLM_OUTPUT_SCHEMA: Record<string, unknown> = schema;

// `strict: true` turns an ajv-side schema mistake (an unknown keyword, a typo
// in a $ref) into a thrown error at module load instead of a validator that
// silently accepts everything — the failure mode this whole module exists to
// avoid, just moved one level up.
const ajv = new Ajv2020({ allErrors: true, strict: true });
const compiled = ajv.compile(schema);

export interface ValidationResult {
  valid: boolean;
  /** Human-readable, ajv-error-derived. Never includes the candidate's own content (§7.3). */
  errors: string[];
}

/**
 * Validates an already-parsed JSON value against `llm_output.schema.json`.
 *
 * Deliberately takes `unknown`, not `LlmOutput`: the type only describes what
 * a *valid* response looks like, and a provider's raw reply has not earned
 * that type yet. The narrowing happens here, not at the call site.
 */
export function validateLlmOutput(candidate: unknown): ValidationResult {
  const valid = compiled(candidate) as boolean;
  if (valid) return { valid: true, errors: [] };

  const errors = (compiled.errors ?? []).map((error: { instancePath?: string; message?: string }) => {
    const path = error.instancePath || "(kök)";
    return `${path} ${error.message ?? "geçersiz"}`;
  });
  return { valid: false, errors };
}

/** Narrows after a successful `validateLlmOutput` call, for call sites that already checked. */
export function assertLlmOutput(candidate: unknown): asserts candidate is LlmOutput {
  const result = validateLlmOutput(candidate);
  if (!result.valid) {
    throw new Error(`LLM çıktısı §14 şemasına uymuyor: ${result.errors.join("; ")}`);
  }
}
