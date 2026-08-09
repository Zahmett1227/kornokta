import Foundation

/// Cards produced for one grounded visual group. Multiple annotations on a
/// page remain separate knowledge units all the way to persistence.
public struct GeneratedAnnotationGroup: Sendable, Equatable {
    public let group: AnnotationGroup
    public let knowledge: GeneratedKnowledge

    public init(group: AnnotationGroup, knowledge: GeneratedKnowledge) {
        self.group = group
        self.knowledge = knowledge
    }
}

/// What one pipeline run produced. Returned rather than written directly so the
/// pipeline stays free of SwiftData and can be tested without a store.
///
/// The OCR-era fields (`recognized`, `ocrSnapshot`, `reconciliation`,
/// `confirmationReason`, …) left with the deterministic pipeline (ADR-005 trim,
/// 2026-08-09); the vision flow fills exactly what is here.
public struct PipelineOutcome: Sendable, Equatable {
    public let jobId: String
    public let finalState: ProcessingState
    /// Structured visual selection. In the vision flow this is always the one
    /// synthetic full-page group.
    public let selection: MarkerSelectionResult
    public let annotationGroups: [AnnotationGroup]
    public let passage: String?
    public let knowledge: GeneratedKnowledge?
    public let generatedGroups: [GeneratedAnnotationGroup]
    public let failure: FailureKind?
    /// Provider call accounting for this run's card generation (§16.8), when
    /// the generator made one. Mirrors `knowledge.modelRun` — carried on the
    /// outcome too so the caller can persist it without reaching back into
    /// `knowledge`.
    public let modelRun: ModelRunMetadata?

    public init(
        jobId: String,
        finalState: ProcessingState,
        selection: MarkerSelectionResult = MarkerSelectionResult(),
        annotationGroups: [AnnotationGroup] = [],
        passage: String? = nil,
        knowledge: GeneratedKnowledge? = nil,
        generatedGroups: [GeneratedAnnotationGroup] = [],
        failure: FailureKind? = nil,
        modelRun: ModelRunMetadata? = nil
    ) {
        self.jobId = jobId
        self.finalState = finalState
        self.selection = selection
        self.annotationGroups = annotationGroups
        self.passage = passage
        self.knowledge = knowledge
        self.generatedGroups = generatedGroups
        self.failure = failure
        self.modelRun = modelRun
    }
}

/// Drives one captured page through the Faz 6 vision pipeline
/// (docs/FAZ6-PLAN.md §2): the marked full page goes straight to the card
/// endpoint and the model reads what the student marked itself.
///
/// The pre-Faz-6 steps — local OCR, marker detection, cloud OCR, grounding, the
/// confirmation gate — were removed from the codebase entirely (ADR-005 trim,
/// 2026-08-09); restoring that path means reverting the trim commit, not
/// flipping a switch.
public struct CapturePipeline: Sendable {
    private let generator: any CardGenerating
    private let maxCards: Int
    private let multipleChoiceMode: MultipleChoiceMode?

    public init(
        generator: any CardGenerating = MockCardProvider(),
        maxCards: Int = 4,
        multipleChoiceMode: MultipleChoiceMode? = nil
    ) {
        self.generator = generator
        self.maxCards = maxCards
        self.multipleChoiceMode = multipleChoiceMode
    }

    /// Same pipeline with a different card generator — how real generation
    /// (§25) replaces `MockCardProvider` once a backend is configured.
    public func withGenerator(_ generator: any CardGenerating) -> CapturePipeline {
        CapturePipeline(generator: generator, maxCards: maxCards, multipleChoiceMode: multipleChoiceMode)
    }

    /// Same pipeline with a different card ceiling, so the user's "cards per
    /// passage" setting reaches the generator instead of the built-in default
    /// (§6.7, §13.2). Clamped because a non-positive limit would silently
    /// produce a page that generates nothing.
    public func withMaxCards(_ maxCards: Int) -> CapturePipeline {
        CapturePipeline(generator: generator, maxCards: max(1, maxCards), multipleChoiceMode: multipleChoiceMode)
    }

    /// Ayarlar's five-option setting (§13.3), carried the same way `maxCards`
    /// is — the pipeline is rebuilt rather than mutated so a request already in
    /// flight keeps the settings it started with.
    public func withMultipleChoiceMode(_ mode: MultipleChoiceMode?) -> CapturePipeline {
        CapturePipeline(generator: generator, maxCards: maxCards, multipleChoiceMode: mode)
    }

    /// Faz 6 vision flow: full marked page → card endpoint → cards.
    public func run(
        jobId: String,
        imageURL: URL,
        subject: String? = nil,
        /// Set only when the user asked for this run themselves ("Tekrar
        /// dene"), never by the queue's own retries — see
        /// `CardGenerationRequest.forceResubmit`.
        forceResubmit: Bool = false
    ) async -> PipelineOutcome {
        let upload: PreparedUpload
        do {
            upload = try Self.prepareUpload(imageURL: imageURL)
        } catch {
            // The page bytes could not be read/encoded — not worth retrying.
            return PipelineOutcome(jobId: jobId, finalState: .permanentFailure, failure: .configuration)
        }

        let knowledge: GeneratedKnowledge
        do {
            knowledge = try await generator.generate(
                CardGenerationRequest(
                    jobId: jobId,
                    // No OCR passage in vision mode; the real generator reads
                    // the image. `MockCardProvider` (offline stand-in) needs a
                    // passage, so offline it returns `sourceInsufficient` here —
                    // Faz 6 expects a configured backend.
                    passage: "",
                    subject: subject,
                    maxCards: maxCards,
                    imageData: upload.data,
                    mimeType: upload.mimeType,
                    multipleChoiceMode: multipleChoiceMode,
                    forceResubmit: forceResubmit
                )
            )
        } catch let error as CardGenerationError {
            if case .sourceInsufficient = error {
                // The model found nothing markable to build a card from. Faz 6
                // has no confirmation lane, so this is a terminal "couldn't make
                // cards from this page" rather than a bounce to the user.
                return PipelineOutcome(jobId: jobId, finalState: .permanentFailure, failure: .noContent)
            }
            let kind = Self.failureKind(for: error)
            return PipelineOutcome(jobId: jobId, finalState: kind.resultingState, failure: kind)
        } catch {
            return PipelineOutcome(jobId: jobId, finalState: .temporaryFailure, failure: .providerUnavailable)
        }

        guard !knowledge.cards.isEmpty else {
            // A well-formed response carrying no cards is not a broken one; the
            // page simply had nothing marked on it (§21.2 — say what happened).
            return PipelineOutcome(jobId: jobId, finalState: .permanentFailure, failure: .noContent)
        }

        // The whole marked page is one implicit unit. A synthetic full-page
        // group carries it to `ProcessingQueue.persist`, which still builds one
        // TextRegion + KnowledgeUnit + cards from a `GeneratedAnnotationGroup`
        // exactly as before — only now the "region" is the page itself.
        let group = Self.fullPageGroup(jobId: jobId, knowledge: knowledge)
        let generated = GeneratedAnnotationGroup(group: group, knowledge: knowledge)
        return PipelineOutcome(
            jobId: jobId,
            finalState: .ready,
            selection: MarkerSelectionResult(groups: [group], autoSelectedGroupIds: [group.id]),
            annotationGroups: [group],
            passage: knowledge.canonicalClaim,
            knowledge: knowledge,
            generatedGroups: [generated],
            modelRun: knowledge.modelRun
        )
    }

    /// The one full-page group that stands in for the pre-Faz-6 marker
    /// grouping: its box is the whole page, its text is the model's read text
    /// (carried as the knowledge's canonical claim), and it needs no
    /// confirmation.
    static func fullPageGroup(jobId: String, knowledge: GeneratedKnowledge) -> AnnotationGroup {
        let id = "vision_\(jobId)"
        return AnnotationGroup(
            id: id,
            evidenceIds: [id],
            selectedLineIds: [],
            contextLineIds: [],
            selectedTokenIds: [],
            contextTokenIds: [],
            handwrittenNoteIds: [],
            boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            parentHeading: nil,
            layoutKind: .unknown,
            confidence: 1,
            needsConfirmation: false,
            selectionType: .manual,
            selectedText: knowledge.canonicalClaim,
            contextText: knowledge.canonicalClaim,
            handwrittenNotes: []
        )
    }

    /// Single mapping from a generator error to the retry classification.
    static func failureKind(for error: CardGenerationError) -> FailureKind {
        switch error {
        case .budgetExceeded: return .budgetExceeded
        // A response that violates the contract will violate it again on replay.
        case .schemaInvalid: return .invalidResponse
        case .providerUnavailable: return .providerUnavailable
        case .sourceInsufficient: return .noContent
        }
    }

    /// Downscaled before sending: a full-resolution scan base64s to more than a
    /// serverless host will accept, and the platform rejects it before our own
    /// endpoint can say why (see `UploadImageEncoder`).
    private static func prepareUpload(imageURL: URL) throws -> PreparedUpload {
        try UploadImageEncoder.prepare(
            contentsOf: imageURL,
            mimeType: Self.mimeType(for: imageURL)
        )
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        default: return "image/jpeg"
        }
    }
}
