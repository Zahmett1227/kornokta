import Foundation
import CoreGraphics

/// What one pipeline run produced. Returned rather than written directly so the
/// pipeline stays free of SwiftData and can be tested without a store.
public struct PipelineOutcome: Sendable, Equatable {
    public let jobId: String
    public let finalState: ProcessingState
    public let recognized: RecognizedPage?
    public let selectedLineIds: [String]
    public let passage: String?
    public let knowledge: GeneratedKnowledge?
    public let failure: FailureKind?
    /// What the backend concluded about the two readings, when there was one.
    ///
    /// Carried through so the confirmation screen can say *what* disagreed
    /// rather than just asking the user to look again — §19.2 requires the
    /// confirmation, and a confirmation with no reason attached is one the
    /// user cannot answer well.
    public let reconciliation: RemoteReconciliation?

    public init(
        jobId: String,
        finalState: ProcessingState,
        recognized: RecognizedPage? = nil,
        selectedLineIds: [String] = [],
        passage: String? = nil,
        knowledge: GeneratedKnowledge? = nil,
        failure: FailureKind? = nil,
        reconciliation: RemoteReconciliation? = nil
    ) {
        self.jobId = jobId
        self.finalState = finalState
        self.recognized = recognized
        self.selectedLineIds = selectedLineIds
        self.passage = passage
        self.knowledge = knowledge
        self.failure = failure
        self.reconciliation = reconciliation
    }
}

/// Chooses which recognized lines the user marked.
///
/// Faz 1 has no real marker detection on device yet — the algorithm was
/// prototyped in `evals/spikes/marker_detection` and lands in Faz 2 (§25). Until
/// then this seam lets the pipeline run with an explicit selection, and makes
/// the missing step visible instead of silently selecting everything.
public protocol MarkerSelecting: Sendable {
    func selectLines(in page: RecognizedPage, imageURL: URL) async throws -> [String]
}

/// Selects nothing, so a capture stops at `confirmationRequired` and the user
/// picks the passage by hand. Honest default for Faz 1: §19.3 says a capture
/// with no detected marker and no manual selection must not become a card.
public struct ManualSelectionOnly: MarkerSelecting {
    public init() {}
    public func selectLines(in page: RecognizedPage, imageURL: URL) async throws -> [String] { [] }
}

/// Selects the lines whose ids are given. Used by the confirmation screen when
/// the user taps a passage, and by tests.
public struct FixedSelection: MarkerSelecting {
    public let lineIds: [String]
    public init(lineIds: [String]) { self.lineIds = lineIds }
    public func selectLines(in page: RecognizedPage, imageURL: URL) async throws -> [String] {
        lineIds.filter { id in page.lines.contains { $0.id == id } }
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

    public func run(jobId: String, imageURL: URL, subject: String? = nil) async -> PipelineOutcome {
        let recognized: RecognizedPage
        do {
            recognized = try await recognizer.recognize(imageAt: imageURL)
        } catch {
            // OCR failing on a readable file is a device/config problem, not a
            // transient one; retrying forever would not help (§17).
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                failure: .configuration
            )
        }

        guard !recognized.lines.isEmpty else {
            // Nothing legible. §19.3: reject rather than invent a card.
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                recognized: recognized,
                failure: .invalidResponse
            )
        }

        let selected: [String]
        do {
            selected = try await selector.selectLines(in: recognized, imageURL: imageURL)
        } catch {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .temporaryFailure,
                recognized: recognized,
                failure: .providerUnavailable
            )
        }

        guard !selected.isEmpty else {
            // No marker found and no manual selection — ask the user which
            // passage they meant (§19.2, §19.3).
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized
            )
        }

        // Cloud OCR (§10.2). The local reading is only a preview: Apple Vision
        // does not support Turkish and produces no ı ş ğ İ at all, so a passage
        // built from it would carry defects into every card
        // (docs/ADR-002-birincil-ocr-secimi.md).
        var passage = Self.passage(from: recognized, lineIds: selected)
        var cloudDecision: RemoteDecision?
        var reconciliation: RemoteReconciliation?

        if let backend {
            do {
                let remote = try await Self.cloudReading(
                    backend: backend,
                    jobId: jobId,
                    imageURL: imageURL,
                    recognized: recognized,
                    selected: selected
                )
                passage = remote.passage
                cloudDecision = remote.reconciliation?.decision
                reconciliation = remote.reconciliation
            } catch let error as BackendError {
                return Self.outcome(for: error, jobId: jobId, recognized: recognized, selected: selected)
            } catch {
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .temporaryFailure,
                    recognized: recognized,
                    selectedLineIds: selected,
                    failure: .providerUnavailable
                )
            }
        }

        guard !passage.isEmpty else {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized,
                selectedLineIds: selected,
                reconciliation: reconciliation
            )
        }

        // §19.3 and §10.5.1: a rejected page never becomes a card, and a
        // critical-token disagreement is asked about rather than recorded.
        // Checked before generation so a disputed passage never reaches the
        // model — and never costs a call.
        switch cloudDecision {
        case .reject:
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                recognized: recognized,
                selectedLineIds: selected,
                passage: passage,
                failure: .invalidResponse,
                reconciliation: reconciliation
            )
        case .quickConfirm:
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized,
                selectedLineIds: selected,
                passage: passage,
                reconciliation: reconciliation
            )
        case .autoAccept, nil:
            break
        }

        do {
            let knowledge = try await generator.generate(
                CardGenerationRequest(
                    jobId: jobId,
                    passage: passage,
                    subject: subject,
                    maxCards: maxCards
                )
            )
            guard !knowledge.cards.isEmpty else {
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .confirmationRequired,
                    recognized: recognized,
                    selectedLineIds: selected,
                    passage: passage
                )
            }
            let needsApproval = knowledge.cards.contains { $0.requiresUserApproval }
                || knowledge.sourceConcern != nil
            return PipelineOutcome(
                jobId: jobId,
                finalState: needsApproval ? .confirmationRequired : .ready,
                recognized: recognized,
                selectedLineIds: selected,
                passage: passage,
                knowledge: knowledge
            )
        } catch let error as CardGenerationError {
            if case .sourceInsufficient = error {
                // The passage itself is too thin. Retrying identical input can
                // only fail again, so ask the user to widen the selection
                // instead of burning attempts (§12.1, §19.3).
                return PipelineOutcome(
                    jobId: jobId,
                    finalState: .confirmationRequired,
                    recognized: recognized,
                    selectedLineIds: selected,
                    passage: passage
                )
            }
            // Let `FailureKind` decide transient vs permanent rather than
            // guessing per call site — that is the one place §17's retry rule
            // is written down.
            let kind = Self.failureKind(for: error)
            return PipelineOutcome(
                jobId: jobId,
                finalState: kind.resultingState,
                recognized: recognized,
                selectedLineIds: selected,
                passage: passage,
                failure: kind
            )
        } catch {
            // An error the generator does not declare. Treat as transient so a
            // one-off is retried, but never silently drop the capture (§21.2).
            return PipelineOutcome(
                jobId: jobId,
                finalState: .temporaryFailure,
                recognized: recognized,
                selectedLineIds: selected,
                passage: passage,
                failure: .providerUnavailable
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

    /// Sends the page to the backend and builds the passage from the reading
    /// that comes back.
    ///
    /// The selected lines are matched to the cloud reading by **overlap**, not
    /// by id: the backend reconciles the same way, and for the same reason —
    /// each engine numbers its own lines and they do not find the same number
    /// of them.
    private static func cloudReading(
        backend: any BackendCalling,
        jobId: String,
        imageURL: URL,
        recognized: RecognizedPage,
        selected: [String]
    ) async throws -> (passage: String, reconciliation: RemoteReconciliation?) {
        let imageData = try Data(contentsOf: imageURL)
        let remote = try await backend.recognize(
            jobId: jobId,
            imageData: imageData,
            mimeType: Self.mimeType(for: imageURL),
            localLines: recognized.lines.map(LocalLine.init)
        )

        let selectedBoxes = recognized.lines
            .filter { selected.contains($0.id) }
            .map(\.box)
        let cloudText = remote.page.lines
            .filter { line in
                selectedBoxes.contains { box in
                    Self.overlaps(box: box, x: line.x, y: line.y, width: line.width, height: line.height)
                }
            }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If nothing overlapped, the cloud reading found the page but not the
        // marked region. Falling back to the local text would quietly ship the
        // reading we know is wrong for Turkish, so the passage stays empty and
        // the caller asks the user (§19.2).
        return (cloudText, remote.reconciliation)
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
        selected: [String]
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
            selectedLineIds: selected,
            failure: failure
        )
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
