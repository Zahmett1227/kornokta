/**
 * Coverage audit prompt (docs/PLAN-kapsama-sozlesmesi.md, Katman B).
 *
 * A second reader — deliberately a different provider family than the one that
 * generated the cards — looks at the same marked page and answers one question:
 * **which marks did the first reader leave uncarded?**
 *
 * Why a second model at all, when schema v2.3 already has the generator keep its
 * own register: a register cannot contain a mark its author never saw. Layer A
 * catches "read it and did not card it" (the reported defect); only an
 * independent pair of eyes can catch "never saw it", and sharing a vision stack
 * would mean sharing that blind spot (§10.4's original argument, the same one
 * that put Gemini on `/api/second-opinion`).
 *
 * Two prohibitions carry most of the weight:
 *   - **Do not write cards.** The schema has nowhere to put one and the prompt
 *     says so, the same discipline `handwritingSecondOpinion.ts` keeps. This
 *     endpoint reports what is missing; the person decides what to do about it.
 *   - **Do not judge whether a card is correct.** That is the second-opinion
 *     endpoint's job, on one card the model itself flagged. Mixing the two
 *     would produce a long verdict nobody asked for on every page.
 *
 * The false-positive rule is the third: a claimed mark that is not on the page
 * costs the owner a decision every time, and a tool that cries wolf on a
 * personal deck gets switched off. So "emin değilsen yazma" is stated for marks,
 * while the opposite bias applies to coverage — a mark whose card the auditor
 * cannot find is reported as uncovered, because that is the whole point and the
 * owner can dismiss it in one tap.
 */

export const COVERAGE_AUDIT_PROMPT_VERSION = "1.0";

export const COVERAGE_AUDIT_PROMPT = `Sen bağımsız bir DENETÇİ okuyucusun. Sana bir tıp ders kitabı sayfasının fotoğrafı ve o sayfadan ÜRETİLMİŞ kartların listesi veriliyor. Kartları başka bir model üretti; senin işin onları denetlemek değil, ATLANMIŞ İŞARET aramak.

Öğrenci sayfada önemli gördüğü yerleri fosforlu kalemle işaretlemiş, altını çizmiş, daire ya da kutu/çerçeve içine almış, yıldız/artı/ünlem/ok gibi semboller koymuş ve kenarlara/satır aralarına el yazısıyla not eklemiş olabilir.

GÖREVİN:
1. Sayfadaki TÜM işaretleri tara — üst, orta, ALT, sol ve sağ kenar boşlukları dahil. El yazısı notlar çoğu zaman kenarda, eğik ya da soluk olur.
2. Her işaret için, verilen kartlardan HERHANGİ BİRİNİN o işaretteki bilgiyi sorup sormadığına bak.
3. Her işareti listeye yaz: kademesi (kind), sayfadan birebir kısa alıntı (quote) ve onu KAPSAYAN kartın numarası (coveredByCardIndex) — hiçbiri kapsamıyorsa null.

kind değerleri (yalnız bu dördü):
- handwriting — öğrencinin el yazısı notu,
- symbol — yıldız/artı/ünlem/ok ve daire/kutu/çerçeve içine alınmış yerler,
- underline — altı çizili kelime/ifade,
- highlight — fosforlu/vurgulu bölge.

KURALLAR:
- KART ÜRETME. Soru, cevap, açıklama yazma. Şemada bunlara yer yok.
- Kartların DOĞRU olup olmadığını değerlendirme; bu senin işin değil. Yalnız "bu işaret bir karta dönüşmüş mü?" sorusunu cevapla.
- quote alanı sayfadan BİREBİR olmalı — uydurma. Okuyamadığın bir el yazısını okuduğun kadarıyla yaz, tamamlamaya çalışma.
- Sayfada gerçekten görmediğin bir işareti YAZMA. Emin değilsen o satırı hiç üretme: var olmayan bir işaret, kullanıcıya her seferinde boş bir iş çıkarır.
- Kapsama konusunda ise tersi geçerli: bir işareti karşılayan kart bulamıyorsan coveredByCardIndex'i null bırak. Kartın konuyu uzaktan anması kapsama değildir — işaretteki ASIL bilgi soruluyorsa kapsanmıştır.
- Bir kart birden çok işareti kapsayabilir; aynı kart numarasını birden çok satırda kullanabilirsin.
- Sayfada hiç işaret yoksa marks listesini boş bırak.`;

/** The per-request half: the cards, numbered, plus the request id. */
export function buildCoverageAuditInstruction(
  requestId: string,
  cards: ReadonlyArray<{ front: string; back: string }>,
): string {
  const lines = cards.map((card, index) => `[${index}] S: ${card.front} | C: ${card.back}`);
  return [
    `requestId: ${requestId}`,
    "Ekteki fotoğraf, kartların üretildiği işaretli sayfanın tamamıdır.",
    cards.length > 0
      ? `Bu sayfadan üretilmiş kartlar (coveredByCardIndex bu numaralardır):\n${lines.join("\n")}`
      : "Bu sayfadan HİÇ kart üretilmemiş: her işaret kapsanmamış sayılır (coveredByCardIndex null).",
  ].join("\n");
}
