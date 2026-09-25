import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { loadConfig, type ExamBankConfig } from "../config.js";
import {
  APP_SUBJECT, KLINIK_SUBJECTS, PAGE_SCHEMA, REPAIR_SCHEMA, REPAIR_SYSTEM, TEMEL_SUBJECTS, labelSchema, labelSystem,
} from "../prompts/examBank.js";
import { OpenAIError, type Transport } from "../providers/openai.js";
import { OpenAITextClient } from "../providers/openaiText.js";
import { SUBJECT_TOPIC_SCHEMA } from "../providers/subjectTopics.js";
import { buildRequest, checkPrices } from "../scripts/examBank.js";

const KEYS = [
  "OPENAI_MODEL", "OPENAI_REASONING_EFFORT", "OPENAI_MAX_OUTPUT_TOKENS",
  "OPENAI_EXAM_MODEL", "OPENAI_EXAM_REASONING_EFFORT", "OPENAI_EXAM_MAX_OUTPUT_TOKENS",
  "OPENAI_EXAM_USD_PER_MILLION_INPUT_TOKENS", "OPENAI_EXAM_USD_PER_MILLION_CACHED_INPUT_TOKENS",
  "OPENAI_EXAM_USD_PER_MILLION_OUTPUT_TOKENS", "OPENAI_USD_PER_MILLION_INPUT_TOKENS", "EXAM_BANK_MAX_USD",
];
let saved: Record<string, string | undefined> = {};
beforeEach(() => {
  saved = Object.fromEntries(KEYS.map((k) => [k, process.env[k]]));
  for (const k of KEYS) delete process.env[k];
});
afterEach(() => {
  for (const k of KEYS) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k];
  }
});

const CONFIG: ExamBankConfig = {
  model: "gpt-5.6-luna", reasoningEffort: "low", maxOutputTokens: 8000, imageDetail: "high", timeoutMs: 1000,
  usdPerMillionInputTokens: 0.2, usdPerMillionCachedInputTokens: 0.02, usdPerMillionOutputTokens: 1.2,
  maxUsdPerRun: 5, concurrency: 1,
};

function transportReturning(status: number, body: unknown): Transport & { sent: unknown[] } {
  const sent: unknown[] = [];
  return { sent, async post(_u, _k, b) { sent.push(b); return { status, body }; } };
}

describe("exam bank config", () => {
  it("does not inherit the card generator's effort, ceiling or prices", () => {
    // The production generator runs at high effort; a ~450-call batch
    // inheriting it would cost 5–8× the plan (§5.8).
    process.env.OPENAI_REASONING_EFFORT = "high";
    process.env.OPENAI_MAX_OUTPUT_TOKENS = "48000";
    process.env.OPENAI_USD_PER_MILLION_INPUT_TOKENS = "5";
    const exam = loadConfig().examBank;
    expect(exam.reasoningEffort).toBe("low");
    expect(exam.maxOutputTokens).toBe(8000);
    expect(exam.usdPerMillionInputTokens).toBe(0);
    expect(exam.maxUsdPerRun).toBe(5);
  });

  it("cached input falls back to the uncached price, never to zero", () => {
    process.env.OPENAI_EXAM_USD_PER_MILLION_INPUT_TOKENS = "0.2";
    expect(loadConfig().examBank.usdPerMillionCachedInputTokens).toBe(0.2);
  });

  it("refuses to run with no price, which would make the ledger read $0", () => {
    expect(checkPrices({ ...CONFIG, usdPerMillionOutputTokens: 0 })).toMatch(/fiyat girilmemiş/);
    expect(checkPrices(CONFIG)).toBeNull();
  });
});

describe("OpenAITextClient", () => {
  it("sends the exam model's own effort, ceiling and a strict schema", async () => {
    const t = transportReturning(200, {
      status: "completed",
      output: [{ type: "message", content: [{ type: "output_text", text: '{"items":[]}' }] }],
      usage: { input_tokens: 1000, output_tokens: 100, input_tokens_details: { cached_tokens: 0 } },
    });
    const client = new OpenAITextClient(CONFIG, "k", t);
    const result = await client.call({ system: "s", user: "u", schemaName: "x", schema: { type: "object" } });
    const body = t.sent[0] as Record<string, any>;
    expect(body.model).toBe("gpt-5.6-luna");
    expect(body.reasoning).toEqual({ effort: "low" });
    expect(body.max_output_tokens).toBe(8000);
    expect(body.text.format.strict).toBe(true);
    expect(result.json).toEqual({ items: [] });
    expect(result.costUSD).toBeCloseTo((1000 * 0.2 + 100 * 1.2) / 1_000_000, 10);
  });

  it("attaches images at the configured detail", () => {
    const client = new OpenAITextClient(CONFIG, "k", transportReturning(200, {}));
    const body = client.body({ system: "s", user: "u", images: [{ mimeType: "image/png", bytes: new Uint8Array([1]) }],
      schemaName: "x", schema: {} }) as Record<string, any>;
    const part = body.input[1].content[1];
    expect(part.type).toBe("input_image");
    expect(part.detail).toBe("high");
    expect(part.image_url.startsWith("data:image/png;base64,")).toBe(true);
  });

  it("carries the usage of a truncated response out with the error", async () => {
    const t = transportReturning(200, {
      status: "incomplete", incomplete_details: { reason: "max_output_tokens" },
      usage: { input_tokens: 10, output_tokens: 8000 },
    });
    const error = await new OpenAITextClient(CONFIG, "k", t)
      .call({ system: "s", user: "u", schemaName: "x", schema: {} }).catch((e) => e);
    expect(error).toBeInstanceOf(OpenAIError);
    expect(error.usage.outputTokens).toBe(8000);
    expect(error.reason).toBe("incomplete_max_output_tokens");
  });

  it("names an exhausted balance", async () => {
    const t = transportReturning(429, { error: { code: "insufficient_quota", message: "no money" } });
    const error = await new OpenAITextClient(CONFIG, "k", t)
      .call({ system: "s", user: "u", schemaName: "x", schema: {} }).catch((e) => e);
    expect(error.reason).toBe("insufficient_quota");
    expect(error.message).toMatch(/kredisi/);
  });
});

describe("exam bank prompts", () => {
  it("forbid correcting the booklet's text", () => {
    expect(REPAIR_SYSTEM).toMatch(/DÜZELTİLMEZ/);
    expect(REPAIR_SYSTEM).toMatch(/⟨\?⟩/);
  });

  it("have five named option fields, all required", () => {
    expect(REPAIR_SCHEMA.required).toEqual(["stem", "a", "b", "c", "d", "e"]);
    const item = (PAGE_SCHEMA.properties.questions as any).items;
    expect(item.required).toEqual(expect.arrayContaining(["number", "column", "a", "e", "continues"]));
  });

  it("offer only the test's own subjects, in ÖSYM's order", () => {
    const temel = labelSchema("T") as any;
    expect(temel.properties.items.items.properties.subject.enum).toEqual([...TEMEL_SUBJECTS]);
    const klinik = labelSchema("K") as any;
    expect(klinik.properties.items.items.properties.subject.enum).toEqual([...KLINIK_SUBJECTS]);
    expect(labelSystem("K")).toContain(KLINIK_SUBJECTS.join(", "));
  });

  it("offer topics only from the app's schema, or null", () => {
    const topic = (labelSchema("T") as any).properties.items.items.properties.topic;
    const known = new Set(SUBJECT_TOPIC_SCHEMA.flatMap((s) => s.topics));
    expect(topic.anyOf[1]).toEqual({ type: "null" });
    for (const t of topic.anyOf[0].enum) expect(known.has(t)).toBe(true);
  });

  it("map every ÖSYM subject to a subject the app knows", () => {
    const names = new Set(SUBJECT_TOPIC_SCHEMA.map((s) => s.name));
    for (const s of [...TEMEL_SUBJECTS, ...KLINIK_SUBJECTS]) expect(names.has(APP_SUBJECT[s] ?? s)).toBe(true);
  });
});

describe("buildRequest", () => {
  const image = () => new Uint8Array([137, 80, 78, 71]);

  it("repair sends the crop and the extracted text", () => {
    const r = buildRequest("repair", { id: "TUS-2013-2-T-028", text: "Histamin …", image: "crops/x.png" }, image);
    expect(r.images).toHaveLength(1);
    expect(r.user).toContain("TUS-2013-2-T-028");
    expect(r.schemaName).toBe("exam_repair");
  });

  it("label and check send numbered questions and no image", () => {
    const qs = [{ k: 1, id: "a", text: "Soru bir" }, { k: 2, id: "b", text: "Soru iki" }];
    const label = buildRequest("label", { id: "p|1", test: "K", questions: qs }, image);
    expect(label.user).toBe("[1] Soru bir\n\n[2] Soru iki");
    expect(label.images).toBeUndefined();
    expect(buildRequest("check", { id: "p", test: "T", questions: qs }, image).schemaName).toBe("exam_check");
  });
});
