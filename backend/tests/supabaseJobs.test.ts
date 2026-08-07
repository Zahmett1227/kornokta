import { describe, expect, it } from "vitest";

import {
  SupabaseError,
  SupabaseJobStore,
  type SupabaseConfig,
  type Transport,
} from "../providers/supabaseJobs.js";

/**
 * The store's whole concurrency story is which PostgREST filter each write
 * carries (`JobStoreLike`'s header). These tests pin exactly that: the URL a
 * write goes out with, and how a Storage 404 is classified. The end-to-end
 * behaviour on top is covered by `jobsEndpoint.test.ts`'s in-memory store.
 */

const CONFIG: SupabaseConfig = {
  url: "https://example.supabase.co",
  bucket: "page-uploads",
  timeoutMs: 1_000,
  staleAfterMs: 330_000,
};

const ROW_JSON =
  `[{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","status":"processing","image_path":"pages/x",` +
  `"mime_type":"image/jpeg","hint":null,"max_cards":null,"mc_mode":null,"attempts":2,"result":null,` +
  `"error":null,"retryable":null,"created_at":"2026-08-06T12:00:00Z","updated_at":"2026-08-06T12:00:00Z",` +
  `"started_at":"2026-08-06T12:00:00+00:00","finished_at":null}]`;

function stubTransport(status: number, body: string) {
  const seen: { url: string; method: string }[] = [];
  const transport: Transport = {
    async send({ url, method }) {
      seen.push({ url, method });
      return { status, body: new TextEncoder().encode(body) };
    },
  };
  return { transport, seen };
}

const STARTED_AT = "2026-08-06T12:00:00+00:00";

describe("SupabaseJobStore fences", () => {
  it("claim, kazandığı satırın kendisini döner (parametreler + started_at fence'i için)", async () => {
    const { transport, seen } = stubTransport(200, ROW_JSON);
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    const claimed = await store.claim("3f2504e0-4f89-11d3-9a0c-0305e82c3301", 2);

    expect(seen[0]?.url).toContain("status=eq.queued");
    expect(claimed?.attempts).toBe(2);
    expect(claimed?.startedAt).toBe(STARTED_AT);
  });

  it("claim, yarışı kaybedince null döner", async () => {
    const { transport } = stubTransport(200, "[]");
    const store = new SupabaseJobStore(CONFIG, "key", transport);
    expect(await store.claim("3f2504e0-4f89-11d3-9a0c-0305e82c3301", 1)).toBeNull();
  });

  it("complete yalnız kendi denemesinin satırını yazar (status + started_at koşulu)", async () => {
    const { transport, seen } = stubTransport(200, ROW_JSON);
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    const won = await store.complete("3f2504e0-4f89-11d3-9a0c-0305e82c3301", STARTED_AT, { ok: true });

    expect(won).toBe(true);
    expect(seen[0]?.url).toContain("status=eq.processing");
    // `+00:00`'daki `+` kodlanmak zorunda — çıplak `+` sorgu dizgisinde boşluk
    // demek ve filtre sessizce hiçbir şeyle eşleşmezdi (expire ile aynı kural).
    expect(seen[0]?.url).toContain(`started_at=eq.${encodeURIComponent(STARTED_AT)}`);
  });

  it("fail de aynı fence'i taşır ve kaybedince false döner", async () => {
    const { transport, seen } = stubTransport(200, "[]");
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    const won = await store.fail("3f2504e0-4f89-11d3-9a0c-0305e82c3301", STARTED_AT, "hata", true);

    expect(won).toBe(false);
    expect(seen[0]?.url).toContain("status=eq.processing");
    expect(seen[0]?.url).toContain(`started_at=eq.${encodeURIComponent(STARTED_AT)}`);
  });
});

describe("SupabaseJobStore getImage", () => {
  it("404'ü tekrar denenebilir sayar: nesne eşzamanlı temizlikte silinmiş olabilir", async () => {
    // Nesne yolu deterministik (`pages/<jobId>`); kalıcı sayılsaydı `requeue`
    // `retryable=is.true` istediği için sayfa sonsuza dek kilitlenirdi.
    const { transport } = stubTransport(404, "yok");
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    const error = await store.getImage("pages/x").catch((caught) => caught as SupabaseError);

    expect(error).toBeInstanceOf(SupabaseError);
    expect((error as SupabaseError).transient).toBe(true);
  });

  it("404 dışındaki hatalar kendi sınıflandırmasını korur", async () => {
    const { transport } = stubTransport(403, "yasak");
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    const error = await store.getImage("pages/x").catch((caught) => caught as SupabaseError);

    expect((error as SupabaseError).transient).toBe(false);
  });
});
