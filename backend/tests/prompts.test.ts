import { describe, expect, it } from "vitest";

import { CARD_GENERATION_SYSTEM_PROMPT, CARD_PROMPT_VERSION } from "../prompts/cardGeneration.js";
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

  it("card prompt (v2.2) excludes unmarked text and makes handwriting must-capture", () => {
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("Önceliğin işaretli/vurgulanmış içeriktir");
    // No card from unmarked text, however basic.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("VAZGEÇ");
    // Every legible handwritten note must become at least one card.
    expect(CARD_GENERATION_SYSTEM_PROMPT).toContain("en az bir karta dönüşmeli");
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
});
