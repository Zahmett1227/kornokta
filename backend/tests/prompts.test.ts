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
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("uydurma");
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

  it("card prompt is at v2.5 (per-card topic assignment)", () => {
    expect(CARD_PROMPT_VERSION).toBe("2.5");
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
