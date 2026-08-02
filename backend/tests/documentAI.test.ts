import { describe, expect, it } from "vitest";

import type { DocumentAIConfig } from "../config.js";
import {
  DocumentAIError,
  DocumentAIRecognizer,
  blocksOf,
  boundsOf,
  textForLayout,
  type ProcessResponse,
  type TokenSource,
  type Transport,
} from "../providers/documentAI.js";

const CONFIG: DocumentAIConfig = {
  projectId: "kornokta",
  location: "eu",
  processorId: "6213367b4c106c7e",
  languageHints: ["tr", "en"],
  timeoutMs: 1_000,
};

const TOKENS: TokenSource = { getToken: async () => "test-token" };

/** Records what was sent and replays a canned response. No network, no key. */
function stubTransport(status: number, body: unknown) {
  const calls: Array<{ url: string; token: string; body: any }> = [];
  const transport: Transport = {
    async post(url, token, requestBody) {
      calls.push({ url, token, body: requestBody });
      return { status, body };
    },
  };
  return { transport, calls };
}

/**
 * A response in Document AI's real shape: text lives once in `document.text`
 * and each line points into it by offset.
 */
function documentWith(lines: Array<{ text: string; y: number; x?: number; confidence?: number }>): ProcessResponse {
  let fullText = "";
  const blocks = lines.map((line) => {
    const startIndex = fullText.length;
    fullText += `${line.text}\n`;
    const x = line.x ?? 0.1;
    return {
      layout: {
        // startIndex is omitted when zero, exactly as proto3 JSON does.
        textAnchor: {
          textSegments: [
            startIndex === 0
              ? { endIndex: String(fullText.length) }
              : { startIndex: String(startIndex), endIndex: String(fullText.length) },
          ],
        },
        confidence: line.confidence ?? 0.98,
        boundingPoly: {
          normalizedVertices: [
            { x, y: line.y },
            { x: x + 0.5, y: line.y },
            { x: x + 0.5, y: line.y + 0.03 },
            { x, y: line.y + 0.03 },
          ],
        },
      },
    };
  });

  return {
    document: {
      text: fullText,
      pages: [{ dimension: { width: 1600, height: 1200 }, lines: blocks }],
    },
  };
}

describe("textForLayout", () => {
  it("treats a missing startIndex as zero, not as a missing segment", () => {
    // proto3 omits default values, so the first line of every page arrives
    // without a startIndex. Reading that as "no segment" drops it silently.
    const text = "Anafilakside ilk seçenek\nikinci satır\n";
    const line = textForLayout(text, {
      textAnchor: { textSegments: [{ endIndex: "24" }] },
    });
    expect(line).toBe("Anafilakside ilk seçenek");
  });

  it("joins multiple segments", () => {
    const text = "abcdef";
    expect(
      textForLayout(text, {
        textAnchor: {
          textSegments: [
            { endIndex: "2" },
            { startIndex: "4", endIndex: "6" },
          ],
        },
      }),
    ).toBe("abef");
  });

  it("drops the trailing newline that separates lines", () => {
    expect(
      textForLayout("satır\n", { textAnchor: { textSegments: [{ endIndex: "6" }] } }),
    ).toBe("satır");
  });

  it("returns empty for a layout with no anchor", () => {
    expect(textForLayout("abc", undefined)).toBe("");
    expect(textForLayout("abc", {})).toBe("");
  });

  it("ignores a segment whose end is not after its start", () => {
    expect(
      textForLayout("abc", { textAnchor: { textSegments: [{ startIndex: "2", endIndex: "1" }] } }),
    ).toBe("");
  });
});

describe("boundsOf", () => {
  it("takes the axis-aligned bounds of the polygon", () => {
    const bounds = boundsOf({
      boundingPoly: {
        normalizedVertices: [
          { x: 0.2, y: 0.1 },
          { x: 0.8, y: 0.12 },
          { x: 0.8, y: 0.16 },
          { x: 0.2, y: 0.14 },
        ],
      },
    });
    expect(bounds.x).toBeCloseTo(0.2);
    expect(bounds.y).toBeCloseTo(0.1);
    expect(bounds.width).toBeCloseTo(0.6);
    expect(bounds.height).toBeCloseTo(0.06);
  });

  it("does not flip the vertical axis", () => {
    // Document AI is already top-left, unlike Vision's bottom-left. A flip
    // here would mirror every box and silently break marker overlap.
    const near = boundsOf({
      boundingPoly: { normalizedVertices: [{ x: 0, y: 0.05 }, { x: 1, y: 0.09 }] },
    });
    expect(near.y).toBeCloseTo(0.05);
  });

  it("survives a missing polygon", () => {
    expect(boundsOf(undefined)).toEqual({ x: 0, y: 0, width: 0, height: 0 });
    expect(boundsOf({})).toEqual({ x: 0, y: 0, width: 0, height: 0 });
  });
});

describe("blocksOf", () => {
  it("prefers lines", () => {
    expect(blocksOf({ lines: [{}, {}], paragraphs: [{}], blocks: [{}] })).toHaveLength(2);
  });

  it("falls back to paragraphs then blocks so a processor swap is not silently empty", () => {
    expect(blocksOf({ paragraphs: [{}, {}, {}] })).toHaveLength(3);
    expect(blocksOf({ blocks: [{}] })).toHaveLength(1);
    expect(blocksOf({})).toHaveLength(0);
  });
});

describe("DocumentAIRecognizer", () => {
  it("addresses the regional endpoint", () => {
    // An eu processor is not reachable on the global host; the 404 it returns
    // reads like the processor does not exist.
    const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS);
    expect(recognizer.endpoint).toBe(
      "https://eu-documentai.googleapis.com/v1/projects/kornokta/locations/eu" +
        "/processors/6213367b4c106c7e:process",
    );
  });

  it("sends the image and the Turkish language hint", async () => {
    const { transport, calls } = stubTransport(200, documentWith([{ text: "merhaba", y: 0.1 }]));
    const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);

    await recognizer.recognize(new Uint8Array([1, 2, 3]), {
      imagePath: "/tmp/a.jpg",
      mimeType: "image/jpeg",
    });

    expect(calls).toHaveLength(1);
    expect(calls[0]!.token).toBe("test-token");
    expect(calls[0]!.body.rawDocument.mimeType).toBe("image/jpeg");
    expect(calls[0]!.body.rawDocument.content).toBe(Buffer.from([1, 2, 3]).toString("base64"));
    expect(calls[0]!.body.processOptions.ocrConfig.hints.languageHints).toEqual(["tr", "en"]);
  });

  it("preserves Turkish characters verbatim", async () => {
    // The whole reason this provider exists (docs/ADR-002): Apple Vision
    // cannot emit ı ş ğ İ at all. Every one of them appears in this sentence,
    // along with the en dash and the decimal comma §10.5 also cares about.
    const source =
      "İlk 0,3–0,5 mg IM adrenalin sağ uyluğa uygulanmalıdır; şok gelişirse gecikilmemelidir.";
    for (const character of ["İ", "ı", "ş", "ğ", "–", ","]) {
      expect(source, `örnek cümlede '${character}' yok`).toContain(character);
    }

    const { transport } = stubTransport(200, documentWith([{ text: source, y: 0.1 }]));
    const page = await new DocumentAIRecognizer(CONFIG, TOKENS, transport).recognize(
      new Uint8Array([0]),
      { imagePath: "/tmp/a.jpg", mimeType: "image/jpeg" },
    );

    expect(page.lines[0]!.text).toBe(source);
  });

  it("orders lines top-to-bottom then left-to-right", async () => {
    const { transport } = stubTransport(
      200,
      documentWith([
        { text: "alt", y: 0.5 },
        { text: "üst sağ", y: 0.1, x: 0.6 },
        { text: "üst sol", y: 0.1, x: 0.1 },
      ]),
    );
    const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);
    const page = await recognizer.recognize(new Uint8Array([0]), {
      imagePath: "/tmp/a.jpg",
      mimeType: "image/jpeg",
    });

    expect(page.lines.map((line) => line.text)).toEqual(["üst sol", "üst sağ", "alt"]);
    expect(page.lines.map((line) => line.lineId)).toEqual(["line_00", "line_01", "line_02"]);
  });

  it("reports page size and never claims language correction", async () => {
    const { transport } = stubTransport(200, documentWith([{ text: "a b c d", y: 0.1 }]));
    const page = await new DocumentAIRecognizer(CONFIG, TOKENS, transport).recognize(
      new Uint8Array([0]),
      { imagePath: "/tmp/page.jpg", mimeType: "image/jpeg" },
    );

    expect(page.imageWidth).toBe(1600);
    expect(page.imageHeight).toBe(1200);
    expect(page.imagePath).toBe("/tmp/page.jpg");
    // §0.5: no silent rewriting, and the report has to say so.
    expect(page.usesLanguageCorrection).toBe(false);
  });

  it("drops blank lines rather than emitting empty entries", async () => {
    const { transport } = stubTransport(
      200,
      documentWith([
        { text: "gerçek satır", y: 0.1 },
        { text: "   ", y: 0.2 },
      ]),
    );
    const page = await new DocumentAIRecognizer(CONFIG, TOKENS, transport).recognize(
      new Uint8Array([0]),
      { imagePath: "/tmp/a.jpg", mimeType: "image/jpeg" },
    );
    expect(page.lines).toHaveLength(1);
  });

  it("returns an empty page rather than throwing when nothing was recognized", async () => {
    const { transport } = stubTransport(200, { document: { text: "", pages: [] } });
    const page = await new DocumentAIRecognizer(CONFIG, TOKENS, transport).recognize(
      new Uint8Array([0]),
      { imagePath: "/tmp/blank.jpg", mimeType: "image/jpeg" },
    );
    expect(page.lines).toEqual([]);
  });

  describe("failures", () => {
    it("marks 5xx and 429 as retryable", async () => {
      for (const status of [429, 500, 503]) {
        const { transport } = stubTransport(status, { error: { message: "boom" } });
        const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);
        const error = await recognizer
          .recognize(new Uint8Array([0]), { imagePath: "a", mimeType: "image/jpeg" })
          .catch((caught) => caught as DocumentAIError);
        expect(error).toBeInstanceOf(DocumentAIError);
        expect((error as DocumentAIError).transient, `status ${status}`).toBe(true);
      }
    });

    it("marks 401/403/404/400 as permanent so a wrong config is not retried forever", async () => {
      for (const status of [400, 401, 403, 404]) {
        const { transport } = stubTransport(status, { error: { message: "nope" } });
        const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);
        const error = await recognizer
          .recognize(new Uint8Array([0]), { imagePath: "a", mimeType: "image/jpeg" })
          .catch((caught) => caught as DocumentAIError);
        expect((error as DocumentAIError).transient, `status ${status}`).toBe(false);
      }
    });

    it("carries Google's message so a misconfiguration is diagnosable", async () => {
      const { transport } = stubTransport(403, {
        error: { message: "Permission 'documentai.processors.process' denied" },
      });
      const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);
      await expect(
        recognizer.recognize(new Uint8Array([0]), { imagePath: "a", mimeType: "image/jpeg" }),
      ).rejects.toThrow(/documentai.processors.process/);
    });

    it("does not put image bytes or recognized text into the error", async () => {
      // §7.3: content must not leak into logs, and an error message is a log.
      const secret = "hasta bilgisi olmayan ama yine de içerik";
      const { transport } = stubTransport(500, { document: { text: secret } });
      const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);

      let message = "";
      try {
        await recognizer.recognize(Buffer.from(secret), {
          imagePath: "a",
          mimeType: "image/jpeg",
        });
        expect.unreachable("500 hata fırlatmalıydı");
      } catch (caught) {
        message = (caught as Error).message;
      }

      expect(message).not.toBe("");
      expect(message).not.toContain(secret);
      expect(message).not.toContain(Buffer.from(secret).toString("base64"));
    });
  });
});
