import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/_auth.js";
import { MAX_IMAGE_BYTES } from "../api/_image.js";
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
const RESULT_RETENTION_MS = 60 * 24 * 60 * 60 * 1000;

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
    async insertQueued(request: EnqueueRequest) {
      calls.push(`insertQueued:${request.id}`);
      // The primary key is what makes a racing second submission lose instead
      // of overwriting a row that may already be claimed.
      if (rows.has(request.id)) return false;
      rows.set(request.id, {
        id: request.id,
        status: "queued",
        imagePath: request.imagePath,
        mimeType: request.mimeType,
        hint: request.hint ?? null,
        maxCards: request.maxCards ?? null,
        mcMode: request.mcMode ?? null,
        subject: request.subject ?? null,
        attempts: 0,
        result: null,
        error: null,
        retryable: null,
        createdAt: new Date(NOW).toISOString(),
        updatedAt: new Date(NOW).toISOString(),
        startedAt: null,
        finishedAt: null,
      });
      return true;
    },
    async requeue(request: EnqueueRequest, options: { includePermanent?: boolean } = {}) {
      calls.push(`requeue:${request.id}`);
      const row = rows.get(request.id);
      if (!row || row.status !== "failed") return false;
      // `includePermanent` drops only the retryable half of the condition —
      // mirroring the real store's filter, so a stub that ignored it could not
      // hide a handler that re-armed a claimed job.
      if (row.retryable !== true && !options.includePermanent) return false;
      rows.set(request.id, {
        ...row,
        status: "queued",
        imagePath: request.imagePath,
        mimeType: request.mimeType,
        hint: request.hint ?? null,
        maxCards: request.maxCards ?? null,
        subject: request.subject ?? null,
        result: null,
        error: null,
        retryable: null,
        startedAt: null,
        finishedAt: null,
      });
      return true;
    },
    async claim(id, attempts) {
      calls.push(`claim:${id}`);
      const row = rows.get(id);
      if (!row || row.status !== "queued") return null;
      const claimed = { ...row, status: "processing" as const, attempts, startedAt: new Date(NOW).toISOString() };
      rows.set(id, claimed);
      return claimed;
    },
    async complete(id, startedAt, result) {
      calls.push(`complete:${id}`);
      const row = rows.get(id);
      // Fenced exactly as the real store fences it: only the attempt whose
      // claim wrote this `started_at` may finish the row.
      if (!row || row.status !== "processing" || row.startedAt !== startedAt) return false;
      rows.set(id, { ...row, status: "ready", result, error: null, retryable: null, imagePath: null });
      return true;
    },
    async fail(id, startedAt, error, retryable) {
      calls.push(`fail:${id}`);
      const row = rows.get(id);
      if (!row || row.status !== "processing" || row.startedAt !== startedAt) return false;
      rows.set(id, { ...row, status: "failed", error, retryable, imagePath: null });
      return true;
    },
    async expire(id, startedAt, error) {
      calls.push(`expire:${id}`);
      const row = rows.get(id);
      if (!row || row.status !== "processing") return false;
      // Fenced to one exact attempt, exactly as the `started_at=eq.` filter
      // does server-side — a stub that ignored it would let a sweep aimed at a
      // dead attempt silently kill a live one and the tests would never notice.
      if (row.startedAt !== startedAt) return false;
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
      // Transient, mirroring the real store: a missing object is almost always
      // a concurrent cleanup's doing, and non-retryable would lock the page.
      if (!bytes) throw new SupabaseError("Supabase 404: yok", 404, true);
      return bytes;
    },
    async deleteImage(path) {
      calls.push(`deleteImage:${path}`);
      images.delete(path);
    },
    async purgeFinished(cutoffIso) {
      calls.push(`purgeFinished:${cutoffIso}`);
      let removed = 0;
      for (const [id, row] of rows) {
        // Mirrors the real filter: terminal status AND a finished_at older
        // than the cutoff. Rows without a finished_at can never match.
        if (
          (row.status === "ready" || row.status === "failed") &&
          row.finishedAt !== null &&
          row.finishedAt < cutoffIso
        ) {
          rows.delete(id);
          removed += 1;
        }
      }
      return removed;
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
    openai: { maxCardsPerKnowledgeUnit: 12, maxOutputTokens: 8192, multipleChoiceMode: "mixed" },
    cost: { openaiUsdPerMillionInputTokens: 0, openaiUsdPerMillionOutputTokens: 0, maxUsdPerCardGeneration: 0 },
    supabase: { staleAfterMs: STALE_AFTER_MS, resultRetentionMs: RESULT_RETENTION_MS },
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
    maxCards: null,
    mcMode: null,
    subject: null,
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

  it("dersi iş satırına yazar ve üreticiye taşır (şema v2.2)", async () => {
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    await handleJobsRequest(post({ ...VALID_BODY, subject: "Patoloji" }), d);
    await d.settled();

    expect(store.rows.get(JOB_ID)?.subject).toBe("Patoloji");
    expect(generator.seen[0]?.subject).toBe("Patoloji");
  });

  it("bilinmeyen dersi null olarak saklar — sınıflandırma inceliği çekimi düşürmez", async () => {
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post({ ...VALID_BODY, subject: "Uydurma Ders" }), d);
    await d.settled();

    expect(response.status).toBe(202);
    expect(store.rows.get(JOB_ID)?.subject).toBeNull();
    expect(generator.seen[0]?.subject).toBeUndefined();
  });

  it("subject string değilse 400 (bozuk gövde), subject'siz eski istemci aynen çalışır", async () => {
    const d = deps({});
    const bad = await handleJobsRequest(post({ ...VALID_BODY, subject: 7 }), d);
    expect(bad.status).toBe(400);

    const store = stubStore();
    const d2 = deps({ store: store.store });
    const ok = await handleJobsRequest(post(VALID_BODY), d2);
    await d2.settled();
    expect(ok.status).toBe(202);
    expect(store.rows.get(JOB_ID)?.subject).toBeNull();
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

  it("force ile kalıcı bir hata da yeniden kurulur (kullanıcının 'Tekrar dene'si)", async () => {
    // İş kimliği = sayfa kimliği olduğundan, kalıcı hata kaçışsız bir durumdu:
    // yanlış bir API anahtarıyla üretilen her sayfa, anahtar düzeltildikten
    // sonra bile sonsuza dek kilitli kalıyordu. Tek çare sayfayı silip yeniden
    // çekmekti.
    const store = stubStore([row({ status: "failed", retryable: false, error: "401", imagePath: null })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post({ ...VALID_BODY, force: true }), d);
    await d.settled();

    expect(response.status).toBe(202);
    expect(store.rows.get(JOB_ID)).toMatchObject({ status: "ready", error: null });
    expect(generator.seen).toHaveLength(1);
  });

  it("force, alınmış (processing) bir işi geri çekmez", async () => {
    // `force` yalnız `retryable` koşulunu düşürür, `status=eq.failed` koşulunu
    // değil: canlı bir işçiyi ikinci bir ücretli üretimle yarıştıramaz.
    const store = stubStore([
      row({ status: "processing", startedAt: new Date(NOW).toISOString(), imagePath: imagePathFor(JOB_ID) }),
    ]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post({ ...VALID_BODY, force: true }), d);
    await d.settled();

    expect(response.status).toBe(202);
    expect(store.rows.get(JOB_ID)?.status).toBe("processing");
    expect(generator.seen).toHaveLength(0);
  });

  it("force, biten bir işi yeniden üretmez", async () => {
    const store = stubStore([row({ status: "ready", result: { ok: true }, imagePath: null })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post({ ...VALID_BODY, force: true }), d);
    await d.settled();

    expect(response.status).toBe(200);
    expect(generator.seen).toHaveLength(0);
  });

  it("force olmadan kalıcı hata olduğu gibi bildirilir", async () => {
    const store = stubStore([row({ status: "failed", retryable: false, error: "401", imagePath: null })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(store.rows.get(JOB_ID)?.status).toBe("failed");
    expect(generator.seen).toHaveLength(0);
  });

  it("force boolean değilse sessizce yutmaz", async () => {
    const response = await handleJobsRequest(post({ ...VALID_BODY, force: "evet" }), deps());
    expect(response.status).toBe(400);
  });
});

describe("POST /api/jobs — yarışlar (Codex, PR #25)", () => {
  /**
   * Yarışı deterministik kuruyor: bu gönderim durumu okuduktan SONRA, ama
   * yazmadan önce, diğer gönderim satırı oluşturup işi almış oluyor. Ayırt
   * edici nokta bu — kaybedenin bütün kontrolleri, artık geçerli olmayan bir
   * okumaya dayanarak geçti.
   *
   * `Promise.all` ile iki isteği aynı anda başlatmak bunu kurmuyor: stub'daki
   * `runInBackground` işi `settled()`'a kadar geciktirdiği için iki gönderim de
   * işçilerden önce bitiyor ve çakışma hiç oluşmuyor.
   */
  function afterReadingState(store: ReturnType<typeof stubStore>, then: () => void) {
    const original = store.store.find.bind(store.store);
    let first = true;
    store.store.find = async (ids) => {
      const result = await original(ids);
      if (first) {
        first = false;
        then();
      }
      return result;
    };
  }

  it("okuması eskimiş bir gönderim, alınmış işi kuyruğa geri çekmez", async () => {
    // Gerçek bir senaryo, uç durum değil: `ProcessingQueue` aynı sayfa için elle
    // "Tekrar dene" ile aşağı-çekmenin çakışmasına açıkça izin veriyor.
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });
    afterReadingState(store, () => {
      store.rows.set(JOB_ID, row({ status: "processing", startedAt: new Date(NOW).toISOString() }));
    });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    // Koşulsuz bir upsert satırı 'queued'a çekerdi, ikinci bir işçi de onu
    // alırdı: aynı sayfa için iki ödemeli üretim.
    expect(store.rows.get(JOB_ID)?.status).toBe("processing");
    expect(generator.seen).toHaveLength(0);
    expect(response.status).toBe(202);
  });

  it("okuması eskimiş bir yeniden gönderim de alınmış işi geri çekmez", async () => {
    // Aynı yarışın ikinci kapısı: tekrar denenebilir bir hata görüp yeniden
    // kuyruğa almaya karar veren gönderim.
    const store = stubStore([row({ status: "failed", retryable: true, imagePath: null })]);
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });
    afterReadingState(store, () => {
      store.rows.set(JOB_ID, row({ status: "processing", startedAt: new Date(NOW).toISOString() }));
    });

    const response = await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(store.rows.get(JOB_ID)?.status).toBe("processing");
    expect(generator.seen).toHaveLength(0);
    expect(response.status).toBe(202);
  });

  it("yarışı kaybeden gönderim kazananın görüntüsünü silmez", async () => {
    const store = stubStore([row({ status: "processing", startedAt: new Date(NOW).toISOString() })]);
    store.images.set(imagePathFor(JOB_ID), new Uint8Array([1, 2, 3]));
    const d = deps({ store: store.store });

    // Süresi dolmamış bir iş: gönderim hiçbir şeye dokunmadan durumu bildirmeli.
    const response = await handleJobsRequest(post(VALID_BODY), d);

    expect(response.status).toBe(202);
    expect(store.images.has(imagePathFor(JOB_ID))).toBe(true);
  });

  it("yarışı kaybeden gönderim, kazanan çoktan bitmişse kendi yüklemesini toplar", async () => {
    // Kaybedenin "kazanan zaten bu nesneyi işaret ediyor" varsayımı yalnız
    // kazanan HÂLÂ çalışıyorsa doğru. Kazanan bitmişse sonlanma yolu nesneyi
    // çoktan silmiştir ve buradaki yükleme, hiçbir satırın işaret etmediği taze
    // bir nesne bırakır — bir daha asla bulunamaz (Codex, PR #26).
    const store = stubStore();
    const d = deps({ store: store.store });
    afterReadingState(store, () => {
      store.rows.set(JOB_ID, row({ status: "ready", imagePath: null, result: { ok: true } }));
    });

    const response = await handleJobsRequest(post(VALID_BODY), d);

    expect(response.status).toBe(200);
    expect(store.images.size).toBe(0);
  });

  it("eskimiş işin yeniden gönderiminde yükleme düşerse eski nesneyi bırakmaz", async () => {
    // `expire` başarılı olduğu anda satırın `image_path`'i boşalıyor ama nesne
    // hâlâ kovada. Yükleme bundan sonra düşerse, "yalnız yükledimse temizle"
    // kuralı o eski nesneyi sahipsiz bırakırdı (Codex, PR #26).
    const staleStartedAt = new Date(NOW - STALE_AFTER_MS - 1).toISOString();
    const store = stubStore([row({ status: "processing", startedAt: staleStartedAt })]);
    store.images.set(imagePathFor(JOB_ID), new Uint8Array([1, 2, 3]));
    store.store.putImage = async () => {
      throw new SupabaseError("Supabase 503", 503, true);
    };
    const d = deps({ store: store.store });

    const response = await handleJobsRequest(post(VALID_BODY), d);

    expect(response.status).toBe(503);
    expect(store.images.size).toBe(0);
  });

  it("kuyruğa alma başarısız olursa yüklenen görüntüyü bırakmaz", async () => {
    // Satırı olmayan bir yükleme bir daha asla bulunamaz: hiçbir yoklama onu
    // döndürmez, hiçbir kurtarma süpürmesi görmez.
    const store = stubStore();
    store.store.insertQueued = async () => {
      throw new SupabaseError("Supabase 503", 503, true);
    };
    const d = deps({ store: store.store });

    const response = await handleJobsRequest(post(VALID_BODY), d);

    expect(response.status).toBe(503);
    expect(store.images.size).toBe(0);
  });

  it("sahibi olan bir görüntüyü telafi silmesiyle kaldırmaz", async () => {
    // Belirsiz bir hatada, yarışı kazanan başka bir gönderim tam bu baytlara
    // güveniyor olabilir. Sızan nesne birkaç megabayt; kırılan canlı iş sayfa.
    const store = stubStore();
    store.store.insertQueued = async () => {
      // Kazanan, biz düşmeden hemen önce satırı yazmış gibi.
      store.rows.set(JOB_ID, row({ status: "processing", startedAt: new Date(NOW).toISOString() }));
      throw new SupabaseError("Supabase 503", 503, true);
    };
    const d = deps({ store: store.store });

    await handleJobsRequest(post(VALID_BODY), d);

    expect(store.images.has(imagePathFor(JOB_ID))).toBe(true);
  });

  it("bayat işçinin geç gelen sonucu, yeniden kurulan denemeyi ezmez", async () => {
    // Üretim sürerken deneme bayatlar: bir yoklama onu emekli eder, yeni bir
    // gönderim işi yeniden kurar. Emekli işçinin cevabı ancak kendi
    // `started_at`'i hâlâ satırdaysa yazılabilir — değilse hem sonuç düşer hem
    // de yeni denemenin taze baytlarına dokunulmaz.
    const store = stubStore();
    const generator: CardGeneratorLike = {
      async generateCards() {
        const current = store.rows.get(JOB_ID);
        await store.store.expire(JOB_ID, current?.startedAt ?? null, "bayat");
        await store.store.putImage(imagePathFor(JOB_ID), new Uint8Array([9]), "image/jpeg");
        await store.store.requeue({ id: JOB_ID, imagePath: imagePathFor(JOB_ID), mimeType: "image/jpeg" });
        return {
          output: validOutput(),
          rawUsage: { inputTokens: 1, outputTokens: 1 },
        } satisfies CardGenerationResult;
      },
    };
    const d = deps({ store: store.store, generator });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    const fresh = store.rows.get(JOB_ID);
    expect(fresh?.status).toBe("queued");
    expect(fresh?.result).toBeNull();
    // The loser must not delete the path either: the bytes belong to the
    // re-armed attempt now.
    expect(store.images.has(imagePathFor(JOB_ID))).toBe(true);
    expect(d.logged.some((entry) => entry.event === "jobs.result_dropped")).toBe(true);
  });

  it("bayat işçinin geç gelen hatası da yeniden kurulan denemeyi ezmez", async () => {
    const store = stubStore();
    const generator: CardGeneratorLike = {
      async generateCards() {
        const current = store.rows.get(JOB_ID);
        await store.store.expire(JOB_ID, current?.startedAt ?? null, "bayat");
        await store.store.putImage(imagePathFor(JOB_ID), new Uint8Array([9]), "image/jpeg");
        await store.store.requeue({ id: JOB_ID, imagePath: imagePathFor(JOB_ID), mimeType: "image/jpeg" });
        throw new OpenAIError("model bu koşuda patladı", undefined, false);
      },
    };
    const d = deps({ store: store.store, generator });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    const fresh = store.rows.get(JOB_ID);
    expect(fresh?.status).toBe("queued");
    expect(fresh?.error).toBeNull();
    expect(store.images.has(imagePathFor(JOB_ID))).toBe(true);
  });
});

describe("POST /api/jobs — kart sınırı (§6.7)", () => {
  it("kullanıcının sınırını işe yazar ve işçi onu kullanır", async () => {
    // Yazılmak zorunda: işçi, ayarı taşıyan istek çoktan bittikten sonra
    // çalışıyor ve ayarı başka hiçbir yerden okuyamaz.
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    await handleJobsRequest(post({ ...VALID_BODY, maxCards: 5 }), d);
    expect(store.rows.get(JOB_ID)?.maxCards).toBe(5);

    await d.settled();
    expect(generator.seen[0]?.maxCards).toBe(5);
  });

  it("istemci sunucunun tavanını yükseltemez", async () => {
    // Config değeri bir maliyet tavanı; istemci onu aşağı çekebilir, yukarı değil (§21.3).
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    await handleJobsRequest(post({ ...VALID_BODY, maxCards: 999 }), d);
    await d.settled();

    expect(generator.seen[0]?.maxCards).toBe(12);
  });

  it("sınır verilmezse dağıtımın varsayılanı kullanılır", async () => {
    const generator = stubGenerator(validOutput());
    const d = deps({ generator: generator.generator });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(generator.seen[0]?.maxCards).toBeUndefined();
  });

  it("bozuk bir sınırı sessizce yutmaz", async () => {
    // Sessizce düşürülen bir ayar, bu ayarın iki faz boyunca hiçbir şey
    // yapmamasının tam olarak sebebiydi.
    for (const bad of [0, -3, 2.5, "üç"]) {
      const response = await handleJobsRequest(post({ ...VALID_BODY, maxCards: bad }), deps());
      expect(response.status, `maxCards=${bad}`).toBe(400);
    }
  });
});

describe("POST /api/jobs — beş şıklı kart modu (§13.3)", () => {
  it("kullanıcının modunu işe yazar ve işçi onu kullanır", async () => {
    // `maxCards` ile aynı sebep: işçi, ayarı taşıyan istek bittikten çok sonra
    // çalışıyor, ayarı satırdan başka hiçbir yerden okuyamaz.
    const store = stubStore();
    const generator = stubGenerator(validOutput());
    const d = deps({ store: store.store, generator: generator.generator });

    await handleJobsRequest(post({ ...VALID_BODY, multipleChoiceMode: "off" }), d);
    expect(store.rows.get(JOB_ID)?.mcMode).toBe("off");

    await d.settled();
    expect(generator.seen[0]?.multipleChoiceMode).toBe("off");
  });

  it("istemci dağıtımın modunu yükseltemez", async () => {
    // off < mixed < all. Dağıtım "mixed" ise istemci "all" isteyemez: her şık
    // takımı ek çıktı token'ı, yani başkasının maliyet kararı (§21.3).
    const generator = stubGenerator(validOutput());
    const d = deps({ generator: generator.generator });

    await handleJobsRequest(post({ ...VALID_BODY, multipleChoiceMode: "all" }), d);
    await d.settled();

    expect(generator.seen[0]?.multipleChoiceMode).toBe("mixed");
  });

  it("mod verilmezse dağıtımın varsayılanı kullanılır", async () => {
    const generator = stubGenerator(validOutput());
    const d = deps({ generator: generator.generator });

    await handleJobsRequest(post(VALID_BODY), d);
    await d.settled();

    expect(generator.seen[0]?.multipleChoiceMode).toBeUndefined();
  });

  it("bilinmeyen bir modu sessizce yutmaz", async () => {
    for (const bad of ["hepsi", "", 3, true]) {
      const response = await handleJobsRequest(
        post({ ...VALID_BODY, multipleChoiceMode: bad }),
        deps(),
      );
      expect(response.status, `mod=${String(bad)}`).toBe(400);
    }
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
  });

  it("vision modelinin okuyamadığı türleri kapıda çevirir", async () => {
    // Kalıcı hatanın bedeli burada yüksek: iş kimliği = sayfa kimliği olduğu
    // için sağlayıcıdan dönecek 400, o sayfayı kilitleyen bir `retryable=false`
    // satırına dönüşürdü.
    for (const mimeType of ["application/pdf", "image/tiff"]) {
      const response = await handleJobsRequest(post({ ...VALID_BODY, mimeType }), deps());
      expect(response.status, mimeType).toBe(415);
    }
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

  it("kurtarma, aradan yeniden başlatılmış bir denemeyi öldürmez", async () => {
    // Yoklama eski, takılı denemeyi okurken iş yeniden kuyruğa alınıp taze bir
    // işçi tarafından alınmış olabilir. Yalnız `status`'e bakan bir koşul, eski
    // denemeye nişan alan süpürmenin YENİ denemeyi öldürmesine izin verirdi.
    const staleStartedAt = new Date(NOW - STALE_AFTER_MS - 1).toISOString();
    const store = stubStore([row({ status: "processing", startedAt: staleStartedAt })]);
    store.images.set(imagePathFor(JOB_ID), new Uint8Array([1, 2, 3]));

    const d = deps({ store: store.store });
    const original = store.store.find.bind(store.store);
    let firstRead = true;
    store.store.find = async (ids) => {
      const result = await original(ids);
      if (firstRead) {
        firstRead = false;
        // Okuduktan hemen sonra: yeni bir işçi işi devraldı.
        store.rows.set(JOB_ID, row({ status: "processing", startedAt: new Date(NOW).toISOString() }));
      }
      return result;
    };

    const response = await handleJobsRequest(get(JOB_ID), d);

    const body = (await response.json()) as { jobs: JobView[] };
    expect(body.jobs[0]).toMatchObject({ status: "processing" });
    expect(store.rows.get(JOB_ID)?.status).toBe("processing");
    // Ve yeni denemenin görüntüsü duruyor.
    expect(store.images.has(imagePathFor(JOB_ID))).toBe(true);
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

describe("GET /api/jobs — sonuç saklama süpürmesi (§7.3)", () => {
  const OLD = new Date(NOW - RESULT_RETENTION_MS - 1000).toISOString();
  const FRESH = new Date(NOW - 1000).toISOString();

  it("saklama süresini aşmış biten işleri yoklama sırasında siler", async () => {
    const store = stubStore([
      row({ status: "ready", result: { ok: true }, imagePath: null, finishedAt: OLD }),
      row({ id: OTHER_JOB_ID, status: "queued" }),
    ]);
    const d = deps({ store: store.store });

    await handleJobsRequest(get(OTHER_JOB_ID), d);
    await d.settled();

    expect(store.rows.has(JOB_ID)).toBe(false);
    // The cutoff is now minus the configured retention, nothing else.
    const expectedCutoff = new Date(NOW - RESULT_RETENTION_MS).toISOString();
    expect(store.calls).toContain(`purgeFinished:${expectedCutoff}`);
    expect(d.logged).toContainEqual({ event: "jobs.results_purged", removed: 1 });
  });

  it("süresi dolmamış biten işlere dokunmaz", async () => {
    const store = stubStore([
      row({ status: "ready", result: { ok: true }, imagePath: null, finishedAt: FRESH }),
    ]);
    const d = deps({ store: store.store });

    await handleJobsRequest(get(JOB_ID), d);
    await d.settled();

    expect(store.rows.get(JOB_ID)?.status).toBe("ready");
  });

  it("canlı işleri yaşına bakmadan bırakır", async () => {
    // A queued/processing row can be arbitrarily old (a phone away for months);
    // the sweep's status condition must leave it for the staleness path.
    const store = stubStore([
      row({ status: "queued", createdAt: OLD, updatedAt: OLD }),
    ]);
    const d = deps({ store: store.store });

    await handleJobsRequest(get(JOB_ID), d);
    await d.settled();

    expect(store.rows.has(JOB_ID)).toBe(true);
  });

  it("aynı depo için süpürmeyi aralıkla sınırlar", async () => {
    const store = stubStore([row({ id: OTHER_JOB_ID, status: "queued" })]);
    const d = deps({ store: store.store });

    await handleJobsRequest(get(OTHER_JOB_ID), d);
    await d.settled();
    await handleJobsRequest(get(OTHER_JOB_ID), d);
    await d.settled();

    const purges = store.calls.filter((call) => call.startsWith("purgeFinished:"));
    expect(purges).toHaveLength(1);
  });

  it("süpürme hatası yoklamayı düşürmez", async () => {
    const store = stubStore([row({ status: "queued" })]);
    store.store.purgeFinished = async () => {
      throw new SupabaseError("Supabase 500: bakım", 500, true);
    };
    const d = deps({ store: store.store });

    const response = await handleJobsRequest(get(JOB_ID), d);
    await d.settled();

    expect(response.status).toBe(200);
    expect(d.logged.some((entry) => entry.event === "jobs.results_purge_failed")).toBe(true);
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
