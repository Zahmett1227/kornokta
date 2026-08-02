import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH } from "../api/auth.js";
import {
  ACCEPTED_MIME_TYPES,
  MAX_IMAGE_BYTES,
  decodeImage,
  handleOcrRequest,
  type Dependencies,
} from "../api/ocr.js";
import { DocumentAIError } from "../providers/documentAI.js";
import type { OCRPage, RecognizeOptions, TextRecognizer } from "../providers/ocrTypes.js";

const TOKEN = "t".repeat(MIN_TOKEN_LENGTH);

function pageWith(lines: string[]): OCRPage {
  return {
    imagePath: "job-1",
    imageWidth: 1600,
    imageHeight: 1200,
    recognitionLanguages: ["tr", "en"],
    usesLanguageCorrection: false,
    engineVersion: "test",
    elapsedMs: 5,
    lines: lines.map((text, index) => ({
      lineId: `line_${String(index).padStart(2, "0")}`,
      text,
      confidence: 0.97,
      x: 0.1,
      y: 0.1 + index * 0.05,
      width: 0.8,
      height: 0.04,
    })),
  };
}

/** Records what it was handed, so privacy claims can be checked. */
function stubRecognizer(result: OCRPage | Error) {
  const seen: Array<{ bytes: Uint8Array; options: RecognizeOptions }> = [];
  const recognizer: TextRecognizer = {
    name: "stub",
    async recognize(bytes, options) {
      seen.push({ bytes, options });
      if (result instanceof Error) throw result;
      return result;
    },
  };
  return { recognizer, seen };
}

function deps(overrides: Partial<Dependencies> = {}): Dependencies & { logged: Record<string, unknown>[] } {
  const logged: Record<string, unknown>[] = [];
  return {
    recognizer: stubRecognizer(pageWith(["merhaba"])).recognizer,
    documentAI: { languageHints: ["tr", "en"] },
    deviceToken: TOKEN,
    log: (entry) => logged.push(entry),
    logged,
    ...overrides,
  };
}

function post(body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request("https://example.test/api/ocr", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const IMAGE = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");

describe("decodeImage", () => {
  it("decodes valid base64", () => {
    expect(decodeImage(Buffer.from("abc").toString("base64"))).toEqual(
      new Uint8Array(Buffer.from("abc")),
    );
  });

  it("rejects a corrupted payload instead of silently shortening it", () => {
    // Buffer.from(..., "base64") drops invalid characters, so a damaged upload
    // would decode to a truncated image and be sent to a paid API as if fine.
    expect(decodeImage("!!!!not base64!!!!")).toBeNull();
    expect(decodeImage("")).toBeNull();
    expect(decodeImage("   ")).toBeNull();
  });

  it("tolerates missing padding", () => {
    const padded = Buffer.from("hello").toString("base64");
    expect(decodeImage(padded.replace(/=+$/, ""))).not.toBeNull();
  });
});

describe("POST /api/ocr", () => {
  it("returns the recognized page", async () => {
    const response = await handleOcrRequest(
      post({ jobId: "job-1", mimeType: "image/jpeg", imageBase64: IMAGE }),
      deps(),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as { jobId: string; page: OCRPage };
    expect(body.jobId).toBe("job-1");
    expect(body.page.lines[0]!.text).toBe("merhaba");
  });

  it("passes the image bytes through unchanged", async () => {
    const { recognizer, seen } = stubRecognizer(pageWith(["x"]));
    await handleOcrRequest(
      post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
      deps({ recognizer }),
    );
    expect(Buffer.from(seen[0]!.bytes).toString("base64")).toBe(IMAGE);
  });

  describe("authorization", () => {
    it("rejects a request with no token", async () => {
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }, null),
        deps(),
      );
      expect(response.status).toBe(401);
    });

    it("does not call the provider when unauthorized", async () => {
      // Otherwise an unauthenticated caller could spend money.
      const { recognizer, seen } = stubRecognizer(pageWith(["x"]));
      await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }, "wrong-token-value-here-1234567890"),
        deps({ recognizer }),
      );
      expect(seen).toHaveLength(0);
    });

    it("reports an unset server token as 500, not 401", async () => {
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
        deps({ deviceToken: undefined }),
      );
      expect(response.status).toBe(500);
    });
  });

  describe("validation", () => {
    it("rejects a non-POST method", async () => {
      const request = new Request("https://example.test/api/ocr", { method: "GET" });
      expect((await handleOcrRequest(request, deps())).status).toBe(405);
    });

    it("rejects a body that is not JSON", async () => {
      const response = await handleOcrRequest(post("{not json"), deps());
      expect(response.status).toBe(400);
    });

    it("requires a jobId", async () => {
      for (const jobId of [undefined, "", "   ", 42]) {
        const response = await handleOcrRequest(
          post({ jobId, mimeType: "image/jpeg", imageBase64: IMAGE }),
          deps(),
        );
        expect(response.status, `jobId: ${jobId}`).toBe(400);
      }
    });

    it("rejects an unaccepted mime type", async () => {
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/heic", imageBase64: IMAGE }),
        deps(),
      );
      expect(response.status).toBe(415);
      // HEIC is what an iPhone shoots, so the message has to be actionable.
      expect(await response.text()).toContain("image/jpeg");
    });

    it("accepts every documented mime type", async () => {
      for (const mimeType of ACCEPTED_MIME_TYPES) {
        const response = await handleOcrRequest(
          post({ jobId: "j", mimeType, imageBase64: IMAGE }),
          deps(),
        );
        expect(response.status, mimeType).toBe(200);
      }
    });

    it("rejects an oversized upload before decoding it", async () => {
      const huge = "A".repeat(Math.ceil(MAX_IMAGE_BYTES * 1.4) + 4);
      const { recognizer, seen } = stubRecognizer(pageWith(["x"]));
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: huge }),
        deps({ recognizer }),
      );
      expect(response.status).toBe(413);
      expect(seen).toHaveLength(0);
    });

    it("rejects a corrupted upload rather than paying to OCR it", async () => {
      const { recognizer, seen } = stubRecognizer(pageWith(["x"]));
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: "%%%%%%" }),
        deps({ recognizer }),
      );
      expect(response.status).toBe(400);
      expect(seen).toHaveLength(0);
    });
  });

  describe("provider failures", () => {
    it("maps a transient provider failure to 503 and says it is retryable", async () => {
      const { recognizer } = stubRecognizer(new DocumentAIError("kısa süreli", 503, true));
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
        deps({ recognizer }),
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toMatchObject({ retryable: true });
    });

    it("maps a permanent provider failure to 502 and says it is not", async () => {
      const { recognizer } = stubRecognizer(new DocumentAIError("kalıcı", 403, false));
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
        deps({ recognizer }),
      );
      // Not 403: the phone must not read a Google permission problem as its
      // own device token being wrong.
      expect(response.status).toBe(502);
      expect(await response.json()).toMatchObject({ retryable: false });
    });

    it("does not leak an unexpected error's message", async () => {
      const secret = "sayfada yazan gizli metin";
      const { recognizer } = stubRecognizer(new Error(secret));
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
        deps({ recognizer }),
      );
      expect(response.status).toBe(500);
      expect(await response.text()).not.toContain(secret);
    });

    it("reports a missing credential as permanent, not as something to retry", async () => {
      // Found by running the server with no key: it answered "unexpected
      // error, retryable" — so the phone would have queued a retry forever
      // for a problem only a human can fix.
      const { recognizer } = stubRecognizer(
        new DocumentAIError("Google kimlik doğrulaması başarısız: ...", undefined, false),
      );
      const response = await handleOcrRequest(
        post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
        deps({ recognizer }),
      );
      expect(response.status).toBe(502);
      expect(await response.json()).toMatchObject({ retryable: false });
    });

    it("tells the log and the client the same thing", async () => {
      // These were computed separately and disagreed: the log said
      // retryable=false while the reply said true. A log that contradicts the
      // client is worse than none, because it is trusted while debugging.
      for (const thrown of [
        new DocumentAIError("geçici", 503, true),
        new DocumentAIError("kalıcı", 403, false),
        new Error("beklenmeyen"),
      ]) {
        const { recognizer } = stubRecognizer(thrown);
        const d = deps({ recognizer });
        const response = await handleOcrRequest(
          post({ jobId: "j", mimeType: "image/jpeg", imageBase64: IMAGE }),
          d,
        );
        const body = (await response.json()) as { retryable: boolean };
        expect(d.logged[0]!.retryable, `${thrown.message}`).toBe(body.retryable);
      }
    });
  });

  describe("privacy (§7.3)", () => {
    it("logs metrics but never content", async () => {
      const text = "Anafilakside 0,3–0,5 mg IM adrenalin uygulanmalıdır";
      const { recognizer } = stubRecognizer(pageWith([text]));
      const d = deps({ recognizer });
      await handleOcrRequest(
        post({ jobId: "job-9", mimeType: "image/jpeg", imageBase64: IMAGE }),
        d,
      );

      const serialized = JSON.stringify(d.logged);
      expect(serialized).not.toContain(text);
      expect(serialized).not.toContain(IMAGE);
      // ...but the metrics that §7.3 does allow are there.
      expect(d.logged[0]).toMatchObject({ jobId: "job-9", lineCount: 1 });
      expect(d.logged[0]).toHaveProperty("elapsedMs");
      expect(d.logged[0]).toHaveProperty("bytes");
    });

    it("logs no content on the failure path either", async () => {
      const secret = "gizli";
      const { recognizer } = stubRecognizer(new DocumentAIError(secret, 500, true));
      const d = deps({ recognizer });
      await handleOcrRequest(
        post({ jobId: "job-x", mimeType: "image/jpeg", imageBase64: IMAGE }),
        d,
      );
      expect(JSON.stringify(d.logged)).not.toContain(IMAGE);
      expect(d.logged[0]).toMatchObject({ jobId: "job-x", event: "ocr.fail" });
    });
  });
});
