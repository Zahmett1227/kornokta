/**
 * The past-exam bank's model stages (docs/PLAN-cikmis-soru-bankasi.md §5.8),
 * run once on the owner's Mac over job files the Python pipeline wrote:
 *
 *     npm run exam-bank -- ../tools/exam_bank/out/jobs/label.json
 *
 * Stages: `repair` (A5 — one question's crop), `vision` (A6 — one 2011/1
 * page), `label` (A7 — a run of up to 25 questions), `check` (V6 — 15 keyed
 * questions of one paper, answered blind).
 *
 * Results go next to the job file (`results/<stage>.json`); every call, paid
 * or failed, is appended to `ledger.jsonl` with `purpose: "exam_bank_build"`.
 * Re-running a stage re-sends only the items that have no result yet, so a
 * run stopped by the budget, a quota or a network drop resumes without paying
 * twice for what it already has.
 *
 * Money: the exam model's own prices must be set (`OPENAI_EXAM_USD_PER_
 * MILLION_*`) — with zero prices the ledger would read $0 and the budget
 * check would never trip, the silent mis-count CLAUDE.md warns about — and
 * the run stops before a call that would take the cumulative spend over
 * `EXAM_BANK_MAX_USD` (default $5, the plan's ceiling for the whole build).
 *
 * Privacy (§7.3): question text and images go to OpenAI and to the local,
 * gitignored out/ folder only. The terminal prints ids, counts, tokens, money.
 */

import { existsSync, readFileSync } from "node:fs";
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnvFile } from "dotenv";

import { loadConfig, type ExamBankConfig } from "../config.js";
import {
  CHECK_SCHEMA, CHECK_SYSTEM, EXAM_BANK_PROMPT_VERSION, PAGE_SCHEMA, PAGE_SYSTEM, REPAIR_SCHEMA, REPAIR_SYSTEM,
  labelSchema, labelSystem, labelUser, repairUser,
} from "../prompts/examBank.js";
import { OpenAIError } from "../providers/openai.js";
import { OpenAITextClient, type TextCallRequest } from "../providers/openaiText.js";

export type Stage = "repair" | "vision" | "label" | "check";

export interface JobItem {
  id: string;
  /** repair: the extracted (incomplete) text. */
  text?: string;
  /** repair / vision: an image path relative to the job file. */
  image?: string;
  /** label / check: the paper's test ("T", "T2", "K"). */
  test?: string;
  questions?: Array<{ k: number; id: string; text: string }>;
}

export interface JobFile {
  stage: Stage;
  items: JobItem[];
}

export interface ItemResult {
  id: string;
  ok: boolean;
  output: Record<string, unknown> | null;
  error: string | null;
  costUSD: number;
  usage: Record<string, number> | null;
  latencyMs: number;
  attempts: number;
}

export interface ResultFile {
  stage: Stage;
  model: string;
  reasoningEffort: string;
  promptVersion: string;
  items: ItemResult[];
}

/** The request one job item becomes. Pure, so tests can check it without a network. */
export function buildRequest(stage: Stage, item: JobItem, readImage: (path: string) => Uint8Array): TextCallRequest {
  switch (stage) {
    case "repair":
      return {
        system: REPAIR_SYSTEM, user: repairUser(item.id, item.text ?? ""),
        images: [{ mimeType: "image/png", bytes: readImage(item.image ?? "") }],
        schemaName: "exam_repair", schema: REPAIR_SCHEMA,
      };
    case "vision":
      return {
        system: PAGE_SYSTEM, user: `Sayfa: ${item.id}`,
        images: [{ mimeType: "image/png", bytes: readImage(item.image ?? "") }],
        schemaName: "exam_page", schema: PAGE_SCHEMA,
      };
    case "label":
      return {
        system: labelSystem(item.test ?? "T"), user: labelUser(item.questions ?? []),
        schemaName: "exam_label", schema: labelSchema(item.test ?? "T"),
      };
    case "check":
      return {
        system: CHECK_SYSTEM, user: labelUser(item.questions ?? []),
        schemaName: "exam_check", schema: CHECK_SCHEMA,
      };
  }
}

/** Refuses to spend with no price set: the ledger would silently read $0. */
export function checkPrices(config: ExamBankConfig): string | null {
  if (config.usdPerMillionInputTokens <= 0 || config.usdPerMillionOutputTokens <= 0) {
    return (
      `${config.model} için fiyat girilmemiş: OPENAI_EXAM_USD_PER_MILLION_INPUT_TOKENS ve ` +
      "OPENAI_EXAM_USD_PER_MILLION_OUTPUT_TOKENS ayarlanmalı (defter ve bütçe tavanı fiyatla çalışır)."
    );
  }
  return null;
}

interface Budget {
  spent: number;
  readonly max: number;
}

async function runItem(client: OpenAITextClient, request: TextCallRequest, item: JobItem, budget: Budget,
  ledger: string, stage: Stage, config: ExamBankConfig, maxAttempts = 3): Promise<ItemResult> {
  let attempts = 0;
  let lastError = "";
  while (attempts < maxAttempts) {
    attempts += 1;
    if (budget.max > 0 && budget.spent >= budget.max) {
      return { id: item.id, ok: false, output: null, error: "budget", costUSD: 0, usage: null, latencyMs: 0, attempts };
    }
    const at = new Date().toISOString();
    try {
      const result = await client.call(request);
      budget.spent += result.costUSD;
      await appendFile(ledger, JSON.stringify({
        purpose: "exam_bank_build", stage, id: item.id, model: config.model, effort: config.reasoningEffort,
        promptVersion: EXAM_BANK_PROMPT_VERSION, outcome: "success", billing: "measured",
        usage: result.usage, estimatedCostUSD: result.costUSD, latencyMs: result.latencyMs, at,
      }) + "\n");
      return { id: item.id, ok: true, output: result.json, error: null, costUSD: result.costUSD,
        usage: { ...result.usage }, latencyMs: result.latencyMs, attempts };
    } catch (error) {
      const e = error instanceof OpenAIError ? error : null;
      const cost = e?.usage ? client.cost(e.usage) : 0;
      budget.spent += cost;
      lastError = e?.reason ?? (error instanceof Error ? error.message : "bilinmeyen");
      await appendFile(ledger, JSON.stringify({
        purpose: "exam_bank_build", stage, id: item.id, model: config.model, effort: config.reasoningEffort,
        promptVersion: EXAM_BANK_PROMPT_VERSION, outcome: "failure", failureReason: lastError,
        billing: e?.usage ? "measured" : e?.reason === "timeout" ? "unmeasured" : "none",
        usage: e?.usage ?? null, estimatedCostUSD: cost, at,
      }) + "\n");
      if (e?.reason === "insufficient_quota" || !(e?.transient ?? true)) break;
      await new Promise((r) => setTimeout(r, 2000 * attempts));
    }
  }
  return { id: item.id, ok: false, output: null, error: lastError, costUSD: 0, usage: null, latencyMs: 0, attempts };
}

async function main(argv: string[]): Promise<number> {
  const jobPath = argv.find((a) => !a.startsWith("--"));
  if (!jobPath) {
    console.error("Kullanım: npm run exam-bank -- <out/jobs/<aşama>.json> [--limit N]");
    return 2;
  }
  const limitArg = argv.indexOf("--limit");
  const limit = limitArg >= 0 ? Number(argv[limitArg + 1]) : Infinity;

  const here = dirname(fileURLToPath(import.meta.url));
  loadEnvFile({ path: join(here, "..", ".env"), quiet: true });
  const config = loadConfig().examBank;
  const priceProblem = checkPrices(config);
  if (priceProblem) {
    console.error(priceProblem);
    return 2;
  }
  const apiKey = process.env.OPENAI_API_KEY?.trim();
  if (!apiKey) {
    console.error("OPENAI_API_KEY yok (backend/.env).");
    return 2;
  }

  const absJob = resolve(jobPath);
  const job = JSON.parse(await readFile(absJob, "utf8")) as JobFile;
  const outDir = join(dirname(absJob), "..", "results");
  await mkdir(outDir, { recursive: true });
  const outPath = join(outDir, `${job.stage}.json`);
  const ledger = join(dirname(absJob), "..", "ledger.jsonl");

  const previous: ResultFile | null = existsSync(outPath) ? JSON.parse(readFileSync(outPath, "utf8")) : null;
  const done = new Map((previous?.items ?? []).filter((r) => r.ok).map((r) => [r.id, r]));
  const todo = job.items.filter((item) => !done.has(item.id)).slice(0, limit);
  const budget: Budget = { spent: 0, max: config.maxUsdPerRun };
  // What the ledger already holds counts against the ceiling: the ceiling is
  // for the whole build, not for one invocation.
  if (existsSync(ledger)) {
    for (const line of readFileSync(ledger, "utf8").split("\n")) {
      if (line.trim()) budget.spent += (JSON.parse(line).estimatedCostUSD as number) ?? 0;
    }
  }
  console.log(`${job.stage}: ${job.items.length} iş, ${done.size} hazır, ${todo.length} gönderilecek · ` +
    `${config.model} @${config.reasoningEffort} · şimdiye kadar $${budget.spent.toFixed(3)} / $${config.maxUsdPerRun}`);

  const client = new OpenAITextClient(config, apiKey);
  const readImage = (p: string) => new Uint8Array(readFileSync(join(dirname(absJob), p)));
  const results = new Map(done);
  let next = 0;
  let finished = 0;
  const save = async () => {
    const file: ResultFile = { stage: job.stage, model: config.model, reasoningEffort: config.reasoningEffort,
      promptVersion: EXAM_BANK_PROMPT_VERSION, items: job.items.map((i) => results.get(i.id)).filter(Boolean) as ItemResult[] };
    await writeFile(outPath, JSON.stringify(file, null, 1));
  };
  const worker = async () => {
    while (next < todo.length) {
      const item = todo[next++]!;
      const result = await runItem(client, buildRequest(job.stage, item, readImage), item, budget, ledger, job.stage, config);
      if (result.ok || !results.has(item.id)) results.set(item.id, result);
      finished += 1;
      if (finished % 10 === 0 || finished === todo.length) {
        console.log(`  ${finished}/${todo.length} · $${budget.spent.toFixed(3)}`);
        await save();
      }
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, config.concurrency) }, worker));
  await save();
  const failed = [...results.values()].filter((r) => !r.ok);
  console.log(`${job.stage}: ${results.size - failed.length}/${job.items.length} tamam, ${failed.length} başarısız · ` +
    `toplam $${budget.spent.toFixed(3)}`);
  for (const f of failed.slice(0, 20)) console.log(`  ${f.id}: ${f.error}`);
  return failed.length ? 1 : 0;
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
