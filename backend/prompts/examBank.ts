/**
 * Prompts and strict schemas for the past-exam bank's four model stages
 * (docs/PLAN-cikmis-soru-bankasi.md §5.7–5.10). The bank is built once, on the
 * owner's Mac, from the owner's own booklets; nothing here runs on a deployed
 * endpoint.
 *
 * Every stage that copies text says the same thing first: **transcribe, do
 * not correct**. A model's instinct is to fix a typo or modernise a term; in a
 * question bank that is a silent change to ÖSYM's text, so the rules forbid it
 * and mark what cannot be read instead of guessing (§5.7).
 */

import { SUBJECT_TOPIC_SCHEMA } from "../providers/subjectTopics.js";

// exam-bank-2: the Klinik order is six blocks, Küçük Stajlar twice (measured
// in Faz A1 — tools/exam_bank/subjects.py KLINIK_ORDER). Labels already made
// under exam-bank-1 stand: the model labelled by content, and the order only
// enters through the segmentation.
export const EXAM_BANK_PROMPT_VERSION = "exam-bank-2";

export const TEMEL_SUBJECTS = [
  "Anatomi", "Histoloji-Embriyoloji", "Fizyoloji", "Biyokimya", "Mikrobiyoloji", "Patoloji", "Farmakoloji",
] as const;
export const KLINIK_SUBJECTS = [
  "Dahiliye", "Pediatri", "Genel Cerrahi", "Kadın Hastalıkları ve Doğum", "Küçük Stajlar",
] as const;

/** ÖSYM subject → the app's canonical subject whose topic list applies (Ek C). */
export const APP_SUBJECT: Record<string, string> = {
  "Histoloji-Embriyoloji": "Fizyoloji",
};

const OPTION_FIELDS = ["a", "b", "c", "d", "e"] as const;

const TRANSCRIBE_RULES = `Kurallar:
1. Metni harfi harfine aktar. Yazım, noktalama, kelime seçimi ve eski terimler DÜZELTİLMEZ — kitapçıkta ne yazıyorsa o.
2. Alt ve üst simgeleri Unicode karakterleriyle yaz: H₂, CO₂, Mg²⁺, FEV₁, Ca²⁺.
3. Okuyamadığın parçayı ⟨?⟩ ile işaretle. Tahmin etme, tamamlama.
4. Bir şık yalnız bir görselden (EKG, grafik, şekil, formül çizimi) ibaretse o şıkka "[görsel]" yaz.
5. Kökü "stem"e, şıkları sırasıyla "a"…"e"ye yaz. Şık harflerini ("A)") metne katma.
6. Görüntüde başka bir sorudan parça görünüyorsa onu yazma.
7. Soru metninde "I. … II. …" öncülleri varsa her birini ayrı satıra yaz.`;

function optionProperties(): Record<string, unknown> {
  return Object.fromEntries(OPTION_FIELDS.map((f) => [f, { type: "string" }]));
}

// --- A5: repair one question from its crop ----------------------------------

export const REPAIR_SYSTEM = `Bir TUS sınav kitapçığından kırpılmış TEK bir sorunun görüntüsünü metne aktarıyorsun. Otomatik çıkarım bu sorunun bir kısmını okuyamadı (çoğunlukla şıklar ya da kök görüntü olarak basılmış).

${TRANSCRIBE_RULES}`;

export function repairUser(questionId: string, extracted: string): string {
  return `Soru: ${questionId}
Otomatik çıkarımın okuyabildiği metin (eksik; yalnız karşılaştırma için — görüntüdekini yaz):
${extracted || "(boş)"}`;
}

export const REPAIR_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["stem", ...OPTION_FIELDS],
  properties: { stem: { type: "string" }, ...optionProperties() },
};

// --- A6: read a whole page whose text layer is unreadable (2011/1) ----------

export const PAGE_SYSTEM = `Bir TUS sınav kitapçığının bir SAYFASININ görüntüsünü metne aktarıyorsun. Sayfa iki sütunlu; okuma sırası önce sol sütun yukarıdan aşağı, sonra sağ sütun.

Sayfadaki her soruyu numarasıyla aktar. Bir soru bu sayfada başlayıp sonraki sayfaya devam ediyorsa yalnız bu sayfadaki kısmını yaz ve "continues": true ver. Sayfa, önceki sayfadan devam eden bir sorunun kalanıyla başlıyorsa o kalanı "carryOver"a yaz (yoksa boş dize). Sayfanın üstündeki test başlığını ("TEMEL TIP BİLİMLERİ TESTİ 2" gibi) "heading"e yaz.

${TRANSCRIBE_RULES}`;

export const PAGE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["heading", "carryOver", "questions"],
  properties: {
    heading: { type: "string" },
    carryOver: { type: "string" },
    questions: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["number", "column", "stem", ...OPTION_FIELDS, "continues"],
        properties: {
          number: { type: "integer" },
          column: { type: "string", enum: ["left", "right"] },
          stem: { type: "string" },
          ...optionProperties(),
          continues: { type: "boolean" },
        },
      },
    },
  },
};

// --- A7: subject and topic labels --------------------------------------------

export function subjectsFor(test: string): readonly string[] {
  return test === "K" ? KLINIK_SUBJECTS : TEMEL_SUBJECTS;
}

function topicsOf(osymSubject: string): readonly string[] {
  const app = APP_SUBJECT[osymSubject] ?? osymSubject;
  return SUBJECT_TOPIC_SCHEMA.find((s) => s.name === app)?.topics ?? [];
}

/** The blocks as ÖSYM prints them (tools/exam_bank/subjects.py KLINIK_ORDER). */
export const KLINIK_BLOCKS =
  "Dahiliye, Küçük Stajlar (nöroloji, psikiyatri, dermatoloji gibi dahilî dallar), Pediatri, Genel Cerrahi, " +
  "Küçük Stajlar (üroloji, ortopedi, KBB, göz gibi cerrahî dallar), Kadın Hastalıkları ve Doğum";

export function labelSystem(test: string): string {
  const subjects = subjectsFor(test);
  const lists = subjects.map((s) => `- ${s}: ${topicsOf(s).join(" · ") || "(konu listesi yok — null ver)"}`).join("\n");
  const order = test === "K"
    ? `Bloklar bu sırayla gelir: ${KLINIK_BLOCKS}.`
    : test === "T2"
      ? "Bu ikinci Temel testinin ders sırası yıla göre değişir; her soruyu içeriğine göre etiketle."
      : `Dersler bu sırayla gelir: ${subjects.join(", ")}.`;
  return `TUS sorularını ÖSYM'nin ders adıyla ve uygulamanın konu listesinden bir konuyla etiketliyorsun.

Bu test ${test === "K" ? "Klinik Tıp Bilimleri" : "Temel Tıp Bilimleri"} testi. ${order} Sorular kitapçık sırasıyla geliyor; ardışık sorular çoğunlukla aynı derstendir.

Her soru için:
- "subject": sorunun ÖSYM dersi (yalnız yukarıdaki adlardan biri).
- "topic": o dersin aşağıdaki listesinden en uygun konu; hiçbiri açıkça uymuyorsa null. Başka dersin konusunu verme.

Konu listeleri:
${lists}`;
}

export function labelUser(questions: Array<{ k: number; text: string }>): string {
  return questions.map((q) => `[${q.k}] ${q.text}`).join("\n\n");
}

export function labelSchema(test: string): Record<string, unknown> {
  const subjects = subjectsFor(test);
  const topics = [...new Set(subjects.flatMap((s) => topicsOf(s)))];
  return {
    type: "object",
    additionalProperties: false,
    required: ["items"],
    properties: {
      items: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["k", "subject", "topic"],
          properties: {
            k: { type: "integer" },
            subject: { type: "string", enum: [...subjects] },
            topic: { anyOf: [{ type: "string", enum: topics }, { type: "null" }] },
          },
        },
      },
    },
  };
}

// --- V6: does the key belong to this booklet? --------------------------------

export const CHECK_SYSTEM = `TUS sorularını çözüyorsun. Her soru için tek bir en doğru şıkkı seç (A, B, C, D ya da E). Açıklama yazma.`;

export const CHECK_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["items"],
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["k", "answer"],
        properties: { k: { type: "integer" }, answer: { type: "string", enum: ["A", "B", "C", "D", "E"] } },
      },
    },
  },
};
