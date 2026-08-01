import Foundation

/// A card the generator proposes, before it becomes a `Card` in the store.
public struct GeneratedCard: Sendable, Equatable {
    public let type: CardType
    public let front: String
    public let back: String
    public let explanation: String?
    public let sourceQuote: String
    public let riskFlags: [RiskFlag]
    public let requiresUserApproval: Bool

    public init(
        type: CardType,
        front: String,
        back: String,
        explanation: String? = nil,
        sourceQuote: String,
        riskFlags: [RiskFlag] = [],
        requiresUserApproval: Bool = false
    ) {
        self.type = type
        self.front = front
        self.back = back
        self.explanation = explanation
        self.sourceQuote = sourceQuote
        self.riskFlags = riskFlags
        self.requiresUserApproval = requiresUserApproval
    }
}

public struct GeneratedKnowledge: Sendable, Equatable {
    public let canonicalClaim: String
    public let tags: [String]
    public let sourceConcern: String?
    public let cards: [GeneratedCard]

    public init(
        canonicalClaim: String,
        tags: [String] = [],
        sourceConcern: String? = nil,
        cards: [GeneratedCard]
    ) {
        self.canonicalClaim = canonicalClaim
        self.tags = tags
        self.sourceConcern = sourceConcern
        self.cards = cards
    }
}

public struct CardGenerationRequest: Sendable {
    public let jobId: String
    public let passage: String
    public let subject: String?
    public let sourceFaithfulOnly: Bool
    public let maxCards: Int

    public init(
        jobId: String,
        passage: String,
        subject: String? = nil,
        sourceFaithfulOnly: Bool = true,
        maxCards: Int = 4
    ) {
        self.jobId = jobId
        self.passage = passage
        self.subject = subject
        self.sourceFaithfulOnly = sourceFaithfulOnly
        self.maxCards = maxCards
    }
}

/// Card generation. In Faz 1 this is always the local mock; the backend-backed
/// implementation arrives in Faz 3 (§25) behind the same protocol so the
/// pipeline does not change.
public protocol CardGenerating: Sendable {
    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge
}
