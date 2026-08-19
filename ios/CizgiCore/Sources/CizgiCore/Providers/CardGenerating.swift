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
    /// Five options for a `multipleChoice` card, `nil` for every other type
    /// (ANA-PLAN §13.3). Already structurally checked by the server's gate —
    /// what arrives here either satisfies §13.3 or is not a five-option card.
    public let options: [CardOption]?
    /// The model's own "I am unsure" signal, plus anything the server's gate
    /// found suspicious but could not decide (§13.3 rule 4, §6).
    ///
    /// Decoded since Faz 6 and dropped on the floor ever since. It is the
    /// substrate for §13.3's sixth rule — "şüpheli soru onay almadan aktif
    /// karta dönüşmemeli" — which Faz 6 answers by flagging rather than
    /// blocking (docs/FAZ7-PLAN-coktan-secmeli.md §9).
    public let lowConfidence: Bool
    /// Canonical topic name (schema v2.2) from the subject's list in
    /// `Resources/subject_topics.json`, or `nil` when the capture carried no
    /// subject or the model was unsure. Already validated server-side; the
    /// phone checks it once more before persisting (`TopicGrouping`).
    public let topic: String?

    public init(
        type: CardType,
        front: String,
        back: String,
        explanation: String? = nil,
        sourceQuote: String,
        riskFlags: [RiskFlag] = [],
        requiresUserApproval: Bool = false,
        options: [CardOption]? = nil,
        lowConfidence: Bool = false,
        topic: String? = nil
    ) {
        self.type = type
        self.front = front
        self.back = back
        self.explanation = explanation
        self.sourceQuote = sourceQuote
        self.riskFlags = riskFlags
        self.requiresUserApproval = requiresUserApproval
        self.options = options
        self.lowConfidence = lowConfidence
        self.topic = topic
    }
}

/// What one real provider call cost (§16.8) — empty for `MockCardProvider`,
/// which makes no network call and has nothing to account for. The caller
/// (`ProcessingQueue`) fills in the fields it already knows itself (`id`,
/// `jobId`, `errorCategory`, `createdAt`) when turning this into a stored
/// `ModelRun`, so only what solely the provider can know lives here.
///
/// Describes *one call*, not one page. A page that failed twice before
/// succeeding produced three of these, and the server reports all three —
/// which is the only way the phone's total can agree with the invoice.
public struct ModelRunMetadata: Sendable, Equatable {
    public let requestId: String
    /// Which attempt at the job this was, as the server counted it. The
    /// de-duplication key together with the job id and `purpose`.
    public let attempt: Int
    public let provider: String
    public let model: String
    public let purpose: String
    public let promptVersion: String
    public let latencyMs: Int
    public let inputTokens: Int
    /// Subset of `inputTokens` served from the provider's cache, billed cheaper.
    public let cachedInputTokens: Int
    public let outputTokens: Int
    /// Subset of `outputTokens` spent on hidden reasoning, billed at the output rate.
    public let reasoningTokens: Int
    public let estimatedCostUSD: Double
    public let success: Bool
    /// One of `ModelRunBilling`'s three values — see there for why 0.00 alone
    /// is not enough to know whether a call was free.
    public let billing: String
    public let failureReason: String?

    public init(
        requestId: String,
        attempt: Int = 0,
        provider: String,
        model: String,
        purpose: String,
        promptVersion: String,
        latencyMs: Int,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        estimatedCostUSD: Double,
        success: Bool = true,
        billing: String = ModelRunBilling.measured,
        failureReason: String? = nil
    ) {
        self.requestId = requestId
        self.attempt = attempt
        self.provider = provider
        self.model = model
        self.purpose = purpose
        self.promptVersion = promptVersion
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.success = success
        self.billing = billing
        self.failureReason = failureReason
    }
}

public struct GeneratedKnowledge: Sendable, Equatable {
    public let canonicalClaim: String
    public let tags: [String]
    public let sourceConcern: String?
    public let cards: [GeneratedCard]
    /// Every provider call the server made for this page, not only the one
    /// that finally worked.
    ///
    /// Plural because the phone is the ledger of last resort and a page really
    /// does cost several calls: the app may be asleep or killed while a job
    /// fails and retries, so anything keyed on "the call I personally watched
    /// succeed" reads low by however many attempts went unwitnessed.
    public let modelRuns: [ModelRunMetadata]
    /// What the model says it saw and did *not* turn into a card (schema v2.3,
    /// docs/PLAN-kapsama-sozlesmesi.md).
    ///
    /// `nil` from a provider that reports none — `MockCardProvider`, or a
    /// backend older than the contract. That is deliberately different from an
    /// empty `PageCoverage`: "nobody looked" and "nothing was missed" are not
    /// the same answer, and only one of them is good news.
    public let coverage: PageCoverage?

    public init(
        canonicalClaim: String,
        tags: [String] = [],
        sourceConcern: String? = nil,
        cards: [GeneratedCard],
        modelRuns: [ModelRunMetadata] = [],
        coverage: PageCoverage? = nil
    ) {
        self.canonicalClaim = canonicalClaim
        self.tags = tags
        self.sourceConcern = sourceConcern
        self.cards = cards
        self.modelRuns = modelRuns
        self.coverage = coverage
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
    /// Optional free-text steer from the user for the Faz 6 vision endpoint
    /// (docs/FAZ6-PLAN.md §5.1), e.g. "sadece sol sütun". Providers that do not
    /// use it (`MockCardProvider`, the OCR-era path) simply ignore it.
    public let hint: String?
    /// Whether five-option cards may be produced (§13.3), from Ayarlar.
    ///
    /// The server treats its own config as the ceiling: this can ask for less
    /// (never for more), the same rule `maxCards` follows (§21.3).
    public let multipleChoiceMode: MultipleChoiceMode?
    /// The user pressed "Tekrar dene", as opposed to the queue retrying by
    /// itself.
    ///
    /// Only a person can carry information the server's own verdict does not
    /// have — a corrected backend key being the case that matters. Without this
    /// a page the server marked permanently failed had no way back at all: the
    /// job id is the page id, so every later attempt polled the same dead row
    /// (`/api/jobs` refuses to re-arm one on its own, deliberately). Automatic
    /// retries leave this false, because repeating alone is exactly what a
    /// permanent failure already told us will not work.
    public let forceResubmit: Bool

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
        hint: String? = nil,
        multipleChoiceMode: MultipleChoiceMode? = nil,
        forceResubmit: Bool = false
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
        self.hint = hint
        self.multipleChoiceMode = multipleChoiceMode
        self.forceResubmit = forceResubmit
    }
}

/// Card generation. `MockCardProvider` is the offline stand-in; `BackendCardProvider`
/// (§25 Faz 3) is the real one — both sit behind this one protocol so the
/// pipeline does not change when Settings switches between them.
public protocol CardGenerating: Sendable {
    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge
}
