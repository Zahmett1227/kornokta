/**
 * Local development server.
 *
 *     npm run serve
 *
 * Runs the same handler a deployment would, so what is tested here is what
 * ships. Bound to localhost only: the process holds a Google key, and binding
 * to every interface would expose it to the network the laptop is on.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { existsSync } from "node:fs";
import { config as loadEnvFile } from "dotenv";

if (existsSync(".env")) {
  const result = loadEnvFile();
  if (result.error) {
    console.error(`.env okunamadı: ${result.error.message}`);
    process.exit(1);
  }
}

const { handler } = await import("../api/index.js");

const PORT = Number(process.env.PORT ?? 8787);
const HOST = "127.0.0.1";

async function readBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}

/** Bridges Node's http types to the fetch `Request`/`Response` the handler speaks. */
function toRequest(incoming: IncomingMessage, body: Buffer): Request {
  const url = `http://${HOST}:${PORT}${incoming.url ?? "/"}`;
  const headers = new Headers();
  for (const [key, value] of Object.entries(incoming.headers)) {
    if (typeof value === "string") headers.set(key, value);
    else if (Array.isArray(value)) headers.set(key, value.join(", "));
  }
  const method = incoming.method ?? "GET";
  return new Request(url, {
    method,
    headers,
    body: method === "GET" || method === "HEAD" ? undefined : body,
  });
}

async function send(response: Response, outgoing: ServerResponse): Promise<void> {
  outgoing.statusCode = response.status;
  response.headers.forEach((value, key) => outgoing.setHeader(key, value));
  outgoing.end(Buffer.from(await response.arrayBuffer()));
}

const server = createServer((incoming, outgoing) => {
  void (async () => {
    try {
      const body = await readBody(incoming);
      const response = await handler(toRequest(incoming, body));
      await send(response, outgoing);
    } catch (error) {
      // Never echo the thrown message: it could carry request content (§7.3).
      console.error("sunucu hatası:", error instanceof Error ? error.name : "bilinmeyen");
      outgoing.statusCode = 500;
      outgoing.setHeader("Content-Type", "application/json");
      outgoing.end(JSON.stringify({ error: "Sunucu hatası.", retryable: true }));
    }
  })();
});

server.listen(PORT, HOST, () => {
  console.log(`Dinleniyor: http://${HOST}:${PORT}`);
  console.log(`  GET  /health`);
  console.log(`  POST /api/ocr   (Authorization: Bearer <DEVICE_TOKEN>)`);
  if (!process.env.DEVICE_TOKEN) {
    console.warn("\nUYARI: DEVICE_TOKEN tanımlı değil; /api/ocr 500 dönecek.");
    console.warn("       Üretmek için: npm run token");
  }
});
