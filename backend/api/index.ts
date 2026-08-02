/**
 * Composition root: builds the real dependencies from the environment and
 * exposes a plain fetch handler.
 *
 * This is the only file that touches `DEVICE_TOKEN`. `config.ts` deliberately
 * carries no credential (a test asserts it), so the secret is read here and
 * handed straight to the authorizer without being stored, echoed or logged
 * (§0.7, §7.3).
 */

import { GoogleAuth } from "google-auth-library";

import { loadConfig } from "../config.js";
import { DocumentAIRecognizer, googleAuthTokenSource } from "../providers/documentAI.js";
import { googleAuthOptions } from "../providers/googleAuth.js";
import { handleOcrRequest, type Dependencies } from "./_ocr.js";

/**
 * Built once per process, not per request: constructing `GoogleAuth` reads the
 * key file and mints a token, and doing that on every request would add a
 * round trip to each page and re-read the key from disk each time.
 */
let cached: Dependencies | null = null;

export function buildDependencies(): Dependencies {
  if (cached) return cached;

  const config = loadConfig();
  // Options rather than a literal, because the credential is a file path
  // locally and inline JSON on a host — and neither form may be logged.
  const auth = new GoogleAuth(googleAuthOptions());

  cached = {
    recognizer: new DocumentAIRecognizer(config.documentAI, googleAuthTokenSource(auth)),
    documentAI: config.documentAI,
    deviceToken: process.env.DEVICE_TOKEN,
    // Structured single-line JSON so a hosting platform's log viewer can
    // filter it. Content never reaches here — `handleOcrRequest` only ever
    // passes ids, counts and durations (§7.3).
    log: (entry) => console.log(JSON.stringify(entry)),
  };
  return cached;
}

/** Reset between tests; not used in production. */
export function resetDependencies(): void {
  cached = null;
}

/**
 * Fetch-style entry point. Exported by name (not as the default) because
 * Vercel's documented shape for a plain, non-framework `/api` file is a
 * default export of `{ fetch(request) {...} }`, not a bare default function —
 * a bare default crashed every request in production (`FUNCTION_INVOCATION_FAILED`
 * on `/health`, which has no logic beyond this). `scripts/serve.ts` imports
 * this named export directly and calls it the same way Vercel's wrapper does.
 */
export async function handler(request: Request): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/health" || url.pathname === "/api/health") {
    // Deliberately unauthenticated and deliberately empty: it answers "is the
    // process up", not "is it configured", so it cannot be used to probe
    // whether a token or key is present.
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (url.pathname === "/api/ocr" || url.pathname === "/ocr") {
    let dependencies: Dependencies;
    try {
      dependencies = buildDependencies();
    } catch (error) {
      // A missing env var is the server's problem, not the caller's, and the
      // message names the variable so it is fixable (§0.6).
      return new Response(
        JSON.stringify({ error: (error as Error).message, retryable: false }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    return handleOcrRequest(request, dependencies);
  }

  return new Response(JSON.stringify({ error: "Bulunamadı.", retryable: false }), {
    status: 404,
    headers: { "Content-Type": "application/json" },
  });
}

/** What Vercel actually looks for on a plain (non-framework) `/api` file. */
export default { fetch: handler };
