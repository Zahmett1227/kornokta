/**
 * Image intake shared by the card endpoints (`/api/cards-vision`, `/api/jobs`).
 *
 * These used to live in `_ocr.ts`; when the deterministic OCR pipeline left the
 * main flow for good (docs/ADR-005, trim of 2026-08-09) the handlers around
 * them were deleted and the two survivors moved here unchanged.
 */

/** DoS guard, not a Document AI constraint: 20 MB is far above any real page photo. */
export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

/**
 * Decodes base64 strictly.
 *
 * `Buffer.from(x, "base64")` silently ignores anything that is not a base64
 * character, so a truncated or corrupted upload would decode to a shorter
 * image and be sent to a paid API as if it were fine. Re-encoding and
 * comparing catches that.
 */
export function decodeImage(base64: string): Uint8Array | null {
  const cleaned = base64.trim();
  if (!cleaned) return null;
  const bytes = Buffer.from(cleaned, "base64");
  if (bytes.length === 0) return null;
  // Compare against the input with padding normalized; a valid payload
  // round-trips exactly.
  const reencoded = bytes.toString("base64");
  const normalize = (value: string) => value.replace(/=+$/, "");
  if (normalize(reencoded) !== normalize(cleaned)) return null;
  return new Uint8Array(bytes);
}
