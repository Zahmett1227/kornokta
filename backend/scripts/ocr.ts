/**
 * Runs Google Document AI over a folder of images and writes the same JSON the
 * Apple Vision spike writes, so `python -m evals.ocr_eval.vision_report` scores
 * both engines with no changes (ANA-PLAN §23.2, §27).
 *
 *     npm run ocr -- --input ../evals/fixtures/deneme --output ../evals/reports/google.json
 *
 * Local measurement tool, not the production path: it reads files from disk and
 * prints per-page progress. The provider it drives is the real one, so a green
 * run here proves the credentials, the processor and the region are all right.
 */

import { readFile, writeFile, mkdir, readdir, stat } from "node:fs/promises";
import { dirname, extname, join, basename } from "node:path";
import { GoogleAuth } from "google-auth-library";

import { loadConfig, ConfigError } from "../config.js";
import { DocumentAIRecognizer, DocumentAIError, googleAuthTokenSource } from "../providers/documentAI.js";
import type { OCRPage, OCRRun } from "../providers/ocrTypes.js";

const USAGE = `
Kullanım:
  npm run ocr -- --input <klasör|görüntü> --output <sonuc.json>

Seçenekler:
  --input <yol>     Görüntü dosyası veya görüntü içeren klasör (zorunlu)
  --output <yol>    Yazılacak JSON dosyası (zorunlu)
  --limit <n>       En fazla n görüntü işle (maliyet denemesi için)
  --help

Ortam değişkenleri backend/.env.example dosyasında açıklanıyor.
`.trim();

/** Document AI accepts these; the key is telling it the right mime type. */
const MIME_TYPES: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".pdf": "application/pdf",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".gif": "image/gif",
};

/**
 * HEIC is what an iPhone shoots by default and what the Faz 0 fixtures are, but
 * Document AI does not accept it. Detected explicitly so the failure is one
 * clear sentence instead of an opaque 400 per page.
 */
const UNSUPPORTED = new Set([".heic", ".heif"]);

interface Options {
  input: string;
  output: string;
  limit: number;
}

function parseArguments(argv: string[]): Options | null {
  let input: string | undefined;
  let output: string | undefined;
  let limit = Number.POSITIVE_INFINITY;

  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--help" || flag === "-h") return null;
    const value = argv[i + 1];
    if (flag === "--input") {
      input = value;
      i += 1;
    } else if (flag === "--output") {
      output = value;
      i += 1;
    } else if (flag === "--limit") {
      limit = Number(value);
      i += 1;
      if (!Number.isFinite(limit) || limit < 1) {
        console.error("--limit pozitif bir sayı olmalı");
        return null;
      }
    } else {
      console.error(`Bilinmeyen seçenek: ${flag}`);
      return null;
    }
  }

  if (!input || !output) return null;
  return { input, output, limit };
}

async function collectImages(target: string): Promise<string[]> {
  const info = await stat(target);
  if (!info.isDirectory()) return [target];
  const entries = await readdir(target);
  return entries
    .map((entry) => join(target, entry))
    .filter((path) => {
      const extension = extname(path).toLowerCase();
      return MIME_TYPES[extension] !== undefined || UNSUPPORTED.has(extension);
    })
    .sort();
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

  const all = await collectImages(options.input);
  const skipped = all.filter((path) => UNSUPPORTED.has(extname(path).toLowerCase()));
  const usable = all.filter((path) => MIME_TYPES[extname(path).toLowerCase()] !== undefined);

  if (skipped.length) {
    console.error(
      `\nUYARI: ${skipped.length} dosya HEIC/HEIF ve Document AI bunu kabul etmiyor.\n` +
        `       Önce JPEG'e çevir (macOS):\n` +
        `         sips -s format jpeg ${dirname(skipped[0]!)}/*.heic --out <hedef-klasör>\n`,
    );
  }

  if (!usable.length) {
    console.error(`İşlenebilir görüntü yok: ${options.input}`);
    return 1;
  }

  const selected = usable.slice(0, options.limit);
  const estimate = (selected.length / 1000) * config.cost.usdPer1000Pages;
  if (config.cost.maxUsdPerRun > 0 && estimate > config.cost.maxUsdPerRun) {
    console.error(
      `Tahmini maliyet ${estimate.toFixed(4)} USD, MAX_USD_PER_RUN=${config.cost.maxUsdPerRun} sınırını aşıyor.`,
    );
    return 1;
  }
  console.log(
    `${selected.length} görüntü, tahmini maliyet ${estimate.toFixed(4)} USD ` +
      `(${config.documentAI.location}, işlemci ${config.documentAI.processorId})`,
  );

  // Prepared before any request, so an unwritable path fails in milliseconds
  // rather than after paying for every page.
  await mkdir(dirname(options.output), { recursive: true });

  const recognizer = new DocumentAIRecognizer(
    config.documentAI,
    googleAuthTokenSource(new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
    })),
  );

  const pages: OCRPage[] = [];
  let failures = 0;
  for (const path of selected) {
    const mimeType = MIME_TYPES[extname(path).toLowerCase()]!;
    try {
      const bytes = await readFile(path);
      const page = await recognizer.recognize(bytes, { imagePath: path, mimeType });
      pages.push(page);
      console.log(`OK   ${basename(path)}  satır=${page.lines.length}  ${page.elapsedMs} ms`);
    } catch (error) {
      failures += 1;
      const detail = error instanceof DocumentAIError ? error.message : String(error);
      console.error(`HATA ${basename(path)}: ${detail}`);
      // A permanent error repeats on every remaining page — usually a wrong
      // project, processor or region — so stop instead of burning the quota.
      if (error instanceof DocumentAIError && !error.transient) {
        console.error("Kalıcı hata; kalan görüntüler atlandı.");
        break;
      }
    }
  }

  const run: OCRRun = {
    generatedBy: "GoogleDocumentAI",
    requestedLanguages: config.documentAI.languageHints,
    unsupportedLanguages: [],
    pages,
  };
  await writeFile(options.output, JSON.stringify(run, null, 2), "utf-8");
  console.log(`\nYazıldı: ${options.output}  (${pages.length} sayfa, ${failures} hata)`);
  return pages.length > 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error(error);
    process.exit(1);
  },
);
