import { describe, expect, it } from "vitest";

import {
  CLOUD_PLATFORM_SCOPE,
  CredentialError,
  googleAuthOptions,
} from "../providers/googleAuth.js";

/** A structurally valid service-account key. The private key is nonsense. */
const SERVICE_ACCOUNT = {
  type: "service_account",
  project_id: "kornokta",
  private_key_id: "abc123",
  private_key: "-----BEGIN PRIVATE KEY-----\nSAHTE\n-----END PRIVATE KEY-----\n",
  client_email: "cizgi@kornokta.iam.gserviceaccount.com",
  client_id: "1234567890",
};

describe("googleAuthOptions", () => {
  it("falls back to the file-based credential when nothing is set inline", () => {
    const options = googleAuthOptions({});
    expect(options.scopes).toEqual([CLOUD_PLATFORM_SCOPE]);
    // No `credentials` key at all: the auth library then resolves
    // GOOGLE_APPLICATION_CREDENTIALS itself and the key never enters our code.
    expect(options.credentials).toBeUndefined();
  });

  it("treats an empty or whitespace value as unset", () => {
    // A deployment dashboard makes it easy to create a variable and leave it
    // blank. That must behave like "not configured", not like "invalid JSON".
    expect(googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: "" }).credentials).toBeUndefined();
    expect(googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: "   " }).credentials).toBeUndefined();
  });

  it("passes an inline service account through to the auth library", () => {
    const options = googleAuthOptions({
      GOOGLE_CREDENTIALS_JSON: JSON.stringify(SERVICE_ACCOUNT),
    });
    expect(options.credentials?.client_email).toBe(SERVICE_ACCOUNT.client_email);
    expect(options.credentials?.private_key).toBe(SERVICE_ACCOUNT.private_key);
  });

  it("survives the newlines a real private key contains", () => {
    // The usual way this breaks: the key is one JSON string containing \n
    // escapes, and a hand-written substitution mangles them.
    const options = googleAuthOptions({
      GOOGLE_CREDENTIALS_JSON: JSON.stringify(SERVICE_ACCOUNT),
    });
    expect(String(options.credentials?.private_key)).toContain("\n");
  });

  it("never puts the credential in the error when the JSON is malformed", () => {
    // The whole point of catching and rewriting. V8 quotes a window of the
    // offending input in its message, and for an unquoted value that window is
    // the value itself:
    //
    //   Unexpected token 'S', ..."ate_key": SUPERGIZLI"... is not valid JSON
    //
    // Losing the quotes around a value is exactly what a shell or a deployment
    // dashboard does to a pasted key, so this is the realistic case, and left
    // unwrapped it writes the private key into a log line (§7.3).
    const secret = "SUPERGIZLIANAHTAR";
    let message = "";
    try {
      googleAuthOptions({
        GOOGLE_CREDENTIALS_JSON: `{"client_email":"a@b.c","private_key": ${secret}}`,
      });
    } catch (error) {
      message = (error as Error).message;
      expect(error).toBeInstanceOf(CredentialError);
    }
    expect(message).not.toBe("");
    expect(message).not.toContain(secret);
    expect(message).not.toContain("GIZLI");
    // Still actionable: it names the variable to fix.
    expect(message).toContain("GOOGLE_CREDENTIALS_JSON");
  });

  it("leaks nothing for any of the ways a pasted key goes wrong", () => {
    // One input is not enough: V8 has several message shapes and only some
    // quote the input, so a single case can pass while the guard does nothing.
    const secret = "SUPERGIZLIANAHTAR";
    const mangled = [
      `{"client_email":"a@b.c","private_key": ${secret}}`, // quotes stripped
      `${secret}`, // only the key pasted
      `{"private_key":"${secret}", "x": None}`, // Python repr
      `{"private_key":"${secret}",,}`, // stray comma
      `{'private_key': '${secret}'}`, // single quotes
    ];
    for (const value of mangled) {
      expect(() => googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: value })).toThrow(
        CredentialError,
      );
      try {
        googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: value });
      } catch (error) {
        expect((error as Error).message).not.toContain(secret);
      }
    }
  });

  it("rejects JSON that parses but is not an object", () => {
    for (const value of ['"metin"', "42", "null", "[1,2]"]) {
      expect(() => googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: value })).toThrow(
        CredentialError,
      );
    }
  });

  it("names the missing field rather than failing later inside the library", () => {
    const { private_key: _omitted, ...withoutKey } = SERVICE_ACCOUNT;
    expect(() =>
      googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: JSON.stringify(withoutKey) }),
    ).toThrow(/private_key/);

    const { client_email: _alsoOmitted, ...withoutEmail } = SERVICE_ACCOUNT;
    expect(() =>
      googleAuthOptions({ GOOGLE_CREDENTIALS_JSON: JSON.stringify(withoutEmail) }),
    ).toThrow(/client_email/);
  });
});
