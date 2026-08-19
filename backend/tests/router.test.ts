import { describe, expect, it } from "vitest";

import handlerModule, { handler } from "../api/index.js";

describe("export shape", () => {
  it("is the Web-handler object Vercel dispatches, not a bare function", () => {
    // This has been changed the wrong way twice, and neither the type checker
    // nor any behavioural test catches it: a bare `export default handler`
    // compiles, passes every test here, and deploys — then Vercel reads it as
    // the legacy `(req, res) => void` signature, discards the returned
    // `Response`, and every request hangs until the 60s timeout.
    expect(typeof handlerModule).toBe("object");
    expect(typeof handlerModule.fetch).toBe("function");
  });

  it("routes through the same function the named export exposes", () => {
    // Otherwise the suite below could be green while the deployed path is not.
    expect(handlerModule.fetch).toBe(handler);
  });
});

describe("handler", () => {
  // Vercel's own docs promise the `request` a `{ fetch }` export receives is
  // a Web-standard `Request`, whose `.url` is always absolute. Measured on a
  // real deployment it was not: `.url` was the bare path ("/", "/favicon.ico"),
  // and `new URL(request.url)` alone threw `ERR_INVALID_URL` on every single
  // request — including `/health`, which has no logic beyond that line. This
  // reproduces that exact shape without a live deployment; a real `Request`
  // cannot even be constructed with a relative URL, so the fake has to be a
  // plain object.
  it("survives a request whose url is a bare path, not an absolute URL", async () => {
    const bareRequest = {
      url: "/health",
      method: "GET",
      headers: new Headers(),
    } as Request;

    const response = await handler(bareRequest);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it("still answers correctly when the url genuinely is absolute", async () => {
    // What `scripts/serve.ts` and every other test in this suite send — the
    // fix must not have narrowed to only the broken shape.
    const response = await handler(new Request("http://127.0.0.1:8787/health"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });

  it("404s on an unknown path either way", async () => {
    const bare = await handler({ url: "/nope", method: "GET", headers: new Headers() } as Request);
    const absolute = await handler(new Request("http://127.0.0.1:8787/nope"));

    expect(bare.status).toBe(404);
    expect(absolute.status).toBe(404);
  });

  it("routes /api/cards to a handler rather than 404ing (§25 Faz 3)", async () => {
    // No device token or OpenAI key is configured in this test process, so
    // this cannot reach 200 — it only has to prove the path is wired to
    // *some* handler (a config error, 500) rather than falling through to the
    // catch-all 404 the way an unrouted path would.
    const response = await handler(new Request("http://127.0.0.1:8787/api/cards", { method: "POST" }));
    expect(response.status).not.toBe(404);
  });

  it("routes /api/second-opinion, and its missing GEMINI_API_KEY names itself (2026-08-11)", async () => {
    // Same isolation contract as /api/jobs with Supabase: the route must be
    // wired, and with no key configured the refusal must say which variable —
    // not fall through to 404 and not break any other route.
    const response = await handler(
      new Request("http://127.0.0.1:8787/api/second-opinion", { method: "POST" }),
    );
    expect(response.status).not.toBe(404);
    if (!process.env.GEMINI_API_KEY) {
      expect(response.status).toBe(500);
      expect(((await response.json()) as { error: string }).error).toContain("GEMINI_API_KEY");
    }
  });

  it("routes /api/coverage with the same isolation contract (2026-08-19)", async () => {
    // The fourth door (docs/PLAN-kapsama-sozlesmesi.md, Katman B). Wired, and
    // when its key is missing it refuses by name — alone. Card generation must
    // not be able to notice that this route is unconfigured.
    const response = await handler(
      new Request("http://127.0.0.1:8787/api/coverage", { method: "POST" }),
    );
    expect(response.status).not.toBe(404);
    if (!process.env.GEMINI_API_KEY) {
      expect(response.status).toBe(500);
      expect(((await response.json()) as { error: string }).error).toContain("GEMINI_API_KEY");
    }
  });
});
