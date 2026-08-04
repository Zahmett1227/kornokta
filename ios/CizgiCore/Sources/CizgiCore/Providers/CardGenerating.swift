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

/// What a real provider call cost (§16.8) — `nil` for `MockCardProvider`,
/// which makes no network call and has nothing to account for. The caller
/// (`ProcessingQueue`) fills in the fields it already knows itself (`id`,
/// `jobId`, `success`, `errorCategory`, `createdAt`) when turning this into a
/// stored `ModelRun`, so only what solely the provider can know lives here.
public struct ModelRunMetadata: Sendable, Equatable {
    public let requestId: String
    public let provider: String
    public let model: String
    public let purpose: String
    public let promptVersion: String
    public let latencyMs: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double

    public init(
        requestId: String,
        provider: String,
        model: String,
        purpose: String,
        promptVersion: String,
        latencyMs: Int,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double
    ) {
        self.requestId = requestId
        self.provider = provider
        self.model = model
        self.purpose = purpose
        self.promptVersion = promptVersion
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct GeneratedKnowledge: Sendable, Equatable {
    public let canonicalClaim: String
    public let tags: [String]
    public let sourceConcern: String?
    public let cards: [GeneratedCard]
    public let modelRun: ModelRunMetadata?

    public init(
        canonicalClaim: String,
        tags: [String] = [],
        sourceConcern: String? = nil,
        cards: [GeneratedCard],
        modelRun: ModelRunMetadata? = nil
    ) {
        self.canonicalClaim = canonicalClaim
        self.tags = tags
        self.sourceConcern = sourceConcern
        self.cards = cards
        self.modelRun = modelRun
    }
}

public struct CardGenerationRequest: Sendable {
    public let jobId: String
    public let passage: String
    public let subject: String?
    public let sourceFaithfulOnly: Bool
    public let maxCards: Int
    /// The rest of these are only needed by a provider that actually calls
    /// the backend (§25 Faz 3): `MockCardProvider` never reads them.
    public let imageData: Data?
    public let mimeType: String?
    public let selectedLineIds: [String]
    public let isHandwritten: Bool
    /// The forward-compatible source contract. `passage` remains as a
    /// compatibility projection for providers that have not yet adopted batch
    /// group output, while new providers can preserve group identity.
    public let annotationGroups: [AnnotationGroup]
    /// Optional free-text steer from the user for the Faz 6 vision endpoint
    /// (docs/FAZ6-PLAN.md §5.1), e.g. "sadece sol sütun". Providers that do not
    /// use it (`MockCardProvider`, the OCR-era path) simply ignore it.
    public let hint: String?

    public init(
        jobId: String,
        passage: String,
        subject: String? = nil,
        sourceFaithfulOnly: Bool = true,
        maxCards: Int = 4,
        imageData: Data? = nil,
        mimeType: String? = nil,
        selectedLineIds: [String] = [],
        isHandwritten: Bool = false,
        annotationGroups: [AnnotationGroup] = [],
        hint: String? = nil
    ) {
        self.jobId = jobId
        self.passage = passage
        self.subject = subject
        self.sourceFaithfulOnly = sourceFaithfulOnly
        self.maxCards = maxCards
        self.imageData = imageData
        self.mimeType = mimeType
        self.selectedLineIds = selectedLineIds
        self.isHandwritten = isHandwritten
        self.annotationGroups = annotationGroups
        self.hint = hint
    }
}

/// Card generation. `MockCardProvider` is the offline stand-in; `BackendCardProvider`
/// (§25 Faz 3) is the real one — both sit behind this one protocol so the
/// pipeline does not change when Settings switches between them.
public protocol CardGenerating: Sendable {
    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge
}
