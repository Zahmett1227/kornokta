/**
 * Device authorization for the backend (ANA-PLAN §7.3).
 *
 * Single-user app: there are no accounts, only "is this my phone". The device
 * holds a long random token in the Keychain and sends it as a bearer token;
 * the backend holds the same value as a secret. That is enough to keep the
 * Google key from being reachable by anyone who finds the URL, which is the
 * whole point of the proxy (§0.7).
 *
 * Deliberately *not* here: user accounts, sessions, refresh flows. §7.2 says
 * the backend need not be a user database, and inventing one would be surface
 * area with nothing behind it.
 */

import { createHash, timingSafeEqual } from "node:crypto";

export type AuthResult =
  | { ok: true }
  | { ok: false; status: 401 | 500; message: string };

/**
 * Constant-time comparison that does not leak length either.
 *
 * `timingSafeEqual` throws when the two buffers differ in length, and guarding
 * that with an early `length !==` return would answer "is the length right?"
 * in observable time. Hashing both sides to a fixed width first removes the
 * question: every comparison is over the same number of bytes.
 */
function secretsMatch(a: string, b: string): boolean {
  const digest = (value: string) => createHash("sha256").update(value, "utf8").digest();
  return timingSafeEqual(digest(a), digest(b));
}

/**
 * Minimum length for the configured token. A short secret would pass every
 * check here and still be guessable, so the weakness is reported as a
 * configuration error rather than silently accepted.
 */
export const MIN_TOKEN_LENGTH = 32;

/**
 * Checks the `Authorization: Bearer <token>` header against `DEVICE_TOKEN`.
 *
 * A missing or too-short `DEVICE_TOKEN` is a **500, not a 401**: it means the
 * server is misconfigured, and answering 401 would make a deployment with no
 * token configured look like a correctly-rejecting one. Worse, treating an
 * unset secret as "no match" is one edit away from treating it as "match all".
 */
export function authorize(
  authorizationHeader: string | null | undefined,
  expectedToken: string | undefined,
): AuthResult {
  const expected = expectedToken?.trim();
  if (!expected) {
    return {
      ok: false,
      status: 500,
      message: "Sunucu yapılandırması eksik: DEVICE_TOKEN tanımlı değil.",
    };
  }
  if (expected.length < MIN_TOKEN_LENGTH) {
    return {
      ok: false,
      status: 500,
      message: `Sunucu yapılandırması zayıf: DEVICE_TOKEN en az ${MIN_TOKEN_LENGTH} karakter olmalı.`,
    };
  }

  const header = authorizationHeader?.trim() ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    return { ok: false, status: 401, message: "Yetkisiz." };
  }

  // One message for every rejection reason. Distinguishing "no token" from
  // "wrong token" tells an attacker which half to work on.
  return secretsMatch(match[1]!.trim(), expected)
    ? { ok: true }
    : { ok: false, status: 401, message: "Yetkisiz." };
}
