/**
 * One structured OpenAI call — text, optionally with images — for the
 * past-exam bank build (docs/PLAN-cikmis-soru-bankasi.md §5.8).
 *
 * The card generator (`openai.ts`) is shaped around one job: a marked page in,
 * the §14 card contract out, with its own sanitisers. The bank's four stages
 * need the same transport, error vocabulary and usage accounting with their
 * own schemas, so they share those pieces rather than the generator itself.
 *
 * Same privacy rule as every provider (§7.3): errors describe the call — its
 * status, the provider's message, a short reason — never the question text.
 */

import type { ExamBankConfig } from "../config.js";
import { OpenAIError, extractOutputText, fetchTransport, type ResponsesApiBody, type Transport } from "./openai.js";
import { EMPTY_TOKEN_USAGE, estimateCostUSD, readOpenAIUsage, type TokenUsage } from "./tokenUsage.js";

const ENDPOINT = "https://api.openai.com/v1/responses";

export interface TextImage {
  mimeType: string;
  bytes: Uint8Array;
}

export interface TextCallRequest {
  system: string;
  user: string;
  images?: TextImage[];
  /** Structured Outputs schema name and body; `strict` is always on. */
  schemaName: string;
  schema: Record<string, unknown>;
}

export interface TextCallResult {
  json: Record<string, unknown>;
  usage: TokenUsage;
  costUSD: number;
  latencyMs: number;
}

export class OpenAITextClient {
  constructor(
    private readonly config: ExamBankConfig,
    private readonly apiKey: string,
    private readonly transport: Transport = fetchTransport,
    private readonly now: () => number = Date.now,
  ) {}

  /** Priced with the exam model's own prices (never the production model's). */
  cost(usage: TokenUsage): number {
    return estimateCostUSD(usage, {
      usdPerMillionInputTokens: this.config.usdPerMillionInputTokens,
      usdPerMillionCachedInputTokens: this.config.usdPerMillionCachedInputTokens,
      usdPerMillionOutputTokens: this.config.usdPerMillionOutputTokens,
    });
  }

  body(request: TextCallRequest): Record<string, unknown> {
    const content: Array<Record<string, unknown>> = [{ type: "input_text", text: request.user }];
    for (const image of request.images ?? []) {
      content.push({
        type: "input_image",
        image_url: `data:${image.mimeType};base64,${Buffer.from(image.bytes).toString("base64")}`,
        detail: this.config.imageDetail,
      });
    }
    return {
      model: this.config.model,
      reasoning: { effort: this.config.reasoningEffort },
      max_output_tokens: this.config.maxOutputTokens,
      input: [
        { role: "system", content: [{ type: "input_text", text: request.system }] },
        { role: "user", content },
      ],
      text: { format: { type: "json_schema", name: request.schemaName, schema: request.schema, strict: true } },
    };
  }

  async call(request: TextCallRequest): Promise<TextCallResult> {
    const started = this.now();
    let response: { status: number; body: unknown };
    try {
      response = await this.transport.post(ENDPOINT, this.apiKey, this.body(request), this.config.timeoutMs);
    } catch (error) {
      const aborted = error instanceof Error && error.name === "AbortError";
      throw new OpenAIError(
        aborted
          ? `OpenAI çağrısı ${this.config.timeoutMs} ms zaman aşımında kesildi; ücretlendirilmiş olabilir.`
          : `OpenAI'ye ulaşılamadı: ${error instanceof Error ? error.message : "bilinmeyen ağ hatası"}`,
        undefined,
        true,
        undefined,
        aborted ? "timeout" : "transport",
      );
    }
    const body = response.body as ResponsesApiBody;
    const usage = readOpenAIUsage(body);
    if (response.status < 200 || response.status >= 300) {
      const detail = (body as { error?: { message?: string; code?: string } } | undefined)?.error;
      const quota = detail?.code === "insufficient_quota";
      throw new OpenAIError(
        quota
          ? `OpenAI kredisi/kotası tükendi (insufficient_quota): ${detail?.message ?? ""}`
          : `OpenAI ${response.status}: ${detail?.message ?? "ayrıntı yok"}`,
        response.status,
        response.status === 408 || response.status === 429 || response.status >= 500,
        undefined,
        quota ? "insufficient_quota" : `http_${response.status}`,
      );
    }
    if (body.status === "incomplete") {
      const reason = body.incomplete_details?.reason ?? "bilinmeyen";
      throw new OpenAIError(`Model üretimi tamamlamadı: ${reason}.`, undefined, true, usage ?? undefined,
        `incomplete_${reason}`);
    }
    if (body.status === "failed") {
      throw new OpenAIError(`Sağlayıcı üretimi başarısız bildirdi: ${body.error?.message ?? "ayrıntı yok"}`,
        undefined, true, usage ?? undefined, "provider_failed");
    }
    const text = extractOutputText(body, usage);
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      throw new OpenAIError("Model yanıtı geçerli JSON değil.", undefined, false, usage ?? undefined, "json_parse");
    }
    if (typeof json !== "object" || json === null || Array.isArray(json)) {
      throw new OpenAIError("Model yanıtı bir JSON nesnesi değil.", undefined, false, usage ?? undefined, "json_shape");
    }
    const measured = usage ?? EMPTY_TOKEN_USAGE;
    return { json: json as Record<string, unknown>, usage: measured, costUSD: this.cost(measured),
      latencyMs: this.now() - started };
  }
}
