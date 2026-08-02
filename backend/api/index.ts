/**
 * Composition root: builds the real dependencies from the environment and
 * exposes a plain fetch handler.
 *
 * This is the only file that touches `DEVICE_TOKEN` or `OPENAI_API_KEY`.
 * `config.ts` deliberately carries no credential (a test asserts it), so each
 * secret is read here and handed straight to its consumer without being
 * stored, echoed or logged (§0.7, §7.3).
 */

import { GoogleAuth } from "google-auth-library";

import { loadConfig } from "../config.js";
import { DocumentAIRecognizer, googleAuthTokenSource } from "../providers/documentAI.js";
import { googleAuthOptions } from "../providers/googleAuth.js";
import { OpenAICardGenerator } from "../providers/openai.js";
import { handleOcrRequest, type Dependencies } from "./_ocr.js";
import { handleCardsRequest, type CardsDependencies } from "./_cards.js";

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

/** Built once per process; separate from `cached` because it needs a different key (`OPENAI_API_KEY`). */
let cachedCards: CardsDependencies | null = null;

export function buildCardsDependencies(): CardsDependencies {
  if (cachedCards) return cachedCards;

  const config = loadConfig();
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    // Named explicitly rather than left to fail inside the provider on the
    // first call, same reasoning as `loadConfig`'s own missing-variable
    // errors: a config problem should say which variable, not surface as an
    // opaque 401 from OpenAI (§0.6).
    throw new Error("Eksik ortam değişkeni: OPENAI_API_KEY. backend/.env.example dosyasına bak.");
  }

  cachedCards = {
    generator: new OpenAICardGenerator(config.openai, apiKey, config.cost),
    openai: config.openai,
    cost: config.cost,
    deviceToken: process.env.DEVICE_TOKEN,
    log: (entry) => console.log(JSON.stringify(entry)),
  };
  return cachedCards;
}

/** Reset between tests; not used in production. */
export function resetDependencies(): void {
  cached = null;
  cachedCards = null;
}

/**
 * Fetch-style entry point.
 *
 * Reached through the `{ fetch }` default export below, never as a bare
 * default function. Vercel reads a bare default export as the legacy Node
 * signature `(req, res) => void` and **ignores whatever it returns**, so a
 * handler that returns a `Response` never answers and the request hangs until
 * the function times out. Its runtime says so in as many words:
 *
 *     WARN: default export returned a `Response`.
 *     The default-export signature is `(req, res) => void` — returns are
 *     ignored. You likely meant the Web `fetch`-style API.
 *
 * That also explains the `ERR_INVALID_URL` seen before it, which looked like a
 * separate bug: under the legacy signature the first argument is a Node
 * `IncomingMessage`, whose `.url` is a bare path ("/health") rather than the
 * absolute URL a Fetch `Request` carries. One wrong export shape, two
 * unrelated-looking symptoms — and a stack trace showing this function being
 * entered, which is what made the shape look innocent.
 *
 * `scripts/serve.ts` and the tests call this named export directly.
 */
export async function handler(request: Request): Promise<Response> {
  // A base, kept as cheap insurance rather than as the fix it was once
  // mistaken for. Through `{ fetch }` the argument is a real `Request` and
  // `.url` is absolute, so the base is inert; it only mattered while the
  // export shape was wrong. Nothing below reads the host or scheme, only
  // `pathname`.
  const url = new URL(request.url, "http://localhost");

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

  if (url.pathname === "/api/cards" || url.pathname === "/cards") {
    let dependencies: CardsDependencies;
    try {
      dependencies = buildCardsDependencies();
    } catch (error) {
      return new Response(
        JSON.stringify({ error: (error as Error).message, retryable: false }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    return handleCardsRequest(request, dependencies);
  }

  return new Response(JSON.stringify({ error: "Bulunamadı.", retryable: false }), {
    status: 404,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * The shape Vercel actually dispatches as a Web handler. A bare
 * `export default handler` is read as the legacy `(req, res)` signature
 * instead, and its return value is discarded — see `handler` above.
 */
export default { fetch: handler };
