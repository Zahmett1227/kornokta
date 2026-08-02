import { describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Regression test for a real bug: `.env` was documented and filled in by hand
 * during setup, but nothing ever loaded it into `process.env` — `config.ts`
 * reads `process.env` directly. Filling in `.env` correctly and running the
 * tool looked identical to leaving it empty; both failed with the same
 * "missing GOOGLE_PROJECT_ID" error.
 *
 * This spawns the actual CLI (not a mock) with cwd set to a directory holding
 * a real `.env` file, the same way `npm run ocr` does from `backend/`. No
 * network call happens: the run is steered to fail at "no images found",
 * which is only reachable once config has loaded successfully.
 */
describe("scripts/ocr.ts loads .env", () => {
  const scriptPath = fileURLToPath(new URL("../scripts/ocr.ts", import.meta.url));
  const tsxBin = fileURLToPath(new URL("../node_modules/.bin/tsx", import.meta.url));

  async function run(env: Record<string, string> | null) {
    const dir = await mkdtemp(join(tmpdir(), "cizgi-env-"));
    try {
      if (env) {
        const lines = Object.entries(env).map(([key, value]) => `${key}=${value}`);
        await writeFile(join(dir, ".env"), lines.join("\n"), "utf-8");
      }
      const emptyImages = join(dir, "images");
      await mkdir(emptyImages);

      const result = spawnSync(
        process.execPath,
        [tsxBin, scriptPath, "--input", emptyImages, "--output", join(dir, "out.json")],
        { cwd: dir, encoding: "utf-8", timeout: 15_000 },
      );
      return result;
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  it("reads GOOGLE_PROJECT_ID etc. from .env, not just from the parent shell", async () => {
    const result = await run({
      GOOGLE_PROJECT_ID: "kornokta",
      DOCUMENTAI_PROCESSOR_ID: "6213367b4c106c7e",
    });

    // Config loaded successfully, so the run gets past config validation and
    // fails for the next real reason: no images in the folder. If .env were
    // not being read, this would instead be "Eksik ortam değişkeni:
    // GOOGLE_PROJECT_ID".
    expect(result.stderr).not.toContain("Eksik ortam değişkeni");
    expect(result.stderr).toContain("İşlenebilir görüntü yok");
  }, 20_000);

  it("still reports the missing variable when .env has none of it", async () => {
    const result = await run(null);
    expect(result.stderr).toContain("GOOGLE_PROJECT_ID");
    expect(result.status).toBe(1);
  }, 20_000);
});
