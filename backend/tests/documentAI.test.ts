import { describe, expect, it } from "vitest";

import type { DocumentAIConfig } from "../config.js";
import {
  DocumentAIError,
  DocumentAIRecognizer,
  blocksOf,
  boundsOf,
  columnBoundaries,
  orderByReadingPosition,
  textForLayout,
  type Positioned,
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
function documentWith(
  lines: Array<{ text: string; y: number; x?: number; width?: number; confidence?: number }>,
): ProcessResponse {
  let fullText = "";
  const blocks = lines.map((line) => {
    const startIndex = fullText.length;
    fullText += `${line.text}\n`;
    const x = line.x ?? 0.1;
    const width = line.width ?? 0.5;
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
            { x: x + width, y: line.y },
            { x: x + width, y: line.y + 0.03 },
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

/** One row of a two-column layout: one labeled item per column at height `y`. */
function twoColumnRow(y: number, leftText: string, rightText: string): Array<Positioned & { text: string }> {
  return [
    { x: 0.05, y, width: 0.4, height: 0.03, text: leftText },
    { x: 0.55, y, width: 0.4, height: 0.03, text: rightText },
  ];
}

describe("columnBoundaries", () => {
  it("finds nothing with too few items to infer a layout", () => {
    expect(columnBoundaries([{ x: 0.1, y: 0.1, width: 0.2, height: 0.03 }])).toEqual([]);
  });

  it("finds nothing for an ordinary single-column page", () => {
    const items: Positioned[] = Array.from({ length: 8 }, (_, index) => ({
      x: 0.1,
      y: index * 0.05,
      width: 0.8,
      height: 0.03,
    }));
    expect(columnBoundaries(items)).toEqual([]);
  });

  it("finds the gutter of a genuine two-column layout", () => {
    const items: Positioned[] = [0.1, 0.2, 0.3, 0.4].flatMap((y) => [
      { x: 0.05, y, width: 0.4, height: 0.03 },
      { x: 0.55, y, width: 0.4, height: 0.03 },
    ]);
    const boundaries = columnBoundaries(items);
    expect(boundaries).toHaveLength(1);
    expect(boundaries[0]).toBeCloseTo(0.5, 1);
  });

  it("does not let a short right column's trailing margin masquerade as a second gutter", () => {
    // The right column ends at x=0.84 (a short comparison-list entry), so its
    // trailing margin to the page edge is 16% wide — wide enough to pass the
    // gutter-width check, and its center (0.92) is right at the old edge
    // threshold. Without rejecting edge-touching runs outright, this reads as
    // a second "gutter", produces an empty third column, fails the
    // minimum-lines check, and the whole (otherwise valid) two-column split
    // is discarded — leaving the page interleaved row by row again.
    const items: Positioned[] = [0.1, 0.2, 0.3].flatMap((y) => [
      { x: 0.05, y, width: 0.4, height: 0.03 },
      { x: 0.5, y, width: 0.34, height: 0.03 },
    ]);
    const boundaries = columnBoundaries(items);
    expect(boundaries).toHaveLength(1);
    expect(boundaries[0]).toBeCloseTo(0.45, 1);
  });

  it("finds genuine columns even with staggered, never pixel-aligned baselines", () => {
    // Independently-typeset columns are never aligned row for row in
    // practice. Left lines at 0.10/0.15/0.20, right lines offset by half a
    // row (0.125/0.175/0.225): both columns occupy the same vertical region,
    // but a strict same-band requirement would see almost no shared bands.
    const left = [0.1, 0.15, 0.2].map((y) => ({ x: 0.05, y, width: 0.4, height: 0.02 }));
    const right = [0.125, 0.175, 0.225].map((y) => ({ x: 0.55, y, width: 0.4, height: 0.02 }));
    const boundaries = columnBoundaries([...left, ...right]);
    expect(boundaries).toHaveLength(1);
    expect(boundaries[0]).toBeCloseTo(0.5, 1);
  });

  it("tolerates a page header and a footer together, not just one outlier", () => {
    // A title at the top and a page number at the bottom both span the full
    // width, so together they cover every bucket the real gutter occupies —
    // if spanning items were merely "tolerated" up to a small count rather
    // than excluded outright, two of them at the same x would still hide the
    // gutter from the gap scan.
    const header = { x: 0.05, y: 0.02, width: 0.9, height: 0.02 };
    const footer = { x: 0.05, y: 0.9, width: 0.9, height: 0.02 };
    const columns = [0.2, 0.3, 0.4, 0.5].flatMap((y) => [
      { x: 0.05, y, width: 0.4, height: 0.03 },
      { x: 0.55, y, width: 0.4, height: 0.03 },
    ]);
    const boundaries = columnBoundaries([header, footer, ...columns]);
    expect(boundaries).toHaveLength(1);
    expect(boundaries[0]).toBeCloseTo(0.5, 1);
  });

  it("ignores a narrow near-edge gap as an ordinary margin, not a column break", () => {
    // Content spans [0.05, 0.97] almost fully; the only "gaps" are the page
    // margins on either side, which must not read as a column split.
    const items: Positioned[] = Array.from({ length: 8 }, (_, index) => ({
      x: 0.05,
      y: index * 0.05,
      width: 0.92,
      height: 0.03,
    }));
    expect(columnBoundaries(items)).toEqual([]);
  });

  it("tolerates one full-width outlier (a header) crossing the gutter", () => {
    const columns: Positioned[] = [0.2, 0.3, 0.4, 0.5, 0.6].flatMap((y) => [
      { x: 0.05, y, width: 0.4, height: 0.03 },
      { x: 0.55, y, width: 0.4, height: 0.03 },
    ]);
    const header: Positioned = { x: 0.05, y: 0.05, width: 0.9, height: 0.03 };
    const boundaries = columnBoundaries([header, ...columns]);
    expect(boundaries).toHaveLength(1);
    expect(boundaries[0]).toBeCloseTo(0.5, 1);
  });

  it("rejects a gap that would leave a column with too few lines", () => {
    // One short, indented line creates a thin apparent gap, but nothing else
    // on the page is split that way — must not be read as two columns.
    const items: Positioned[] = [
      { x: 0.3, y: 0.1, width: 0.3, height: 0.03 },
      ...Array.from({ length: 6 }, (_, index) => ({
        x: 0.05,
        y: 0.2 + index * 0.05,
        width: 0.9,
        height: 0.03,
      })),
    ];
    expect(columnBoundaries(items)).toEqual([]);
  });

  it("rejects horizontally-separated regions that never coexist vertically", () => {
    // Two right-aligned metadata lines at the very top, then unrelated
    // left-aligned body text below: different x-ranges, but not a column
    // layout — one region sits entirely above the other.
    const metadata = [0.02, 0.05].map((y) => ({ x: 0.6, y, width: 0.35, height: 0.02 }));
    const body = Array.from({ length: 6 }, (_, index) => ({
      x: 0.05,
      y: 0.15 + index * 0.05,
      width: 0.5,
      height: 0.03,
    }));
    expect(columnBoundaries([...metadata, ...body])).toEqual([]);
  });

  it("rejects columns whose outer envelopes overlap but whose lines never actually coexist", () => {
    // Left column has two lines far apart (top and bottom of the page) with a
    // large empty gap between them; the right column's lines sit entirely in
    // that gap. The left column's *envelope* [0.05, 0.88] contains the right
    // column's range, but no line from either side is ever actually beside a
    // line from the other — this must not read as a two-column layout.
    const left = [0.05, 0.85].map((y) => ({ x: 0.05, y, width: 0.4, height: 0.03 }));
    const right = [0.4, 0.42].map((y) => ({ x: 0.55, y, width: 0.4, height: 0.03 }));
    expect(columnBoundaries([...left, ...right])).toEqual([]);
  });
});

describe("orderByReadingPosition", () => {
  it("falls back to top-to-bottom-then-left-to-right with no detected columns", () => {
    const items = [
      { id: "alt", x: 0.1, y: 0.5, width: 0.5, height: 0.03 },
      { id: "üst sağ", x: 0.6, y: 0.1, width: 0.5, height: 0.03 },
      { id: "üst sol", x: 0.1, y: 0.1, width: 0.5, height: 0.03 },
    ];
    expect(orderByReadingPosition(items).map((item) => item.id)).toEqual([
      "üst sol",
      "üst sağ",
      "alt",
    ]);
  });

  it("reads a two-column comparison list column by column, not row by row", () => {
    // Mirrors the real bug: a Nekroz/Apoptoz style comparison list where each
    // row has one bullet per column at the same height. Row-by-row reading
    // interleaves the two topics into one garbled sentence.
    const items = [
      ...twoColumnRow(0.1, "Nekroz 1", "Apoptoz 1"),
      ...twoColumnRow(0.2, "Nekroz 2", "Apoptoz 2"),
      ...twoColumnRow(0.3, "Nekroz 3", "Apoptoz 3"),
    ];

    const ordered = orderByReadingPosition(items).map((item) => item.text);
    expect(ordered).toEqual([
      "Nekroz 1",
      "Nekroz 2",
      "Nekroz 3",
      "Apoptoz 1",
      "Apoptoz 2",
      "Apoptoz 3",
    ]);
  });

  it("places a header before both columns rather than inside one of them", () => {
    const header = { text: "Başlık", x: 0.05, y: 0.02, width: 0.9, height: 0.03 };
    const items = [
      header,
      ...twoColumnRow(0.1, "Nekroz 1", "Apoptoz 1"),
      ...twoColumnRow(0.2, "Nekroz 2", "Apoptoz 2"),
      ...twoColumnRow(0.3, "Nekroz 3", "Apoptoz 3"),
    ];

    const ordered = orderByReadingPosition(items).map((item) => item.text);
    expect(ordered).toEqual([
      "Başlık",
      "Nekroz 1",
      "Nekroz 2",
      "Nekroz 3",
      "Apoptoz 1",
      "Apoptoz 2",
      "Apoptoz 3",
    ]);
  });

  it("places a footer after both columns rather than between them", () => {
    // The exact corruption Codex flagged: assigning a gutter-spanning line to
    // a column purely by its center stranded a footer between the columns.
    const footer = { text: "Dipnot", x: 0.05, y: 0.4, width: 0.9, height: 0.03 };
    const items = [
      ...twoColumnRow(0.1, "Nekroz 1", "Apoptoz 1"),
      ...twoColumnRow(0.2, "Nekroz 2", "Apoptoz 2"),
      ...twoColumnRow(0.3, "Nekroz 3", "Apoptoz 3"),
      footer,
    ];

    const ordered = orderByReadingPosition(items).map((item) => item.text);
    expect(ordered).toEqual([
      "Nekroz 1",
      "Nekroz 2",
      "Nekroz 3",
      "Apoptoz 1",
      "Apoptoz 2",
      "Apoptoz 3",
      "Dipnot",
    ]);
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

  it("reads a two-column comparison page column by column end to end", async () => {
    // The actual reported bug: a Nekroz/Apoptoz-style comparison list read
    // row by row instead of column by column, which merges two unrelated
    // topics into one garbled passage.
    const { transport } = stubTransport(
      200,
      documentWith([
        { text: "Apoptoz 1", y: 0.1, x: 0.55, width: 0.4 },
        { text: "Nekroz 1", y: 0.1, x: 0.05, width: 0.4 },
        { text: "Apoptoz 2", y: 0.2, x: 0.55, width: 0.4 },
        { text: "Nekroz 2", y: 0.2, x: 0.05, width: 0.4 },
        { text: "Apoptoz 3", y: 0.3, x: 0.55, width: 0.4 },
        { text: "Nekroz 3", y: 0.3, x: 0.05, width: 0.4 },
      ]),
    );
    const recognizer = new DocumentAIRecognizer(CONFIG, TOKENS, transport);
    const page = await recognizer.recognize(new Uint8Array([0]), {
      imagePath: "/tmp/a.jpg",
      mimeType: "image/jpeg",
    });

    expect(page.lines.map((line) => line.text)).toEqual([
      "Nekroz 1",
      "Nekroz 2",
      "Nekroz 3",
      "Apoptoz 1",
      "Apoptoz 2",
      "Apoptoz 3",
    ]);
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
