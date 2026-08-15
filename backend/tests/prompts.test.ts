import { describe, expect, it } from "vitest";

import { CARD_GENERATION_SYSTEM_PROMPT, CARD_PROMPT_VERSION, topicInstruction } from "../prompts/cardGeneration.js";
import {
  HANDWRITING_SECOND_OPINION_PROMPT,
  HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
} from "../prompts/handwritingSecondOpinion.js";
import {
  TRANSCRIPTION_PROMPT_VERSION,
  TRANSCRIPTION_SYSTEM_PROMPT,
} from "../prompts/transcriptionVerification.js";

/**
 * §15 requires "sessizce düzeltme yapma" and "kaynakta bulunmayan kelime
 * ekleme" to actually be *in* the prompt text sent to the model — a prompt
 * that quietly dropped this instruction would still compile and still call
 * the API, so nothing but a test would notice.
 */
describe("prompt contracts (§15)", () => {
  it("each prompt is versioned (§15 'Prompt metinleri versiyonlanmalıdır')", () => {
    for (const version of [
      TRANSCRIPTION_PROMPT_VERSION,
      CARD_PROMPT_VERSION,
      HANDWRITING_SECOND_OPINION_PROMPT_VERSION,
    ]) {
      expect(version).toMatch(/^\d+\.\d+$/);
    }
  });

  it("transcription prompt forbids silent correction and invented words (§0.5, §15.1)", () => {
    expect(TRANSCRIPTION_SYSTEM_PROMPT).toContain("sessizce düzeltme");
    expect(TRANSCRIPTION_SYSTEM_PROMPT).toContain("Kaynakta bulunmayan kelime ekleme");
    expect(TRANSCRIPTION_SYSTEM_PROMPT).toContain("uncertainSpans");
  });

  it("card prompt (v2.2) finds marks first and confines readText to them (Faz 6 §4)", () => {
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("ÖNCE İŞARETLERİ BUL");
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("sayfanın tamamını transkribe ETME");
  });

  it("card prompt (v2.3) excludes unmarked text and makes handwriting must-capture", () => {
    // No card from unmarked text, however basic.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("VAZGEÇ");
    // Every legible handwritten note must become at least one card.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("bir karta dönüşmeli");
  });

  it("card prompt (v2.3) covers the whole page and prioritises handwriting over basic facts", () => {
    // Don't cluster on the top-of-page basics; reach the marks lower down.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("SAYFANIN TAMAMINI KAPSA");
    // Basic well-known facts go last / may be skipped.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("EN SONA bırak");
  });

  it("card prompt (v2) allows enrichment but forbids fabrication when unsure (Faz 6 §4)", () => {
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("Zenginleştirmeye izin var");
    // Case-insensitive: the prompt capitalises for emphasis and which words
    // carry caps shifts between versions. Pinning the exact casing made a
    // v2.6 emphasis edit look like the anti-fabrication rule had been deleted.
    expect(CARD_GENERATION_SYSTEM_PROMPT.toLocaleLowerCase("tr")).toContain("uydurma");
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("lowConfidence");
  });

  it("card prompt (v2) no longer asks for approval or source-fidelity accounting (Faz 6 pivot)", () => {
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("onay isteme");
    expect(CARD_GENERATION_SYSTEM_PROMPT).not.toContain("source_insufficient");
    expect(CARD_GENERATION_SYSTEM_PROMPT).not.toContain("sourceConcern");
  });

  it("handwriting prompt asks for transcription only, never a card (§10.4, §15.3)", () => {
    expect(HANDWRITING_SECOND_OPINION_PROMPT).toContain("Kart veya açıklama üretme");
    expect(HANDWRITING_SECOND_OPINION_PROMPT).toContain("en fazla üç aday");
  });

  it("handwriting prompt v2 casts an independent reader with a three-way verdict (2026-08-11)", () => {
    expect(HANDWRITING_SECOND_OPINION_PROMPT_VERSION).toBe("2.0");
    expect(HANDWRITING_SECOND_OPINION_PROMPT).toContain("bağımsız");
    for (const verdict of ["supports", "contradicts", "unclear"]) {
      expect(HANDWRITING_SECOND_OPINION_PROMPT).toContain(`"${verdict}"`);
    }
    // The v1 criticality rule survives the pivot: these are the exact
    // misreadings a medical card cannot afford.
    expect(HANDWRITING_SECOND_OPINION_PROMPT).toContain("hipo/hiper");
  });

  it("card prompt is at v2.7 (self-contained cards, one idea, full-page scan, marks bind)", () => {
    expect(CARD_PROMPT_VERSION).toBe("2.7");
  });

  it("card prompt (v2.6) forbids referring to the page inside the card", () => {
    // The defect this rule exists for: a card whose question quotes the
    // book's own layout ("sayfadaki kutuya göre…") is unanswerable months
    // later with the book shut — 10 such cards in the Tur A comparison.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("KART TEK BAŞINA ANLAŞILMALI");
    for (const banned of ["sayfadaki", "işaretlenen", "daire içine alınmış"]) {
      expect(CARD_GENERATION_SYSTEM_PROMPT).toContain(`"${banned}"`);
    }
    // front/back stay clean even in the one case explanation may mention it.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("TEK İSTİSNA");
  });

  it("card prompt (v2.6) makes the one-idea rule splittable and checkable", () => {
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("o kartı BÖL");
    // The rule needs a test the model can apply, not just a prohibition.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("dürüst bir not verebilmeli");
  });

  it("card prompt (v2.6) ranks a star above highlighter and resolves what it points at", () => {
    // A highlighter stroke is fast and broad; a star is a separate deliberate
    // act. The priority order already placed them, but as a bare list item —
    // and the thing that actually separated the tiers in Tur A was resolving
    // an arrow to its *target* (the margin note whose arrow pointed at the
    // necroptosis block), which no rule had asked for.
    const prompt = CARD_GENERATION_SYSTEM_PROMPT;
    expect(prompt).toContain("İŞARET EDER");

    // Ordering is the contract: handwriting, then stars, then underline, then
    // highlighter. Positions, not prose, so a reworded list still fails here.
    //
    // Sliced to rule 3's own block first, and that is the whole point rather
    // than tidiness: "EL YAZISI notlar" also appears up in the scanning
    // section, hundreds of characters earlier, so searching the whole prompt
    // compared the *scanning bullet* to the star item. That comparison is
    // true no matter what rule 3 says — item (a) could be demoted below the
    // star, or deleted outright, and this test would still have passed while
    // claiming to guard the order.
    const rule3 = prompt.slice(prompt.indexOf("3. HANGİ işaretlerin"), prompt.indexOf("4. El yazısını"));
    expect(rule3).not.toBe("");

    // The star tier is matched by its name rather than its member list: the
    // list moved once already (v2.7 round two added kutu/çerçeve) and a marker
    // that enumerates members turns every such addition into a test failure
    // that says "order broke" when the order did not.
    const positions = ["EL YAZISI notlar", "SEMBOL İŞARETLERİ", "altı çizili tek terim", "geniş fosforlu vurgu"]
      .map((item) => rule3.indexOf(item));
    // -1 would sort as "first" and quietly satisfy the ordering below, so a
    // deleted item has to fail here rather than pass as a bad comparison.
    expect(positions).not.toContain(-1);
    expect(positions).toEqual([...positions].sort((left, right) => left - right));
  });

  it("card prompt (v2.6) demands a whole-page scan and a coverage check", () => {
    // The cheap tier's failure was silent: marks that never became cards
    // carry no lowConfidence flag, so nothing downstream can notice them.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("kenar boşlukları");
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("Bitirmeden önce KONTROL ET");
  });

  it("card prompt (v2.7) names read-but-not-carded and shows the pair that produces it", () => {
    // The reported defect: the starred passage is in readText — perceived —
    // and the cards come from unmarked text anyway. v2.6's measurement is the
    // reason this is written as a named failure plus a wrong/right pair rather
    // than a stronger preference: that is the form that moved rule 8 from
    // 82/360 to 0/239, while rule 5's bare prohibition moved nothing.
    const prompt = CARD_GENERATION_SYSTEM_PROMPT;
    const rule3 = prompt.slice(prompt.indexOf("3. HANGİ işaretlerin"), prompt.indexOf("4. El yazısını"));
    expect(rule3).toContain("okudum ama karta çevirmedim");
    // The pair lives inside rule 3 — not merely somewhere in the prompt, which
    // is also true of rule 8's own YANLIŞ/DOĞRU pair hundreds of characters
    // away (the mistake this file already made once, see the ordering test).
    expect(rule3).toContain("YANLIŞ:");
    expect(rule3).toContain("DOĞRU:");
    // The operative sentence: an uncarded star outranks anything weaker.
    expect(rule3).toContain("kart ÜRETME");

    // "Weaker" has to name EVERY lower tier, not just the highlighter. Its
    // first draft said "(yalnız fosforlu)", which on a page holding both a
    // star and an underline left the underline free to take the slot while
    // the star stayed uncarded — the reported failure exactly, one tier up
    // (Codex, PR #45). The parenthetical reads as the definition of the class,
    // so an omission there is not a wording detail.
    const binding = rule3.slice(rule3.indexOf("KURAL:"));
    expect(binding).not.toBe("");
    expect(binding).toContain("altı çizili");
    expect(binding).toContain("fosforlu");
  });

  it("card prompt (v2.7) enforces the star tier by name, and the tier holds every symbol", () => {
    // Round two of the same defect (Codex, PR #45): item (b) covered
    // star/plus/exclamation/arrow/circle, but the check and the binding
    // sentence each re-listed the tier as "yıldız/daire" — so an arrow-marked
    // passage was inside the priority list and outside its enforcement.
    // Naming the tier once and referring to it by name is what makes adding a
    // mark type one edit instead of three, so the name is the contract here.
    const prompt = CARD_GENERATION_SYSTEM_PROMPT;
    const rule3 = prompt.slice(prompt.indexOf("3. HANGİ işaretlerin"), prompt.indexOf("4. El yazısını"));
    const check = prompt.slice(prompt.indexOf("Bitirmeden önce KONTROL ET"), prompt.indexOf("3. HANGİ işaretlerin"));

    // Both enforcement sites reference the tier by name, not by re-listing it.
    expect(check).toContain("SEMBOL İŞARETLERİ");
    expect(rule3.slice(rule3.indexOf("KURAL:"))).toContain("SEMBOL İŞARET");

    // And the tier itself names every mark the owner actually uses. `kutu` is
    // here because it was in none of the three places — not the priority list,
    // not the binding rule, not even the scan list — while being one of the
    // marks the defect was reported about.
    const tier = rule3.slice(rule3.indexOf("SEMBOL İŞARETLERİ"), rule3.indexOf("c) altı çizili"));
    for (const mark of ["yıldız", "artı", "ünlem", "ok", "daire", "kutu"]) {
      expect(tier).toContain(mark);
    }
    // A mark that is prioritised but never scanned for cannot be found at all.
    const scan = prompt.slice(prompt.indexOf("ÖNCE İŞARETLERİ BUL"), prompt.indexOf("readText alanına"));
    expect(scan).toContain("kutu");
  });

  it("card prompt (v2.7) keeps the member list out of every enforcement site", () => {
    // Third round of the same defect (Codex, PR #45). Rule 1 is a *gate*, not a
    // ranking — "cevap hayırsa o karttan VAZGEÇ" — and it had kept its own
    // partial member list through the rename, so a passage marked only with a
    // plus or an exclamation could be dropped there before the priority rule
    // ever saw it. Three rounds on one defect is the signal: the invariant, not
    // the wording, is what needs pinning.
    //
    // Members live in exactly two places — the scan list (what to look for) and
    // 3(b) (how it ranks). Enforcement sites name the tier and list nothing, so
    // adding a mark type cannot silently narrow a gate.
    const prompt = CARD_GENERATION_SYSTEM_PROMPT;
    const rule1 = prompt.slice(prompt.indexOf("1. Bir kart üretmeden önce"), prompt.indexOf("2. SAYFANIN TAMAMINI"));
    const check = prompt.slice(prompt.indexOf("Bitirmeden önce KONTROL ET"), prompt.indexOf("3. HANGİ işaretlerin"));
    const rule3 = prompt.slice(prompt.indexOf("3. HANGİ işaretlerin"), prompt.indexOf("4. El yazısını"));
    const binding = rule3.slice(rule3.indexOf("KURAL:"), rule3.indexOf("c) altı çizili"));

    for (const [name, site] of [["rule 1 gate", rule1], ["final check", check], ["binding rule", binding]] as const) {
      expect(site, `${name} slice not found`).not.toBe("");
      expect(site, `${name} refers to the tier by name`).toContain("SEMBOL İŞARET");
      for (const member of ["yıldız", "artı", "ünlem", "daire", "kutu", "çerçeve"]) {
        // Not `toContain`: Turkish morphology makes plain substring matching
        // lie — "kartı" contains "artı", and the check sentence says "o kartı
        // üret". Require a non-letter (or the start) before the member so a
        // suffix inside another word is not read as an enumeration.
        const standalone = new RegExp(`(^|[^\\p{L}])${member}`, "iu");
        expect(standalone.test(site), `${name} re-enumerates "${member}"`).toBe(false);
      }
    }
  });

  it("card prompt (v2.7) runs the final check in priority order and forbids unjustified drops", () => {
    // Ordering the *check* is the point. A page-order check passes as soon as
    // every region produced something, which is exactly what happened on the
    // reported page: cards existed, they were just built from the wrong marks.
    const prompt = CARD_GENERATION_SYSTEM_PROMPT;
    const check = prompt.slice(prompt.indexOf("Bitirmeden önce KONTROL ET"), prompt.indexOf("3. HANGİ işaretlerin"));
    expect(check).not.toBe("");
    expect(check).toContain("ÖNCELİK SIRASINA");
    // Dropping a mark is legitimate only against a named better one; the
    // difference between a choice and a skip is the justification.
    expect(check).toContain("ATLAMA");
  });

  it("topic instruction names the subject, lists topics verbatim, and allows null (v2.5)", () => {
    const text = topicInstruction("Patoloji", ["İnflamasyon", "Neoplazi"]);
    expect(text).toContain('"Patoloji" dersinden');
    expect(text).toContain("İnflamasyon | Neoplazi");
    expect(text).toContain("null");
    expect(text).toContain("Listede olmayan bir konu adı üretme");
  });

  it("topic instruction says leave-it-null when there is no subject or no list", () => {
    // The strict schema always carries the `topic` key, so the model must be
    // told explicitly — same reason multipleChoiceInstruction has an "off"
    // sentence.
    for (const text of [topicInstruction(null, null), topicInstruction("Patoloji", []), topicInstruction(null, ["X"])]) {
      expect(text).toContain("topic alanını null bırak");
    }
  });
});
