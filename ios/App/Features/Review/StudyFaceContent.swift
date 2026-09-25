import SwiftUI
import CizgiCore

/// What `ReviewCardFace` draws — the words of a study item, not the model
/// object they came from.
///
/// ### Why this exists
///
/// The face used to take a `Card` and read six things off it: its type, its
/// subject and topic, the question, the answer, the explanation and the two
/// chips. A past exam question (docs/PLAN-cikmis-soru-bankasi.md §7.4) needs
/// the very same page — the rubric down the margin, the serif question, the
/// options slot, the source disclosure — but it is not a `Card` and must never
/// become one (docs/ADR-012). Building a throwaway `Card` for it would be
/// wrong twice over: an uninserted SwiftData model is fragile, and the face
/// would read subject and topic through a `knowledgeUnit` the question does
/// not have.
///
/// So the face draws a value, and each kind of study item says how it fills
/// one. `init(card:isAnswerVisible:showsFesMark:)` below is the card's way;
/// the face's own `init(card:...)` calls it, so Tekrar and Egzersiz did not
/// change a line.
struct StudyFaceContent {
    /// A note *about* the item, shown as a chip under its text.
    struct Mark: Hashable {
        let title: String
        let systemImage: String
    }

    /// Drawn by `CardTypeMark`, and spoken as the start of the eyebrow.
    let type: CardType
    /// The line above the question — subject and topic for a card. Never
    /// empty: a blank line would read as a layout slip, not as missing data.
    let eyebrow: String
    /// Colours the margin rule. `nil` falls back to the accent.
    let subject: CizgiSubject?
    let question: String
    /// `nil` hides the answer line. A five-option card marks its answer in
    /// the option list instead, and repeating it as text would push the
    /// reasons off screen.
    let answer: String?
    let explanation: String?
    let marks: [Mark]
    /// The serif's size. A card's question is a line or two and gets the
    /// face's full 27; a TUS vignette runs to eighty words, and at 27 it
    /// pushed all five options off the first screen (simulator, 2026-09-25).
    var questionSize: CGFloat = 27
}

extension StudyFaceContent {
    /// How a card fills the face. Every rule here moved verbatim from
    /// `ReviewCardFace`, where it lived when the face took a `Card`.
    init(card: Card, isAnswerVisible: Bool, showsFesMark: Bool) {
        let parts = [card.knowledgeUnit?.subject, card.knowledgeUnit?.topic]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        var marks: [Mark] = []
        // Flagged, not blocked (§13.3 rule 6): the card is reviewed like any
        // other, but the user is told it was never fully vouched for before
        // they trust the answer. The old `DogEar` that said this a second time
        // is gone with the box it was folded into — the chip carries both an
        // icon and the words, so the meaning never rested on colour anyway.
        if card.lowConfidence {
            marks.append(Mark(title: "Gözden geçir", systemImage: "exclamationmark.triangle.fill"))
        }
        // Egzersiz marks a FES card once the answer is out; Tekrar does not.
        // Never before the reveal — seeing "this one is hard" before trying to
        // recall it contaminates the very measurement FES is built from.
        if showsFesMark, isAnswerVisible, FesScore.isFes(score: card.fesScore) {
            marks.append(Mark(title: "FES", systemImage: "flame.fill"))
        }

        self.init(
            type: card.type,
            // Where the card sits, in the order a reader wants it: subject,
            // then topic. The question's *type* is not repeated here —
            // `CardTypeMark` draws its shape. If the card has neither subject
            // nor topic the type name stands in, so the line is never empty.
            eyebrow: parts.isEmpty ? card.type.displayName : parts.joined(separator: " · "),
            subject: CizgiSubject.matching(card.knowledgeUnit?.subject),
            question: card.front,
            answer: card.options == nil ? card.back : nil,
            explanation: card.explanation,
            marks: marks
        )
    }
}
