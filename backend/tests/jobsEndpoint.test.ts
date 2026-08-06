import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/_auth.js";
import { ACCEPTED_MIME_TYPES, MAX_IMAGE_BYTES } from "../api/_ocr.js";
import type { CardGeneratorLike } from "../api/_cards.js";
import {
  MAX_POLL_IDS,
  handleJobsRequest,
  imagePathFor,
  type JobsDependencies,
  type JobView,
} from "../api/_jobs.js";
import { OpenAIError } from "../providers/openai.js";
import type { CardGenerationRequest, CardGenerationResult } from "../providers/openai.js";
import { SupabaseError, type EnqueueRequest, type JobRow, type JobStoreLike } from "../providers/supabaseJobs.js";
import type { LlmOutput } from "../schemas/llmOutputTypes.js";
import { CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";

const TOKEN = "t".repeat(MIN_TOKEN_LENGTH);
const IMAGE = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");
const JOB_ID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const OTHER_JOB_ID = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8";

const NOW = Date.parse("2026-08-06T12:00:00.000Z");
const STALE_AFTER_MS = 330_000;

function validOutput(overrides: Partial<LlmOutput> = {}): LlmOutput {
  return {
    schemaVersion: "2.0",
    requestId: JOB_ID,
    readText: "0,5 mg IM adrenalin",
    cards: [
      {
        id: "card_1",
        type: "direct_recall",
        front: "Anaflakside ilk doz nedir?",
        back: "0,5 mg IM adrenalin",
        explanation: "",
        difficulty: 2,
        tags: ["anafilaksi"],
        lowConfidence: false,
      },
    ],
    usage: { provider: "openai", model: "gpt-5.6-sol", inputTokens: 500, outputTokens: 120, estimatedCostUSD: 0 },
    ...overrides,
  };
}

/**
 * An in-memory `jobs` table plus bucket. Deliberately reproduces the two
 * conditional writes the real store leans on — `claim` only from `queued`,
 * `expire` only from `processing` — because those are what make a double
 * dispatch safe, and a stand-in that ignored the condition would let a broken
 * dispatcher pass.
 */
function stubStore(seed: JobRow[] = []) {
  const rows = new Map<string, JobRow>(seed.map((row) => [row.id, row]));
  const images = new Map<string, Uint8Array>();
  const calls: string[] = [];

  const store: JobStoreLike = {
    async find(ids) {
      calls.push(`find:${ids.join("+")}`);
      return ids.map((id) => rows.get(id)).filter((row): row is JobRow => row !== undefined);
    },
    async enqueue(request: EnqueueRequest) {
      calls.push(`enqueue:${request.id}`);
      const previous = rows.get(request.id);
      rows.set(request.id, {
        id: request.id,
        status: "queued",
        imagePath: request.imagePath,
        mimeType: request.mimeType,
        hint: request.hint ?? null,
        attempts: previous?.attempts ?? 0,
        result: null,
        error: null,
        retryable: null,
        createdAt: previous?.createdAt ?? new Date(NOW).toISOString(),
        updatedAt: new Date(NOW).toISOString(),
        startedAt: null,
        finishedAt: null,
      });
    },
    async claim(id, attempts) {
      calls.push(`claim:${id}`);
      const row = rows.get(id);
      if (!row || row.status !== "queued") return false;
      rows.set(id, { ...row, status: "processing", attempts, startedAt: new Date(NOW).toISOString() });
      return true;
    },
    async complete(id, result) {
      calls.push(`complete:${id}`);
      const row = rows.get(id);
      if (row) rows.set(id, { ...row, status: "ready", result, error: null, retryable: null, imagePath: null });
    },
    async fail(id, error, retryable) {
      calls.push(`fail:${id}`);
      const row = rows.get(id);
      if (row) rows.set(id, { ...row, status: "failed", error, retryable, imagePath: null });
    },
    async expire(id, error) {
      calls.push(`expire:${id}`);
      const row = rows.get(id);
      if (!row || row.status !== "processing") return false;
      rows.set(id, { ...row, status: "failed", error, retryable: true, imagePath: null });
      return true;
    },
    async putImage(path, bytes) {
      calls.push(`putImage:${path}`);
      images.set(path, bytes);
    },
    async getImage(path) {
      calls.push(`getImage:${path}`);
      const bytes = images.get(path);
      if (!bytes) throw new SupabaseError("Supabase 404: yok", 404, false);
      return bytes;
    },
    async deleteImage(path) {
      calls.push(`deleteImage:${path}`);
      images.delete(path);
    },
  };

  return { store, rows, images, calls };
}

function stubGenerator(result: LlmOutput | Error) {
  const seen: CardGenerationRequest[] = [];
  const generator: CardGeneratorLike = {
    async generateCards(request) {
      seen.push(request);
      if (result instanceof Error) throw result;
      return {
        output: result,
        rawUsage: { inputTokens: result.usage.inputTokens, outputTokens: result.usage.outputTokens },
      } satisfies CardGenerationResult;
    },
  };
  return { generator, seen };
}

/**
 * `runInBackground` awaits rather than detaching, so a test can assert on what
 * the worker did without a timer. That is the whole reason the runner is
 * injected instead of `waitUntil` being called directly from the handler.
 */
function deps(
  overrides: Partial<JobsDependencies> = {},
): JobsDependencies & { logged: Record<string, unknown>[]; settled: () => Promise<void> } {
  const logged: Record<string, unknown>[] = [];
  const pending: Promise<void>[] = [];
  return {
    store: stubStore().store,
    generator: stubGenerator(validOutput()).generator,
    openai: { maxCardsPerKnowledgeUnit: 12, maxOutputTokens: 8192 },
    cost: { openaiUsdPerMillionInputTokens: 0, openaiUsdPerMillionOutputTokens: 0, maxUsdPerCardGeneration: 0 },
    supabase: { staleAfterMs: STALE_AFTER_MS },
    deviceToken: TOKEN,
    runInBackground: (work) => {
      pending.push(work());
    },
    now: () => NOW,
    log: (entry) => logged.push(entry),
    logged,
    settled: async () => {
      // Drains transitively: a rescue dispatch may enqueue more work.
      while (pending.length > 0) await pending.shift();
    },
    ...overrides,
  };
}

function post(body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request("https://example.test/api/jobs", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function get(ids: string, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request(`https://example.test/api/jobs?ids=${ids}`, { method: "GET", headers });
}

const VALID_BODY = { jobId: JOB_ID, mimeType: "image/jpeg", imageBase64: IMAGE };

function row(overrides: Partial<JobRow> = {}): JobRow {
  return {
    id: JOB_ID,
    status: "queued",
    imagePath: imagePathFor(JOB_ID),
    mimeType: "image/jpeg",
    hint: null,
    attempts: 0,
    result: null,
    error: null,
    retryable: null,
    createdAt: new Date(NOW).toISOString(),
    updatedAt: new Date(NOW).toISOString(),
    startedAt: null,
    finishedAt: null,
    ...overrides,
  };
}

describe("POST /api/jobs — kabul", () => {
  it("model hiç cevap vermese bile hemen 202 döner", async () => {
    // The point of the whole design, stated as the one thing that must be true:
    // the reply does not wait on the model. A generator that never settles
    // stands in for the real four-minute one — if the handler awaited it at all,
    // this test would hang instead of failing.
    const store = stubStore();
    const neverAnswers: CardGeneratorLike = { generateCards: () => new Promise(() => {}) };
    const d = deps({ store: store.store, generator: neverAnswers });

    const response = await handleJobsRequest(post(VALID_BODY), d);

    expect(response.status).toBe(202);
    expect((await response.json()) as JobView).toMatchObject({ jobId: JOB_ID, status: "queued" });
    // Written down before the answer exists, which is what survives the phone
    // being suspended, killed or moved to another network.
    expect(store.rows.get(JOB_ID)?.status).toBe("processing");
  });

  it("kartları arka planda üretip işi tamamlar", async () => {
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(generator.seen).toHaveLength(1);
    expect(store.rows.get(JOB_ID)?.status).toBe("ready");
  });

  it("biten işin sonucu /api/cards-vision'ın gövdesiyle aynı şekle sahiptir", async () => {
    const store = stubStore();
    const d = deps({ store: store.store });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    // The iOS decoder is the one written for `/api/cards-vision`; if this shape
    // drifts, the phone silently stops understanding finished jobs.
    expect(store.rows.get(JOB_ID)?.result).toMatchObject({
      jobId: JOB_ID,
      output: { schemaVersion: "2.0", cards: [{ id: "card_1" }] },
      gate: { verdicts: [{ cardId: "card_1" }] },
      cardPromptVersion: CARD_PROMPT_VERSION,
    });
  });

  it("kullanıcının ipucunu modele taşır", async () => {
    const generator = stubGenerator(validOutput());
    const d = deps({ generator: generator.generator });

    await handleJobsRequest(post({ ...VALID_BODY, hint: "  sadece sol sütun  " }), d);
    await d.settled();

    expect(generator.seen[0]?.hint).toBe("sadece sol sütun");
  });

  it("iş bittiğinde sayfa görüntüsünü depodan siler (§7.3)", async () => {
    const store = stubStore();
    const d = deps({ store: store.store });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(store.images.size).toBe(0);
    expect(store.rows.get(JOB_ID)?.imagePath).toBeNull();
  });

  it("başarısız iş de görüntüyü bırakmaz", async () => {
    const store = stubStore();
    const d = deps({
      store: store.store,
      generator: stubGenerator(new OpenAIError("OpenAI 500", 500, true)).generator,
    });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(store.images.size).toBe(0);
    expect(store.rows.get(JOB_ID)).toMatchObject({ status: "failed", retryable: true });
  });

  it("kalıcı sağlayıcı hatasını tekrar denenmez olarak kaydeder", async () => {
    const store = stubStore();
    const d = deps({
      store: store.store,
      generator: stubGenerator(new OpenAIError("Model yanıtı geçerli JSON değil.", undefined, false)).generator,
    });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(store.rows.get(JOB_ID)).toMatchObject({ status: "failed", retryable: false });
  });

  it("hiçbir log satırı görüntü ya da kart metni taşımaz (§7.3)", async () => {
    const d = deps();
    await handleJobsRequest(post({ ...VALID_BODY, hint: "sadece sol sütun" }), d);
    await d.settled();

    const serialized = JSON.stringify(d.logged);
    expect(serialized).not.toContain(IMAGE);
    expect(serialized).not.toContain("adrenalin");
    expect(serialized).not.toContain("sadece sol sütun");
  });
});

describe("POST /api/jobs — yeniden gönderim", () => {
  it("zaten biten işi ikinci kez üretmez, sonucu doğrudan verir", async () => {
    const finished = row({ status: "ready", imagePath: null, result: { jobId: JOB_ID, output: {}, gate: {} } });
    const store = stubStore([finished]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    // This is how the work survives the app being killed mid-wait: the phone
    // resubmits the same page id on the next launch and collects the answer it
    // already paid for.
    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(response.status).toBe(200);
    expect((await response.json()) as JobView).toMatchObject({ status: "ready" });
    expect(generator.seen).toHaveLength(0);
    expect(store.calls).not.toContain(`putImage:${imagePathFor(JOB_ID)}`);
  });

  it("hâlâ çalışan işe ikinci bir işçi eklemez", async () => {
    const store = stubStore([row({ status: "processing", startedAt: new Date(NOW - 10_000).toISOString() })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(response.status).toBe(202);
    expect(generator.seen).toHaveLength(0);
  });

  it("takılı kalmış bir işi yeniden kuyruğa alır", async () => {
    const store = stubStore([
      row({ status: "processing", startedAt: new Date(NOW - STALE_AFTER_MS - 1).toISOString() }),
    ]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(response.status).toBe(202);
    expect(generator.seen).toHaveLength(1);
    expect(store.rows.get(JOB_ID)?.status).toBe("ready");
  });

  it("tekrar denenmeyecek bir hatayı yeniden denemez", async () => {
    const store = stubStore([row({ status: "failed", retryable: false, error: "şema hatası", imagePath: null })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(response.status).toBe(200);
    expect((await response.json()) as JobView).toMatchObject({ status: "failed", retryable: false });
    expect(generator.seen).toHaveLength(0);
  });

  it("tekrar denenebilir bir hatadan sonra yeniden kuyruğa alır", async () => {
    const store = stubStore([row({ status: "failed", retryable: true, error: "ağ", imagePath: null })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(response.status).toBe(202);
    expect(store.rows.get(JOB_ID)).toMatchObject({ status: "ready", error: null });
  });
});

describe("POST /api/jobs — doğrulama", () => {
  it("token olmadan 401 verir", async () => {
    const response = await handleJobsRequest(post(VALID_BODY, null), deps());
    expect(response.status).toBe(401);
  });

  it("UUID olmayan jobId'yi reddeder", async () => {
    // Not cosmetic: `jobId` is a Postgres uuid primary key and is interpolated
    // into a PostgREST filter.
    const response = await handleJobsRequest(post({ ...VALID_BODY, jobId: "job-1" }), deps());
    expect(response.status).toBe(400);
  });

  it("desteklenmeyen tür için 415 verir", async () => {
    const response = await handleJobsRequest(post({ ...VALID_BODY, mimeType: "image/gif" }), deps());
    expect(response.status).toBe(415);
    expect(ACCEPTED_MIME_TYPES.has("image/gif")).toBe(false);
  });

  it("çok büyük görüntü için 413 verir", async () => {
    const oversized = "A".repeat(Math.ceil(MAX_IMAGE_BYTES * 1.4) + 1);
    const response = await handleJobsRequest(post({ ...VALID_BODY, imageBase64: oversized }), deps());
    expect(response.status).toBe(413);
  });

  it("bütçe tavanı aşılırsa hiç kuyruğa almadan 402 verir", async () => {
    const store = stubStore();
    const d = deps({
      store: store.store,
      cost: {
        openaiUsdPerMillionInputTokens: 0,
        openaiUsdPerMillionOutputTokens: 100,
        maxUsdPerCardGeneration: 0.0001,
      },
    });

    const response = await handleJobsRequest(post(VALID_BODY), d);

    expect(response.status).toBe(402);
    expect(store.calls).toHaveLength(0);
  });

  it("depo erişilemezse geçici hata olarak 503 verir", async () => {
    const store = stubStore();
    store.store.find = async () => {
      throw new SupabaseError("Supabase 503", 503, true);
    };
    const response = await handleJobsRequest(post(VALID_BODY), deps({ store: store.store }));
    expect(response.status).toBe(503);
    expect(((await response.json()) as { retryable: boolean }).retryable).toBe(true);
  });
});

describe("GET /api/jobs", () => {
  it("birden çok işin durumunu tek çağrıda döner", async () => {
    const store = stubStore([
      row({ status: "ready", result: { ok: true } }),
      row({ id: OTHER_JOB_ID, status: "processing", startedAt: new Date(NOW - 1000).toISOString() }),
    ]);
    const response = await handleJobsRequest(get(`${JOB_ID},${OTHER_JOB_ID}`), deps({ store: store.store }));

    expect(response.status).toBe(200);
    const body = (await response.json()) as { jobs: JobView[] };
    expect(body.jobs).toHaveLength(2);
    expect(body.jobs[0]).toMatchObject({ jobId: JOB_ID, status: "ready", result: { ok: true } });
    expect(body.jobs[1]).toMatchObject({ jobId: OTHER_JOB_ID, status: "processing" });
  });

  it("bilinmeyen kimlik için satır döndürmez", async () => {
    const response = await handleJobsRequest(get(JOB_ID), deps({ store: stubStore().store }));
    expect(((await response.json()) as { jobs: JobView[] }).jobs).toEqual([]);
  });

  it("işçisi ölmüş bir işi tekrar denenebilir hata olarak geri alır", async () => {
    const store = stubStore([
      row({ status: "processing", startedAt: new Date(NOW - STALE_AFTER_MS - 1).toISOString() }),
    ]);
    const d = deps({ store: store.store });

    const response = await handleJobsRequest(get(JOB_ID), d);

    const body = (await response.json()) as { jobs: JobView[] };
    expect(body.jobs[0]).toMatchObject({ status: "failed", retryable: true });
    expect(store.images.size).toBe(0);
  });

  it("henüz süresi dolmamış bir işi geri almaz", async () => {
    const store = stubStore([
      row({ status: "processing", startedAt: new Date(NOW - STALE_AFTER_MS + 1000).toISOString() }),
    ]);
    const response = await handleJobsRequest(get(JOB_ID), deps({ store: store.store }));

    expect(((await response.json()) as { jobs: JobView[] }).jobs[0]).toMatchObject({ status: "processing" });
  });

  it("kimsenin almadığı kuyruktaki bir işi yoklama sırasında başlatır", async () => {
    // The rescue that removes the need for a cron: the hosting plan's minimum
    // cron interval is a day, and the phone is already polling.
    const store = stubStore([row({ status: "queued" })]);
    store.images.set(imagePathFor(JOB_ID), new Uint8Array([1, 2, 3]));
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    await handleJobsRequest(get(JOB_ID), d);
    await d.settled();

    expect(generator.seen).toHaveLength(1);
    expect(store.rows.get(JOB_ID)?.status).toBe("ready");
  });

  it("aynı işe iki kez el atılsa bile modeli bir kez çağırır", async () => {
    const store = stubStore([row({ status: "queued" })]);
    store.images.set(imagePathFor(JOB_ID), new Uint8Array([1, 2, 3]));
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    // Two polls racing on one queued job is the normal case, not an edge one:
    // the submit dispatches and the phone starts polling immediately after.
    await handleJobsRequest(get(JOB_ID), d);
    await handleJobsRequest(get(JOB_ID), d);
    await d.settled();

    expect(generator.seen).toHaveLength(1);
  });

  it("ids olmadan 400 verir", async () => {
    const response = await handleJobsRequest(get(""), deps());
    expect(response.status).toBe(400);
  });

  it("UUID olmayan kimlikleri reddeder", async () => {
    const response = await handleJobsRequest(get("job-1"), deps());
    expect(response.status).toBe(400);
  });

  it("tek seferde sorulabilecek iş sayısını sınırlar", async () => {
    const ids = Array.from({ length: MAX_POLL_IDS + 1 }, () => JOB_ID).join(",");
    const response = await handleJobsRequest(get(ids), deps());
    expect(response.status).toBe(400);
  });

  it("token olmadan 401 verir", async () => {
    const response = await handleJobsRequest(get(JOB_ID, null), deps());
    expect(response.status).toBe(401);
  });
});

describe("/api/jobs — diğer yöntemler", () => {
  it("PUT'u reddeder", async () => {
    const request = new Request("https://example.test/api/jobs", {
      method: "PUT",
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    expect((await handleJobsRequest(request, deps())).status).toBe(405);
  });
});
