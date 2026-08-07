import Foundation

/// One of a five-option card's choices (ANA-PLAN §13.3).
///
/// `why` is its own field because §13.3 requires the model to say why each
/// distractor is wrong *separately*. Folding those sentences into the card's
/// single `explanation` would leave nothing able to say which reason belongs to
/// which option — and the reason is the part that actually teaches: getting a
/// question wrong is only useful if you learn why the thing you picked was
/// wrong.
public struct CardOption: Codable, Equatable, Sendable {
    public let text: String
    public let isCorrect: Bool
    /// Why this option is wrong, one sentence. Empty on the correct option.
    public let why: String?

    public init(text: String, isCorrect: Bool, why: String? = nil) {
        self.text = text
        self.isCorrect = isCorrect
        self.why = why
    }
}

/// How much of a page may become five-option cards (§13.3).
///
/// Mirrors the backend's `MULTIPLE_CHOICE_MODES`; the raw values are the wire
/// format, so they are the same three words on both sides.
public enum MultipleChoiceMode: String, Codable, CaseIterable, Sendable {
    case off
    case mixed
    case all

    public var label: String {
        switch self {
        case .off: return "Kapalı"
        case .mixed: return "Karışık"
        case .all: return "Hepsi"
        }
    }

    /// What the option costs, said plainly — every set of five options is extra
    /// output tokens, and output tokens are what the latency is made of.
    public var detail: String {
        switch self {
        case .off: return "Beş şıklı kart üretilmez."
        case .mixed: return "Yalnız ayırt etme/istisna kartları beş şıklı olur."
        case .all: return "Üretilebilen her kart beş şıklı olur; daha yavaş ve daha pahalı."
        }
    }
}

public enum MultipleChoiceValidation: Equatable, Sendable {
    case valid
    case wrongOptionCount(Int)
    case noCorrectOption
    case severalCorrectOptions(Int)
    case emptyOption
    case duplicateOptions

    /// Shown next to a disabled "Kaydet" in the editor, so it has to say what
    /// to fix rather than that something is wrong.
    public var message: String? {
        switch self {
        case .valid:
            return nil
        case .wrongOptionCount(let count):
            return "Beş şık olmalı; şu an \(count) tane var."
        case .noCorrectOption:
            return "Doğru şık işaretlenmemiş."
        case .severalCorrectOptions(let count):
            return "\(count) şık doğru işaretlenmiş; yalnız biri doğru olabilir."
        case .emptyOption:
            return "Boş şık var."
        case .duplicateOptions:
            return "İki şık aynı; distraktörler birbirinden farklı olmalı."
        }
    }
}

/// Storing, validating and presenting five-option cards.
///
/// Deliberately Foundation-only — every judgement here (is this card sound? in
/// what order are the options shown?) is decidable without SwiftData or a UI,
/// which is what makes it testable in this repo's Linux environment.
public enum MultipleChoice {
    /// §13.3: five options, no more, no fewer.
    public static let optionCount = 5

    // MARK: Storage

    /// `Card.optionsRaw` is a JSON string rather than a related SwiftData model.
    ///
    /// The option list is never queried from outside its own card, so a second
    /// entity would buy nothing and cost a cascade rule, a migration and a
    /// backup shape.
    public static func encode(_ options: [CardOption]) -> String? {
        guard let data = try? JSONEncoder().encode(options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns `nil` for anything that is not a usable option list, so a card
    /// with broken storage simply shows as a plain card instead of crashing or
    /// rendering half a question.
    public static func decode(_ raw: String?) -> [CardOption]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let options = try? JSONDecoder().decode([CardOption].self, from: data) else { return nil }
        guard case .valid = validate(options) else { return nil }
        return options
    }

    // MARK: Validation

    /// §13.3's structural rules, in the order that produces the most useful
    /// single message for someone fixing a card by hand.
    public static func validate(_ options: [CardOption]) -> MultipleChoiceValidation {
        guard options.count == optionCount else { return .wrongOptionCount(options.count) }

        let trimmed = options.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.contains(where: \.isEmpty) else { return .emptyOption }

        let correctCount = options.filter(\.isCorrect).count
        guard correctCount != 0 else { return .noCorrectOption }
        guard correctCount == 1 else { return .severalCorrectOptions(correctCount) }

        // Compared the way Turkish has to be compared (ADR-001): the İ/ı pair
        // makes `lowercased()` alone wrong, and two options differing only in
        // case or spacing are the same option to a reader.
        let keys = trimmed.map(comparisonKey)
        guard Set(keys).count == keys.count else { return .duplicateOptions }

        return .valid
    }

    /// Canonical form used only to tell two options apart.
    ///
    /// Hand-rolled rather than `folding(options:locale:)` on purpose: this runs
    /// in tests on Linux and in the app on iOS, and the ICU-backed folding does
    /// not behave identically on both. A table this small is worth more than a
    /// clever call that could quietly differ per platform.
    ///
    /// It is *not* the critical-token engine (`evals/ocr_eval/critical_tokens.py`
    /// and its TS twin). Nothing medical is decided here — the question is only
    /// "did the model write the same distractor twice?"
    ///
    /// **Must stay identical to `optionKey` in `backend/providers/multipleChoice.ts`.**
    /// It briefly was not: this side also split on punctuation, so `HER2+` and
    /// `HER2` were duplicates here and distinct there — a card the server had
    /// passed arrived and lost its options, ending up a five-option card with
    /// nothing to choose from (Codex, PR #29). Punctuation is now kept on both
    /// sides, because `A-B` and `A B` can genuinely be different answers.
    static func comparisonKey(_ text: String) -> String {
        var folded = ""
        folded.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "İ", "I", "ı", "i", "Î", "î": folded.append("i")
            case "Ç", "ç": folded.append("c")
            case "Ğ", "ğ": folded.append("g")
            case "Ş", "ş": folded.append("s")
            case "Ö", "ö": folded.append("o")
            case "Ü", "ü", "Û", "û": folded.append("u")
            case "Â", "â": folded.append("a")
            default: folded.append(contentsOf: character.lowercased())
            }
        }
        // Whitespace only — see the note above on staying identical to the
        // server's `optionKey`.
        return folded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// What a card's type becomes once its options are (or are no longer) sound.
    ///
    /// Editing is the one place a card can change kind: removing broken options
    /// has to leave a usable plain card rather than a `multipleChoice` card with
    /// nothing to choose from, and adding a sound set has to make the review
    /// screen actually ask the question.
    public static func resolvedType(current: CardType, options: [CardOption]?) -> CardType {
        if let options, case .valid = validate(options) { return .multipleChoice }
        return current == .multipleChoice ? .directRecall : current
    }

    /// Index of the correct option, or `nil` if the list is not sound.
    public static func correctIndex(_ options: [CardOption]) -> Int? {
        guard case .valid = validate(options) else { return nil }
        return options.firstIndex(where: \.isCorrect)
    }

    // MARK: Presentation order

    /// The order the options are shown in for one particular sitting.
    ///
    /// Two failures to avoid at once. Always showing the correct answer in the
    /// stored position teaches the *position*, not the fact — after a few
    /// reviews the card is answered without reading. Reshuffling on every
    /// redraw, on the other hand, makes the options jump around under the
    /// user's thumb, and SwiftUI redraws a lot.
    ///
    /// So the order is derived from the card's id and how many times it has
    /// been reviewed: stable for the whole of one review, different at the next
    /// one, and reproducible in a test — no `Date.now`, no `Int.random`.
    public static func presentationOrder(cardId: UUID, reviewCount: Int, count: Int) -> [Int] {
        guard count > 1 else { return Array(0..<max(0, count)) }

        var state = seed(cardId: cardId, reviewCount: reviewCount)
        var indices = Array(0..<count)
        // Fisher-Yates with a small deterministic LCG (Numerical Recipes
        // constants). Not cryptography — it only has to be well-mixed and the
        // same on every device for the same inputs.
        for position in stride(from: count - 1, through: 1, by: -1) {
            state = 1_664_525 &* state &+ 1_013_904_223
            let pick = Int(state % UInt64(position + 1))
            indices.swapAt(position, pick)
        }
        return indices
    }

    static func seed(cardId: UUID, reviewCount: Int) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        withUnsafeBytes(of: cardId.uuid) { bytes in
            for byte in bytes {
                value ^= UInt64(byte)
                value = value &* 0x100_0000_01b3
            }
        }
        value ^= UInt64(bitPattern: Int64(reviewCount))
        return value &* 0x100_0000_01b3
    }
}
