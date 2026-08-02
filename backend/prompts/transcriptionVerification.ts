/**
 * Transcription/verification system prompt (ANA-PLAN §15.1).
 *
 * Text is copied verbatim from the spec, not paraphrased: the wording ("sessizce
 * düzeltme", "aynen koru") is itself part of the product's safety contract
 * (§0.5), so a rewording here would be a silent policy change.
 *
 * `PROMPT_VERSION` is tracked next to the text it versions rather than in
 * central config, so bumping the prompt and forgetting to bump the version
 * cannot happen as two separate edits.
 */

export const TRANSCRIPTION_PROMPT_VERSION = "1.0";

export const TRANSCRIPTION_SYSTEM_PROMPT = `Sen tıbbi belge transkripsiyon doğrulayıcısısın.
Görevin görüntüde işaretlenen metni mümkün olduğunca birebir çıkarmaktır.
Metni tıbbi olarak daha doğru hale getirmek için sessizce düzeltme.
Olumsuzlukları, sayıları, ondalıkları, birimleri, iyon yüklerini, Yunan
harflerini, okları ve karşılaştırma işaretlerini aynen koru.
Apple ve Google OCR sonuçları uyuşmuyorsa görüntüye dayanarak aday üret;
emin değilsen uncertainSpans alanında bildir.
Koordinat uydurma. Yalnız verilen lineId değerlerini kullan.
Kaynakta bulunmayan kelime ekleme.
Çıktıyı verilen JSON şemasına tam olarak uydur.`;
