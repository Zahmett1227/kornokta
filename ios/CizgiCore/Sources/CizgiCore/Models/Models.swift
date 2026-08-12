import Foundation
import SwiftData

// SwiftData models for the local store (ANA-PLAN §16). The phone is the source
// of truth; the backend keeps no user database (§7.2).

@Model
public final class Source {
    @Attribute(.unique) public var id: UUID
    public var title: String?
    public var author: String?
    public var edition: String?
    public var subject: String?
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CapturedPage.source)
    public var pages: [CapturedPage]

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        author: String? = nil,
        edition: String? = nil,
        subject: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.edition = edition
        self.subject = subject
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.pages = []
    }
}

@Model
public final class CapturedPage {
    @Attribute(.unique) public var id: UUID
    public var pageNumber: String?
    /// Relative to the app's image directory, never an absolute path — the
    /// container path changes between installs.
    public var originalImagePath: String
    public var processedImagePath: String?
    public var perceptualHash: String?
    public var captureDate: Date
    public var documentQualityScore: Double
    public var processingStateRaw: String
    public var lastError: String?
    /// Critical-token disagreements the backend reported, kept so the
    /// confirmation screen can say what changed rather than only that
    /// something did (§19.2).
    public var confirmationFlags: [String]
    public var retryCount: Int
    /// Set when the job may next be retried after a temporary failure (§17).
    public var nextAttemptAt: Date?
    /// Set once the retention setting says the original image should go,
    /// cleared only once it actually is removed (§22). Durable so a crash
    /// between persisting `.ready` and deleting the file — or a later,
    /// unrelated save that happens to flush this page — can't leave the
    /// image orphaned forever; `shouldProcess` never revisits a `.ready`
    /// page, so nothing else would ever retry the deletion.
    public var pendingOriginalImageDeletion: Bool = false
    /// Set when the user deletes a page while it is mid-`pipeline.run`
    /// (`ProcessingQueue` tracks this via `inFlightPageIDs`). Deleting the
    /// SwiftData record out from under that in-flight run would hand `apply`
    /// a page that is a fault by the time the run's `await`s resume; instead
    /// the request is recorded here and `apply` performs the actual deletion
    /// once the run finishes, so the tap is honored without racing it.
    /// Declaration-time default keeps this a lightweight migration.
    public var pendingDeletion: Bool = false
    /// Device-local checkpoint of the completed primary OCR run. The data is
    /// intentionally held only on the phone and is cleared after successful
    /// persistence; the backend remains stateless (§7.2, §22).
    public var ocrSnapshotData: Data?

    public var source: Source?

    @Relationship(deleteRule: .cascade, inverse: \TextRegion.page)
    public var regions: [TextRegion]

    public var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .captured }
        set { processingStateRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        originalImagePath: String,
        captureDate: Date = .now,
        documentQualityScore: Double = 0.9,
        state: ProcessingState = .captured
    ) {
        self.id = id
        self.originalImagePath = originalImagePath
        self.captureDate = captureDate
        self.documentQualityScore = documentQualityScore
        self.processingStateRaw = state.rawValue
        self.confirmationFlags = []
        self.retryCount = 0
        self.pendingOriginalImageDeletion = false
        self.pendingDeletion = false
        self.ocrSnapshotData = nil
        self.regions = []
    }
}

@Model
public final class TextRegion {
    @Attribute(.unique) public var id: UUID
    /// Normalized to the page image, top-left origin.
    public var boundingBoxX: Double
    public var boundingBoxY: Double
    public var boundingBoxWidth: Double
    public var boundingBoxHeight: Double
    /// Flattened x/y polygon coordinates when a non-rectangular source region
    /// is available. Current detectors emit a rectangle, but this prevents a
    /// later lasso selection from being forced back into a whole-page box.
    public var boundingPolygon: [Double] = []
    public var lineIds: [String]
    public var tokenIds: [String] = []
    public var evidenceIds: [String] = []
    public var appleOCRText: String?
    public var googleOCRText: String?
    public var finalText: String
    public var selectedText: String = ""
    public var contextText: String = ""
    public var handwrittenNotes: [String] = []
    /// Declaration-time defaults make this a lightweight SwiftData migration
    /// for stores created before annotation grounding existed.
    public var layoutKindRaw: String = "unknown"
    /// Relative image-store path for the actual source crop, never an
    /// absolute sandbox path.
    public var sourceCropPath: String?
    public var confidence: Double
    public var isHandwritten: Bool
    public var selectionTypeRaw: String
    public var requiresConfirmation: Bool
    public var confirmedAt: Date?

    public var page: CapturedPage?

    @Relationship(deleteRule: .cascade, inverse: \KnowledgeUnit.region)
    public var knowledgeUnits: [KnowledgeUnit]

    public var selectionType: SelectionType {
        get { SelectionType(rawValue: selectionTypeRaw) ?? .manual }
        set { selectionTypeRaw = newValue.rawValue }
    }

    public var layoutKind: LayoutKind {
        get { LayoutKind(rawValue: layoutKindRaw) ?? .unknown }
        set { layoutKindRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        boundingBox: (x: Double, y: Double, width: Double, height: Double),
        lineIds: [String],
        tokenIds: [String] = [],
        evidenceIds: [String] = [],
        finalText: String,
        selectedText: String = "",
        contextText: String = "",
        handwrittenNotes: [String] = [],
        layoutKind: LayoutKind = .unknown,
        sourceCropPath: String? = nil,
        confidence: Double,
        isHandwritten: Bool = false,
        selectionType: SelectionType = .manual,
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.boundingBoxX = boundingBox.x
        self.boundingBoxY = boundingBox.y
        self.boundingBoxWidth = boundingBox.width
        self.boundingBoxHeight = boundingBox.height
        self.boundingPolygon = [
            boundingBox.x, boundingBox.y,
            boundingBox.x + boundingBox.width, boundingBox.y,
            boundingBox.x + boundingBox.width, boundingBox.y + boundingBox.height,
            boundingBox.x, boundingBox.y + boundingBox.height,
        ]
        self.lineIds = lineIds
        self.tokenIds = tokenIds
        self.evidenceIds = evidenceIds
        self.finalText = finalText
        self.selectedText = selectedText
        self.contextText = contextText
        self.handwrittenNotes = handwrittenNotes
        self.layoutKindRaw = layoutKind.rawValue
        self.sourceCropPath = sourceCropPath
        self.confidence = confidence
        self.isHandwritten = isHandwritten
        self.selectionTypeRaw = selectionType.rawValue
        self.requiresConfirmation = requiresConfirmation
        self.knowledgeUnits = []
    }
}

@Model
public final class KnowledgeUnit {
    @Attribute(.unique) public var id: UUID
    public var canonicalClaim: String
    public var mechanism: String?
    public var subject: String?
    public var topic: String?
    public var tags: [String]
    public var sourceFaithful: Bool
    public var enriched: Bool
    public var sourceConcern: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var region: TextRegion?

    @Relationship(deleteRule: .cascade, inverse: \Card.knowledgeUnit)
    public var cards: [Card]

    public init(
        id: UUID = UUID(),
        canonicalClaim: String,
        mechanism: String? = nil,
        subject: String? = nil,
        topic: String? = nil,
        tags: [String] = [],
        sourceFaithful: Bool = true,
        enriched: Bool = false,
        sourceConcern: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.canonicalClaim = canonicalClaim
        self.mechanism = mechanism
        self.subject = subject
        self.topic = topic
        self.tags = tags
        self.sourceFaithful = sourceFaithful
        self.enriched = enriched
        self.sourceConcern = sourceConcern
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.cards = []
    }
}

@Model
public final class Card {
    @Attribute(.unique) public var id: UUID
    public var typeRaw: String
    public var front: String
    public var back: String
    public var explanation: String?
    public var sourceQuote: String?
    public var riskFlagsRaw: [String]
    public var statusRaw: String
    public var createdAt: Date
    public var updatedAt: Date

    /// Five-option cards (ANA-PLAN §13.3), schema v2.1.
    ///
    /// Optional, so SwiftData migrates existing cards with nothing to do —
    /// §10.4's "mevcut kartlar korunmalı" is satisfied by the shape rather than
    /// by a migration step. Stored as JSON instead of a related model because
    /// nothing ever queries an option outside its own card; a second entity
    /// would only add a cascade rule and a backup shape.
    public var optionsRaw: String?
    /// Index of the correct option within `options`. `nil` on a plain card.
    public var correctOptionIndex: Int?

    /// The card is in the deck, but something about it deserves a second look
    /// (§13.3 rule 6, docs/FAZ7-PLAN-coktan-secmeli.md §9).
    ///
    /// Faz 6 removed the approval gate, and §13.3 asks for one on suspicious
    /// questions. The compromise is this flag: the card is active and reviewable,
    /// and Bilgilerim lists it under "Gözden geçir" instead of a blocking queue.
    /// Defaulted rather than optional so existing cards migrate with nothing to
    /// decide.
    public var lowConfidence: Bool = false

    // Scheduling state. Faz 1 uses a placeholder scheduler; FSRS replaces the
    // algorithm in Faz 4 (§18) without changing these fields.
    public var dueDate: Date
    public var stability: Double
    public var difficulty: Double
    public var reviewCount: Int
    public var lapseCount: Int
    /// Early practice misses (docs/ADR-007): the card was answered wrong in
    /// Egzersiz well before it was due. Kept apart from `lapseCount` on
    /// purpose — failing a self-test taken too soon is not evidence of
    /// forgetting, so it must never feed the FSRS failure update. Defaulted so
    /// existing decks migrate with nothing to decide.
    public var softLapseCount: Int = 0
    /// When Egzersiz last touched this card's FSRS state (docs/ADR-007).
    /// Arms `EarlyPractice`'s one-day practice freeze, without which repeated
    /// same-evening passes would compound partial credit.
    public var lastPracticedAt: Date?
    public var lastReviewedAt: Date?

    public var knowledgeUnit: KnowledgeUnit?

    @Relationship(deleteRule: .cascade, inverse: \ReviewLog.card)
    public var reviews: [ReviewLog]

    public var type: CardType {
        get { CardType(rawValue: typeRaw) ?? .directRecall }
        set { typeRaw = newValue.rawValue }
    }

    public var status: CardStatus {
        get { CardStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    public var riskFlags: [RiskFlag] {
        get { riskFlagsRaw.compactMap(RiskFlag.init(rawValue:)) }
        set { riskFlagsRaw = newValue.map(\.rawValue) }
    }

    /// The card's options, or `nil` if it is not a sound five-option card.
    ///
    /// The getter validates rather than trusting storage: a half-written or
    /// hand-edited option list makes the card read as a plain one instead of
    /// rendering a question nobody can answer.
    public var options: [CardOption]? {
        get {
            guard type == .multipleChoice, let options = MultipleChoice.decode(optionsRaw) else { return nil }
            return options
        }
        set {
            guard let newValue, case .valid = MultipleChoice.validate(newValue) else {
                optionsRaw = nil
                correctOptionIndex = nil
                return
            }
            optionsRaw = MultipleChoice.encode(newValue)
            correctOptionIndex = MultipleChoice.correctIndex(newValue)
        }
    }

    public init(
        id: UUID = UUID(),
        type: CardType,
        front: String,
        back: String,
        explanation: String? = nil,
        sourceQuote: String? = nil,
        riskFlags: [RiskFlag] = [],
        status: CardStatus = .draft,
        createdAt: Date = .now,
        dueDate: Date = .now,
        options: [CardOption]? = nil,
        lowConfidence: Bool = false
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.front = front
        self.back = back
        self.explanation = explanation
        self.sourceQuote = sourceQuote
        self.riskFlagsRaw = riskFlags.map(\.rawValue)
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.dueDate = dueDate
        self.stability = 0
        self.difficulty = 0
        self.reviewCount = 0
        self.lapseCount = 0
        self.softLapseCount = 0
        self.reviews = []
        self.lowConfidence = lowConfidence
        if let options, case .valid = MultipleChoice.validate(options) {
            self.optionsRaw = MultipleChoice.encode(options)
            self.correctOptionIndex = MultipleChoice.correctIndex(options)
        }
    }
}

@Model
public final class ReviewLog {
    @Attribute(.unique) public var id: UUID
    public var reviewedAt: Date
    public var ratingRaw: String
    public var responseTimeMs: Int
    public var scheduledDays: Double
    public var elapsedDays: Double
    public var stabilityBefore: Double
    public var stabilityAfter: Double
    public var difficultyBefore: Double
    public var difficultyAfter: Double
    public var deviceTimeZone: String

    public var card: Card?

    public var rating: ReviewRating {
        get { ReviewRating(rawValue: ratingRaw) ?? .good }
        set { ratingRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        reviewedAt: Date = .now,
        rating: ReviewRating,
        responseTimeMs: Int,
        scheduledDays: Double,
        elapsedDays: Double,
        stabilityBefore: Double,
        stabilityAfter: Double,
        difficultyBefore: Double,
        difficultyAfter: Double,
        deviceTimeZone: String = TimeZone.current.identifier
    ) {
        self.id = id
        self.reviewedAt = reviewedAt
        self.ratingRaw = rating.rawValue
        self.responseTimeMs = responseTimeMs
        self.scheduledDays = scheduledDays
        self.elapsedDays = elapsedDays
        self.stabilityBefore = stabilityBefore
        self.stabilityAfter = stabilityAfter
        self.difficultyBefore = difficultyBefore
        self.difficultyAfter = difficultyAfter
        self.deviceTimeZone = deviceTimeZone
    }
}

/// Personal handwriting/abbreviation dictionary (§10.6). Used to rank
/// candidates, never to substitute text automatically.
@Model
public final class OCRCorrection {
    @Attribute(.unique) public var id: UUID
    public var observedText: String
    public var correctedText: String
    public var contextTags: [String]
    public var isCriticalToken: Bool
    public var useCount: Int
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        observedText: String,
        correctedText: String,
        contextTags: [String] = [],
        isCriticalToken: Bool = false
    ) {
        self.id = id
        self.observedText = observedText
        self.correctedText = correctedText
        self.contextTags = contextTags
        self.isCriticalToken = isCriticalToken
        self.useCount = 0
    }
}

/// Provider call accounting (§16.8). Content and OCR text are deliberately not
/// stored here (§22).
///
/// One row per real provider call, successes and failures alike. It used to be
/// written only on success, which made the total structurally incapable of
/// matching the provider's invoice: a generation that burns its whole output
/// budget and then fails costs exactly what a successful one costs, and there
/// were three separate ways for that to happen. Every new field below exists
/// to answer a question the old five could not.
@Model
public final class ModelRun {
    @Attribute(.unique) public var id: UUID
    public var requestId: String
    public var jobId: String
    /// Which attempt at `jobId` this was, as the server's job row counted them.
    ///
    /// The de-duplication key, with `jobId` and `purpose`: the server reports
    /// its whole ledger on every poll, and a page is polled many times, so
    /// without this one call would be recorded once per poll. Defaults to 0
    /// for rows written before per-attempt accounting existed.
    ///
    /// The `= 0` is load-bearing and belongs *here*, not only in `init`.
    /// SwiftData's lightweight migration never calls the initializer: it fills
    /// added columns from the property's own default, and a mandatory
    /// attribute without one aborts the migration — which means the app
    /// refuses to open at all, on a store it cannot repair. That is exactly
    /// what shipping this row without a default did.
    public var attempt: Int = 0
    public var provider: String
    public var model: String
    public var purpose: String
    public var promptVersion: String
    public var latencyMs: Int
    public var inputTokens: Int
    /// Share of `inputTokens` served from the provider's prompt cache — a
    /// subset, not an addition — billed at roughly a tenth of the usual rate.
    /// Defaulted for migration; see `attempt`.
    public var cachedInputTokens: Int = 0
    public var outputTokens: Int
    /// Share of `outputTokens` the model spent thinking rather than answering.
    /// A subset, like `cachedInputTokens`, and the most expensive tokens here.
    /// Defaulted for migration; see `attempt`.
    public var reasoningTokens: Int = 0
    public var estimatedCostUSD: Double
    public var success: Bool
    /// `measured`, `unmeasured` or `none` — see `CallAccounting.billing`.
    ///
    /// A cost of 0.00 is ambiguous without it: the call may have been rejected
    /// before generating (free) or aborted after generating (billed, amount
    /// unknowable). Only the first may be added into a total as zero; the
    /// second has to be counted separately or it hides the leak.
    ///
    /// Defaulted to `measured` for migration (see `attempt`), and that is the
    /// right value for the rows it backfills: before this field existed only
    /// successful calls were written, and every one of them carried real
    /// reported usage.
    public var billing: String = ModelRunBilling.measured
    /// Short machine-readable cause on a failed call: `timeout`,
    /// `incomplete_max_output_tokens`, `schema_invalid`, `worker_killed`, …
    public var failureReason: String?
    public var errorCategory: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        requestId: String,
        jobId: String,
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
        success: Bool,
        billing: String = ModelRunBilling.measured,
        failureReason: String? = nil,
        errorCategory: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.requestId = requestId
        self.jobId = jobId
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
        self.errorCategory = errorCategory
        self.createdAt = createdAt
    }
}


/// A free-practice session. It is deliberately separate from `ReviewLog` and
/// has no relationship to Card scheduling fields: Egzersiz history may inform
/// its own weak-point picker, but can never mutate FSRS by being saved.
@Model
public final class ExerciseRun {
    @Attribute(.unique) public var id: UUID
    public var modeRaw: String
    public var subject: String?
    /// The chosen `TopicFilter`, not a topic name — see `TopicFilter.
    /// storageValue`. Storing the name alone cannot tell "Konusuz" apart from
    /// "no topic filter", and restoring into the wrong one changes which cards
    /// the resumed session covers.
    ///
    /// `originalName` because this property used to be called `topic`. Without
    /// it lightweight migration reads the rename as "drop one column, add an
    /// empty one", so a device that ran an earlier build of this work would
    /// resume its in-flight run with the topic filter silently widened to
    /// "Tümü". Legacy rows carried a bare topic name, which is already the
    /// right storage value; a legacy `nil` still cannot say whether the user
    /// had picked "Tümü" or "Konusuz", but that ambiguity is exactly the bug
    /// this rename fixes and no migration can recover it after the fact.
    @Attribute(originalName: "topic") public var topicFilterRaw: String?
    /// String UUIDs keep the exact shuffled order durable across relaunches.
    public var queuedCardIds: [String]
    public var position: Int
    public var startedAt: Date
    public var finishedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseAttempt.run)
    public var attempts: [ExerciseAttempt]

    public var mode: ExerciseMode {
        get { ExerciseMode(rawValue: modeRaw) ?? .free }
        set { modeRaw = newValue.rawValue }
    }

    public var topicFilter: TopicFilter {
        get { TopicFilter.fromStorage(topicFilterRaw) }
        set { topicFilterRaw = newValue.storageValue }
    }

    public init(
        id: UUID = UUID(),
        mode: ExerciseMode,
        subject: String? = nil,
        topicFilter: TopicFilter = .all,
        queuedCardIds: [UUID],
        position: Int = 0,
        startedAt: Date = .now,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.modeRaw = mode.rawValue
        self.subject = subject
        self.topicFilterRaw = topicFilter.storageValue
        self.queuedCardIds = queuedCardIds.map(\.uuidString)
        self.position = position
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempts = []
    }

    public var queue: [UUID] {
        queuedCardIds.compactMap(UUID.init(uuidString:))
    }
}

@Model
public final class ExerciseAttempt {
    @Attribute(.unique) public var id: UUID
    public var cardId: UUID
    public var resultRaw: String
    public var selectedOption: Int?
    public var responseTimeMs: Int
    public var answeredAt: Date
    public var run: ExerciseRun?

    public var result: ExerciseResult {
        get { ExerciseResult(rawValue: resultRaw) ?? .unsure }
        set { resultRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        cardId: UUID,
        result: ExerciseResult,
        selectedOption: Int? = nil,
        responseTimeMs: Int,
        answeredAt: Date = .now
    ) {
        self.id = id
        self.cardId = cardId
        self.resultRaw = result.rawValue
        self.selectedOption = selectedOption
        self.responseTimeMs = responseTimeMs
        self.answeredAt = answeredAt
    }
}

public enum CizgiSchema {
    /// Every model type, for `ModelContainer(for:)`.
    public static let allModels: [any PersistentModel.Type] = [
        Source.self,
        CapturedPage.self,
        TextRegion.self,
        KnowledgeUnit.self,
        Card.self,
        ReviewLog.self,
        OCRCorrection.self,
        ModelRun.self,
        ExerciseRun.self,
        ExerciseAttempt.self
    ]
}
