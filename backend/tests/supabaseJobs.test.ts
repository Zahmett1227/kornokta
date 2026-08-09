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
  resultRetentionMs: 60 * 24 * 60 * 60 * 1000,
};

const ROW_JSON =
  `[{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","status":"processing","image_path":"pages/x",` +
  `"mime_type":"image/jpeg","hint":null,"max_cards":null,"mc_mode":null,"subject":"Patoloji","attempts":2,"result":null,` +
  `"error":null,"retryable":null,"created_at":"2026-08-06T12:00:00Z","updated_at":"2026-08-06T12:00:00Z",` +
  `"started_at":"2026-08-06T12:00:00+00:00","finished_at":null}]`;

function stubTransport(status: number, body: string) {
  const seen: { url: string; method: string; body?: Uint8Array | string }[] = [];
  const transport: Transport = {
    async send({ url, method, body: sentBody }) {
      seen.push({ url, method, body: sentBody });
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
    // The subject column round-trips into camelCase like hint/maxCards do.
    expect(claimed?.subject).toBe("Patoloji");
  });

  it("insertQueued yazdığı satırda subject kolonunu taşır (yoksa null)", async () => {
    const { transport, seen } = stubTransport(201, "");
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    await store.insertQueued({
      id: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
      imagePath: "pages/x",
      mimeType: "image/jpeg",
      subject: "Patoloji",
    });
    await store.insertQueued({
      id: "3f2504e0-4f89-11d3-9a0c-0305e82c3302",
      imagePath: "pages/y",
      mimeType: "image/jpeg",
    });

    const first = JSON.parse(String(seen[0]?.body)) as Array<Record<string, unknown>>;
    const second = JSON.parse(String(seen[1]?.body)) as Array<Record<string, unknown>>;
    expect(first[0]?.subject).toBe("Patoloji");
    expect(second[0]?.subject).toBeNull();
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

describe("SupabaseJobStore purgeFinished", () => {
  it("yalnız biten ve süresi geçmiş satırları hedefleyen filtreyle DELETE atar", async () => {
    const { transport, seen } = stubTransport(
      200,
      `[{"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301"},{"id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8"}]`,
    );
    const store = new SupabaseJobStore(CONFIG, "key", transport);
    const cutoff = "2026-06-07T12:00:00.000Z";

    const removed = await store.purgeFinished(cutoff);

    expect(removed).toBe(2);
    expect(seen[0]?.method).toBe("DELETE");
    // The status condition is what keeps live rows (`queued`/`processing`)
    // out of reach no matter how old they are; `finished_at=lt.` additionally
    // excludes null, so nothing that has not visibly finished can match.
    expect(seen[0]?.url).toContain("status=in.(ready,failed)");
    expect(seen[0]?.url).toContain(`finished_at=lt.${encodeURIComponent(cutoff)}`);
  });

  it("hiçbir satır silinmediyse 0 döner", async () => {
    const { transport } = stubTransport(200, "[]");
    const store = new SupabaseJobStore(CONFIG, "key", transport);

    expect(await store.purgeFinished("2026-06-07T12:00:00.000Z")).toBe(0);
  });
});
