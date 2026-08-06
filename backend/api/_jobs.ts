/**
 * `POST /api/jobs` and `GET /api/jobs` — asynchronous card generation
 * (docs/ADR-006).
 *
 * The synchronous `/api/cards-vision` asked the phone to hold one connection
 * open for as long as the model took, which for a densely marked page is one to
 * five minutes. No phone can be relied on to do that: the screen auto-locks
 * after 30 s, iOS suspends the app, and the upload dies as a timeout. A single
 * photo usually beat the clock; a batch of five never did.
 *
 * So the wait moves off the phone. `POST` stores the page and answers in a
 * couple of seconds; the generation continues in the background, past the
 * response, and writes its answer into the job row. `GET` collects it, whenever
 * the phone next happens to be awake. Nothing is lost if the app is backgrounded,
 * killed, or the network changes — the work is written down.
 *
 * `/api/cards-vision` is untouched and still works; this is a second door, not a
 * replacement, so a rollback is a client-side switch (ADR-006 §6).
 *
 * Same privacy discipline as `_cards.ts` and `_ocr.ts`: no image bytes or card
 * text in a log line, and the stored page is deleted the moment its job reaches
 * a terminal state (§7.3).
 */

import { authorize } from "./_auth.js";
import { ACCEPTED_MIME_TYPES, MAX_IMAGE_BYTES, decodeImage } from "./_ocr.js";
import type { CostConfig, OpenAIConfig } from "../config.js";
import { CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";
import { OpenAIError, estimateOpenAICostUSD } from "../providers/openai.js";
import { runCardGate } from "../providers/cardGate.js";
import { SupabaseError, type JobRow, type JobStoreLike, type SupabaseConfig } from "../providers/supabaseJobs.js";
import type { CardGeneratorLike } from "./_cards.js";

/** How many jobs one poll may ask about. A batch is a handful of pages, never a hundred. */
export const MAX_POLL_IDS = 50;

/**
 * `id` is the primary key of a Postgres `uuid` column and is interpolated into
 * a PostgREST filter, so it is checked rather than trusted. The phone sends
 * `CapturedPage.id.uuidString`, which is this shape in upper case.
 */
const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export interface JobsDependencies {
  store: JobStoreLike;
  generator: CardGeneratorLike;
  openai: Pick<OpenAIConfig, "maxCardsPerKnowledgeUnit" | "maxOutputTokens">;
  cost: Pick<
    CostConfig,
    "openaiUsdPerMillionInputTokens" | "openaiUsdPerMillionOutputTokens" | "maxUsdPerCardGeneration"
  >;
  supabase: Pick<SupabaseConfig, "staleAfterMs">;
  deviceToken: string | undefined;
  /**
   * Continues work after the response has been sent. On Vercel this is
   * `waitUntil`, which is what keeps the instance alive past the reply; in a
   * test it simply awaits, which is what makes the whole flow assertable
   * without timers.
   */
  runInBackground: (work: () => Promise<void>) => void;
  /** Injected so the staleness sweep is testable without waiting minutes. */
  now?: () => number;
  /** Content never reaches this — only ids, counts and durations (§7.3). */
  log?: (entry: Record<string, unknown>) => void;
}

/** What the phone sees for one job. `result` is exactly `/api/cards-vision`'s success body. */
export interface JobView {
  jobId: string;
  status: JobRow["status"];
  result?: unknown;
  error?: string;
  retryable?: boolean;
  attempts: number;
}

export interface JobsFailure {
  error: string;
  retryable: boolean;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(message: string, status: number, retryable: boolean): Response {
  return json({ error: message, retryable } satisfies JobsFailure, status);
}

export function toJobView(row: JobRow): JobView {
  const view: JobView = { jobId: row.id, status: row.status, attempts: row.attempts };
  if (row.result !== null && row.result !== undefined) view.result = row.result;
  if (row.error !== null) view.error = row.error;
  if (row.retryable !== null) view.retryable = row.retryable;
  return view;
}

/** Object path inside the private bucket. No extension: `mime_type` is on the row. */
export function imagePathFor(jobId: string): string {
  return `pages/${jobId}`;
}

export async function handleJobsRequest(request: Request, deps: JobsDependencies): Promise<Response> {
  const auth = authorize(request.headers.get("authorization"), deps.deviceToken);
  if (!auth.ok) {
    return fail(auth.message, auth.status, auth.status === 500);
  }

  if (request.method === "POST") return submit(request, deps);
  if (request.method === "GET") return poll(request, deps);
  return fail("Yalnızca POST veya GET.", 405, false);
}

// ---------------------------------------------------------------------------
// POST — submit
// ---------------------------------------------------------------------------

interface SubmitBody {
  jobId?: unknown;
  imageBase64?: unknown;
  mimeType?: unknown;
  hint?: unknown;
}

async function submit(request: Request, deps: JobsDependencies): Promise<Response> {
  let body: SubmitBody;
  try {
    body = (await request.json()) as SubmitBody;
  } catch {
    return fail("Gövde geçerli JSON değil.", 400, false);
  }

  const jobId = typeof body.jobId === "string" ? body.jobId.trim() : "";
  if (!UUID_PATTERN.test(jobId)) {
    return fail("jobId bir UUID olmalı.", 400, false);
  }

  const mimeType = typeof body.mimeType === "string" ? body.mimeType.trim() : "";
  if (!ACCEPTED_MIME_TYPES.has(mimeType)) {
    return fail(
      `Desteklenmeyen tür: ${mimeType || "(boş)"}. Kabul edilenler: ${[...ACCEPTED_MIME_TYPES].join(", ")}.`,
      415,
      false,
    );
  }

  if (typeof body.imageBase64 !== "string") {
    return fail("imageBase64 zorunlu.", 400, false);
  }
  if (body.imageBase64.length > Math.ceil(MAX_IMAGE_BYTES * 1.4)) {
    return fail(`Görüntü çok büyük (en fazla ${MAX_IMAGE_BYTES} bayt).`, 413, false);
  }
  const image = decodeImage(body.imageBase64);
  if (!image) {
    return fail("imageBase64 çözülemedi; yükleme bozuk olabilir.", 400, false);
  }
  if (image.length > MAX_IMAGE_BYTES) {
    return fail(`Görüntü çok büyük (en fazla ${MAX_IMAGE_BYTES} bayt).`, 413, false);
  }

  if (body.hint !== undefined && typeof body.hint !== "string") {
    return fail("hint bir metin (string) olmalı.", 400, false);
  }
  const hint = typeof body.hint === "string" ? body.hint.trim() : undefined;

  // §21.3: refuse before spending, on the only bound knowable before the call.
  // Checked at submit rather than in the worker so the phone learns about it in
  // its own reply, instead of having to poll to find out it was never going to
  // happen.
  if (deps.cost.maxUsdPerCardGeneration > 0) {
    const upperBound = estimateOpenAICostUSD(0, deps.openai.maxOutputTokens, deps.cost);
    if (upperBound > deps.cost.maxUsdPerCardGeneration) {
      return fail(
        `Tahmini üst sınır maliyet (${upperBound.toFixed(4)} USD) yapılandırılan sınırı ` +
          `(${deps.cost.maxUsdPerCardGeneration} USD) aşıyor; çağrı yapılmadı (§21.3).`,
        402,
        false,
      );
    }
  }

  let existing: JobRow | undefined;
  try {
    [existing] = await deps.store.find([jobId]);
  } catch (error) {
    return storeFailure(error, deps, jobId, "jobs.submit.lookup_failed");
  }

  // Already answered: hand the result straight back and, crucially, do not
  // generate a second time. `jobId` is the phone's page id, so a resubmit after
  // the app was killed mid-wait lands here — which is exactly how the work
  // survives the app dying (ADR-006 §4).
  if (existing?.status === "ready") {
    return json(toJobView(existing), 200);
  }
  // Already running and not yet stale: adding a second worker would only race
  // the first for the same paid call.
  if (existing?.status === "processing" && !isStale(existing, deps)) {
    return json(toJobView(existing), 202);
  }
  // A failure the phone cannot fix by trying again is reported as it stands
  // rather than silently re-armed into another identical failure.
  if (existing?.status === "failed" && existing.retryable === false) {
    return json(toJobView(existing), 200);
  }

  const imagePath = imagePathFor(jobId);
  try {
    await deps.store.putImage(imagePath, image, mimeType);
    await deps.store.enqueue({ id: jobId, imagePath, mimeType, hint });
  } catch (error) {
    return storeFailure(error, deps, jobId, "jobs.submit.enqueue_failed");
  }

  deps.log?.({
    jobId,
    event: "jobs.queued",
    bytes: image.length,
    resubmitted: existing !== undefined,
  });

  deps.runInBackground(() => runJob(jobId, deps));

  return json({ jobId, status: "queued", attempts: existing?.attempts ?? 0 } satisfies JobView, 202);
}

// ---------------------------------------------------------------------------
// GET — poll
// ---------------------------------------------------------------------------

async function poll(request: Request, deps: JobsDependencies): Promise<Response> {
  const url = new URL(request.url, "http://localhost");
  const raw = (url.searchParams.get("ids") ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter(Boolean);

  if (raw.length === 0) {
    return fail("ids zorunlu (virgülle ayrılmış iş kimlikleri).", 400, false);
  }
  if (raw.length > MAX_POLL_IDS) {
    return fail(`Tek seferde en fazla ${MAX_POLL_IDS} iş sorulabilir.`, 400, false);
  }
  const invalid = raw.find((id) => !UUID_PATTERN.test(id));
  if (invalid) {
    return fail("ids yalnızca UUID içerebilir.", 400, false);
  }

  let rows: JobRow[];
  try {
    rows = await deps.store.find(raw);
  } catch (error) {
    return storeFailure(error, deps, raw[0] ?? "", "jobs.poll.lookup_failed");
  }

  const views: JobView[] = [];
  for (const row of rows) {
    // A worker killed at the platform's duration ceiling never got to write an
    // answer, and nothing else would ever notice: the row would stay
    // `processing` and the phone would poll it forever. Reclaiming here — on
    // the polls the phone is making anyway — is why this needs no cron, which
    // matters because the hosting plan's minimum cron interval is a day.
    if (row.status === "processing" && isStale(row, deps)) {
      views.push(await reclaim(row, deps));
      continue;
    }
    // Queued with nobody working on it. Usually the submit's own dispatch has
    // it already, in which case `claim` inside `runJob` returns false and this
    // costs nothing — that atomic claim is what makes an unconditional rescue
    // safe, so there is no grace period to tune.
    if (row.status === "queued") {
      deps.runInBackground(() => runJob(row.id, deps));
    }
    views.push(toJobView(row));
  }

  // Unknown ids simply do not come back. The phone reads an absent job as "not
  // submitted yet" and submits it, which is the correct recovery whether the row
  // was never written or was cleaned up.
  return json({ jobs: views }, 200);
}

function isStale(row: JobRow, deps: JobsDependencies): boolean {
  const startedAt = Date.parse(row.startedAt ?? row.updatedAt);
  if (Number.isNaN(startedAt)) return false;
  const now = deps.now?.() ?? Date.now();
  return now - startedAt > deps.supabase.staleAfterMs;
}

async function reclaim(row: JobRow, deps: JobsDependencies): Promise<JobView> {
  const message = "İşleyen sunucu yanıt vermeden sonlandı; tekrar denenebilir.";
  try {
    const expired = await deps.store.expire(row.id, message);
    if (row.imagePath) await deleteImageQuietly(row.imagePath, deps);
    if (!expired) {
      // It finished between our read and our write. Re-read rather than report
      // a stale snapshot as a failure the user would see for no reason.
      const [fresh] = await deps.store.find([row.id]);
      return toJobView(fresh ?? row);
    }
    deps.log?.({ jobId: row.id, event: "jobs.expired", attempts: row.attempts });
    return { jobId: row.id, status: "failed", error: message, retryable: true, attempts: row.attempts };
  } catch {
    // Reporting the row as it stands is better than failing the whole poll: the
    // other jobs in this batch have nothing to do with this one.
    return toJobView(row);
  }
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

/**
 * Generates the cards for one job. Runs *after* the response the phone got, so
 * nothing here may throw into a caller — every path ends by writing a terminal
 * row, which is the only thing the phone can observe.
 *
 * Exported for the tests, which drive it through `runInBackground`.
 */
export async function runJob(jobId: string, deps: JobsDependencies): Promise<void> {
  const started = deps.now?.() ?? Date.now();
  let row: JobRow | undefined;

  try {
    [row] = await deps.store.find([jobId]);
    if (!row || row.status !== "queued") return;

    // Exactly one caller wins this, so the submit's dispatch and a poll's
    // rescue can both fire without racing for the same paid generation.
    const claimed = await deps.store.claim(jobId, row.attempts + 1);
    if (!claimed) return;
  } catch (error) {
    deps.log?.({ jobId, event: "jobs.claim_failed", message: describe(error) });
    return;
  }

  if (!row.imagePath) {
    await finishFailed(jobId, "İş kaydında görüntü yolu yok.", false, deps, started, undefined);
    return;
  }

  try {
    const image = await deps.store.getImage(row.imagePath);
    const { output, rawUsage } = await deps.generator.generateCards({
      requestId: jobId,
      image,
      mimeType: row.mimeType,
      hint: row.hint ?? undefined,
    });
    const gate = runCardGate(output, { maxCardsPerKnowledgeUnit: deps.openai.maxCardsPerKnowledgeUnit });

    // Stored in the shape `/api/cards-vision` returns, so the phone's decoder is
    // the same one and this table never becomes a second definition of the card
    // contract.
    await deps.store.complete(jobId, { jobId, output, gate, cardPromptVersion: CARD_PROMPT_VERSION });
    await deleteImageQuietly(row.imagePath, deps);

    deps.log?.({
      jobId,
      event: "jobs.ready",
      cardCount: output.cards.length,
      inputTokens: rawUsage.inputTokens,
      outputTokens: rawUsage.outputTokens,
      estimatedCostUSD: output.usage.estimatedCostUSD,
      cardPromptVersion: CARD_PROMPT_VERSION,
      attempts: row.attempts + 1,
      elapsedMs: (deps.now?.() ?? Date.now()) - started,
    });
  } catch (error) {
    const openAIError = error instanceof OpenAIError ? error : null;
    const supabaseError = error instanceof SupabaseError ? error : null;
    const retryable = openAIError?.transient ?? supabaseError?.transient ?? true;
    await finishFailed(jobId, describe(error), retryable, deps, started, row.imagePath);
  }
}

async function finishFailed(
  jobId: string,
  message: string,
  retryable: boolean,
  deps: JobsDependencies,
  started: number,
  imagePath: string | undefined,
): Promise<void> {
  try {
    await deps.store.fail(jobId, message, retryable);
  } catch {
    // Nothing left to do: the row stays `processing` and the staleness sweep in
    // `poll` will reclaim it. That path exists precisely for this.
  }
  if (imagePath) await deleteImageQuietly(imagePath, deps);
  deps.log?.({
    jobId,
    event: "jobs.failed",
    retryable,
    elapsedMs: (deps.now?.() ?? Date.now()) - started,
  });
}

/**
 * A page that outlives its job is a privacy problem (§7.3), not a correctness
 * one — the answer is already written. So a failed delete is logged and dropped
 * rather than turned into a job failure the user would see.
 */
async function deleteImageQuietly(path: string, deps: JobsDependencies): Promise<void> {
  try {
    await deps.store.deleteImage(path);
  } catch (error) {
    deps.log?.({ event: "jobs.image_delete_failed", message: describe(error) });
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : "Bilinmeyen hata.";
}

function storeFailure(
  error: unknown,
  deps: JobsDependencies,
  jobId: string,
  event: string,
): Response {
  const supabaseError = error instanceof SupabaseError ? error : null;
  const retryable = supabaseError ? supabaseError.transient : true;
  deps.log?.({ jobId, event, status: supabaseError?.status, retryable });
  return fail(
    supabaseError ? supabaseError.message : "İş kuyruğuna erişilemedi.",
    retryable ? 503 : 502,
    retryable,
  );
}
