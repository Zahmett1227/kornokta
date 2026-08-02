import { describe, expect, it } from "vitest";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Regression test for a real bug: a gold-set capture is organized into
 * category subfolders (`evals/fixtures/highlight/`, `.../pencil/`, ...) and
 * `--input` is pointed at the parent, but `collectImages` only listed the
 * immediate directory. Every image was one level too deep, so the tool
 * reported zero images found no matter how many were actually there.
 *
 * Spawns the actual CLI, the same way `envLoading.test.ts` does, and steers
 * it to fail right after image collection — before any Google credential or
 * network dependency — so this stays offline and deterministic. It only
 * needs to observe whether the run gets *past* "no images", not what happens
 * after; asserting on a Google Auth error message would make this depend on
 * ambient credentials on whatever machine runs it.
 */
describe("scripts/ocr.ts collectImages", () => {
  const scriptPath = fileURLToPath(new URL("../scripts/ocr.ts", import.meta.url));
  const tsxBin = fileURLToPath(new URL("../node_modules/.bin/tsx", import.meta.url));

  async function runAgainst(imagesDir: string) {
    const dir = await mkdtemp(join(tmpdir(), "cizgi-collect-"));
    try {
      await writeFile(
        join(dir, ".env"),
        "GOOGLE_PROJECT_ID=kornokta\nDOCUMENTAI_PROCESSOR_ID=deneme\n",
        "utf-8",
      );
      const result = spawnSync(
        process.execPath,
        [tsxBin, scriptPath, "--input", imagesDir, "--output", join(dir, "out.json")],
        { cwd: dir, encoding: "utf-8", timeout: 15_000 },
      );
      return result;
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  it("finds nothing in an empty directory tree", async () => {
    const dir = await mkdtemp(join(tmpdir(), "cizgi-images-"));
    try {
      await mkdir(join(dir, "highlight"));
      const result = await runAgainst(dir);
      expect(result.stderr).toContain("İşlenebilir görüntü yok");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }, 20_000);

  it("finds an image one level down in a category subfolder", async () => {
    const dir = await mkdtemp(join(tmpdir(), "cizgi-images-"));
    try {
      await mkdir(join(dir, "highlight"));
      await writeFile(join(dir, "highlight", "a.jpg"), "sahte-bayt");

      const result = await runAgainst(dir);

      // Got past collection with something to process — the old,
      // non-recursive listing would have reported zero images here.
      expect(result.stderr).not.toContain("İşlenebilir görüntü yok");
      // And the process actually ran to completion (or a clean failure)
      // rather than hanging — spawnSync leaves `status: null` on a timeout.
      expect(result.status).not.toBeNull();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }, 20_000);

  it("still finds an image directly in the input folder (unchanged behaviour)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "cizgi-images-"));
    try {
      await writeFile(join(dir, "a.jpg"), "sahte-bayt");
      const result = await runAgainst(dir);
      expect(result.stderr).not.toContain("İşlenebilir görüntü yok");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }, 20_000);
});
