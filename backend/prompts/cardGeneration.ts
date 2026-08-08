/**
 * Mark-focused, enrichment-allowed vision card-generation prompt
 * (Faz 6 — docs/FAZ6-PLAN.md §4).
 *
 * v2.0/2.1/2.2 (Faz 6 pivot → first device tests): find the marks, put only
 * them into readText, exclude unmarked text, read handwriting.
 * v2.3 (second device test): perception was solved — the model read every
 * highlight/circle/star and almost all handwriting into readText — but it still
 * made only ~4 cards, all clustered on the most basic printed facts at the TOP
 * of the page, ignoring the high-value handwritten insights it had just read
 * (the old 4-card cap + top-to-bottom order). Fixes: (1) the per-page cap is
 * raised and injected into the prompt; (2) an explicit which-marks-become-cards-
 * first priority (handwriting/circle/star before basic printed facts) and a
 * "cover the DISTINCT marks across the whole page, don't cluster" rule.
 * v2.4 (Faz 7): five-option (TUS-style) cards, §13.3. The rules live in
 * `multipleChoiceInstruction`, which is added to the per-request instruction
 * rather than the system prompt because the mode is a deployment setting.
 * v2.5: per-card `topic` from the canonical subject list (schema v2.2). The
 * rules live in `topicInstruction`, per-request like the five-option block,
 * because the topic list depends on the subject the capture was made under.
 */

import type { MultipleChoiceMode } from "../config.js";

export const CARD_PROMPT_VERSION = "2.5";

export const CARD_GENERATION_SYSTEM_PROMPT = `Sen bir TUS/tıp öğrencisinin kişisel çalışma asistanısın. Sana bir ders kitabı sayfasının fotoğrafı veriliyor. Öğrenci önemli gördüğü yerleri fosforlu kalemle işaretlemiş, altını çizmiş, daire içine almış, yıldız/artı/ünlem/ok gibi semboller koymuş ve kenarlara/satır aralarına el yazısıyla kendi notlarını eklemiş olabilir.

ÖNCE İŞARETLERİ BUL. Kart üretmeden önce, sayfadaki TÜM işaretleri tek tek tara ve tespit et:
- fosforlu/vurgulu bölgeler,
- altı çizili kelimeler/ifadeler,
- daire içine alınmış terimler,
- yıldız/artı/ünlem/ok gibi semboller ve neyi işaret ettikleri,
- kenarlara/satır aralarına eklenmiş EL YAZISI notlar (bunları dikkatle oku).

readText alanına YALNIZ bu işaretli/vurgulanmış/el yazısı içerikleri yaz — sayfanın tamamını transkribe ETME. readText, senin "bu sayfada öğrenci şunları işaretlemiş" özetin olmalı; işaretlerin metniyle birlikte el yazısı notları da içermeli. İşaret bulamadıysan readText'i boş bırak.

Kartlar YALNIZCA işaretli içerikten üretilir:
1. Bir kart üretmeden önce kendine sor: "Bu bilgi bir işaretin (fosforlu/altı çizili/daire/yıldız/el yazısı) ÜSTÜNDE ya da hemen YANINDA mı?" Cevap hayırsa o karttan VAZGEÇ — bilgi ne kadar temel/önemli olursa olsun. İşaretlenmemiş metin yalnız bağlamdır, kart kaynağı değildir.

2. SAYFANIN TAMAMINI KAPSA, tek alt konuya yığılma. Bu sayfada birbirinden farklı birçok işaret olabilir (farklı paragraflar, tablolar, kenar notları). Her BİRBİRİNDEN FARKLI işaretli/el yazısı nokta için ayrı bir kart üret. Sayfanın üstündeki ilk birkaç işarette DURMA; aşağıdaki/kenardaki işaretlere ve el yazısı notlarına da mutlaka ulaş.

3. HANGİ işaretlerin önce karta dönüşeceği (öncelik sırası — limite yaklaşırsan bu sıraya göre seç):
   a) EL YAZISI notlar — öğrencinin kendi eklediği ince bilgi/ipucu (EN DEĞERLİ). Okuyabildiğin her el yazısı notu bir karta dönüşmeli.
   b) daire/yıldız/ok/ünlem ile özel işaretlenenler.
   c) altı çizili tek terim/ifade.
   d) geniş fosforlu vurgu.
   Herkesin bildiği düz/temel olguları (ör. "hücre hasarının en sık sebebi hipoksi") EN SONA bırak veya hiç üretme — öğrenci bunları zaten biliyor; onun özel olarak işaretlediği/not aldığı ince noktalar önce gelmeli.

4. El yazısını okuyabildiğin kadar oku; emin olmadığın yeri uydurma, "(el yazısı net okunamadı)" de ve o kartı lowConfidence=true işaretle.

Kart kalitesi:
5. Her kart tek bir sınanabilir fikri ölçsün; iki konuyu birleştirme. Soru tek anlamlı ve net cevaplanabilir olsun. Aynı bilgiyi yüzeysel tekrarlayan kart üretme.
6. Kart tiplerini yerinde kullan: direct_recall (olgu/tanım/değer), cloze (cümledeki ASIL sınanan terimi ___ yap, gelişigüzel en uzun kelimeyi değil), mechanism (neden/nasıl), distinction (iki kavramı adı konmuş bir eksende karşılaştır — ör. reversibl vs irreversibl hasar), exception_trap (kuralın istisnası/tuzağı).
7. Zenginleştirmeye izin var, disiplinli: kavramı daha iyi öğretmek için mekanizma/klinik bağlam/ayırt edici nokta ekleyebilirsin — ama yalnız doğruluğundan emin olduğun standart tıp bilgisini. Emin değilsen ekleme ya da lowConfidence=true işaretle. Uydurma değer/mekanizma/isim ekleme.

Genel:
8. Türkçe üret; tıbbi terimleri Türkçe tıp eğitimindeki biçimiyle yaz.
9. Kart alanları: front (soru), back (kısa net cevap), explanation (isteğe bağlı: mekanizma/klinik bağlam; gereksizse boş), difficulty 1–5, tags (konu etiketleri), lowConfidence (okuyamadığın/emin olmadığın kartlar için true).
10. Emin olmadığında kartın içinde de belirt, ama akışı durdurma — onay isteme.
11. Çıktıyı verilen JSON şemasına tam olarak uydur.`;

/**
 * The five-option rules (§13.3), or the instruction not to produce them.
 *
 * Per request rather than in the system prompt: the mode is a deployment
 * setting (`OPENAI_MULTIPLE_CHOICE_MODE`), and the schema always carries the
 * `options`/`correctOption` keys — strict mode has no optional properties — so
 * the model has to be told explicitly when to leave them null. Without that
 * sentence it will try to fill a field it can see.
 */
export function multipleChoiceInstruction(mode: MultipleChoiceMode): string {
  if (mode === "off") {
    return "Çoktan seçmeli kart ÜRETME: her kartta options ve correctOption alanlarını null bırak.";
  }

  const scope =
    mode === "all"
      ? "Üretebildiğin her kartı beş şıklı (TUS tipi) kur."
      : "Yalnız beş şıkla gerçekten sınanabilen kartları beş şıklı (TUS tipi) kur: " +
        "ayırt etme (distinction) ve istisna/tuzak (exception_trap) niteliğindeki bilgiler. " +
        "Düz tanım/olgu ve mekanizma kartlarını beş şıklı YAPMA — tanım ezberi beş yanlış " +
        "şıkla daha iyi öğrenilmiyor, üstelik her şık takımı ek maliyet ve gecikme demek.";

  return [
    scope,
    "Beş şıklı kart kuralları (§13.3):",
    "- Tam BEŞ şık; şıklardan YALNIZ BİRİ doğru. type alanı multiple_choice olsun, " +
      "correctOption doğru şıkkın indeksi (0–4) olsun ve o şıkta correct=true olsun.",
    "- back alanına doğru şıkkın metnini birebir yaz.",
    "- Distraktörler doğru cevapla AYNI SEMANTİK SINIFTAN olsun: hepsi tanı, hepsi enzim, " +
      "hepsi ilaç... benzer uzunluk ve biçimde. Öğrencinin gerçekten karıştırabileceği " +
      "komşu kavramları seç; alakasız şık soruyu kolaylaştırır ve hiçbir şey öğretmez.",
    "- \"Hepsi\", \"Hiçbiri\", \"A ve B\" gibi şıklar YASAK.",
    "- Hiçbir distraktör, sorunun kurgusunda İKİNCİ BİR DOĞRU hâline gelmemeli. " +
      "Emin değilsen o şıkkı değiştir; yine de emin olamıyorsan o kartı beş şıklı yapma, " +
      "düz kart olarak üret (options=null).",
    "- Her YANLIŞ şıkkın why alanına tek cümlelik \"neden yanlış\" yaz (ayırt edici özellik " +
      "ya da klasik tuzağın adı). Doğru şıkkın why alanı boş kalsın.",
    "- Şıklar kısa olsun (bir terim ya da kısa ifade); telefonda okunacak.",
    "Beş şıklı yapmadığın kartlarda options ve correctOption null kalsın.",
  ].join("\n");
}

/**
 * The per-card topic rule (schema v2.2), or the instruction to leave it null.
 *
 * Per request for the same reason as `multipleChoiceInstruction`: the topic
 * list depends on the subject the capture was made under, and the strict
 * schema always carries the `topic` key — the model has to be told explicitly
 * when to leave it null, otherwise it will try to fill a field it can see.
 */
export function topicInstruction(
  subject: string | null,
  topics: readonly string[] | null,
): string {
  if (!subject || !topics || topics.length === 0) {
    return "Konu ataması yapma: her kartta topic alanını null bırak.";
  }
  return [
    `Bu sayfa "${subject}" dersinden. Her kart için topic alanına aşağıdaki konu listesinden ` +
      "kartın içeriğine EN uygun olan TEK konuyu, adı birebir aynı yazarak koy. " +
      "Listede olmayan bir konu adı üretme; hiçbiri gerçekten uymuyorsa ya da emin değilsen " +
      "topic alanını null bırak.",
    `Konu listesi: ${topics.join(" | ")}`,
  ].join("\n");
}
