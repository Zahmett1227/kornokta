/**
 * Local live-verification tool for the Gemini handwriting second-opinion call
 * (docs/FAZ3-PLAN.md), the same habit as `scripts/cards.ts` for OpenAI and
 * `scripts/ocr.ts --limit 1` for Document AI in Faz 2: one real call before
 * trusting the request shape for anything real.
 *
 *     npm run handwriting
 *     npm run handwriting -- --primary-reading "krea 1.2 yukseldi"
 *
 * The image is a tiny embedded blank JPEG, not a real handwriting crop — this
 * checks whether `generateContent` accepts the request shape this codebase
 * sends (systemInstruction, responseSchema, inlineData), not transcription
 * accuracy.
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
import { GeminiHandwritingSecondOpinion, GeminiError } from "../providers/gemini.js";

const USAGE = `
Kullanım:
  npm run handwriting -- [--primary-reading "..."] [--output <sonuc.json>]

Seçenekler:
  --primary-reading <metin>   Karşılaştırma için verilen birincil okuma
  --output <yol>              Tam yanıtın yazılacağı JSON
                               (varsayılan: ../evals/reports/handwriting-smoke-test.json)
  --help

Ortam değişkenleri backend/.env.example dosyasında açıklanıyor; en azından
GEMINI_API_KEY dolu olmalı.
`.trim();

const SAMPLE_PRIMARY_READING = "krea 1.2 yukseldi";

/** A 1x1 JPEG — just enough bytes to be a decodable image; content is irrelevant here. */
const BLANK_JPEG_BASE64 =
  "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k=";

interface Options {
  primaryReading: string;
  output: string;
}

function parseArguments(argv: string[]): Options | null {
  let primaryReading = SAMPLE_PRIMARY_READING;
  let output = "../evals/reports/handwriting-smoke-test.json";

  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--help" || flag === "-h") return null;
    const value = argv[i + 1];
    if (flag === "--primary-reading") {
      primaryReading = value ?? primaryReading;
      i += 1;
    } else if (flag === "--output") {
      output = value ?? output;
      i += 1;
    } else {
      console.error(`Bilinmeyen seçenek: ${flag}`);
      return null;
    }
  }
  return { primaryReading, output };
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

  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) {
    console.error("GEMINI_API_KEY tanımlı değil (.env'e bak, backend/.env.example örnek alınabilir).");
    return 1;
  }

  console.log(`Model: ${config.gemini.model}  maxOutputTokens=${config.gemini.maxOutputTokens}`);
  console.log("Tek bir gerçek Gemini çağrısı yapılıyor...\n");

  const generator = new GeminiHandwritingSecondOpinion(config.gemini, apiKey, config.cost);
  const started = Date.now();

  try {
    const { opinion, rawUsage } = await generator.getSecondOpinion({
      image: Buffer.from(BLANK_JPEG_BASE64, "base64"),
      mimeType: "image/jpeg",
      primaryReading: options.primaryReading,
    });
    const elapsedMs = Date.now() - started;

    await mkdir(dirname(options.output), { recursive: true });
    await writeFile(options.output, JSON.stringify(opinion, null, 2), "utf-8");

    console.log(`OK   ${elapsedMs} ms`);
    console.log(`Belirsiz span sayısı: ${opinion.uncertainSpans.length}`);
    console.log(`Token (girdi/çıktı): ${rawUsage.inputTokens}/${rawUsage.outputTokens}`);
    console.log(`\nTam çıktı yazıldı: ${options.output} (gitignore'lu, repoya gitmez)`);
    return 0;
  } catch (error) {
    const elapsedMs = Date.now() - started;
    if (error instanceof GeminiError) {
      console.error(`HATA (${elapsedMs} ms): ${error.message}`);
      console.error(`  status=${error.status ?? "—"}  retryable=${error.transient}`);
      // Gemini's own convention: an invalid key comes back as 400 ("API key
      // not valid"), not 401/403 — confirmed with a live (fake-key) call, so
      // this checks the message rather than assuming OpenAI's status codes.
      if (/api key/i.test(error.message)) {
        console.error("\nGEMINI_API_KEY hatalı ya da eksik görünüyor — .env'deki değeri kontrol et.");
      } else if (!error.transient) {
        console.error(
          "\nKalıcı hata, kimlik doğrulama dışı bir sebepten — sıkça karşılaşılan durum: " +
            `GEMINI_MODEL'daki isim (şu an config'te '${config.gemini.model}') hesabında ` +
            "erişimin olmayan ya da artık yayında olmayan bir model olabilir. .env'deki " +
            "GEMINI_MODEL değerini değiştirip tekrar dene (§0.6: model adı kodda gömülü değil).",
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
