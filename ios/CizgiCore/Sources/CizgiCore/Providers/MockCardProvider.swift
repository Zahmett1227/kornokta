import Foundation

/// Offline card generator for Faz 1 (ANA-PLAN §25).
///
/// It exists so the whole capture → queue → review loop can be exercised with
/// no network, no API key and no cost. It does **not** try to be clever: it
/// produces a direct-recall card and a cloze from the passage, which is enough
/// to prove the pipeline and the review screen work.
///
/// It deliberately keeps two of the real generator's guarantees so the
/// downstream code is written against honest data from the start:
///   * never more than `maxCards` (§13.2)
///   * every card carries the passage as `sourceQuote`, so "Kaynağı Göster"
///     works from day one (§5.5)
public struct MockCardProvider: CardGenerating {
    public init() {}

    public func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        let passage = request.passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else {
            throw CardGenerationError.sourceInsufficient
        }

        var cards: [GeneratedCard] = [
            GeneratedCard(
                type: .directRecall,
                front: Self.recallQuestion(for: passage),
                back: passage,
                explanation: nil,
                sourceQuote: passage,
                riskFlags: []
            )
        ]

        if let cloze = Self.clozeCard(for: passage) {
            cards.append(cloze)
        }

        return GeneratedKnowledge(
            canonicalClaim: passage,
            tags: [request.subject].compactMap { $0 },
            sourceConcern: nil,
            cards: Array(cards.prefix(request.maxCards))
        )
    }

    /// Turns a statement into a question without inventing content — the mock
    /// must not add anything the passage does not say (§12.1).
    static func recallQuestion(for passage: String) -> String {
        let head = passage.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        let firstSentence = head.map { String($0).trimmingCharacters(in: .whitespaces) } ?? passage
        return "[Taslak] \(firstSentence) — bu ifadeyi tamamlayın."
    }

    /// Blanks the longest word so there is something to recall. Real cloze
    /// selection is the model's job in Faz 3.
    static func clozeCard(for passage: String) -> GeneratedCard? {
        let words = passage.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return nil }
        guard let target = words.max(by: { $0.count < $1.count }), target.count >= 4 else {
            return nil
        }
        let blanked = words
            .map { $0 == target ? String(repeating: "_", count: max(3, target.count)) : $0 }
            .joined(separator: " ")
        return GeneratedCard(
            type: .cloze,
            front: blanked,
            back: target,
            sourceQuote: passage
        )
    }
}

/// Why generation failed.
///
/// The pipeline maps each case onto a `FailureKind`, so the transient/permanent
/// split is decided once (§17): a malformed response is a contract bug that
/// replaying will reproduce, while an unreachable provider is worth retrying.
public enum CardGenerationError: Error, Sendable, Equatable {
    /// The passage does not carry enough to build a card from (§12.1, §19.3).
    case sourceInsufficient
    /// The provider answered, but not in the shape §14 requires.
    case schemaInvalid(String)
    /// The provider could not be reached, or failed for a transient reason.
    case providerUnavailable(String)
    case budgetExceeded
}

/// A `CardGenerationError` with the ledger of whatever the failed attempt (and
/// any attempt before it) already spent.
///
/// Thrown instead of a bare `CardGenerationError` by the real provider, and
/// caught ahead of it in `CapturePipeline`. A separate wrapper rather than a
/// payload on every case so that the enum stays `Equatable` and the offline
/// stand-ins — and the tests — can keep throwing plain cases.
///
/// This exists because the expensive failures are exactly the ones nobody was
/// writing down: a page that never succeeds still spent money on every attempt
/// it made, and without carrying that out with the error the only record of it
/// was the provider's invoice.
public struct CardGenerationFailure: Error, Sendable {
    public let error: CardGenerationError
    public let accounting: [ModelRunMetadata]

    public init(error: CardGenerationError, accounting: [ModelRunMetadata] = []) {
        self.error = error
        self.accounting = accounting
    }
}
