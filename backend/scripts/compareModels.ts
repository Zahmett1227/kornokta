/**
 * Runs the same real pages through several models and prices the difference.
 *
 *     npm run compare -- --models "gpt-5.6-sol:5/0.5/30,gpt-5.6-terra:2/0.2/12"
 *
 * Answers half of "can we spend less without losing quality?". This half — the
 * money — it answers on its own, exactly, from the providers' own reported
 * usage. The other half is a judgement about medical cards on the owner's own
 * marked pages, which no benchmark published anywhere can settle: the tiers'
 * scores are reported on agentic and long-context work, and this app does one
 * short-context vision read of faint highlighter and margin handwriting.
 *
 * So the quality half is set up here and decided by a human, **blind**. The
 * script writes three files:
 *
 *   - `compare-<stamp>.json`   full report: every card, priced, per model.
 *   - `blind-<stamp>.json`     every card from every model, shuffled together,
 *                              with no model attribution. This is what gets
 *                              read and scored.
 *   - `key-<stamp>.json`       cardId → model. Not opened until scoring is done.
 *
 * The blinding is not ceremony. Knowing which tier produced a card is exactly
 * the kind of thing that decides a borderline score, and the whole question
 * here is borderline by construction — nobody switches tiers over an obvious
 * quality collapse, they switch over "close enough". Score the blind sheet
 * against the §23.3 rubric, then join with the key:
 *
 *     python -m evals.model_compare.report --scores <scores.json> \
 *         --key evals/reports/key-<stamp>.json \
 *         --report evals/reports/compare-<stamp>.json
 *
 * Uses the production generator — same prompt, same schema, same sanitisation,
 * same gate — because a comparison run through a different code path measures
 * the path, not the model.
 *
 * Privacy (§7.3): page bytes and card text go only to the local, gitignored
 * report files. The terminal prints counts, tokens, money and durations.
 */

import { readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { basename, extname, join } from "node:path";
import { config as loadEnvFile } from "dotenv";

if (existsSync(".env")) {
  const result = loadEnvFile();
  if (result.error) {
    console.error(`.env okunamadı: ${result.error.message}`);
    process.exit(1);
  }
}

import { loadConfig, ConfigError } from "../config.js";
import { CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";
import { OpenAICardGenerator, OpenAIError, estimateOpenAICostUSD } from "../providers/openai.js";
import { runCardGate } from "../providers/cardGate.js";
import { sanitizeMultipleChoice } from "../providers/multipleChoice.js";
import { EMPTY_TOKEN_USAGE, type TokenUsage } from "../providers/tokenUsage.js";

const USAGE = `
Kullanım:
  npm run compare -- --models "<model>[:<girdi>/<önbellek>/<çıktı>], ..." [seçenekler]

Seçenekler:
  --models <liste>   Karşılaştırılacak modeller, virgülle. Her modele kendi
                     1M token fiyatını ekleyebilirsin: girdi/önbellek/çıktı USD.
                     Fiyat verilmezse .env'deki OPENAI_USD_PER_MILLION_* kullanılır
                     ve rapor bunu "fiyat varsayılandan" diye işaretler — modeller
                     farklı fiyatlıyken bu karşılaştırmayı anlamsız yapar, o yüzden
                     uyarı basılır. (§0.6: fiyat asla uydurulmaz, hep verilir.)
  --pages <dizin>    İşaretli sayfa görüntüleri (varsayılan: ../evals/fixtures/pages)
  --subject <ders>   Konu ataması için kanonik ders adı (örn. Patoloji)
  --max-cards <n>    Sayfa başına kart tavanı (varsayılan: .env'deki değer)
  --out <dizin>      Rapor dizini (varsayılan: ../evals/reports)
  --help

Her sayfa her model için BİR gerçek çağrı yapar: 5 sayfa × 2 model = 10 çağrı.
Maliyet, çağrıların kendi bildirdiği token sayılarından hesaplanır.
`.trim();

const IMAGE_MIME: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
};

interface ModelSpec {
  model: string;
  prices: {
    openaiUsdPerMillionInputTokens: number;
    openaiUsdPerMillionCachedInputTokens: number;
    openaiUsdPerMillionOutputTokens: number;
  };
  /** True when no per-model price was given and the deployment's own was used. */
  pricesInherited: boolean;
}

interface PageResult {
  page: string;
  model: string;
  ok: boolean;
  error?: string;
  failureReason?: string;
  cardCount: number;
  /** Cards the deterministic gate threw away — paid for, never shown. */
  rejectedCount: number;
  multipleChoiceCount: number;
  lowConfidenceCount: number;
  topicAssignedCount: number;
  usage: TokenUsage;
  estimatedCostUSD: number;
  latencyMs: number;
  cards: unknown[];
}

function parseArgs(argv: string[]): Record<string, string | boolean> {
  const args: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token?.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) {
      args[key] = true;
    } else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

/**
 * `name` or `name:input/cached/output`.
 *
 * The prices are required *per model* rather than read from the environment,
 * because the environment holds exactly one set and the entire point of this
 * script is that the tiers cost different amounts. Inheriting silently would
 * produce a report saying the cheap model costs the same as the expensive one,
 * which is worse than no report.
 */
function parseModelSpec(raw: string, fallback: ModelSpec["prices"]): ModelSpec {
  const [model, pricePart] = raw.split(":");
  const name = model?.trim() ?? "";
  if (!name) throw new Error(`Model adı boş: "${raw}"`);
  if (!pricePart) {
    return { model: name, prices: fallback, pricesInherited: true };
  }
  const parts = pricePart.split("/").map((value) => Number(value.trim()));
  if (parts.length !== 3 || parts.some((value) => !Number.isFinite(value) || value < 0)) {
    throw new Error(
      `"${raw}" fiyatı okunamadı. Beklenen biçim: model:girdi/önbellek/çıktı (örn. gpt-5.6-terra:2/0.2/12)`,
    );
  }
  return {
    model: name,
    prices: {
      openaiUsdPerMillionInputTokens: parts[0]!,
      openaiUsdPerMillionCachedInputTokens: parts[1]!,
      openaiUsdPerMillionOutputTokens: parts[2]!,
    },
    pricesInherited: false,
  };
}

async function readPages(dir: string): Promise<Array<{ name: string; bytes: Uint8Array; mimeType: string }>> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    throw new Error(
      `Sayfa dizini okunamadı: ${dir}\n` +
        "İşaretli sayfa fotoğraflarını oraya koy (dizin gitignore'lu — telifli sayfa repoya girmez).",
    );
  }
  const pages = [];
  for (const name of names.sort()) {
    const mimeType = IMAGE_MIME[extname(name).toLowerCase()];
    if (!mimeType) continue;
    pages.push({ name, bytes: new Uint8Array(await readFile(join(dir, name))), mimeType });
  }
  if (pages.length === 0) {
    throw new Error(`${dir} içinde desteklenen görüntü yok (${Object.keys(IMAGE_MIME).join(", ")}).`);
  }
  return pages;
}

function fmtUsd(value: number): string {
  return `$${value.toFixed(4)}`;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(USAGE);
    return;
  }

  const config = loadConfig();
  const apiKey = process.env.OPENAI_API_KEY?.trim();
  if (!apiKey) {
    console.error("OPENAI_API_KEY yok. backend/.env dosyasına ekle.");
    process.exit(1);
  }

  if (typeof args.models !== "string") {
    console.error("--models zorunlu.\n\n" + USAGE);
    process.exit(1);
  }

  const specs = args.models.split(",").map((raw) =>
    parseModelSpec(raw.trim(), {
      openaiUsdPerMillionInputTokens: config.cost.openaiUsdPerMillionInputTokens,
      openaiUsdPerMillionCachedInputTokens: config.cost.openaiUsdPerMillionCachedInputTokens,
      openaiUsdPerMillionOutputTokens: config.cost.openaiUsdPerMillionOutputTokens,
    }),
  );
  const inherited = specs.filter((spec) => spec.pricesInherited).map((spec) => spec.model);
  if (inherited.length > 0) {
    console.warn(
      `⚠ Şu modeller için fiyat verilmedi, .env'deki tek fiyat seti kullanılıyor: ${inherited.join(", ")}.\n` +
        "  Modeller farklı fiyatlıysa maliyet karşılaştırması yanıltıcı olur — her modele kendi\n" +
        "  fiyatını ver: model:girdi/önbellek/çıktı\n",
    );
  }

  const pagesDir = typeof args.pages === "string" ? args.pages : "../evals/fixtures/pages";
  const outDir = typeof args.out === "string" ? args.out : "../evals/reports";
  const subject = typeof args.subject === "string" ? args.subject : undefined;
  const maxCards =
    typeof args["max-cards"] === "string"
      ? Number(args["max-cards"])
      : config.openai.maxCardsPerKnowledgeUnit;

  const pages = await readPages(pagesDir);
  console.log(
    `${pages.length} sayfa × ${specs.length} model = ${pages.length * specs.length} gerçek çağrı.\n`,
  );

  const results: PageResult[] = [];

  for (const spec of specs) {
    const generator = new OpenAICardGenerator(
      { ...config.openai, model: spec.model },
      apiKey,
      spec.prices,
    );

    for (const page of pages) {
      const requestId = `cmp_${spec.model}_${basename(page.name, extname(page.name))}`;
      const started = Date.now();
      process.stdout.write(`  ${spec.model} · ${page.name} … `);

      try {
        const { output, rawUsage } = await generator.generateCards({
          requestId,
          image: page.bytes,
          mimeType: page.mimeType,
          maxCards,
          subject,
        });
        // Exactly what production does before anything is stored, so the cards
        // being judged are the cards that would have reached the deck.
        const checked = sanitizeMultipleChoice(output.cards);
        const sanitized = { ...output, cards: checked.cards };
        const gate = runCardGate(sanitized, { maxCardsPerKnowledgeUnit: maxCards });
        const rejected = new Set(
          gate.verdicts.filter((verdict) => verdict.decision === "reject").map((v) => v.cardId),
        );
        const kept = sanitized.cards.filter((card) => !rejected.has(card.id));

        results.push({
          page: page.name,
          model: spec.model,
          ok: true,
          cardCount: kept.length,
          rejectedCount: rejected.size,
          multipleChoiceCount: kept.filter((card) => card.type === "multiple_choice").length,
          lowConfidenceCount: kept.filter((card) => card.lowConfidence).length,
          topicAssignedCount: kept.filter((card) => card.topic).length,
          usage: rawUsage,
          estimatedCostUSD: estimateOpenAICostUSD(rawUsage, spec.prices),
          latencyMs: Date.now() - started,
          cards: kept,
        });
        console.log(
          `${kept.length} kart · ${fmtUsd(estimateOpenAICostUSD(rawUsage, spec.prices))} · ` +
            `${Math.round((Date.now() - started) / 1000)} sn`,
        );
      } catch (error) {
        const openAIError = error instanceof OpenAIError ? error : null;
        const usage = openAIError?.usage ?? EMPTY_TOKEN_USAGE;
        results.push({
          page: page.name,
          model: spec.model,
          ok: false,
          error: openAIError?.message ?? String(error),
          failureReason: openAIError?.reason ?? "unknown",
          cardCount: 0,
          rejectedCount: 0,
          multipleChoiceCount: 0,
          lowConfidenceCount: 0,
          topicAssignedCount: 0,
          usage,
          // A failed call is priced too — that is the whole lesson of the cost
          // ledger, and a model that fails often is not cheap.
          estimatedCostUSD: estimateOpenAICostUSD(usage, spec.prices),
          latencyMs: Date.now() - started,
          cards: [],
        });
        console.log(`HATA (${openAIError?.reason ?? "bilinmiyor"})`);
      }
    }
  }

  await mkdir(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");

  // --- Full report -------------------------------------------------------
  const perModel = specs.map((spec) => {
    const rows = results.filter((row) => row.model === spec.model);
    const ok = rows.filter((row) => row.ok);
    const cost = rows.reduce((sum, row) => sum + row.estimatedCostUSD, 0);
    return {
      model: spec.model,
      pricesInherited: spec.pricesInherited,
      prices: spec.prices,
      calls: rows.length,
      succeeded: ok.length,
      failed: rows.length - ok.length,
      cards: ok.reduce((sum, row) => sum + row.cardCount, 0),
      gateRejected: ok.reduce((sum, row) => sum + row.rejectedCount, 0),
      multipleChoice: ok.reduce((sum, row) => sum + row.multipleChoiceCount, 0),
      lowConfidence: ok.reduce((sum, row) => sum + row.lowConfidenceCount, 0),
      topicAssigned: ok.reduce((sum, row) => sum + row.topicAssignedCount, 0),
      inputTokens: rows.reduce((sum, row) => sum + row.usage.inputTokens, 0),
      cachedInputTokens: rows.reduce((sum, row) => sum + row.usage.cachedInputTokens, 0),
      outputTokens: rows.reduce((sum, row) => sum + row.usage.outputTokens, 0),
      reasoningTokens: rows.reduce((sum, row) => sum + row.usage.reasoningTokens, 0),
      totalCostUSD: cost,
      costPerPageUSD: rows.length > 0 ? cost / rows.length : 0,
      medianLatencyMs: median(rows.map((row) => row.latencyMs)),
    };
  });

  const reportPath = join(outDir, `compare-${stamp}.json`);
  await writeFile(
    reportPath,
    JSON.stringify(
      { stamp, cardPromptVersion: CARD_PROMPT_VERSION, subject, maxCards, perModel, results },
      null,
      2,
    ),
    "utf-8",
  );

  // --- Blind sheet + key -------------------------------------------------
  //
  // Deterministically shuffled from the card ids themselves rather than from a
  // random seed: the same run always produces the same sheet, so a re-read
  // after a crash is the same experiment rather than a new one.
  const blind = results
    .filter((row) => row.ok)
    .flatMap((row) =>
      (row.cards as Array<Record<string, unknown>>).map((card) => ({
        cardId: String(card.id),
        page: row.page,
        card,
      })),
    )
    .sort((left, right) => hash(left.cardId) - hash(right.cardId));

  const blindPath = join(outDir, `blind-${stamp}.json`);
  await writeFile(
    blindPath,
    JSON.stringify(
      {
        note:
          "Kartları §23.3 rubriğiyle puanla. Hangi modelin ürettiği bilerek yazılmadı — " +
          "eşiğe yakın bir kararı en çok bozan şey budur.",
        entries: blind,
      },
      null,
      2,
    ),
    "utf-8",
  );

  const keyPath = join(outDir, `key-${stamp}.json`);
  await writeFile(
    keyPath,
    JSON.stringify(
      Object.fromEntries(
        results.flatMap((row) =>
          (row.cards as Array<Record<string, unknown>>).map((card) => [String(card.id), row.model]),
        ),
      ),
      null,
      2,
    ),
    "utf-8",
  );

  // --- Terminal summary --------------------------------------------------
  console.log("\nModel başına:");
  for (const row of perModel) {
    console.log(
      `  ${row.model.padEnd(16)} ${String(row.cards).padStart(4)} kart · ` +
        `${fmtUsd(row.totalCostUSD)} toplam · ${fmtUsd(row.costPerPageUSD)}/sayfa · ` +
        `${row.failed} başarısız · ${Math.round(row.medianLatencyMs / 1000)} sn ortanca`,
    );
  }

  const cheapest = [...perModel].sort((a, b) => a.totalCostUSD - b.totalCostUSD)[0];
  const dearest = [...perModel].sort((a, b) => b.totalCostUSD - a.totalCostUSD)[0];
  if (cheapest && dearest && cheapest.model !== dearest.model && dearest.totalCostUSD > 0) {
    const saving = 1 - cheapest.totalCostUSD / dearest.totalCostUSD;
    console.log(
      `\n  ${cheapest.model}, ${dearest.model}'e göre %${Math.round(saving * 100)} daha ucuz.`,
    );
  }

  console.log(`\nRapor:      ${reportPath}`);
  console.log(`Kör puanlama: ${blindPath}`);
  console.log(`Anahtar:    ${keyPath}   ← puanlama bitene kadar AÇMA`);
  console.log(
    "\nKaliteyi puanladıktan sonra:\n" +
      `  python -m evals.model_compare.report --scores <puanlar.json> --key ${keyPath} --report ${reportPath}`,
  );
}

function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1]! + sorted[middle]!) / 2 : sorted[middle]!;
}

/** Stable, content-derived ordering for the blind sheet. Not a security hash. */
function hash(value: string): number {
  let result = 0;
  for (let i = 0; i < value.length; i += 1) {
    result = (result * 31 + value.charCodeAt(i)) % 2_147_483_647;
  }
  return result;
}

main().catch((error) => {
  if (error instanceof ConfigError) {
    console.error(`Yapılandırma hatası: ${error.message}`);
  } else {
    console.error(error instanceof Error ? error.message : String(error));
  }
  process.exit(1);
});
