/**
 * Local live-verification tool for the OpenAI card-generation call
 * (docs/FAZ3-PLAN.md: "önce tek küçük pasajla canlı doğrulama, gold set
 * ölçümüne geçmeden önce" — the same habit `scripts/ocr.ts --limit 1`
 * established for Document AI in Faz 2).
 *
 *     npm run cards
 *     npm run cards -- --text "Hiperkalemide ilk tedavi kalsiyum glukonattır."
 *
 * Makes exactly ONE real API call. The image is not a real page — a tiny
 * embedded blank JPEG — because this call is not testing transcription
 * accuracy, only whether the Responses API accepts the request shape this
 * codebase sends it (model id, `reasoning.effort`, `text.format` Structured
 * Outputs, an `input_image` part) and returns something that parses and
 * validates against §14. `--text` supplies the passage instead.
 *
 * Terminal output is metadata only (§7.3 discipline, kept even for a local
 * tool): card count, decisions, token counts, cost, elapsed time, and — on
 * failure — the provider's own error message and status, which describes
 * the call, not card content. The full response is written to a local,
 * gitignored JSON file for inspection.
 */

import { writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { existsSync } from "node:fs";
import { config as loadEnvFile } from "dotenv";

if (existsSync(".env")) {
  const result = loadEnvFile();
  if (result.error) {
    console.error(`.env okunamadı: ${result.error.message}`);
    process.exit(1);
  }
}

import { loadConfig, ConfigError } from "../config.js";
import { OpenAICardGenerator, OpenAIError } from "../providers/openai.js";
import { runCardGate, type CardDecision } from "../providers/cardGate.js";

const USAGE = `
Kullanım:
  npm run cards -- [--text "..."] [--output <sonuc.json>]

Seçenekler:
  --text <metin>    Test edilecek örnek pasaj (varsayılan aşağıda)
  --output <yol>    Tam yanıtın yazılacağı JSON
                     (varsayılan: ../evals/reports/cards-smoke-test.json)
  --help

Ortam değişkenleri backend/.env.example dosyasında açıklanıyor; en azından
OPENAI_API_KEY dolu olmalı.
`.trim();

const SAMPLE_TEXT = "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.";

/** A 1x1 JPEG — just enough bytes to be a decodable image; content is irrelevant here. */
const BLANK_JPEG_BASE64 =
  "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k=";

interface Options {
  text: string;
  output: string;
}

function parseArguments(argv: string[]): Options | null {
  let text = SAMPLE_TEXT;
  let output = "../evals/reports/cards-smoke-test.json";

  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--help" || flag === "-h") return null;
    const value = argv[i + 1];
    if (flag === "--text") {
      text = value ?? text;
      i += 1;
    } else if (flag === "--output") {
      output = value ?? output;
      i += 1;
    } else {
      console.error(`Bilinmeyen seçenek: ${flag}`);
      return null;
    }
  }
  return { text, output };
}

function summarizeDecisions(verdicts: Array<{ decision: CardDecision }>): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const verdict of verdicts) counts[verdict.decision] = (counts[verdict.decision] ?? 0) + 1;
  return counts;
}

async function main(): Promise<number> {
  const options = parseArguments(process.argv.slice(2));
  if (!options) {
    console.log(USAGE);
    return 1;
  }

  let config;
  try {
    config = loadConfig();
  } catch (error) {
    if (error instanceof ConfigError) {
      console.error(error.message);
      return 1;
    }
    throw error;
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    console.error("OPENAI_API_KEY tanımlı değil (.env'e bak, backend/.env.example örnek alınabilir).");
    return 1;
  }

  console.log(
    `Model: ${config.openai.model}  reasoning=${config.openai.reasoningEffort}  ` +
      `maxOutputTokens=${config.openai.maxOutputTokens}  maxCards=${config.openai.maxCardsPerKnowledgeUnit}`,
  );
  console.log("Tek bir gerçek OpenAI çağrısı yapılıyor...\n");

  const generator = new OpenAICardGenerator(config.openai, apiKey, config.cost);
  const started = Date.now();

  try {
    const { output: result, rawUsage } = await generator.generateCards({
      requestId: "smoke-test",
      image: Buffer.from(BLANK_JPEG_BASE64, "base64"),
      mimeType: "image/jpeg",
      cleanText: options.text,
      selectedLineIds: ["line_00"],
      isHandwritten: false,
    });
    const elapsedMs = Date.now() - started;
    const gate = runCardGate(result, { maxCardsPerKnowledgeUnit: config.openai.maxCardsPerKnowledgeUnit });

    await mkdir(dirname(options.output), { recursive: true });
    await writeFile(options.output, JSON.stringify(result, null, 2), "utf-8");

    console.log(`OK   ${elapsedMs} ms`);
    console.log(`Kart sayısı: ${result.cards.length}`);
    console.log(`Kalite kapısı kararları: ${JSON.stringify(summarizeDecisions(gate.verdicts))}`);
    console.log(`Token (girdi/çıktı): ${rawUsage.inputTokens}/${rawUsage.outputTokens}`);
    console.log(`Tahmini maliyet: ${result.usage.estimatedCostUSD.toFixed(6)} USD` +
      (config.cost.openaiUsdPerMillionInputTokens === 0 && config.cost.openaiUsdPerMillionOutputTokens === 0
        ? " (fiyat alanları 0 — .env'de OPENAI_USD_PER_MILLION_* doldurulmadıysa gerçek maliyeti yansıtmaz)"
        : ""));
    console.log(`\nTam çıktı yazıldı: ${options.output} (gitignore'lu, repoya gitmez)`);
    return 0;
  } catch (error) {
    const elapsedMs = Date.now() - started;
    if (error instanceof OpenAIError) {
      console.error(`HATA (${elapsedMs} ms): ${error.message}`);
      console.error(`  status=${error.status ?? "—"}  retryable=${error.transient}`);
      if (error.status === 401 || error.status === 403) {
        console.error("\nOPENAI_API_KEY hatalı ya da eksik görünüyor — .env'deki değeri kontrol et.");
      } else if (!error.transient) {
        // ANA-PLAN was written naming a model ("gpt-5.6-sol") that did not
        // exist in any API this codebase was actually built against; a 404 or
        // an explicit "model not found"-shaped 400 is the expected first
        // failure once a real key is in place, not a bug in this script.
        console.error(
          "\nKalıcı hata, kimlik doğrulama dışı bir sebepten — sıkça karşılaşılan durum: " +
            `OPENAI_MODEL'daki isim (şu an config'te '${config.openai.model}') OpenAI'ın ` +
            "gerçek API'sinde tanınmıyor olabilir. .env'deki OPENAI_MODEL değerini hesabında " +
            "erişimin olan gerçek bir model kimliğiyle değiştirip tekrar dene " +
            "(§0.6: model adı kodda gömülü değil).",
        );
      }
    } else {
      console.error(`Beklenmeyen hata (${elapsedMs} ms):`, error);
    }
    return 1;
  }
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error(error);
    process.exit(1);
  },
);
