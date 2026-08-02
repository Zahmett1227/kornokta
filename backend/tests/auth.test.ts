import { describe, expect, it } from "vitest";

import { MIN_TOKEN_LENGTH, authorize } from "../api/_auth.js";

const GOOD_TOKEN = "x".repeat(MIN_TOKEN_LENGTH);

describe("authorize", () => {
  it("accepts the configured token", () => {
    expect(authorize(`Bearer ${GOOD_TOKEN}`, GOOD_TOKEN)).toEqual({ ok: true });
  });

  it("accepts the scheme case-insensitively and ignores surrounding space", () => {
    expect(authorize(`  bearer   ${GOOD_TOKEN}  `, GOOD_TOKEN).ok).toBe(true);
    expect(authorize(`BEARER ${GOOD_TOKEN}`, GOOD_TOKEN).ok).toBe(true);
  });

  it("rejects a wrong token", () => {
    const result = authorize(`Bearer ${"y".repeat(MIN_TOKEN_LENGTH)}`, GOOD_TOKEN);
    expect(result).toEqual({ ok: false, status: 401, message: "Yetkisiz." });
  });

  it("rejects a missing or malformed header", () => {
    for (const header of [null, undefined, "", "Basic abc", GOOD_TOKEN, "Bearer"]) {
      expect(authorize(header, GOOD_TOKEN).ok, `header: ${header}`).toBe(false);
    }
  });

  it("gives the same message however it was rejected", () => {
    // Distinguishing "no token" from "wrong token" tells an attacker which
    // half of the problem to work on.
    const noHeader = authorize(null, GOOD_TOKEN);
    const wrongToken = authorize(`Bearer ${"z".repeat(MIN_TOKEN_LENGTH)}`, GOOD_TOKEN);
    const notBearer = authorize("Basic abc", GOOD_TOKEN);

    expect(noHeader).toEqual(wrongToken);
    expect(notBearer).toEqual(wrongToken);
  });

  describe("server misconfiguration", () => {
    it("is a 500, not a 401", () => {
      // A deployment with no token set must not look like one that is
      // correctly rejecting requests.
      for (const missing of [undefined, "", "   "]) {
        const result = authorize(`Bearer ${GOOD_TOKEN}`, missing);
        expect(result.ok).toBe(false);
        expect(result.ok === false && result.status).toBe(500);
      }
    });

    it("never authorizes against an unset token", () => {
      // The failure mode being guarded: an empty expected value being
      // compared against an empty presented value and matching.
      expect(authorize("Bearer ", undefined).ok).toBe(false);
      expect(authorize("Bearer ", "").ok).toBe(false);
      expect(authorize(null, "").ok).toBe(false);
    });

    it("refuses a token short enough to guess", () => {
      const short = "a".repeat(MIN_TOKEN_LENGTH - 1);
      const result = authorize(`Bearer ${short}`, short);
      expect(result.ok).toBe(false);
      expect(result.ok === false && result.status).toBe(500);
      expect(result.ok === false && result.message).toMatch(/DEVICE_TOKEN/);
    });
  });

  it("compares tokens of differing length without throwing", () => {
    // timingSafeEqual throws on a length mismatch; hashing first avoids both
    // the throw and the length oracle.
    expect(() => authorize("Bearer short", GOOD_TOKEN)).not.toThrow();
    expect(() => authorize(`Bearer ${"q".repeat(500)}`, GOOD_TOKEN)).not.toThrow();
    expect(authorize("Bearer short", GOOD_TOKEN).ok).toBe(false);
  });
});
