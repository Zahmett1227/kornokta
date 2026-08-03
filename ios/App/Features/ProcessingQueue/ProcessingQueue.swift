import Foundation
import SwiftData
import CizgiCore

/// Runs captured pages through the pipeline and writes the results to the store.
///
/// The queue is the only place that persists pipeline output, so idempotence
/// lives in one spot: a page that already produced knowledge units is not
/// processed again (ANA-PLAN §17).
@MainActor
final class ProcessingQueue: ObservableObject {
    private let container: ModelContainer
    private let imageStore: ImageStore
    /// `var` because the cloud client is attached and detached as the user
    /// edits Settings; the rest of the pipeline never changes.
    private var pipeline: CapturePipeline
    private let retryPolicy = RetryPolicy()

    @Published private(set) var isRunning = false

    init(container: ModelContainer, imageStore: ImageStore, pipeline: CapturePipeline) {
        self.container = container
        self.imageStore = imageStore
        self.pipeline = pipeline
    }

    /// Attaches or removes cloud OCR. Called when the backend URL or the
    /// device token changes, so the next page uses the new setting rather than
    /// waiting for a relaunch.
    func setBackend(_ backend: (any BackendCalling)?) {
        pipeline = pipeline.withBackend(backend)
    }

    /// Swaps the card generator. Called alongside `setBackend` when the
    /// backend URL or device token changes, so real (§25 Faz 3) and mock
    /// generation follow the same on/off switch as cloud OCR rather than a
    /// second one.
    func setCardGenerator(_ generator: any CardGenerating) {
        pipeline = pipeline.withGenerator(generator)
    }

    /// Registers a freshly captured image. Returns once the bytes are on disk —
    /// §24.1 forbids telling the user a capture succeeded before that.
    @discardableResult
    func enqueue(imageData: Data, subject: String?) throws -> UUID {
        let context = container.mainContext
        let id = UUID()
        let relativePath = try imageStore.store(imageData, id: id)

        let page = CapturedPage(id: id, originalImagePath: relativePath)
        if let subject, !subject.isEmpty {
            page.source = try existingOrNewSource(named: subject, in: context)
        }
        context.insert(page)
        try context.save()
        return id
    }

    /// Reuses the subject's `Source` instead of creating one per capture, which
    /// would fill "Bilgilerim" with duplicates of the same book.
    private func existingOrNewSource(named subject: String, in context: ModelContext) throws -> Source {
        var descriptor = FetchDescriptor<Source>(
            predicate: #Predicate { $0.subject == subject }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let source = Source(title: subject, subject: subject)
        context.insert(source)
        return source
    }

    /// Processes every page that is not finished. Safe to call repeatedly; a
    /// page already at `.ready` is skipped.
    func processPending() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let context = container.mainContext
        let descriptor = FetchDescriptor<CapturedPage>(
            sortBy: [SortDescriptor(\.captureDate, order: .forward)]
        )
        guard let pages = try? context.fetch(descriptor) else { return }

        for page in pages where shouldProcess(page) {
            await process(page)
        }
    }

    private func shouldProcess(_ page: CapturedPage) -> Bool {
        switch page.processingState {
        case .ready, .cancelled, .permanentFailure, .confirmationRequired:
            return false
        case .temporaryFailure:
            guard retryPolicy.shouldRetry(attempt: page.retryCount) else { return false }
            if let next = page.nextAttemptAt, next > .now { return false }
            return true
        default:
            // A page that already produced knowledge units must not be run
            // again — that is how duplicate cards would appear (§17).
            return page.regions.allSatisfy { $0.knowledgeUnits.isEmpty }
        }
    }

    /// Runs one page. `selection` overrides the detector, which is how the
    /// confirmation screen resumes a job after the user picks the passage.
    func process(_ page: CapturedPage, selection: [String]? = nil) async {
        let context = container.mainContext
        let imageURL = imageStore.url(forRelativePath: page.originalImagePath)

        // Read the ceiling per run rather than caching it at init, so changing
        // "Pasaj başına kart" in Ayarlar takes effect on the next page instead
        // of the next launch (§6.7). UserDefaults is the single stored copy of
        // the setting, so this cannot drift from what the screen shows.
        var effectivePipeline = pipeline.withMaxCards(AppSettings.load().maxCardsPerPassage)
        if let selection, !selection.isEmpty {
            effectivePipeline = effectivePipeline.withSelector(FixedSelection(lineIds: selection))
        }

        page.processingState = .localOCR
        try? context.save()

        let outcome = await effectivePipeline.run(
            jobId: page.id.uuidString,
            imageURL: imageURL,
            subject: page.source?.subject
        )

        apply(outcome, to: page, context: context)
    }

    private func apply(_ outcome: PipelineOutcome, to page: CapturedPage, context: ModelContext) {
        // Keep the local OCR even when a later step failed (§21.2).
        if let recognized = outcome.recognized, page.regions.isEmpty {
            page.documentQualityScore = recognized.lines
                .map(\.confidence)
                .reduce(0, +) / Double(max(recognized.lines.count, 1))
        }

        switch outcome.finalState {
        case .ready:
            if let knowledge = outcome.knowledge, let passage = outcome.passage {
                persist(knowledge: knowledge, passage: passage, outcome: outcome, page: page, context: context)
            }
            page.processingState = .ready
            page.lastError = nil

        case .confirmationRequired:
            page.processingState = .confirmationRequired
            // Not an error, but the reason has to survive: §19.2 requires the
            // confirmation, and a confirmation with no reason attached is one
            // the user cannot answer well. `lastError` is the field the queue
            // and the confirmation screen already read.
            page.lastError = outcome.reconciliation?.reason
            page.confirmationFlags = outcome.reconciliation?.lines
                .flatMap(\.criticalTokenFlags) ?? []

        case .temporaryFailure:
            page.retryCount += 1
            page.nextAttemptAt = Date().addingTimeInterval(
                retryPolicy.delay(forAttempt: page.retryCount)
            )
            page.processingState = retryPolicy.shouldRetry(attempt: page.retryCount)
                ? .temporaryFailure
                : .permanentFailure
            page.lastError = outcome.failure.map(String.init(describing:))

        case .permanentFailure:
            page.processingState = .permanentFailure
            page.lastError = outcome.failure.map(String.init(describing:))

        default:
            page.processingState = outcome.finalState
        }

        try? context.save()
    }

    private func persist(
        knowledge: GeneratedKnowledge,
        passage: String,
        outcome: PipelineOutcome,
        page: CapturedPage,
        context: ModelContext
    ) {
        let region = TextRegion(
            boundingBox: (0, 0, 1, 1),
            lineIds: outcome.selectedLineIds,
            finalText: passage,
            confidence: page.documentQualityScore,
            selectionType: .manual
        )
        region.appleOCRText = outcome.recognized?.fullText
        region.page = page
        context.insert(region)

        let unit = KnowledgeUnit(
            canonicalClaim: knowledge.canonicalClaim,
            subject: page.source?.subject,
            tags: knowledge.tags,
            sourceConcern: knowledge.sourceConcern
        )
        unit.region = region
        context.insert(unit)

        for generated in knowledge.cards {
            let card = Card(
                type: generated.type,
                front: generated.front,
                back: generated.back,
                explanation: generated.explanation,
                sourceQuote: generated.sourceQuote,
                riskFlags: generated.riskFlags,
                // Faz 1 cards come from the mock, so they start as drafts the
                // user activates — nothing auto-enters the deck (§19.1).
                status: generated.requiresUserApproval ? .needsReview : .active
            )
            card.knowledgeUnit = unit
            context.insert(card)
        }

        // Only the real backend generator reports this (§16.8); the mock
        // makes no network call and has nothing to account for. Recorded
        // only on success — `persist` runs solely from the `.ready` branch of
        // `apply`, so a failed call never reaches here (a known, deliberate
        // gap: a failed generation is not yet given its own `ModelRun`).
        if let metadata = outcome.modelRun {
            let run = ModelRun(
                requestId: metadata.requestId,
                jobId: page.id.uuidString,
                provider: metadata.provider,
                model: metadata.model,
                purpose: metadata.purpose,
                promptVersion: metadata.promptVersion,
                latencyMs: metadata.latencyMs,
                inputTokens: metadata.inputTokens,
                outputTokens: metadata.outputTokens,
                estimatedCostUSD: metadata.estimatedCostUSD,
                success: true
            )
            context.insert(run)
        }
    }

    func cancel(_ page: CapturedPage) {
        guard PipelineStateMachine.canTransition(from: page.processingState, to: .cancelled) else { return }
        page.processingState = .cancelled
        try? container.mainContext.save()
    }

    func retry(_ page: CapturedPage) async {
        guard page.processingState == .temporaryFailure || page.processingState == .permanentFailure else { return }
        page.retryCount = 0
        page.nextAttemptAt = nil
        page.processingState = .captured
        try? container.mainContext.save()
        await process(page)
    }
}
