/**
 * Supabase-backed job store for asynchronous card generation (docs/ADR-006).
 *
 * The phone used to hold one HTTP connection open for the whole OpenAI vision
 * call — one to five minutes — which no phone can be relied on to do: the
 * screen locks, iOS suspends the app, and the upload dies as a timeout. Here
 * the work is written down instead. The phone submits, the backend does the
 * generation in its own time, and the result waits in a row until the phone is
 * next awake to collect it.
 *
 * Talks to PostgREST and Storage over plain `fetch`, like `documentAI.ts` and
 * `openai.ts` do with their providers, rather than pulling in the Supabase SDK:
 * six endpoints, all of them a single request, and the `Transport` seam is what
 * lets the tests drive this without a network or a key.
 *
 * Privacy (§7.3): the page bytes rest in the bucket only while a job needs
 * them. Every terminal path — success, failure, expiry — deletes the object and
 * nulls `image_path`. Nothing here logs image content, card text or the key.
 */

/** The credential is deliberately absent: it is read at the composition root and passed in (§0.7). */
import type { MultipleChoiceMode } from "../config.js";

export interface SupabaseConfig {
  /** Project URL, e.g. `https://abcd.supabase.co`. Not a secret. */
  url: string;
  /** Private Storage bucket holding page bytes for the duration of a job. */
  bucket: string;
  /** Per-request timeout for a Supabase call, in milliseconds. */
  timeoutMs: number;
  /**
   * A job left `processing` longer than this is presumed dead — the serverless
   * instance that claimed it was killed at its own duration ceiling before it
   * could write an answer. Nothing else would ever notice: without this the row
   * would sit `processing` forever and the phone would poll it forever.
   */
  staleAfterMs: number;
}

export class SupabaseError extends Error {
  constructor(
    message: string,
    readonly status: number | undefined,
    /** Transient failures are worth retrying; permanent ones are not (§17). */
    readonly transient: boolean,
  ) {
    super(message);
    this.name = "SupabaseError";
  }
}

export type JobStatus = "queued" | "processing" | "ready" | "failed";

/** One row of `public.jobs`, in this codebase's camelCase. */
export interface JobRow {
  id: string;
  status: JobStatus;
  imagePath: string | null;
  mimeType: string;
  hint: string | null;
  /** The user's per-page card ceiling for this job; null means the deployment default. */
  maxCards: number | null;
  /** The user's five-option setting (§13.3); null means the deployment default. */
  mcMode: MultipleChoiceMode | null;
  attempts: number;
  /** `{ output, gate, cardPromptVersion }` — exactly what `/api/cards-vision` returns. */
  result: unknown | null;
  error: string | null;
  retryable: boolean | null;
  createdAt: string;
  updatedAt: string;
  startedAt: string | null;
  finishedAt: string | null;
}

export interface EnqueueRequest {
  id: string;
  imagePath: string;
  mimeType: string;
  hint?: string;
  maxCards?: number;
  mcMode?: MultipleChoiceMode;
}

/**
 * Structural, not a class reference, so `_jobs.ts` can be driven by an
 * in-memory stand-in — the same role `CardGeneratorLike` plays for the
 * generator.
 */
/**
 * Every state change is conditional on the state that justified it.
 *
 * That is the whole concurrency story, and it is not optional: two invocations
 * routinely decide the same job needs the same thing (the submit's own dispatch
 * and a poll's rescue sweep; a manual "Tekrar dene" racing a pull-to-refresh —
 * `ProcessingQueue` explicitly allows overlapping calls for one page). PostgREST
 * folds a filter into the UPDATE's WHERE clause, so the loser of any race
 * changes nothing and gets `false` back. No lock, no queue table.
 *
 * An unconditional write anywhere here reintroduces the failure this whole file
 * exists to prevent: two workers on one job means two paid generations and a
 * race over the shared image and result (Codex, PR #25 P1).
 */
export interface JobStoreLike {
  find(ids: string[]): Promise<JobRow[]>;
  /** Creates a brand-new queued job. `false` when a row for this id already exists. */
  insertQueued(request: EnqueueRequest): Promise<boolean>;
  /**
   * failed → `queued`, with fresh page bytes.
   *
   * Conditional on the row still being a failure, so a submission that raced
   * another one cannot reset a job a worker has already claimed.
   *
   * `includePermanent` drops only the `retryable=is.true` half of that
   * condition, never the `status=eq.failed` half. It exists for one caller: the
   * user pressing "Tekrar dene" on a page the server gave up on. Automatic
   * retries must not use it — a permanent failure is by definition one that
   * repeating alone will not fix — but a *person* asking again usually knows
   * something the server does not (a corrected API key, most of all), and
   * without this the page was unrecoverable: the job id is the page id, so the
   * only escape was deleting the capture and re-shooting it.
   */
  requeue(request: EnqueueRequest, options?: { includePermanent?: boolean }): Promise<boolean>;
  /**
   * `queued` → `processing`, conditional on the row still being `queued`.
   *
   * Returns the row as claimed rather than a bare boolean, for two reasons that
   * are both fences: the worker must generate from the parameters of the
   * attempt it actually won (a re-armed row may carry a different
   * hint/maxCards/mcMode than the snapshot the dispatcher read), and the
   * returned `startedAt` is the token `complete`/`fail` need to prove they are
   * still that attempt.
   */
  claim(id: string, attempts: number): Promise<JobRow | null>;
  /**
   * `processing` → `ready`, fenced to the attempt that claimed it — the same
   * `started_at` condition `expire` uses, for the same reason: between claiming
   * and finishing, the job can be expired, re-armed and claimed afresh, and an
   * id-only write would let the retired worker overwrite the live attempt.
   * `false` means the fence lost and nothing was written.
   */
  complete(id: string, startedAt: string | null, result: unknown): Promise<boolean>;
  /** Same fence as `complete`, for the same race. */
  fail(id: string, startedAt: string | null, error: string, retryable: boolean): Promise<boolean>;
  /**
   * `processing` → failed-and-retryable, fenced to one exact attempt.
   *
   * `startedAt` is part of the condition, not just `status`: between reading a
   * stale row and writing this, the job can be re-armed and claimed afresh, and
   * a status-only condition would then kill the *new* attempt (Codex, PR #25 P2).
   */
  expire(id: string, startedAt: string | null, error: string): Promise<boolean>;
  putImage(path: string, bytes: Uint8Array, mimeType: string): Promise<void>;
  getImage(path: string): Promise<Uint8Array>;
  deleteImage(path: string): Promise<void>;
}

/** The HTTP call, isolated so tests can drive the store without a network or a key. */
export interface Transport {
  send(request: {
    url: string;
    method: string;
    headers: Record<string, string>;
    body?: Uint8Array | string;
    timeoutMs: number;
  }): Promise<{ status: number; body: Uint8Array }>;
}

export const fetchTransport: Transport = {
  async send({ url, method, headers, body, timeoutMs }) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, {
        method,
        headers,
        // Cast because this project compiles against Node's own fetch typings
        // (`lib: ES2023`, no DOM), whose body union does not name `Uint8Array`
        // even though the runtime accepts one — which is how the page bytes get
        // uploaded without being base64'd a second time.
        body: body as RequestInit["body"],
        signal: controller.signal,
      });
      const buffer = await response.arrayBuffer();
      return { status: response.status, body: new Uint8Array(buffer) };
    } finally {
      clearTimeout(timer);
    }
  },
};

/** 5xx and the two "come back later" 4xx codes are worth retrying; the rest are our bug (§17). */
function isTransientStatus(status: number): boolean {
  return status >= 500 || status === 408 || status === 429;
}

function decodeText(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

interface JobRowJson {
  id: string;
  status: JobStatus;
  image_path: string | null;
  mime_type: string;
  hint: string | null;
  max_cards: number | null;
  mc_mode: MultipleChoiceMode | null;
  attempts: number;
  result: unknown | null;
  error: string | null;
  retryable: boolean | null;
  created_at: string;
  updated_at: string;
  started_at: string | null;
  finished_at: string | null;
}

export function toJobRow(row: JobRowJson): JobRow {
  return {
    id: row.id,
    status: row.status,
    imagePath: row.image_path,
    mimeType: row.mime_type,
    hint: row.hint,
    maxCards: row.max_cards,
    mcMode: row.mc_mode,
    attempts: row.attempts,
    result: row.result,
    error: row.error,
    retryable: row.retryable,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    startedAt: row.started_at,
    finishedAt: row.finished_at,
  };
}

export class SupabaseJobStore implements JobStoreLike {
  constructor(
    private readonly config: SupabaseConfig,
    private readonly serviceRoleKey: string,
    private readonly transport: Transport = fetchTransport,
  ) {}

  private get restBase(): string {
    return `${this.config.url.replace(/\/+$/, "")}/rest/v1/jobs`;
  }

  private get storageBase(): string {
    return `${this.config.url.replace(/\/+$/, "")}/storage/v1/object/${this.config.bucket}`;
  }

  /**
   * Both headers carry the same value, which looks redundant but is not:
   * PostgREST authenticates with `apikey` and authorises the *role* from the
   * bearer token. Sending only one of them yields a confusing anon-role denial
   * rather than an auth error.
   */
  private authHeaders(): Record<string, string> {
    return {
      apikey: this.serviceRoleKey,
      Authorization: `Bearer ${this.serviceRoleKey}`,
    };
  }

  private async call(
    url: string,
    method: string,
    extraHeaders: Record<string, string>,
    body?: Uint8Array | string,
  ): Promise<Uint8Array> {
    const response = await this.transport.send({
      url,
      method,
      headers: { ...this.authHeaders(), ...extraHeaders },
      body,
      timeoutMs: this.config.timeoutMs,
    });

    if (response.status < 200 || response.status >= 300) {
      // Supabase's error bodies are small and describe the *call* — a missing
      // column, a bad filter — never the content (§7.3). Truncated anyway.
      const detail = decodeText(response.body).slice(0, 200) || "ayrıntı yok";
      throw new SupabaseError(
        `Supabase ${response.status}: ${detail}`,
        response.status,
        isTransientStatus(response.status),
      );
    }
    return response.body;
  }

  private async callJson(
    url: string,
    method: string,
    extraHeaders: Record<string, string>,
    body?: unknown,
  ): Promise<unknown> {
    const bytes = await this.call(
      url,
      method,
      {
        "Content-Type": "application/json",
        ...extraHeaders,
      },
      body === undefined ? undefined : JSON.stringify(body),
    );
    const text = decodeText(bytes);
    if (!text) return undefined;
    try {
      return JSON.parse(text);
    } catch {
      throw new SupabaseError("Supabase yanıtı geçerli JSON değil.", undefined, false);
    }
  }

  private static rows(payload: unknown): JobRowJson[] {
    return Array.isArray(payload) ? (payload as JobRowJson[]) : [];
  }

  async find(ids: string[]): Promise<JobRow[]> {
    if (ids.length === 0) return [];
    // PostgREST's `in.(…)` takes a bare comma-separated list; the ids are
    // validated as UUIDs before they reach here, so there is nothing to quote.
    const filter = `id=in.(${ids.join(",")})`;
    const payload = await this.callJson(`${this.restBase}?${filter}&select=*`, "GET", {});
    return SupabaseJobStore.rows(payload).map(toJobRow);
  }

  /** The queued-state columns both entry points write, in one place. */
  private static queuedFields(request: EnqueueRequest): Record<string, unknown> {
    return {
      status: "queued",
      image_path: request.imagePath,
      mime_type: request.mimeType,
      hint: request.hint ?? null,
      max_cards: request.maxCards ?? null,
      mc_mode: request.mcMode ?? null,
      // Cleared, not left behind: a resubmitted page must not show the phone
      // the error from the attempt before it.
      result: null,
      error: null,
      retryable: null,
      started_at: null,
      finished_at: null,
    };
  }

  async insertQueued(request: EnqueueRequest): Promise<boolean> {
    try {
      // A plain insert, deliberately *not* an upsert: the primary key is what
      // makes a concurrent second submission lose rather than overwrite a row
      // that may already have been claimed.
      await this.callJson(this.restBase, "POST", { Prefer: "return=minimal" }, [
        { id: request.id, ...SupabaseJobStore.queuedFields(request) },
      ]);
      return true;
    } catch (error) {
      // 409 is the primary-key conflict — the expected way to lose, not a fault.
      if (error instanceof SupabaseError && error.status === 409) return false;
      throw error;
    }
  }

  async requeue(
    request: EnqueueRequest,
    options: { includePermanent?: boolean } = {},
  ): Promise<boolean> {
    const retryableFilter = options.includePermanent ? "" : "&retryable=is.true";
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${request.id}&status=eq.failed${retryableFilter}`,
      "PATCH",
      { Prefer: "return=representation" },
      SupabaseJobStore.queuedFields(request),
    );
    return SupabaseJobStore.rows(payload).length > 0;
  }

  async claim(id: string, attempts: number): Promise<JobRow | null> {
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${id}&status=eq.queued`,
      "PATCH",
      { Prefer: "return=representation" },
      { status: "processing", started_at: new Date().toISOString(), attempts },
    );
    const [row] = SupabaseJobStore.rows(payload).map(toJobRow);
    return row ?? null;
  }

  /** Same `started_at` encoding rule as `expire` — see the comment there. */
  private static startedAtFilter(startedAt: string | null): string {
    return startedAt
      ? `&started_at=eq.${encodeURIComponent(startedAt)}`
      : "&started_at=is.null";
  }

  async complete(id: string, startedAt: string | null, result: unknown): Promise<boolean> {
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${id}&status=eq.processing${SupabaseJobStore.startedAtFilter(startedAt)}`,
      "PATCH",
      { Prefer: "return=representation" },
      {
        status: "ready",
        result,
        error: null,
        retryable: null,
        image_path: null,
        finished_at: new Date().toISOString(),
      },
    );
    return SupabaseJobStore.rows(payload).length > 0;
  }

  async fail(id: string, startedAt: string | null, error: string, retryable: boolean): Promise<boolean> {
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${id}&status=eq.processing${SupabaseJobStore.startedAtFilter(startedAt)}`,
      "PATCH",
      { Prefer: "return=representation" },
      {
        status: "failed",
        error,
        retryable,
        image_path: null,
        finished_at: new Date().toISOString(),
      },
    );
    return SupabaseJobStore.rows(payload).length > 0;
  }

  async expire(id: string, startedAt: string | null, error: string): Promise<boolean> {
    // Encoded, not interpolated raw: a Postgres timestamp carries `+00:00`, and
    // a bare `+` in a query string means a space — the filter would match
    // nothing and every reclaim would silently become a no-op.
    const attemptFilter = startedAt
      ? `&started_at=eq.${encodeURIComponent(startedAt)}`
      : "&started_at=is.null";
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${id}&status=eq.processing${attemptFilter}`,
      "PATCH",
      { Prefer: "return=representation" },
      {
        status: "failed",
        error,
        // Always retryable: a worker that vanished tells us nothing about
        // whether the page itself is generatable.
        retryable: true,
        image_path: null,
        finished_at: new Date().toISOString(),
      },
    );
    return SupabaseJobStore.rows(payload).length > 0;
  }

  async putImage(path: string, bytes: Uint8Array, mimeType: string): Promise<void> {
    await this.call(`${this.storageBase}/${path}`, "POST", {
      "Content-Type": mimeType,
      // A resubmitted page reuses its own object path; without this the second
      // upload fails on "already exists".
      "x-upsert": "true",
    }, bytes);
  }

  async getImage(path: string): Promise<Uint8Array> {
    try {
      return await this.call(`${this.storageBase}/${path}`, "GET", {});
    } catch (error) {
      // A 404 here is not "our bug" the way it is on the REST endpoints: the
      // object path is deterministic (`pages/<jobId>`), so a concurrent
      // expire/submit cycle can legitimately have deleted these bytes between
      // this worker's claim and this read. Non-retryable would lock the page
      // forever (`requeue` demands `retryable=is.true` and the job id never
      // changes); retryable lets the phone's next submit upload a fresh copy.
      if (error instanceof SupabaseError && error.status === 404) {
        throw new SupabaseError(
          "Sayfa görüntüsü bulunamadı; eşzamanlı bir temizlik silmiş olabilir. Yeniden gönderim yeni bir kopya yükler.",
          404,
          true,
        );
      }
      throw error;
    }
  }

  async deleteImage(path: string): Promise<void> {
    await this.call(`${this.storageBase}/${path}`, "DELETE", {});
  }
}
