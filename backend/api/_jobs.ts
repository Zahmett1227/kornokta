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
import { MAX_IMAGE_BYTES, decodeImage } from "./_image.js";
import { MULTIPLE_CHOICE_MODES, type CostConfig, type OpenAIConfig } from "../config.js";
import { CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";
import { OpenAIError, estimateOpenAICostUSD, outputCeilingUsage } from "../providers/openai.js";
import { EMPTY_TOKEN_USAGE, type CallAccounting, type TokenUsage } from "../providers/tokenUsage.js";
import { runCardGate } from "../providers/cardGate.js";
import { coverageFromGate } from "../providers/coverage.js";
import { sanitizeMultipleChoice } from "../providers/multipleChoice.js";
import { SupabaseError, type JobRow, type JobStoreLike, type SupabaseConfig } from "../providers/supabaseJobs.js";
import {
  VISION_MIME_TYPES,
  parseMaxCards,
  parseMultipleChoiceMode,
  parseSubject,
  type CardGeneratorLike,
} from "./_cards.js";

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
  openai: Pick<
    OpenAIConfig,
    // `model` is here only for the ledger: a failed call has no response to
    // read the model id off, and an accounting line that cannot say which
    // model spent the money is useless the moment a comparison run starts.
    "maxCardsPerKnowledgeUnit" | "maxOutputTokens" | "multipleChoiceMode" | "model"
  >;
  cost: Pick<
    CostConfig,
    | "openaiUsdPerMillionInputTokens"
    | "openaiUsdPerMillionCachedInputTokens"
    | "openaiUsdPerMillionOutputTokens"
    | "maxUsdPerCardGeneration"
  >;
  supabase: Pick<SupabaseConfig, "staleAfterMs" | "resultRetentionMs">;
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
  /**
   * Every provider call this job has made, priced (§16.8).
   *
   * Sent on every view, not only the terminal one, and deliberately not gated
   * on `status`: a page that is on its third attempt has already spent money
   * twice, and the phone should be able to write that down the moment it asks
   * — not only if it is still listening when the job finally resolves.
   *
   * Omitted entirely when empty so an untouched job's reply stays the shape it
   * always was.
   */
  usage?: CallAccounting[];
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
  if (row.usage.length > 0) view.usage = row.usage;
  return view;
}

/** Object path inside the private bucket. No extension: `mime_type` is on the row. */
export function imagePathFor(jobId: string): string {
  return `pages/${jobId}`;
}

const STALE_MESSAGE =
  "İşleyen sunucu yanıt vermeden sonlandı; tekrar denenebilir. Model üretimi sağlayıcı " +
  "tarafında tamamlanmış ve ücretlendirilmiş olabilir.";

/**
 * The ledger line for an attempt whose worker was killed before it could write
 * anything.
 *
 * Always `unmeasured`, never `none`: the instance died at the platform's
 * duration ceiling, which by definition is *after* it had been generating for
 * minutes. The provider finished that generation and billed it; the only
 * reason there are no token counts is that the process holding them stopped
 * existing. Recording it as a zero-cost event would hide the most expensive
 * failure mode this system has.
 */
function staleAccounting(row: JobRow, deps: JobsDependencies): CallAccounting {
  const now = deps.now?.() ?? Date.now();
  const startedAt = Date.parse(row.startedAt ?? row.updatedAt);
  return {
    attempt: row.attempts,
    provider: "openai",
    model: deps.openai.model,
    purpose: "card_generation",
    promptVersion: CARD_PROMPT_VERSION,
    outcome: "failure",
    failureReason: "worker_killed",
    billing: "unmeasured",
    usage: EMPTY_TOKEN_USAGE,
    estimatedCostUSD: 0,
    latencyMs: Number.isNaN(startedAt) ? 0 : now - startedAt,
    at: new Date(now).toISOString(),
  };
}

/**
 * Re-reads a job whose state moved under this request and reports what it
 * actually is now, rather than the snapshot that turned out to be stale.
 */
async function currentState(
  jobId: string,
  deps: JobsDependencies,
  fallback: JobRow | undefined,
): Promise<Response> {
  try {
    const [fresh] = await deps.store.find([jobId]);
    if (fresh) return json(toJobView(fresh), fresh.status === "ready" ? 200 : 202);
  } catch {
    // Fall through: a failed re-read is no reason to fail a request whose work
    // is demonstrably already in hand somewhere else.
  }
  return json(
    fallback
      ? toJobView(fallback)
      : ({ jobId, status: "queued", attempts: 0 } satisfies JobView),
    202,
  );
}

/**
 * Deletes a page upload only once it is certain nothing references it.
 *
 * The check is not paranoia: on an ambiguous failure a concurrent submission
 * may have won and be relying on these exact bytes, and deleting them would
 * turn its generation into a "görüntü bulunamadı" the user sees. A leaked
 * object costs a few megabytes; a broken live job costs the page.
 */
async function deleteUnreferencedImage(
  jobId: string,
  imagePath: string,
  deps: JobsDependencies,
): Promise<void> {
  try {
    const [row] = await deps.store.find([jobId]);
    // A row pointing at this object owns it, and its own terminal path deletes it.
    if (row?.imagePath === imagePath) return;
  } catch {
    // Cannot tell who owns it — leave it rather than break a job that might.
    return;
  }
  await deleteImageQuietly(imagePath, deps);
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
  maxCards?: unknown;
  /** The user's "beş şıklı kart" setting (§13.3); clamped to the deployment's own mode. */
  multipleChoiceMode?: unknown;
  /** Canonical subject name for per-card topics (schema v2.2). Unknown names degrade to null. */
  subject?: unknown;
  /**
   * The user pressed "Tekrar dene" on a page this server had given up on. Only
   * ever set by a deliberate human action, never by the queue's automatic
   * retries — see `JobStoreLike.requeue` for why that distinction is the point.
   */
  force?: unknown;
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
  if (!VISION_MIME_TYPES.has(mimeType)) {
    return fail(
      `Desteklenmeyen tür: ${mimeType || "(boş)"}. Kabul edilenler: ${[...VISION_MIME_TYPES].join(", ")}.`,
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

  const maxCards = parseMaxCards(body.maxCards, deps.openai.maxCardsPerKnowledgeUnit);
  if (maxCards === null) {
    return fail("maxCards 1 veya daha büyük bir tam sayı olmalı.", 400, false);
  }

  const mcMode = parseMultipleChoiceMode(body.multipleChoiceMode, deps.openai.multipleChoiceMode);
  if (mcMode === null) {
    return fail(`multipleChoiceMode şunlardan biri olmalı: ${MULTIPLE_CHOICE_MODES.join(", ")}.`, 400, false);
  }

  if (body.subject !== undefined && typeof body.subject !== "string") {
    return fail("subject bir metin (string) olmalı.", 400, false);
  }
  const subject = parseSubject(body.subject);

  if (body.force !== undefined && typeof body.force !== "boolean") {
    return fail("force true/false olmalı.", 400, false);
  }
  const force = body.force === true;

  // §21.3: refuse before spending, on the only bound knowable before the call.
  // Checked at submit rather than in the worker so the phone learns about it in
  // its own reply, instead of having to poll to find out it was never going to
  // happen.
  if (deps.cost.maxUsdPerCardGeneration > 0) {
    const upperBound = estimateOpenAICostUSD(
      outputCeilingUsage(deps.openai.maxOutputTokens),
      deps.cost,
    );
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
  // rather than silently re-armed into another identical failure — unless the
  // user asked for exactly that, which is the one thing that can carry
  // information this row does not have (a corrected key, most of all).
  if (existing?.status === "failed" && existing.retryable === false && !force) {
    return json(toJobView(existing), 200);
  }

  // Everything below is conditional on the state read above still holding.
  // Two submissions for one page really do overlap — `ProcessingQueue` allows a
  // manual retry to race a pull-to-refresh for the same page — and an
  // unconditional write here would let the later one reset a row the first
  // one's worker had already claimed, producing two paid generations racing
  // over one image and one result row (Codex, PR #25 P1).
  const imagePath = imagePathFor(jobId);
  const enqueueRequest = { id: jobId, imagePath, mimeType, hint, maxCards, mcMode, subject };
  // Set the moment this request could leave bytes at `imagePath` that no row
  // points at — which happens two ways, not one: a successful `expire` nulls
  // `image_path` while the old object is still in the bucket, and a successful
  // `putImage` writes bytes before any row claims them. An object nothing
  // references can never be found again: no poll returns it, no reclaim sweep
  // sees it (§7.3; Codex, PR #25 and #26).
  let mayHaveOrphanedObject = false;

  try {
    // A stale `processing` row has to be retired before it can be re-armed, and
    // that retirement is itself fenced to the attempt this request saw.
    if (existing?.status === "processing") {
      const retired = await deps.store.expire(jobId, existing.startedAt, STALE_MESSAGE, [
        ...existing.usage,
        staleAccounting(existing, deps),
      ]);
      if (!retired) return await currentState(jobId, deps, existing);
      mayHaveOrphanedObject = true;
    }

    await deps.store.putImage(imagePath, image, mimeType);
    mayHaveOrphanedObject = true;

    const armed = existing
      ? await deps.store.requeue(enqueueRequest, { includePermanent: force })
      : await deps.store.insertQueued(enqueueRequest);

    if (!armed) {
      // Lost the race, and this path leaks unless it cleans up. The winner owns
      // the object only while its row still points at it; if it had already
      // *finished*, its terminal path deleted the object and the upload above
      // put a fresh one back that nothing will ever reference (Codex, PR #26).
      // The ownership check below distinguishes the two.
      await deleteUnreferencedImage(jobId, imagePath, deps);
      return await currentState(jobId, deps, existing);
    }
  } catch (error) {
    if (mayHaveOrphanedObject) await deleteUnreferencedImage(jobId, imagePath, deps);
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

  // Rides the polls the phone is making anyway, like the staleness sweep
  // above, because there is no cron on this plan (ADR-006). Throttled and in
  // the background, so no poll ever waits on it or fails because of it.
  deps.runInBackground(() => sweepFinishedResults(deps));

  // Unknown ids simply do not come back. The phone reads an absent job as "not
  // submitted yet" and submits it, which is the correct recovery whether the row
  // was never written or was cleaned up.
  return json({ jobs: views }, 200);
}

/**
 * At most one purge attempt per store per interval. Keyed by the store object —
 * a serverless instance keeps one store for its lifetime, so this throttles per
 * instance; a fresh instance sweeping once immediately is harmless and is also
 * what lets every test observe the sweep without waiting.
 */
const RESULT_SWEEP_INTERVAL_MS = 6 * 60 * 60 * 1000;
const lastResultSweep = new WeakMap<JobStoreLike, number>();

/**
 * Deletes finished rows older than the configured retention (§7.3's text half;
 * 60 days by the owner's decision — docs/PRIVACY.md). Failures are logged and
 * dropped: an undeleted old row is a kept-too-long text, not a broken job, and
 * the next poll after the interval will try again.
 */
async function sweepFinishedResults(deps: JobsDependencies): Promise<void> {
  const now = deps.now?.() ?? Date.now();
  const last = lastResultSweep.get(deps.store);
  if (last !== undefined && now - last < RESULT_SWEEP_INTERVAL_MS) return;
  lastResultSweep.set(deps.store, now);
  try {
    const cutoff = new Date(now - deps.supabase.resultRetentionMs).toISOString();
    const removed = await deps.store.purgeFinished(cutoff);
    // Count only, never content (§7.3).
    if (removed > 0) deps.log?.({ event: "jobs.results_purged", removed });
  } catch (error) {
    deps.log?.({ event: "jobs.results_purge_failed", message: describe(error) });
  }
}

function isStale(row: JobRow, deps: JobsDependencies): boolean {
  const startedAt = Date.parse(row.startedAt ?? row.updatedAt);
  if (Number.isNaN(startedAt)) return false;
  const now = deps.now?.() ?? Date.now();
  return now - startedAt > deps.supabase.staleAfterMs;
}

async function reclaim(row: JobRow, deps: JobsDependencies): Promise<JobView> {
  const accounting = staleAccounting(row, deps);
  try {
    // Fenced to the attempt this poll observed. Without `startedAt` in the
    // condition, a job re-armed and re-claimed between the read and this write
    // would have its *new* attempt killed by a sweep aimed at the old one.
    const expired = await deps.store.expire(row.id, row.startedAt, STALE_MESSAGE, [
      ...row.usage,
      accounting,
    ]);
    if (!expired) {
      // It finished, or moved on, between our read and our write. Re-read
      // rather than report a stale snapshot as a failure the user would see for
      // no reason — and touch nothing, because whatever is there now is not the
      // attempt this sweep was about.
      const [fresh] = await deps.store.find([row.id]);
      return toJobView(fresh ?? row);
    }
    // Only now is the object certainly the retired attempt's own. Deleting it
    // before the fenced write succeeded could remove a replacement worker's
    // freshly uploaded page (Codex, PR #25 P2).
    if (row.imagePath) await deleteImageQuietly(row.imagePath, deps);
    deps.log?.({
      jobId: row.id,
      event: "jobs.expired",
      attempts: row.attempts,
      billing: accounting.billing,
      elapsedMs: accounting.latencyMs,
    });
    return {
      jobId: row.id,
      status: "failed",
      error: STALE_MESSAGE,
      retryable: true,
      attempts: row.attempts,
      // The reclaimed attempt's own line goes back with the view, so a phone
      // that only ever sees this one poll still records the killed generation.
      usage: [...row.usage, accounting],
    };
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
  let job: JobRow;

  try {
    const [row] = await deps.store.find([jobId]);
    if (!row || row.status !== "queued") return;

    // Exactly one caller wins this, so the submit's dispatch and a poll's
    // rescue can both fire without racing for the same paid generation.
    //
    // Everything below reads the row `claim` returned, not the snapshot above:
    // between the read and the claim the job can be failed and re-armed with
    // different parameters, and the claim is what decides which attempt this
    // worker actually owns — including the `startedAt` that fences its own
    // terminal write.
    const claimed = await deps.store.claim(jobId, row.attempts + 1);
    if (!claimed) return;
    job = claimed;
  } catch (error) {
    deps.log?.({ jobId, event: "jobs.claim_failed", message: describe(error) });
    return;
  }

  if (!job.imagePath) {
    // No provider call was made, so no ledger line: `usage` passes through
    // unchanged. A row full of zero-cost entries for things that never reached
    // a model would make "how many calls did this page take?" unanswerable.
    await finishFailed(jobId, job, "İş kaydında görüntü yolu yok.", false, deps, started, undefined, null);
    return;
  }

  // Flipped immediately before the call and read on the failure path, which is
  // the only way to tell a provider failure from a store failure that happened
  // on the way to one. `getImage` throwing means nothing was ever sent and
  // nothing was ever charged; anything after this line means a request left
  // the building and may well have been billed.
  let providerCalled = false;

  try {
    const image = await deps.store.getImage(job.imagePath);
    providerCalled = true;
    const { output, rawUsage } = await deps.generator.generateCards({
      requestId: jobId,
      image,
      mimeType: job.mimeType,
      hint: job.hint ?? undefined,
      // Recorded at submit time, because the worker runs long after the request
      // that carried the setting has gone.
      maxCards: job.maxCards ?? undefined,
      // Recorded at submit time for the same reason `maxCards` is: the setting
      // that chose this is long gone by the time the worker runs.
      multipleChoiceMode: job.mcMode ?? undefined,
      // Also recorded at submit time; an unknown name in an old row degrades
      // to "no topic assignment" inside the generator, never to a failure.
      subject: job.subject ?? undefined,
    });
    // §13.3's structural check, before the health gate: a card whose options
    // are broken is downgraded to a plain one rather than lost, so what the
    // gate sees is already the card as it will be stored.
    const checked = sanitizeMultipleChoice(output.cards);
    const output_ = { ...output, cards: checked.cards };
    const gate = runCardGate(output_, {
      maxCardsPerKnowledgeUnit: job.maxCards ?? deps.openai.maxCardsPerKnowledgeUnit,
    });
    // Schema v2.3's coverage accounting, derived from the same pair the
    // synchronous endpoint uses (`coverageFromGate`) so the two doors cannot
    // disagree about what "covered" means.
    const coverage = coverageFromGate(output_, gate);

    const accounting = accountingEntry({
      job,
      deps,
      started,
      outcome: "success",
      billing: "measured",
      usage: rawUsage,
      model: output.usage.model,
    });

    // Stored in the shape `/api/cards-vision` returns, so the phone's decoder is
    // the same one and this table never becomes a second definition of the card
    // contract.
    const completed = await deps.store.complete(
      jobId,
      job.startedAt,
      {
        jobId,
        output: output_,
        gate,
        coverage,
        cardPromptVersion: CARD_PROMPT_VERSION,
      },
      [...job.usage, accounting],
    );
    if (!completed) {
      // The fence lost: this attempt was expired and the row — and the bytes at
      // the shared object path — now belong to a newer one. Touch nothing;
      // deleting the path here would strand the live attempt without its image.
      deps.log?.({ jobId, event: "jobs.result_dropped", attempts: job.attempts });
      return;
    }
    await deleteImageQuietly(job.imagePath, deps);

    deps.log?.({
      jobId,
      event: "jobs.ready",
      cardCount: output_.cards.length,
      // Counts only, never option text (§7.3).
      multipleChoiceNotes: checked.notes.length,
      // Same three coverage counts `/api/cards-vision` logs, and never a
      // mark's `quote` — that is page content (§7.3).
      markCount: coverage.marks.length,
      uncoveredMarkCount: coverage.uncovered.length,
      unmarkedCardCount: coverage.unmarkedCardIds.length,
      inputTokens: rawUsage.inputTokens,
      cachedInputTokens: rawUsage.cachedInputTokens,
      outputTokens: rawUsage.outputTokens,
      reasoningTokens: rawUsage.reasoningTokens,
      estimatedCostUSD: output.usage.estimatedCostUSD,
      cardPromptVersion: CARD_PROMPT_VERSION,
      attempts: job.attempts,
      elapsedMs: (deps.now?.() ?? Date.now()) - started,
    });
  } catch (error) {
    const openAIError = error instanceof OpenAIError ? error : null;
    const supabaseError = error instanceof SupabaseError ? error : null;
    const retryable = openAIError?.transient ?? supabaseError?.transient ?? true;
    await finishFailed(
      jobId,
      job,
      describe(error),
      retryable,
      deps,
      started,
      job.imagePath,
      // A failure on the way to the provider is not a call and gets no ledger
      // line; a failure at or after it always does, priced if the provider
      // said what it spent and flagged `unmeasured` if it did not.
      providerCalled
        ? accountingEntry({
            job,
            deps,
            started,
            outcome: "failure",
            billing: billingVerdict(openAIError),
            usage: openAIError?.usage ?? EMPTY_TOKEN_USAGE,
            model: deps.openai.model,
            failureReason: openAIError?.reason ?? "unknown",
          })
        : null,
    );
  }
}

/**
 * What is known about the money for a failed provider call.
 *
 * The rule is about *where* the call died, not about how bad the error was.
 * An HTTP status means OpenAI answered before generating — rate limit, bad
 * key, exhausted quota — and charged nothing. A reported usage block means it
 * generated and told us the size. Anything else (our abort at the timeout, a
 * connection dropped mid-stream) means it generated and did not get to tell
 * us: billed, unmeasurable, and the single most useful thing this ledger can
 * point at.
 */
function billingVerdict(error: OpenAIError | null): CallAccounting["billing"] {
  if (!error) return "unmeasured";
  if (error.usage) return "measured";
  return error.status === undefined ? "unmeasured" : "none";
}

/**
 * One ledger line, priced from the deployment's configured rates.
 *
 * `attempt` comes from the row's own counter rather than a local variable so
 * that the phone can key on it: the same job polled from two devices, or twice
 * by one, must produce one `ModelRun` per real call and not one per poll.
 */
function accountingEntry(params: {
  job: JobRow;
  deps: JobsDependencies;
  started: number;
  outcome: CallAccounting["outcome"];
  billing: CallAccounting["billing"];
  usage: TokenUsage;
  model: string;
  failureReason?: string;
}): CallAccounting {
  const { job, deps, started, outcome, billing, usage, model, failureReason } = params;
  const now = deps.now?.() ?? Date.now();
  return {
    attempt: job.attempts,
    provider: "openai",
    model,
    purpose: "card_generation",
    promptVersion: CARD_PROMPT_VERSION,
    outcome,
    ...(failureReason ? { failureReason } : {}),
    billing,
    usage,
    // Priced even when `billing` is `unmeasured`: the usage is all zeros
    // there, so this comes out 0.00 and the phone reports the call as
    // "cost unknown" from the flag rather than from a fabricated figure.
    estimatedCostUSD: estimateOpenAICostUSD(usage, deps.cost),
    latencyMs: now - started,
    at: new Date(now).toISOString(),
  };
}

async function finishFailed(
  jobId: string,
  job: JobRow,
  message: string,
  retryable: boolean,
  deps: JobsDependencies,
  started: number,
  imagePath: string | undefined,
  /** `null` when this failure was not a provider call and so buys no ledger line. */
  accounting: CallAccounting | null,
): Promise<void> {
  const usage = accounting ? [...job.usage, accounting] : job.usage;
  let wrote = false;
  try {
    wrote = await deps.store.fail(jobId, job.startedAt, message, retryable, usage);
  } catch {
    // Nothing left to do: the row stays `processing` and the staleness sweep in
    // `poll` will reclaim it. That path exists precisely for this.
  }
  // Only the attempt that actually wrote the failure owns the object; a lost
  // fence means a newer attempt may be relying on fresh bytes at this same path.
  if (wrote && imagePath) await deleteImageQuietly(imagePath, deps);
  deps.log?.({
    jobId,
    event: "jobs.failed",
    retryable,
    attempts: job.attempts,
    // The whole point of the ledger, in the one line an operator reads first:
    // did this failure cost anything, and if so how much (§20.3, §7.3 — counts
    // and money only, never content).
    billing: accounting?.billing ?? "none",
    reason: accounting?.failureReason,
    inputTokens: accounting?.usage.inputTokens,
    cachedInputTokens: accounting?.usage.cachedInputTokens,
    outputTokens: accounting?.usage.outputTokens,
    reasoningTokens: accounting?.usage.reasoningTokens,
    estimatedCostUSD: accounting?.estimatedCostUSD,
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
