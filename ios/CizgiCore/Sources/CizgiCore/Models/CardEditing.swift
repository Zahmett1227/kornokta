import Foundation

/// Editing a card, and finding what it came from (ANA-PLAN §5.5, §6.5, §6.6).
///
/// Both were promises the app never kept. Faz 6 removed the approval step on the
/// grounds that a wrong card could be fixed in Bilgilerim afterwards
/// (docs/FAZ6-PLAN.md §9) — but the fixing half was never built, so the only
/// remedy for a misread was deleting the card. And "Kaynağı göster" was gated on
/// a per-card quote the vision flow never produces, so it never appeared at all.
///
/// The rules live here rather than in the views because both are decisions —
/// what counts as a saveable edit, what counts as real source material — and
/// `swift test` can hold a decision still in a way a SwiftUI preview cannot.

/// A validated edit, trimmed and normalised, ready to be written to a card.
public struct CardEdit: Equatable, Sendable {
    public let front: String
    public let back: String
    /// Empty input becomes `nil` rather than `""`, matching how the generator
    /// stores an absent explanation — otherwise a card edited to remove its
    /// explanation would render an empty section instead of none.
    public let explanation: String?

    public init(front: String, back: String, explanation: String?) {
        self.front = front
        self.back = back
        self.explanation = explanation
    }
}

public enum CardEditValidation: Equatable, Sendable {
    case valid(CardEdit)
    case emptyFront
    case emptyBack

    public var edit: CardEdit? {
        if case .valid(let edit) = self { return edit }
        return nil
    }

    /// The one place the reason is worded, so the disabled Save button and the
    /// message under the field cannot disagree.
    public var message: String? {
        switch self {
        case .valid: return nil
        case .emptyFront: return "Soru boş olamaz."
        case .emptyBack: return "Cevap boş olamaz."
        }
    }
}

public enum CardEditor {

    /// A card with no question or no answer is not a card. Everything else —
    /// length, wording, whether it still matches the page — is the user's call:
    /// this is their correction of the model, and second-guessing it here would
    /// reintroduce the approval gate Faz 6 deliberately removed.
    public static func validate(front: String, back: String, explanation: String) -> CardEditValidation {
        let trimmedFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFront.isEmpty else { return .emptyFront }

        let trimmedBack = back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBack.isEmpty else { return .emptyBack }

        let trimmedExplanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return .valid(
            CardEdit(
                front: trimmedFront,
                back: trimmedBack,
                explanation: trimmedExplanation.isEmpty ? nil : trimmedExplanation
            )
        )
    }

    /// Whether saving would actually change anything, so an untouched sheet does
    /// not bump `updatedAt` and write to the store for nothing.
    public static func changes(_ edit: CardEdit, from front: String, _ back: String, _ explanation: String?) -> Bool {
        edit.front != front || edit.back != back || edit.explanation != explanation
    }
}

/// Changing a card's kind in the editor (2026-08-15).
///
/// Before this, type was only ever *derived*: adding a sound set of options made
/// a card `multipleChoice`, removing them degraded it back
/// (`MultipleChoice.resolvedType`). Picking a type directly opens a second door
/// onto the same state, and the two doors can contradict each other — a card
/// claiming `.multipleChoice` with no options, or five options sitting under
/// `.cloze`.
///
/// So every type change, from the picker *and* from "Şıkları kaldır", goes
/// through this one function. The invariant it maintains, and the editor's whole
/// contract with itself:
///
///     options UI visible  ⟺  type == .multipleChoice  ⟺  options is non-empty
///
/// This is deliberately structural rather than careful: both Codex bugs in this
/// area (PR #29) were ordering mistakes in exactly this derivation — the answer
/// left pointing at the old option — and a rule written once in a testable
/// function is the only kind that cannot be forgotten at the second call site.
public enum CardTypeChange {

    public enum Effect: Equatable, Sendable {
        /// Plain → plain. Nothing but the type moves.
        case setTypeOnly(CardType)
        /// → five options. The editor shows the option rows and stops editing
        /// `back` directly; the answer is now the correct option.
        case enterMultipleChoice(options: [CardOption])
        /// Five options → plain. `back` carries the answer out of the options
        /// before they are dropped, which is the ordering both PR #29 bugs got
        /// wrong; `stash` keeps them for an undo within the same sheet.
        case leaveMultipleChoice(type: CardType, back: String, stash: [CardOption])
    }

    /// What picking `newType` should do to the editor's state.
    ///
    /// - Parameters:
    ///   - derivedBack: the answer as it stands now — the editor's `effectiveBack`,
    ///     i.e. the ticked option's text on a five-option card, the typed answer
    ///     otherwise.
    ///   - currentOptions: the options as edited, empty on a plain card.
    ///   - stash: options from an earlier `leaveMultipleChoice` in this sheet, so
    ///     switching away and back does not make the user retype four distractors.
    public static func effect(
        picking newType: CardType,
        currentType: CardType,
        derivedBack: String,
        currentOptions: [CardOption],
        stash: [CardOption]?
    ) -> Effect {
        guard newType != currentType else {
            return newType == .multipleChoice
                ? .enterMultipleChoice(options: currentOptions)
                : .setTypeOnly(newType)
        }

        if newType == .multipleChoice {
            return .enterMultipleChoice(options: seededOptions(answer: derivedBack, stash: stash))
        }

        if currentType == .multipleChoice {
            return .leaveMultipleChoice(type: newType, back: derivedBack, stash: currentOptions)
        }

        return .setTypeOnly(newType)
    }

    /// The option list to start from when the card becomes a five-option one.
    ///
    /// A restored stash keeps its distractors but **takes its answer from the
    /// current `back`**: the user may have rewritten the answer while the card
    /// was plain, and restoring the old correct option would silently reinstate
    /// the answer they just replaced — the same invariant break as PR #29, only
    /// arriving by a different route.
    static func seededOptions(answer: String, stash: [CardOption]?) -> [CardOption] {
        guard let stash, stash.count == MultipleChoice.optionCount else {
            return [CardOption(text: answer, isCorrect: true, why: nil)]
                + Array(
                    repeating: CardOption(text: "", isCorrect: false, why: nil),
                    count: MultipleChoice.optionCount - 1
                )
        }
        return stash.map { option in
            option.isCorrect ? CardOption(text: answer, isCorrect: true, why: nil) : option
        }
    }
}

/// What can honestly be shown as the origin of a card.
public struct CardSourceMaterial: Equatable, Sendable {
    /// Per-card quote. Only legacy cards have one — the Faz 6 contract dropped it.
    public let quote: String?
    /// What the model reported reading off the marked page.
    public let readText: String?
    public let subject: String?
    /// The captured page, when it is still on disk.
    public let pageImagePath: String?
    public let capturedAt: Date?
    /// True when a page was captured but its image is no longer kept, which is
    /// a different thing from a card that never had a page — and the user
    /// deserves to be told which (they chose it in Ayarlar).
    public let pageImageDiscarded: Bool

    public var isEmpty: Bool {
        quote == nil && readText == nil && subject == nil && pageImagePath == nil && !pageImageDiscarded
    }

    public init(
        quote: String? = nil,
        readText: String? = nil,
        subject: String? = nil,
        pageImagePath: String? = nil,
        capturedAt: Date? = nil,
        pageImageDiscarded: Bool = false
    ) {
        self.quote = quote
        self.readText = readText
        self.subject = subject
        self.pageImagePath = pageImagePath
        self.capturedAt = capturedAt
        self.pageImageDiscarded = pageImageDiscarded
    }
}

public enum CardSourceResolver {

    /// Placeholder the generator falls back to when the model returned no read
    /// text at all (`BackendCardProvider.map`). Showing it as "what the page
    /// said" would be a lie dressed as provenance.
    public static let readTextPlaceholder = "Kart destesi"

    /// Assembles what is genuinely available, dropping anything that would only
    /// look like a source.
    ///
    /// The caller passes raw model values; every decision about what survives is
    /// made here so the review screen and the detail screen cannot show
    /// different provenance for the same card.
    public static func material(
        cardFront: String,
        quote: String?,
        readText: String?,
        subject: String?,
        pageImagePath: String?,
        pageImageExists: Bool,
        capturedAt: Date?
    ) -> CardSourceMaterial {
        let cleanedQuote = nonEmpty(quote)
        let cleanedSubject = nonEmpty(subject)

        var cleanedReadText = nonEmpty(readText)
        if let text = cleanedReadText {
            // Two ways the "read text" is not a reading. The generator's own
            // fallbacks: the placeholder above, and the first card's front when
            // the model returned nothing. Echoing the question back as its own
            // source is worse than showing no source.
            if text == readTextPlaceholder
                || text.compare(cardFront.trimmingCharacters(in: .whitespacesAndNewlines),
                                options: .caseInsensitive) == .orderedSame {
                cleanedReadText = nil
            }
        }

        let hasPage = nonEmpty(pageImagePath) != nil
        return CardSourceMaterial(
            quote: cleanedQuote,
            readText: cleanedReadText,
            subject: cleanedSubject,
            pageImagePath: pageImageExists ? nonEmpty(pageImagePath) : nil,
            capturedAt: capturedAt,
            pageImageDiscarded: hasPage && !pageImageExists
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
