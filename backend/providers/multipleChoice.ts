/**
 * Structural quality control for five-option cards (ANA-PLAN §13.3 rule 4).
 *
 * §13.3 asks for five options with exactly one correct answer, distractors from
 * the same semantic class, and an automatic check against options that turn
 * into a second correct answer. Only part of that is decidable in code, and
 * this module is careful about the line:
 *
 *   - **Countable** — how many options there are, how many claim to be correct,
 *     whether two of them are the same string, whether the stated index agrees
 *     with the flag. Those are checked here, deterministically (§0.8).
 *   - **A judgement** — whether two *differently worded* options are both true
 *     of the stem. That is semantics, it cannot be settled by string
 *     comparison, and pretending otherwise would be the dishonest half of §0.5.
 *     The card is marked `lowConfidence` instead, and the user sees it flagged.
 *
 * A broken option set never costs the card. `front`/`back` were paid for and
 * are usually fine, so the card is **downgraded to a plain one** rather than
 * rejected — the options are dropped, the type falls back to `direct_recall`,
 * and the reason is recorded. Throwing away a sound card because its options
 * were malformed would be the expensive way to enforce a cosmetic rule.
 */

import { collapseWhitespace, foldDiacritics, nfc, turkishLower } from "./turkish.js";
import type { Card, CardOption } from "../schemas/llmOutputTypes.js";

export const OPTION_COUNT = 5;

export type MultipleChoiceAction = "downgraded" | "flagged" | "back_rewritten" | "options_stripped";

export interface MultipleChoiceNote {
  cardId: string;
  action: MultipleChoiceAction;
  /** Turkish, for the same audience as the gate's other reasons. */
  reason: string;
}

export interface MultipleChoiceReport {
  cards: Card[];
  notes: MultipleChoiceNote[];
}

/**
 * Comparison key for "are these two options the same option?".
 *
 * `turkishLower` **before** `foldDiacritics`, which is the opposite of
 * `canonicalHypoHyper` in `criticalTokens.ts` — and deliberately so. That one
 * folds first because it then calls plain `toLowerCase()`, which mangles `İ`
 * into `i` + a combining dot (PR #7). `turkishLower` has no such problem, and
 * folding first would actively break this key: `foldDiacritics` maps `İ` to a
 * plain capital `I`, which Turkish lowercasing then turns into dotless `ı` —
 * so `İskemi` and `iskemi` would stop matching, the one pair this exists for.
 */
export function optionKey(text: string): string {
  return collapseWhitespace(foldDiacritics(turkishLower(nfc(text))));
}

function isUsableOption(option: CardOption | undefined): option is CardOption {
  return (
    !!option &&
    typeof option.text === "string" &&
    option.text.trim().length > 0 &&
    typeof option.correct === "boolean"
  );
}

function downgrade(card: Card): Card {
  return { ...card, type: "direct_recall", options: null, correctOption: null };
}

/**
 * Checks one card's options and returns the card as it should be stored.
 *
 * Order matters: the checks that make the question unanswerable come first and
 * end in a downgrade; the ones that only make it suspicious come after and only
 * raise `lowConfidence`.
 */
function reviewCard(card: Card, notes: MultipleChoiceNote[]): Card {
  const hasOptions = Array.isArray(card.options) && card.options.length > 0;

  if (card.type !== "multiple_choice") {
    // A plain card carrying options is a contract violation, not a hidden
    // multiple-choice card: the type is what the model committed to, and
    // promoting it here would be this module guessing at intent.
    // `!= null` on purpose: a v2.0 card has neither field, and "absent" is not
    // a contract violation — only a *filled* one is.
    if (hasOptions || card.correctOption != null) {
      notes.push({
        cardId: card.id,
        action: "options_stripped",
        reason: "Çoktan seçmeli olmayan kartta şık alanları doluydu; temizlendi.",
      });
      return { ...card, options: null, correctOption: null };
    }
    return card;
  }

  if (!Array.isArray(card.options)) {
    notes.push({
      cardId: card.id,
      action: "downgraded",
      reason: "Beş şıklı işaretlenmiş ama şık listesi yok; düz karta indirildi.",
    });
    return downgrade(card);
  }

  const options = card.options;
  if (options.length !== OPTION_COUNT) {
    notes.push({
      cardId: card.id,
      action: "downgraded",
      reason: `Şık sayısı ${options.length}; §13.3 tam ${OPTION_COUNT} istiyor. Düz karta indirildi.`,
    });
    return downgrade(card);
  }

  if (!options.every(isUsableOption)) {
    notes.push({
      cardId: card.id,
      action: "downgraded",
      reason: "Boş ya da bozuk şık var; düz karta indirildi.",
    });
    return downgrade(card);
  }

  const correctIndexes = options
    .map((option, index) => (option.correct ? index : -1))
    .filter((index) => index >= 0);
  if (correctIndexes.length !== 1) {
    notes.push({
      cardId: card.id,
      action: "downgraded",
      reason:
        correctIndexes.length === 0
          ? "Hiçbir şık doğru işaretlenmemiş; düz karta indirildi."
          : `${correctIndexes.length} şık doğru işaretlenmiş (§13.3 tek doğru ister); düz karta indirildi.`,
    });
    return downgrade(card);
  }

  const correctIndex = correctIndexes[0]!;
  if (card.correctOption !== correctIndex) {
    // The cheapest signal that the model lost track of its own answer key —
    // and the one case where two fields disagreeing is worth more than either
    // field alone.
    notes.push({
      cardId: card.id,
      action: "downgraded",
      reason: `correctOption (${String(card.correctOption)}) doğru şıkla (${correctIndex}) uyuşmuyor; düz karta indirildi.`,
    });
    return downgrade(card);
  }

  const keys = options.map((option) => optionKey(option.text));
  if (new Set(keys).size !== keys.length) {
    notes.push({
      cardId: card.id,
      action: "downgraded",
      reason: "İki şık aynı; soru bu hâliyle cevaplanamaz. Düz karta indirildi.",
    });
    return downgrade(card);
  }

  let reviewed: Card = { ...card, options, correctOption: correctIndex };
  let flagged = false;
  const flag = (reason: string) => {
    if (!flagged) {
      reviewed = { ...reviewed, lowConfidence: true };
      flagged = true;
    }
    notes.push({ cardId: card.id, action: "flagged", reason });
  };

  // One option containing another ("hipokalemi" / "ağır hipokalemi") is
  // sometimes legitimate and sometimes a second correct answer. Not decidable
  // here, so it is surfaced rather than acted on.
  for (let i = 0; i < keys.length; i += 1) {
    for (let j = 0; j < keys.length; j += 1) {
      if (i === j) continue;
      if (keys[i]!.includes(keys[j]!)) {
        flag("Bir şık diğerini kapsıyor; iki doğrulu olabilir, gözden geçir (§13.3).");
        i = keys.length;
        break;
      }
    }
  }

  if (options.some((option) => !option.correct && !option.why.trim())) {
    flag("Bazı yanlış şıkların 'neden yanlış' açıklaması boş (§13.3).");
  }

  // §13.3 does not say it, but the deck does: everything outside the review
  // screen (search, Bilgilerim, the backup) reads `back`. If it disagrees with
  // the answer key, the card teaches one thing and tests another.
  const correctText = options[correctIndex]!.text.trim();
  if (optionKey(reviewed.back) !== optionKey(correctText)) {
    reviewed = { ...reviewed, back: correctText };
    notes.push({
      cardId: card.id,
      action: "back_rewritten",
      reason: "Kartın cevabı doğru şıkla uyuşmuyordu; doğru şıktan yeniden yazıldı.",
    });
  }

  return reviewed;
}

/** Runs the structural check over every card, before the health gate. */
export function sanitizeMultipleChoice(cards: Card[]): MultipleChoiceReport {
  const notes: MultipleChoiceNote[] = [];
  return { cards: cards.map((card) => reviewCard(card, notes)), notes };
}
