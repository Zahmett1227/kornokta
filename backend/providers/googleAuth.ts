/**
 * Where the Google credential comes from (ANA-PLAN §0.7, §7.3).
 *
 * Two sources, because the two places this runs cannot use the same one:
 *
 *   * **Locally** the key is a file and `GOOGLE_APPLICATION_CREDENTIALS` holds
 *     its path. The auth library reads it; the key never passes through our
 *     code, which is the safest arrangement and stays the default.
 *   * **On a host** there is no file to point at — a deployment sets
 *     environment variables, not files — so the service-account JSON is passed
 *     inline in `GOOGLE_CREDENTIALS_JSON`.
 *
 * This module is the only thing that touches the inline form. It is separate
 * from `config.ts` on purpose: that file's return value is asserted to carry no
 * credential, and this one exists precisely to carry one.
 */

/** The subset of `GoogleAuthOptions` we set. Typed locally so this module does
 *  not have to import the auth library just for a shape. */
export interface GoogleAuthOptions {
  scopes: string[];
  /** Absent when the credential is a file the library finds for itself. */
  credentials?: Record<string, unknown>;
}

export const CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform";

export class CredentialError extends Error {}

/**
 * Builds the options for `new GoogleAuth(...)`.
 *
 * Reads `process.env` directly rather than going through `loadConfig()`: a
 * credential must not become a field on a config object that other code holds,
 * logs or serializes. It is read here and handed straight to the auth library.
 */
export function googleAuthOptions(
  env: NodeJS.ProcessEnv = process.env,
): GoogleAuthOptions {
  const inline = env.GOOGLE_CREDENTIALS_JSON?.trim();
  if (!inline) {
    return { scopes: [CLOUD_PLATFORM_SCOPE] };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(inline);
  } catch {
    // The caught error is deliberately discarded. V8's JSON parse messages
    // quote the offending input ("Unexpected token ... at position N"), and the
    // input here is a private key — logging that error, or returning it to a
    // caller, would put the key in a log line (§7.3). The variable name alone
    // is enough to fix the problem.
    throw new CredentialError(
      "GOOGLE_CREDENTIALS_JSON geçerli bir JSON değil. " +
        "Servis hesabı dosyasının tamamını tek satır olarak yapıştır.",
    );
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new CredentialError(
      "GOOGLE_CREDENTIALS_JSON bir JSON nesnesi olmalı (servis hesabı dosyasının içeriği).",
    );
  }

  const credentials = parsed as Record<string, unknown>;
  // Named up front rather than letting the auth library fail later with a
  // message about a field the user has never heard of.
  for (const field of ["client_email", "private_key"]) {
    if (typeof credentials[field] !== "string" || !credentials[field]) {
      throw new CredentialError(
        `GOOGLE_CREDENTIALS_JSON içinde '${field}' yok. ` +
          "Servis hesabı anahtarının tamamını kopyaladığından emin ol.",
      );
    }
  }

  return { scopes: [CLOUD_PLATFORM_SCOPE], credentials };
}
