/**
 * Generates a device token (ANA-PLAN §7.3).
 *
 *     npm run token
 *
 * Printed, never written: the same value has to end up in two places that are
 * not this repo — the server's secret store and the phone's Keychain — and
 * writing it to a file here would only create a third copy to leak.
 */

import { randomBytes } from "node:crypto";

// 32 bytes of CSPRNG output. `randomBytes`, not Math.random: the latter is
// predictable and would make the token guessable from a few samples.
const token = randomBytes(32).toString("base64url");

console.log(token);
console.error(
  [
    "",
    "Bu değeri iki yere koy, üçüncü bir kopyasını bırakma:",
    "  1. backend/.env  ->  DEVICE_TOKEN=<yukarıdaki>",
    "  2. iPhone tarafında Keychain'e (uygulama ayarları)",
    "",
    "Depoya ekleme, sohbete yapıştırma. Kaybedersen yenisini üret ve",
    "iki yeri birden güncelle.",
  ].join("\n"),
);
