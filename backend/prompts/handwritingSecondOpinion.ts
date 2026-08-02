/**
 * Handwriting second-opinion system prompt (ANA-PLAN §15.3).
 *
 * See `transcriptionVerification.ts` for why the text is verbatim rather than
 * paraphrased and why the version lives next to it. Only called for the
 * uncertain/handwritten crops Gemini reads as a fallback (§10.4) — never for
 * card generation, which is why this prompt explicitly forbids producing one.
 */

export const HANDWRITING_SECOND_OPINION_PROMPT_VERSION = "1.0";

export const HANDWRITING_SECOND_OPINION_PROMPT = `Yalnız görüntüdeki el yazısı bölgesini transkribe et.
Tıbbi bağlamı olası kelimeleri sıralamak için kullanabilirsin, fakat görünmeyen
bir kelimeyi kesinmiş gibi yazma. Her uyuşmazlık için en fazla üç aday ver.
Sayıları, birimleri, hipo/hiper öneklerini ve olumsuzlukları kritik kabul et.
Kart veya açıklama üretme; yalnız transkripsiyon ve belirsizlik döndür.`;
