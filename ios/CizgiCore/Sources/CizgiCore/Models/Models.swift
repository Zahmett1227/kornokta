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

    // Scheduling state. Faz 1 uses a placeholder scheduler; FSRS replaces the
    // algorithm in Faz 4 (§18) without changing these fields.
    public var dueDate: Date
    public var stability: Double
    public var difficulty: Double
    public var reviewCount: Int
    public var lapseCount: Int
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
        dueDate: Date = .now
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
        self.reviews = []
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
@Model
public final class ModelRun {
    @Attribute(.unique) public var id: UUID
    public var requestId: String
    public var jobId: String
    public var provider: String
    public var model: String
    public var purpose: String
    public var promptVersion: String
    public var latencyMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCostUSD: Double
    public var success: Bool
    public var errorCategory: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        requestId: String,
        jobId: String,
        provider: String,
        model: String,
        purpose: String,
        promptVersion: String,
        latencyMs: Int,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double,
        success: Bool,
        errorCategory: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.requestId = requestId
        self.jobId = jobId
        self.provider = provider
        self.model = model
        self.purpose = purpose
        self.promptVersion = promptVersion
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.success = success
        self.errorCategory = errorCategory
        self.createdAt = createdAt
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
        ModelRun.self
    ]
}
