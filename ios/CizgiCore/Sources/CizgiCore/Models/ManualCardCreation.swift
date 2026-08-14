import Foundation

/// Writing a card by hand, on the page it belongs to (2026-08-15).
///
/// The vision flow's failure mode is not a wrong card — the quality gate and the
/// editor already answer that — it is a *missing* one: the model reads the page,
/// produces its cards, and the fact the owner actually underlined is not among
/// them. Nothing in the app could add it. `docs/PLAN-model-karsilastirma.md`
/// calls this the silent coverage gap and notes no automatic signal sees it: an
/// ungenerated card carries no `lowConfidence`, so only the person who marked
/// the page knows it is missing.
///
/// So the remedy is manual and immediate: on the page detail screen, while the
/// photo and the model's reading are still in front of you.
///
/// The rules live here rather than in the sheet for the reason `CardEditing`
/// states — what counts as a saveable card is a decision, and `swift test` can
/// hold a decision still. The sheet only collects text.

/// A card being written by hand, before it is known to be valid.
///
/// `distractors` is always four entries: on a five-option card the fifth option
/// *is* the answer (§13.3's five, minus the one the user already typed as
/// Cevap). Keeping the answer out of this list is what makes the
/// back-equals-correct-option invariant unbreakable here — unlike the editor,
/// where the answer is derived from a tick that can move (Codex, PR #29).
public struct ManualCardDraft: Equatable, Sendable {

    public struct Distractor: Equatable, Sendable {
        public var text: String
        /// Why this option is wrong. Optional by the owner's decision: a hand-written
        /// card is a gap being plugged, and demanding four explanations is how a
        /// gap stays open. Leaving it empty is not a defect either — it must not
        /// set `lowConfidence`, which means "the model was unsure", not "the
        /// owner was brief".
        public var why: String

        public init(text: String = "", why: String = "") {
            self.text = text
            self.why = why
        }
    }

    /// Four, always — see the type's note.
    public static let distractorCount = MultipleChoice.optionCount - 1

    public var front: String
    public var back: String
    public var explanation: String
    public var type: CardType
    public var distractors: [Distractor]
    /// Pre-filled and locked when the page carries a subject; chosen in the sheet
    /// when it does not.
    public var subject: String?
    public var topic: String?

    public init(
        front: String = "",
        back: String = "",
        explanation: String = "",
        type: CardType = .directRecall,
        distractors: [Distractor] = Array(repeating: Distractor(), count: ManualCardDraft.distractorCount),
        subject: String? = nil,
        topic: String? = nil
    ) {
        self.front = front
        self.back = back
        self.explanation = explanation
        self.type = type
        self.distractors = distractors
        self.subject = subject
        self.topic = topic
    }

    /// Everything that must be true before this becomes a card in the deck.
    ///
    /// `schema` is the bundled subject/topic template, or `nil` when it could not
    /// be read. A nil schema is not an error: every screen in the app hides the
    /// ders/konu UI in that case rather than crashing, so a draft made without it
    /// is saved unclassified instead of being blocked on a picker that is not on
    /// screen.
    public func validate(schema: SubjectTopicSchema?) -> ManualCardValidation {
        // Front/back/explanation follow exactly the editor's rules, reused rather
        // than restated: a card with no question or no answer is not a card, and
        // an emptied explanation is `nil`, not `""`.
        let edit: CardEdit
        switch CardEditor.validate(front: front, back: back, explanation: explanation) {
        case .valid(let validated): edit = validated
        case .emptyFront: return .emptyFront
        case .emptyBack: return .emptyBack
        }

        var options: [CardOption]?
        if type == .multipleChoice {
            let built = buildOptions(answer: edit.back)
            if case .valid = MultipleChoice.validate(built) {
                options = built
            } else {
                return .options(MultipleChoice.validate(built))
            }
        }

        // The topic is picked from the template or not at all (§ders/konu
        // contract): a hand-typed topic would create a name Bilgi Haritası can
        // never map to a canonical node, and the owner asked for the subject's
        // own topic list here. Required by the owner's decision — unlike the
        // editor, this form has no "Konusuz".
        var subject: String?
        var topic: String?
        if let schema {
            guard let chosenSubject = schema.canonicalSubject(matching: self.subject) else {
                return .missingSubject
            }
            guard let chosenTopic = nonEmpty(self.topic) else { return .missingTopic }
            guard schema.isValidTopic(chosenTopic, subject: chosenSubject) else { return .invalidTopic }
            subject = chosenSubject
            topic = chosenTopic
        }

        return .valid(
            ManualCard(
                front: edit.front,
                back: edit.back,
                explanation: edit.explanation,
                // The final belt, same as every other save path: sound options
                // make it a five-option card, and nothing else can claim to be
                // one. A `.multipleChoice` draft cannot reach here with unsound
                // options — the guard above returns first — so this only ever
                // confirms the choice.
                type: MultipleChoice.resolvedType(current: type, options: options),
                options: options,
                subject: subject,
                topic: topic
            )
        )
    }

    /// The answer plus the four distractors, in that order.
    ///
    /// Presentation shuffles them per sitting (`MultipleChoice.presentationOrder`),
    /// so storing the correct one first teaches nothing.
    private func buildOptions(answer: String) -> [CardOption] {
        [CardOption(text: answer, isCorrect: true, why: nil)]
            + distractors.map {
                CardOption(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isCorrect: false,
                    why: nonEmpty($0.why)
                )
            }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// A validated hand-written card, trimmed and normalised, ready to be inserted.
public struct ManualCard: Equatable, Sendable {
    public let front: String
    public let back: String
    public let explanation: String?
    public let type: CardType
    /// `nil` on anything but a five-option card.
    public let options: [CardOption]?
    public let subject: String?
    public let topic: String?

    public init(
        front: String,
        back: String,
        explanation: String?,
        type: CardType,
        options: [CardOption]?,
        subject: String?,
        topic: String?
    ) {
        self.front = front
        self.back = back
        self.explanation = explanation
        self.type = type
        self.options = options
        self.subject = subject
        self.topic = topic
    }
}

public enum ManualCardValidation: Equatable, Sendable {
    case valid(ManualCard)
    case emptyFront
    case emptyBack
    case missingSubject
    case missingTopic
    case invalidTopic
    /// The option list's own complaint, worded by `MultipleChoiceValidation`.
    case options(MultipleChoiceValidation)

    public var card: ManualCard? {
        if case .valid(let card) = self { return card }
        return nil
    }

    /// The one place each reason is worded, so the disabled "Kaydet" and the
    /// message under the fields cannot disagree.
    public var message: String? {
        switch self {
        case .valid: return nil
        case .emptyFront: return CardEditValidation.emptyFront.message
        case .emptyBack: return CardEditValidation.emptyBack.message
        case .missingSubject: return "Ders seçilmeli."
        case .missingTopic: return "Konu seçilmeli."
        case .invalidTopic: return "Seçilen konu bu derse ait değil."
        case .options(let validation): return validation.message
        }
    }
}
