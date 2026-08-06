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
}

/**
 * Structural, not a class reference, so `_jobs.ts` can be driven by an
 * in-memory stand-in — the same role `CardGeneratorLike` plays for the
 * generator.
 */
export interface JobStoreLike {
  find(ids: string[]): Promise<JobRow[]>;
  /** Upserts to `queued`, clearing any previous error and result. */
  enqueue(request: EnqueueRequest): Promise<void>;
  /**
   * `queued` → `processing`, conditional on the row still being `queued`.
   *
   * This is the whole concurrency story: two invocations may both decide a job
   * needs running (the submit's own dispatch and a poll's rescue sweep), and
   * exactly one of them gets `true` back because PostgREST turns the status
   * filter into part of the UPDATE's WHERE clause. No lock, no queue table.
   */
  claim(id: string, attempts: number): Promise<boolean>;
  complete(id: string, result: unknown): Promise<void>;
  fail(id: string, error: string, retryable: boolean): Promise<void>;
  /** `processing` → failed-and-retryable, conditional on it still being `processing`. */
  expire(id: string, error: string): Promise<boolean>;
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

  async enqueue(request: EnqueueRequest): Promise<void> {
    await this.callJson(
      this.restBase,
      "POST",
      { Prefer: "resolution=merge-duplicates,return=minimal" },
      [
        {
          id: request.id,
          status: "queued",
          image_path: request.imagePath,
          mime_type: request.mimeType,
          hint: request.hint ?? null,
          // Cleared, not left behind: a resubmitted page must not show the
          // phone the error from the attempt before it.
          result: null,
          error: null,
          retryable: null,
          started_at: null,
          finished_at: null,
        },
      ],
    );
  }

  async claim(id: string, attempts: number): Promise<boolean> {
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${id}&status=eq.queued`,
      "PATCH",
      { Prefer: "return=representation" },
      { status: "processing", started_at: new Date().toISOString(), attempts },
    );
    return SupabaseJobStore.rows(payload).length > 0;
  }

  async complete(id: string, result: unknown): Promise<void> {
    await this.callJson(
      `${this.restBase}?id=eq.${id}`,
      "PATCH",
      { Prefer: "return=minimal" },
      {
        status: "ready",
        result,
        error: null,
        retryable: null,
        image_path: null,
        finished_at: new Date().toISOString(),
      },
    );
  }

  async fail(id: string, error: string, retryable: boolean): Promise<void> {
    await this.callJson(
      `${this.restBase}?id=eq.${id}`,
      "PATCH",
      { Prefer: "return=minimal" },
      {
        status: "failed",
        error,
        retryable,
        image_path: null,
        finished_at: new Date().toISOString(),
      },
    );
  }

  async expire(id: string, error: string): Promise<boolean> {
    const payload = await this.callJson(
      `${this.restBase}?id=eq.${id}&status=eq.processing`,
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
    return this.call(`${this.storageBase}/${path}`, "GET", {});
  }

  async deleteImage(path: string): Promise<void> {
    await this.call(`${this.storageBase}/${path}`, "DELETE", {});
  }
}
