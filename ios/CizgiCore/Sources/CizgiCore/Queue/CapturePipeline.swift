import Foundation

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

    public init(
        jobId: String,
        finalState: ProcessingState,
        recognized: RecognizedPage? = nil,
        selectedLineIds: [String] = [],
        passage: String? = nil,
        knowledge: GeneratedKnowledge? = nil,
        failure: FailureKind? = nil
    ) {
        self.jobId = jobId
        self.finalState = finalState
        self.recognized = recognized
        self.selectedLineIds = selectedLineIds
        self.passage = passage
        self.knowledge = knowledge
        self.failure = failure
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

    public init(
        recognizer: any TextRecognizing,
        selector: any MarkerSelecting = ManualSelectionOnly(),
        generator: any CardGenerating = MockCardProvider(),
        maxCards: Int = 4
    ) {
        self.recognizer = recognizer
        self.selector = selector
        self.generator = generator
        self.maxCards = maxCards
    }

    /// Same pipeline with a different line selector. The confirmation screen
    /// uses this to resume a job with the passage the user picked.
    public func withSelector(_ selector: any MarkerSelecting) -> CapturePipeline {
        CapturePipeline(
            recognizer: recognizer,
            selector: selector,
            generator: generator,
            maxCards: maxCards
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

        let passage = Self.passage(from: recognized, lineIds: selected)
        guard !passage.isEmpty else {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .confirmationRequired,
                recognized: recognized,
                selectedLineIds: selected
            )
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
        } catch CardGenerationError.budgetExceeded {
            return PipelineOutcome(
                jobId: jobId,
                finalState: .permanentFailure,
                recognized: recognized,
                selectedLineIds: selected,
                passage: passage,
                failure: .budgetExceeded
            )
        } catch {
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
