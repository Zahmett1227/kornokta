import Foundation
import CoreGraphics

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
/// Faz 6 note (docs/FAZ6-PLAN.md): the vision flow only ever fills `jobId`,
/// `finalState`, `passage`, `knowledge`, `generatedGroups`, `modelRun` (on
/// success) or `finalState`/`failure` (on error). The OCR-era fields
/// (`recognized`, `selection`, `ocrSnapshot`, `reconciliation`,
/// `confirmationReason`, …) are kept on the type so `ProcessingQueue` and the
/// retained pre-Faz-6 code still compile, but the main flow no longer produces
/// them.
public struct PipelineOutcome: Sendable, Equatable {
    public let jobId: String
    public let finalState: ProcessingState
    public let recognized: RecognizedPage?
    public let selectedLineIds: [String]
    /// Structured visual selection, retained through confirmation instead of
    /// collapsing it into line ids at the detector boundary.
    public let selection: MarkerSelectionResult
    public let annotationGroups: [AnnotationGroup]
    /// Local, device-only checkpoint used to resume a confirmation without a
    /// second Vision or Document AI run.
    public let ocrSnapshot: OCRSnapshot?
    public let passage: String?
    public let knowledge: GeneratedKnowledge?
    public let generatedGroups: [GeneratedAnnotationGroup]
    public let failure: FailureKind?
    /// What the backend concluded about the two readings, when there was one.
    ///
    /// Carried through so the confirmation screen can say *what* disagreed
    /// rather than just asking the user to look again — the pre-Faz-6 flow
    /// required the confirmation, and a confirmation with no reason attached is
    /// one the user cannot answer well.
    public let reconciliation: RemoteReconciliation?
    /// Why this run stopped at `confirmationRequired`, in the pipeline's own
    /// words. Unused by the Faz 6 vision flow (which never stops for
    /// confirmation); retained for the rollback path.
    public let confirmationReason: String?
    /// Provider call accounting for this run's card generation (§16.8), when
    /// the generator made one. Mirrors `knowledge.modelRun` — carried on the
    /// outcome too so the caller can persist it without reaching back into
    /// `knowledge`.
    public let modelRun: ModelRunMetadata?

    public init(
        jobId: String,
        finalState: ProcessingState,
        recognized: RecognizedPage? = nil,
        selectedLineIds: [String] = [],
        selection: MarkerSelectionResult = MarkerSelectionResult(),
        annotationGroups: [AnnotationGroup] = [],
        ocrSnapshot: OCRSnapshot? = nil,
        passage: String? = nil,
        knowledge: GeneratedKnowledge? = nil,
        generatedGroups: [GeneratedAnnotationGroup] = [],
        failure: FailureKind? = nil,
        reconciliation: RemoteReconciliation? = nil,
        confirmationReason: String? = nil,
        modelRun: ModelRunMetadata? = nil
    ) {
        self.jobId = jobId
        self.finalState = finalState
        self.recognized = recognized
        self.selectedLineIds = selectedLineIds
        self.selection = selection
        self.annotationGroups = annotationGroups
        self.ocrSnapshot = ocrSnapshot
        self.passage = passage
        self.knowledge = knowledge
        self.generatedGroups = generatedGroups
        self.failure = failure
        self.reconciliation = reconciliation
        self.confirmationReason = confirmationReason
        self.modelRun = modelRun
    }
}

/// Chooses which recognized lines the user marked.
///
/// Retained from the pre-Faz-6 flow (docs/ADR-005 rollback). The Faz 6 vision
/// pipeline does not use a selector — the model reads the marked content off
/// the page itself — but the seam and its two stand-ins stay on disk so the
/// deterministic path can be restored.
public protocol MarkerSelecting: Sendable {
    func select(in page: RecognizedPage, imageURL: URL) async throws -> MarkerSelectionResult
}

/// Selects nothing. Honest default for the retained deterministic path: a
/// capture with no detected marker and no manual selection must not become a
/// card (§19.3).
public struct ManualSelectionOnly: MarkerSelecting {
    public init() {}
    public func select(in page: RecognizedPage, imageURL: URL) async throws -> MarkerSelectionResult {
        MarkerSelectionResult()
    }
}

/// Selects the lines whose ids are given. Used by the retained confirmation
/// path when the user taps a passage, and by tests.
public struct FixedSelection: MarkerSelecting {
    public let lineIds: [String]
    public init(lineIds: [String]) { self.lineIds = lineIds }
    public func select(in page: RecognizedPage, imageURL: URL) async throws -> MarkerSelectionResult {
        let lines = page.lines.filter { lineIds.contains($0.id) }
        guard let first = lines.first else { return MarkerSelectionResult() }
        let box = lines.map { NormalizedRect($0.box) }.reduce(NormalizedRect(first.box)) { $0.union($1) }
        let ids = lines.map(\.id)
        let tokenIds = lines.flatMap { $0.tokens.map(\.id) }
        let evidence = AnnotationEvidence(
            id: "manual_\(ids.joined(separator: "_"))",
            type: .manual,
            boundingBox: box,
            lineIds: ids,
            tokenIds: tokenIds,
            confidence: 1,
            decision: .autoCandidate
        )
        let group = AnnotationGroup(
            id: "manual_group",
            evidenceIds: [evidence.id],
            selectedLineIds: ids,
            contextLineIds: ids,
            selectedTokenIds: tokenIds,
            boundingBox: box,
            confidence: 1,
            needsConfirmation: false,
            selectionType: .manual
        )
        return MarkerSelectionResult(evidence: [evidence], groups: [group], autoSelectedGroupIds: [group.id])
    }
}

/// Drives one captured page through the Faz 6 vision pipeline
/// (docs/FAZ6-PLAN.md §2): the marked full page goes straight to
/// `/api/cards-vision` and the model reads what the student marked itself.
///
/// The pre-Faz-6 steps — local OCR, marker detection, cloud OCR, grounding, the
/// confirmation gate — are gone from the main flow. Their modules stay on disk
/// for ADR-005's rollback (`documentAI`/`reconcile`/`MarkerDetection`/
/// `Annotation`/`Confirmation`). The struct keeps its old shape (a recognizer,
/// a selector, an optional backend, the builders) so the queue and the retained
/// code still compile and a rollback can rewire them; the vision `run` simply
/// does not consult them.
public struct CapturePipeline: Sendable {
    private let recognizer: any TextRecognizing
    private let selector: any MarkerSelecting
    private let generator: any CardGenerating
    private let maxCards: Int
    private let multipleChoiceMode: MultipleChoiceMode?
    /// Cloud OCR seam, retained for the rollback path. The vision flow does not
    /// use it (the card endpoint reads the page itself).
    private let backend: (any BackendCalling)?

    public init(
        recognizer: any TextRecognizing,
        selector: any MarkerSelecting = ManualSelectionOnly(),
        generator: any CardGenerating = MockCardProvider(),
        maxCards: Int = 4,
        multipleChoiceMode: MultipleChoiceMode? = nil,
        backend: (any BackendCalling)? = nil
    ) {
        self.recognizer = recognizer
        self.selector = selector
        self.generator = generator
        self.maxCards = maxCards
        self.multipleChoiceMode = multipleChoiceMode
        self.backend = backend
    }

    /// Same pipeline with cloud OCR attached (retained seam).
    public func withBackend(_ backend: (any BackendCalling)?) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
            multipleChoiceMode: multipleChoiceMode,
            backend: backend
        )
    }

    /// Same pipeline with a different line selector (retained seam).
    public func withSelector(_ selector: any MarkerSelecting) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
            multipleChoiceMode: multipleChoiceMode,
            backend: backend
        )
    }

    /// Same pipeline with a different card generator — how real generation
    /// (§25) replaces `MockCardProvider` once a backend is configured.
    public func withGenerator(_ generator: any CardGenerating) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
            multipleChoiceMode: multipleChoiceMode,
            backend: backend
        )
    }

    /// Same pipeline with a different card ceiling, so the user's "cards per
    /// passage" setting reaches the generator instead of the built-in default
    /// (§6.7, §13.2). Clamped because a non-positive limit would silently
    /// produce a page that generates nothing.
    public func withMaxCards(_ maxCards: Int) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: max(1, maxCards),
            multipleChoiceMode: multipleChoiceMode,
            backend: backend
        )
    }

    /// Ayarlar's five-option setting (§13.3), carried the same way `maxCards`
    /// is — the pipeline is rebuilt rather than mutated so a request already in
    /// flight keeps the settings it started with.
    public func withMultipleChoiceMode(_ mode: MultipleChoiceMode?) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
            multipleChoiceMode: mode,
            backend: backend
        )
    }

    /// Faz 6 vision flow: full marked page → `/api/cards-vision` → cards.
    ///
    /// The OCR-era parameters (`snapshot`, `selectionOverride`,
    /// `selectionResultOverride`, `completedGroupIds`) are accepted but ignored,
    /// so `ProcessingQueue` and the retained pre-Faz-6 code still call the same
    /// signature. There is no local OCR, marker detection, grounding or
    /// confirmation gate any more: the model reads the marked content itself and
    /// the cards go straight to the active deck (`ProcessingQueue.apply`'s
    /// `.ready` path persists them, `requiresUserApproval` is always false).
    public func run(
        jobId: String,
        imageURL: URL,
        subject: String? = nil,
        snapshot: OCRSnapshot? = nil,
        selectionOverride: [String]? = nil,
        selectionResultOverride: MarkerSelectionResult? = nil,
        completedGroupIds: [String] = []
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
                    multipleChoiceMode: multipleChoiceMode
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

    /// `TextRegion` predates a first-class annotation-group id. Its stable
    /// evidence set is therefore the persistence identity used to skip work
    /// that succeeded before a later group failed.
    static func persistenceKey(for group: AnnotationGroup) -> String {
        group.evidenceIds.sorted().joined(separator: ":")
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

    /// Fraction of the smaller box that has to be covered for two boxes to be
    /// the same line. Retained helper (used by the rollback path and tests).
    static let lineOverlapThreshold = 0.3

    static func overlaps(box: CGRect, x: Double, y: Double, width: Double, height: Double) -> Bool {
        let other = CGRect(x: x, y: y, width: width, height: height)
        let intersection = box.intersection(other)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return false
        }
        let smaller = min(box.width * box.height, other.width * other.height)
        guard smaller > 0 else { return false }
        return Double(intersection.width * intersection.height) / Double(smaller) >= lineOverlapThreshold
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

    private static func groupPassage(_ group: AnnotationGroup) -> String {
        let context = group.contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { return context }
        return group.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins the selected lines in page order, so a passage reads the way it
    /// does on the page rather than in tap order. Retained helper (rollback +
    /// the retained confirmation UI).
    static func passage(from page: RecognizedPage, lineIds: [String]) -> String {
        let wanted = Set(lineIds)
        return page.lines
            .filter { wanted.contains($0.id) }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
