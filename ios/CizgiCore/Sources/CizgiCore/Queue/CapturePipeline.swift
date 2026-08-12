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
    /// The server's own description of what went wrong, verbatim.
    ///
    /// The classification in `failure` is a retry policy, not a diagnosis, and
    /// it was the only thing surviving the trip to the screen: an aborted
    /// generation that burned its whole output budget, a job still running
    /// happily on the server, an exhausted API quota and a dropped Wi-Fi
    /// connection all arrived as one sentence — "Sağlayıcıya ulaşılamadı" —
    /// so no one could tell which failures had cost money. The server always
    /// knew and always said; this is where its words stopped being discarded.
    public let failureDetail: String?
    /// Provider call accounting for this run (§16.8).
    ///
    /// Carried on the outcome — rather than left inside `knowledge` — because
    /// a *failed* run has no knowledge to reach into and is exactly the case
    /// worth recording: the call still happened and still cost money. Plural
    /// because one page can take several attempts, all of them billed.
    public let modelRuns: [ModelRunMetadata]

    public init(
        jobId: String,
        finalState: ProcessingState,
        selection: MarkerSelectionResult = MarkerSelectionResult(),
        annotationGroups: [AnnotationGroup] = [],
        passage: String? = nil,
        knowledge: GeneratedKnowledge? = nil,
        generatedGroups: [GeneratedAnnotationGroup] = [],
        failure: FailureKind? = nil,
        failureDetail: String? = nil,
        modelRuns: [ModelRunMetadata] = []
    ) {
        self.jobId = jobId
        self.finalState = finalState
        self.selection = selection
        self.annotationGroups = annotationGroups
        self.passage = passage
        self.knowledge = knowledge
        self.generatedGroups = generatedGroups
        self.failure = failure
        self.failureDetail = failureDetail
        self.modelRuns = modelRuns
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
        } catch let failure as CardGenerationFailure {
            // The real provider's error: it carries the ledger of what the
            // failed attempt — and every attempt before it — already spent, so
            // a page that never succeeds still records its cost.
            return Self.failed(jobId: jobId, error: failure.error, accounting: failure.accounting)
        } catch let error as CardGenerationError {
            // A bare case: the offline stand-in and the tests throw these, and
            // they have nothing to account for.
            return Self.failed(jobId: jobId, error: error, accounting: [])
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
            modelRuns: knowledge.modelRuns
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

    /// The one place a generation error becomes an outcome, so the two throw
    /// sites cannot disagree about the classification or drop the ledger.
    static func failed(
        jobId: String,
        error: CardGenerationError,
        accounting: [ModelRunMetadata]
    ) -> PipelineOutcome {
        let detail = Self.detail(of: error)
        if case .sourceInsufficient = error {
            // The model found nothing markable to build a card from. Faz 6 has
            // no confirmation lane, so this is a terminal "couldn't make cards
            // from this page" rather than a bounce to the user. It is also a
            // *paid* outcome — the model read the whole page to decide it — so
            // the accounting travels with it like every other failure.
            // No detail: `.noContent`'s own sentence already says the useful
            // thing ("nothing marked on this page"), and the server's wording
            // for it is an internal one.
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                failure: .noContent,
                modelRuns: accounting
            )
        }
        let kind = FailureDiagnosis.refine(
            Self.failureKind(for: error),
            using: accounting.last?.failureReason
        )
        return PipelineOutcome(
            jobId: jobId,
            finalState: kind.resultingState,
            failure: kind,
            failureDetail: detail,
            modelRuns: accounting
        )
    }

    /// The message the error is carrying, or nil when it has nothing to add.
    /// The trimming rule itself lives in `FailureDiagnosis`, which is where it
    /// is tested.
    static func detail(of error: CardGenerationError) -> String? {
        switch error {
        case .schemaInvalid(let message), .providerUnavailable(let message):
            return FailureDiagnosis.detail(message)
        case .budgetExceeded, .sourceInsufficient:
            return nil
        }
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
