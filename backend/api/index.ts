/**
 * Composition root: builds the real dependencies from the environment and
 * exposes a plain fetch handler.
 *
 * This is the only file that touches `DEVICE_TOKEN` or `OPENAI_API_KEY`.
 * `config.ts` deliberately carries no credential (a test asserts it), so each
 * secret is read here and handed straight to its consumer without being
 * stored, echoed or logged (§0.7, §7.3).
 */

import { waitUntil } from "@vercel/functions";

import { loadConfig } from "../config.js";
import { OpenAICardGenerator } from "../providers/openai.js";
import { SupabaseJobStore } from "../providers/supabaseJobs.js";
import { handleCardsRequest, type CardsDependencies } from "./_cards.js";
import { handleJobsRequest, type JobsDependencies } from "./_jobs.js";

/**
 * Built once per process, not per request, so the config is parsed and the
 * generator constructed exactly once per instance.
 */
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

/**
 * Continues work after the response has been sent.
 *
 * Without `waitUntil` the platform is free to freeze the instance the moment the
 * reply leaves, and a background generation would simply stop mid-call — the job
 * row would sit `processing` until the staleness sweep reclaimed it, which is a
 * working system that never actually produces a card. With it, the instance
 * stays alive until the promise settles, bounded by the same `maxDuration` the
 * synchronous endpoint already lives under.
 *
 * The rejection handler is not decoration: an unhandled rejection here would
 * take down the whole instance, including any *other* job sharing it under
 * fluid compute. `runJob` writes its own terminal row before it can reject, so
 * there is nothing left to report by the time this runs.
 */
function runInBackground(work: () => Promise<void>): void {
  const promise = work().catch((error: unknown) => {
    console.log(
      JSON.stringify({
        event: "jobs.background_crashed",
        message: error instanceof Error ? error.message : "Bilinmeyen hata.",
      }),
    );
  });
  try {
    waitUntil(promise);
  } catch {
    // Outside a Vercel request context — `npm run serve`, a script, a test.
    // The promise still runs to completion there; nothing needs to be told to
    // stay awake because nothing is about to be frozen.
  }
}

/** Built once per process; needs both `OPENAI_API_KEY` and the Supabase service-role key. */
let cachedJobs: JobsDependencies | null = null;

export function buildJobsDependencies(): JobsDependencies {
  if (cachedJobs) return cachedJobs;

  const config = loadConfig();
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("Eksik ortam değişkeni: OPENAI_API_KEY. backend/.env.example dosyasına bak.");
  }
  if (!config.supabase.url) {
    throw new Error("Eksik ortam değişkeni: SUPABASE_URL. backend/.env.example dosyasına bak.");
  }
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    throw new Error(
      "Eksik ortam değişkeni: SUPABASE_SERVICE_ROLE_KEY. backend/.env.example dosyasına bak.",
    );
  }

  cachedJobs = {
    store: new SupabaseJobStore(config.supabase, serviceRoleKey),
    generator: new OpenAICardGenerator(config.openai, apiKey, config.cost),
    openai: config.openai,
    cost: config.cost,
    supabase: config.supabase,
    deviceToken: process.env.DEVICE_TOKEN,
    runInBackground,
    log: (entry) => console.log(JSON.stringify(entry)),
  };
  return cachedJobs;
}

/** Reset between tests; not used in production. */
export function resetDependencies(): void {
  cachedCards = null;
  cachedJobs = null;
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

  // `/api/ocr` was removed with the deterministic OCR pipeline (ADR-005 trim,
  // 2026-08-09); an old client calling it now gets the plain 404 below.

  // Faz 6 (docs/FAZ6-PLAN.md §5.1) renamed the main route to `/api/cards-vision`;
  // the legacy `/api/cards` paths stay mapped to the same handler so an older
  // client build keeps working during the transition.
  if (
    url.pathname === "/api/cards-vision" ||
    url.pathname === "/cards-vision" ||
    url.pathname === "/api/cards" ||
    url.pathname === "/cards"
  ) {
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

  // Faz 6 / ADR-006: the asynchronous door. `/api/cards-vision` above stays
  // exactly as it was — this is a second route, not a replacement, so falling
  // back is a client-side switch and needs no redeploy.
  if (url.pathname === "/api/jobs" || url.pathname === "/jobs") {
    let dependencies: JobsDependencies;
    try {
      dependencies = buildJobsDependencies();
    } catch (error) {
      return new Response(
        JSON.stringify({ error: (error as Error).message, retryable: false }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    return handleJobsRequest(request, dependencies);
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
