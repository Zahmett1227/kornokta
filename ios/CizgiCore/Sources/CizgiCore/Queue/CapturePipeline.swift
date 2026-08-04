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
    /// rather than just asking the user to look again — §19.2 requires the
    /// confirmation, and a confirmation with no reason attached is one the
    /// user cannot answer well.
    public let reconciliation: RemoteReconciliation?
    /// Why this run stopped at `confirmationRequired`, in the pipeline's own
    /// words.
    ///
    /// `reconciliation?.reason` only covers the OCR-disagreement case. A run
    /// that stopped because nothing was marked, a group's passage came back
    /// empty, or card generation produced nothing usable has nothing to do
    /// with OCR disagreement — reusing that field there left the screen with
    /// no explanation at all (§19.2: a confirmation with no reason is one the
    /// user cannot answer).
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
/// Faz 1 has no real marker detection on device yet — the algorithm was
/// prototyped in `evals/spikes/marker_detection` and lands in Faz 2 (§25). Until
/// then this seam lets the pipeline run with an explicit selection, and makes
/// the missing step visible instead of silently selecting everything.
public protocol MarkerSelecting: Sendable {
    func select(in page: RecognizedPage, imageURL: URL) async throws -> MarkerSelectionResult
}

/// Selects nothing, so a capture stops at `confirmationRequired` and the user
/// picks the passage by hand. Honest default for Faz 1: §19.3 says a capture
/// with no detected marker and no manual selection must not become a card.
public struct ManualSelectionOnly: MarkerSelecting {
    public init() {}
    public func select(in page: RecognizedPage, imageURL: URL) async throws -> MarkerSelectionResult {
        MarkerSelectionResult()
    }
}

/// Selects the lines whose ids are given. Used by the confirmation screen when
/// the user taps a passage, and by tests.
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

/// Drives one captured page through the pipeline (ANA-PLAN §17).
///
/// Every step is re-runnable: the pipeline reports what it produced and the
/// caller decides what to persist, so replaying a job cannot create a second
/// set of cards.
public struct CapturePipeline: Sendable {
    private let recognizer: any TextRecognizing
    private let selector: any MarkerSelecting
    private let generator: any CardGenerating
    private let maxCards: Int
    /// Cloud OCR. Optional because the app must still work with no backend
    /// configured — capture and local OCR do not depend on it (§24.1).
    private let backend: (any BackendCalling)?

    public init(
        recognizer: any TextRecognizing,
        selector: any MarkerSelecting = ManualSelectionOnly(),
        generator: any CardGenerating = MockCardProvider(),
        maxCards: Int = 4,
        backend: (any BackendCalling)? = nil
    ) {
        self.recognizer = recognizer
        self.selector = selector
        self.generator = generator
        self.maxCards = maxCards
        self.backend = backend
    }

    /// Same pipeline with cloud OCR attached.
    public func withBackend(_ backend: (any BackendCalling)?) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
            backend: backend
        )
    }

    /// Same pipeline with a different line selector. The confirmation screen
    /// uses this to resume a job with the passage the user picked.
    public func withSelector(_ selector: any MarkerSelecting) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
            backend: backend
        )
    }

    /// Same pipeline with a different card generator — how real generation
    /// (§25 Faz 3) replaces `MockCardProvider` once a backend is configured,
    /// mirroring `withBackend`.
    public func withGenerator(_ generator: any CardGenerating) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards,
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
            backend: backend
        )
    }

    public func run(
        jobId: String,
        imageURL: URL,
        subject: String? = nil,
        snapshot: OCRSnapshot? = nil,
        selectionOverride: [String]? = nil,
        selectionResultOverride: MarkerSelectionResult? = nil,
        completedGroupIds: [String] = []
    ) async -> PipelineOutcome {
        let recognized: RecognizedPage
        if let snapshot {
            recognized = snapshot.recognizedPage
        } else {
            do {
                recognized = try await recognizer.recognize(imageAt: imageURL)
            } catch {
                return PipelineOutcome(jobId: jobId, finalState: .permanentFailure, failure: .configuration)
            }
        }

        guard !recognized.lines.isEmpty else {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                recognized: recognized,
                failure: .invalidResponse
            )
        }

        let initialSelection: MarkerSelectionResult
        if let selectionResultOverride {
            initialSelection = selectionResultOverride
        } else if let selectionOverride {
            do {
                initialSelection = try await FixedSelection(lineIds: selectionOverride).select(
                    in: recognized,
                    imageURL: imageURL
                )
            } catch {
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .temporaryFailure,
                    recognized: recognized,
                    failure: .providerUnavailable
                )
            }
        } else if let snapshot {
            initialSelection = snapshot.selection
        } else {
            do {
                initialSelection = try await selector.select(in: recognized, imageURL: imageURL)
            } catch {
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .temporaryFailure,
                    recognized: recognized,
                    failure: .providerUnavailable
                )
            }
        }

        // Cloud OCR is a page-level operation and happens before deciding
        // whether marker confidence needs confirmation. That lets the photo UI
        // resume from the exact primary OCR snapshot instead of paying for a
        // second call after a user tap.
        var remote = snapshot?.remote
        var upload: PreparedUpload?
        if let backend {
            if remote == nil {
                do {
                    let reading = try await Self.cloudReading(
                        backend: backend,
                        jobId: jobId,
                        imageURL: imageURL,
                        recognized: recognized
                    )
                    remote = reading.remote
                    upload = reading.upload
                } catch let error as BackendError {
                    return Self.outcome(
                        for: error,
                        jobId: jobId,
                        recognized: recognized,
                        selection: initialSelection
                    )
                } catch {
                    return PipelineOutcome(
                        jobId: jobId,
                        finalState: .temporaryFailure,
                        recognized: recognized,
                        selectedLineIds: initialSelection.selectedLineIds,
                        selection: initialSelection,
                        failure: .providerUnavailable
                    )
                }
            } else {
                // OCR is already complete, but the card endpoint still needs
                // the page bytes. Rebuild only this local upload on resume;
                // never pay for or alter the persisted OCR snapshot again.
                do {
                    upload = try Self.prepareUpload(imageURL: imageURL)
                } catch {
                    return PipelineOutcome(
                        jobId: jobId,
                        finalState: .temporaryFailure,
                        recognized: recognized,
                        selectedLineIds: initialSelection.selectedLineIds,
                        selection: initialSelection,
                        ocrSnapshot: snapshot,
                        failure: .providerUnavailable
                    )
                }
            }
        } else if snapshot?.remote != nil {
            // A confirmation can outlive a Settings change or an app
            // relaunch. In that case the saved cloud OCR is still valid, but
            // a real card provider must not be invoked without the original
            // page bytes. Recreate the derived upload even though this run no
            // longer has a cloud-OCR client attached.
            do {
                upload = try Self.prepareUpload(imageURL: imageURL)
            } catch {
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .temporaryFailure,
                    recognized: recognized,
                    selectedLineIds: initialSelection.selectedLineIds,
                    selection: initialSelection,
                    ocrSnapshot: snapshot,
                    failure: .providerUnavailable
                )
            }
        }

        // Loaded independently of `selector`'s own copy: it is a static
        // bundled resource (same file, no divergence risk), and grounding
        // needs the highlighter hue/saturation/value gate for Google's
        // `backgroundColor` style candidates (`RemoteAnnotationCandidateBuilder`).
        // A load failure here (should not happen in practice) only means this
        // run skips backgroundColor-based candidates, not a crash — no
        // invented substitute numbers, just a graceful skip of that one
        // feature (§0.6).
        let markerConfig = try? MarkerConfig.bundled()
        let groundedSelection = AnnotationGrouper.ground(
            selection: initialSelection,
            localPage: recognized,
            remotePage: remote?.page,
            discoverHandwriting: selectionResultOverride == nil,
            config: markerConfig
        )
        let selection: MarkerSelectionResult
        if selectionResultOverride != nil {
            let confirmedGroups = groundedSelection.groups.map { $0.markedConfirmed() }
            selection = MarkerSelectionResult(
                evidence: groundedSelection.evidence,
                groups: confirmedGroups,
                autoSelectedGroupIds: confirmedGroups.map(\.id)
            )
        } else {
            selection = groundedSelection
        }
        let checkpoint = OCRSnapshot(
            localLines: recognized.lines.map(LocalLine.init),
            remote: remote,
            selection: selection,
            userConfirmed: selectionResultOverride != nil || snapshot?.userConfirmed == true
        )
        let selectedGroups = selection.groups.filter {
            selection.autoSelectedGroupIds.contains($0.id)
                && !completedGroupIds.contains(Self.persistenceKey(for: $0))
        }
        // Preserve the caller-facing local ids for compatibility and UI
        // selection. Grounded groups retain their separate primary OCR ids.
        let selectedLineIds = initialSelection.selectedLineIds
        let firstPassage = selectedGroups.first.map { Self.groupPassage($0) }

        guard !selection.groups.isEmpty else {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized,
                selection: selection,
                ocrSnapshot: checkpoint,
                reconciliation: remote?.reconciliation,
                confirmationReason: "Sayfada işaretli bir bölge bulunamadı. Fotoğrafta bir alana dokun veya "
                    + "'Manuel alan ekle' ile kendin çiz."
            )
        }

        guard !selection.needsConfirmation, !selectedGroups.isEmpty else {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized,
                selectedLineIds: selectedLineIds,
                selection: selection,
                annotationGroups: selection.groups,
                ocrSnapshot: checkpoint,
                passage: firstPassage,
                reconciliation: remote?.reconciliation,
                confirmationReason: selection.needsConfirmation
                    ? "Bazı işaretli bölgeler için onayın gerekiyor. Turuncu kesikli çerçeveli bölgelere dokunup gözden geçir."
                    : "Seçili bölgelerin tamamı zaten işlendi. Karta dönüşmesini istediğin yeni bir bölge seç."
            )
        }

        let cloudDecision: RemoteDecision? = (selectionResultOverride != nil || snapshot?.userConfirmed == true)
            ? nil
            : remote?.reconciliation?.decision
        switch cloudDecision {
        case .reject:
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                recognized: recognized,
                selectedLineIds: selectedLineIds,
                selection: selection,
                annotationGroups: selection.groups,
                ocrSnapshot: checkpoint,
                passage: firstPassage,
                failure: .invalidResponse,
                reconciliation: remote?.reconciliation
            )
        case .quickConfirm:
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized,
                selectedLineIds: selectedLineIds,
                selection: selection,
                annotationGroups: selection.groups,
                ocrSnapshot: checkpoint,
                passage: firstPassage,
                reconciliation: remote?.reconciliation,
                confirmationReason: remote?.reconciliation?.reason
            )
        case .autoAccept, nil:
            break
        }

        var generated: [GeneratedAnnotationGroup] = []
        do {
            for group in selectedGroups {
                let passage = Self.groupPassage(group)
                guard !passage.isEmpty else {
                    return PipelineOutcome(
                        jobId: jobId,
                        finalState: .confirmationRequired,
                        recognized: recognized,
                        selectedLineIds: selectedLineIds,
                        selection: selection,
                        annotationGroups: selection.groups,
                        ocrSnapshot: checkpoint,
                        // Carries whatever earlier groups in this same batch
                        // already generated — dropping them here (the default
                        // `[]`) would silently lose already-paid-for cards the
                        // moment a *later* group in a multi-group submission
                        // failed, with nothing in the outcome for
                        // `ProcessingQueue.apply`'s partial-progress persist
                        // to find.
                        generatedGroups: generated,
                        reconciliation: remote?.reconciliation,
                        confirmationReason: "Seçilen bölgeden pasaj oluşturulamadı. Farklı bir bölge seçmeyi dene."
                    )
                }
                let knowledge = try await generator.generate(
                    CardGenerationRequest(
                        jobId: "\(jobId):\(group.id)",
                        passage: passage,
                        subject: subject,
                        maxCards: maxCards,
                        imageData: upload?.data,
                        mimeType: upload?.mimeType,
                        // This legacy field remains local-Vision ids for the
                        // existing card API; the structured group retains the
                        // primary OCR line/token ids for the next contract.
                        selectedLineIds: initialSelection.evidence
                            .filter { group.evidenceIds.contains($0.id) }
                            .flatMap(\.lineIds),
                        isHandwritten: !group.handwrittenNotes.isEmpty,
                        annotationGroups: [group]
                    )
                )
                guard !knowledge.cards.isEmpty else {
                    return PipelineOutcome(
                        jobId: jobId,
                        finalState: .confirmationRequired,
                        recognized: recognized,
                        selectedLineIds: selectedLineIds,
                        selection: selection,
                        annotationGroups: selection.groups,
                        ocrSnapshot: checkpoint,
                        passage: passage,
                        // See the comment on the same field a few lines above.
                        generatedGroups: generated,
                        reconciliation: remote?.reconciliation,
                        confirmationReason: "Seçilen bölgeden kart üretilemedi. Daha geniş bir bölge seçmeyi "
                            + "ya da 'Manuel alan ekle' ile genişletmeyi dene."
                    )
                }
                generated.append(GeneratedAnnotationGroup(group: group, knowledge: knowledge))
            }
            // A card the model or the gate flagged (`requiresUserApproval`) —
            // or a group whose knowledge carries a `sourceConcern` — is still
            // a real, generated card, not a reason to bounce the whole page
            // back to `confirmationRequired`. Persisting always happens
            // regardless of `finalState` (`ProcessingQueue.apply`), so the old
            // `.confirmationRequired` here did not protect anything; it only
            // meant the group's `Self.persistenceKey` landed in
            // `completedGroupIds` on the very next resume, `selectedGroups`
            // filtered it straight back out, and every subsequent tap of
            // "Kart oluştur" regenerated nothing and looked like it did
            // nothing at all — a permanent stuck loop for any page whose
            // cards needed review, which is most real pages once the v1.1
            // prompt started adding `explanation` text (cardGate.ts escalates
            // any non-empty explanation to `quick_confirm`). The cards are
            // reviewed in Bilgilerim now (`CardStatus.needsReview`), not by
            // re-opening this screen (found via real device use, 2026-08-04).
            return PipelineOutcome(
                jobId: jobId,
                finalState: .ready,
                recognized: recognized,
                selectedLineIds: selectedLineIds,
                selection: selection,
                annotationGroups: selection.groups,
                ocrSnapshot: checkpoint,
                passage: firstPassage,
                knowledge: generated.first?.knowledge,
                generatedGroups: generated,
                reconciliation: remote?.reconciliation,
                modelRun: generated.first?.knowledge.modelRun
            )
        } catch let error as CardGenerationError {
            if case .sourceInsufficient = error {
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .confirmationRequired,
                    recognized: recognized,
                    selectedLineIds: selectedLineIds,
                    selection: selection,
                    annotationGroups: selection.groups,
                    ocrSnapshot: checkpoint,
                    passage: firstPassage,
                    // See the comment further up this same loop.
                    generatedGroups: generated,
                    reconciliation: remote?.reconciliation,
                    confirmationReason: "Seçilen bölge tek başına yetersiz kaldı. İlgili bağlamı da kapsayan "
                        + "bir bölge seçmeyi dene."
                )
            }
            let kind = Self.failureKind(for: error)
            return PipelineOutcome(
                jobId: jobId,
                finalState: kind.resultingState,
                recognized: recognized,
                selectedLineIds: selectedLineIds,
                selection: selection,
                annotationGroups: selection.groups,
                ocrSnapshot: checkpoint,
                passage: firstPassage,
                generatedGroups: generated,
                failure: kind,
                reconciliation: remote?.reconciliation
            )
        } catch {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .temporaryFailure,
                recognized: recognized,
                selectedLineIds: selectedLineIds,
                selection: selection,
                annotationGroups: selection.groups,
                ocrSnapshot: checkpoint,
                passage: firstPassage,
                generatedGroups: generated,
                failure: .providerUnavailable,
                reconciliation: remote?.reconciliation
            )
        }
    }

    /// Single mapping from a generator error to the retry classification.
    static func failureKind(for error: CardGenerationError) -> FailureKind {
        switch error {
        case .budgetExceeded: return .budgetExceeded
        // A response that violates §14 will violate it again on replay.
        case .schemaInvalid: return .invalidResponse
        case .providerUnavailable: return .providerUnavailable
        case .sourceInsufficient: return .invalidResponse
        }
    }

    /// `TextRegion` predates a first-class annotation-group id. Its stable
    /// evidence set is therefore the persistence identity used to skip work
    /// that succeeded before a later group failed.
    static func persistenceKey(for group: AnnotationGroup) -> String {
        group.evidenceIds.sorted().joined(separator: ":")
    }

    /// Sends a page to the backend once. Group-to-token grounding happens only
    /// after this complete primary OCR snapshot has returned.
    private static func cloudReading(
        backend: any BackendCalling,
        jobId: String,
        imageURL: URL,
        recognized: RecognizedPage
    ) async throws -> (remote: RemoteRecognition, upload: PreparedUpload) {
        // Downscaled before sending: a full-resolution scan base64s to more
        // than a serverless host will accept, and the platform rejects it
        // before our own endpoint can say why (see `UploadImageEncoder`).
        let upload = try prepareUpload(imageURL: imageURL)

        let remote = try await backend.recognize(
            jobId: jobId,
            imageData: upload.data,
            mimeType: upload.mimeType,
            localLines: recognized.lines.map(LocalLine.init)
        )

        return (remote, upload)
    }

    /// Recreated locally when a user confirms a stored OCR snapshot. The
    /// result is intentionally not part of the snapshot: it is derived from
    /// the original page and may be discarded after the request.
    private static func prepareUpload(imageURL: URL) throws -> PreparedUpload {
        try UploadImageEncoder.prepare(
            contentsOf: imageURL,
            mimeType: Self.mimeType(for: imageURL)
        )
    }

    /// Fraction of the smaller box that has to be covered for two boxes to be
    /// the same line. Deliberately loose: the engines crop lines differently,
    /// and a missed pairing costs a confirmation tap while a wrong one would
    /// silently mix two lines together.
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

    /// Maps a backend failure onto the pipeline's own vocabulary (§17).
    private static func outcome(
        for error: BackendError,
        jobId: String,
        recognized: RecognizedPage,
        selection: MarkerSelectionResult
    ) -> PipelineOutcome {
        let failure: FailureKind
        switch error {
        case .unauthorized, .notConfigured:
            // Neither is fixed by waiting; both need the user to set something.
            failure = .configuration
        case .permanent:
            failure = .invalidResponse
        case .transient:
            failure = .providerUnavailable
        }
        return PipelineOutcome(
            jobId: jobId,
            finalState: failure.resultingState,
            recognized: recognized,
            selectedLineIds: selection.selectedLineIds,
            selection: selection,
            failure: failure
        )
    }

    private static func groupPassage(_ group: AnnotationGroup) -> String {
        let context = group.contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { return context }
        return group.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins the selected lines in page order, so a passage reads the way it
    /// does on the page rather than in tap order.
    static func passage(from page: RecognizedPage, lineIds: [String]) -> String {
        let wanted = Set(lineIds)
        return page.lines
            .filter { wanted.contains($0.id) }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
