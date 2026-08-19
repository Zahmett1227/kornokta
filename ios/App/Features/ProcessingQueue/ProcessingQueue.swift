import Foundation
import SwiftData
import UIKit
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
    /// How many `process(_:)` calls are currently parked inside `pipeline.run`
    /// for each page id — a suspension point (network/OCR `await`) a call can
    /// be at while `ProcessingQueue` (`@MainActor`) runs other queued work,
    /// including a user's delete tap, in between. A plain count rather than a
    /// `Set<UUID>`: `retry(_:)` doesn't set `isRunning`, so a manual "Tekrar
    /// dene" can already be awaiting `run` for a page when a pull-to-refresh
    /// starts a second `process` call for that same page — a `Set` would lose
    /// the first call's membership the moment either one's `defer` fired,
    /// even though the other was still in flight. `delete(_:)` checks this
    /// before touching the SwiftData model (PR #12 review, Codex P1, both
    /// rounds).
    private var inFlightPageCounts: [UUID: Int] = [:]

    /// How many pages may be at the provider at once.
    ///
    /// Running a multi-page batch strictly one after another made the *batch*
    /// the problem rather than any single call: the Faz 6 vision call takes one
    /// to five minutes, so five pages in a row asked the phone to stay awake and
    /// connected for the better part of a quarter of an hour. That is what the
    /// user saw as "çoklu fotoğrafta zaman aşımı".
    ///
    /// Under ADR-006 a slot costs almost nothing locally: a page spends its time
    /// asleep between small polls, not holding a connection open, and the
    /// generation itself happens server-side where each page is an independent
    /// invocation. So this is set by what is polite to the provider's rate
    /// limits rather than by anything the phone contends over — high enough that
    /// an ordinary batch is submitted in one wave instead of being drip-fed.
    private static let maxConcurrentPages = 6

    /// Held while any page is in flight — see `beginProcessingActivity`.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// The pending "come back and retry the pages that failed transiently" pass.
    private var retryDrainTask: Task<Void, Never>?

    @Published private(set) var isRunning = false

    /// Someone asked for a pass while one was already running.
    ///
    /// The eligible set is chosen once, before anything is in flight, so pages
    /// captured *during* a batch are invisible to it — and a batch on the job
    /// queue runs for minutes. Dropping the request on the floor left those
    /// pages sitting at "Bekliyor" until the next launch or pull-to-refresh,
    /// because the follow-up pass `processPending` schedules only ever looks at
    /// pages that failed transiently.
    private var rerunRequested = false

    init(container: ModelContainer, imageStore: ImageStore, pipeline: CapturePipeline) {
        self.container = container
        self.imageStore = imageStore
        self.pipeline = pipeline
    }

    /// Swaps the card generator. Called when the backend URL or device token
    /// changes, so the next page uses the new setting rather than waiting for
    /// a relaunch.
    func setCardGenerator(_ generator: any CardGenerating) {
        pipeline = pipeline.withGenerator(generator)
    }

    /// Hashes of every page already in the store, for the capture screen's
    /// duplicate check.
    ///
    /// Returns the raw hashes rather than answering "is this a duplicate?" per
    /// image: the batch has to be compared against itself as well as against the
    /// store, and that decision belongs in one tested place
    /// (`PerceptualHasher.duplicateIndices`).
    func storedPageHashes() -> [PerceptualHash] {
        let context = container.mainContext
        guard let pages = try? context.fetch(FetchDescriptor<CapturedPage>()) else { return [] }
        return pages.compactMap { page in
            guard !page.pendingDeletion, let stored = page.perceptualHash else { return nil }
            return PerceptualHash(stringValue: stored)
        }
    }

    /// Registers a freshly captured image. Returns once the bytes are on disk —
    /// §24.1 forbids telling the user a capture succeeded before that.
    @discardableResult
    func enqueue(imageData: Data, subject: String?) throws -> UUID {
        let context = container.mainContext
        let id = UUID()
        let relativePath = try imageStore.store(imageData, id: id)

        let page = CapturedPage(id: id, originalImagePath: relativePath)
        // Recorded even when nothing is asked about it right now: the field is
        // what lets a *later* capture recognise this page, and a page stored
        // without one is invisible to every future check.
        page.perceptualHash = PageImageHasher.hash(imageData)?.stringValue
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
    ///
    /// A call that arrives while a pass is running is remembered rather than
    /// dropped, and the running pass loops once more when it finishes — that is
    /// how a page captured mid-batch gets picked up without waiting for the
    /// next launch. `shouldProcess` is what makes the extra lap cheap: a page
    /// the first lap already finished is not selected again.
    func processPending() async {
        guard !isRunning else {
            rerunRequested = true
            return
        }
        isRunning = true
        defer { isRunning = false }

        repeat {
            rerunRequested = false
            await runOnePass()
        } while rerunRequested
    }

    private func runOnePass() async {
        reconcilePendingImageDeletions()

        let context = container.mainContext
        let descriptor = FetchDescriptor<CapturedPage>(
            sortBy: [SortDescriptor(\.captureDate, order: .forward)]
        )
        guard let pages = try? context.fetch(descriptor) else { return }

        // Collected first, then run: `process` awaits, and this actor is free to
        // run other queued work at every suspension point. Deciding what is
        // eligible up front — while nothing is in flight — keeps that decision
        // reading a consistent snapshot of the store.
        var pendingIDs: [UUID] = []

        for page in pages {
            // A deletion always wins over resuming work, without a network
            // call, on every launch (PR #12 review, Codex P1 — second
            // round): if the app was terminated between an in-flight
            // `delete(_:)` marking `pendingDeletion` and that run finishing,
            // a fresh launch's `inFlightPageCounts` starts empty and
            // `shouldProcess` would otherwise accept the page's still-
            // `.localOCR` state and re-upload/re-OCR an image the user
            // already asked to delete.
            //
            // But `pendingDeletion` alone is not enough to act immediately —
            // `retry(_:)` doesn't set `isRunning`, so a manual "Tekrar dene"
            // can already be inside `process` for this exact page (counted
            // in `inFlightPageCounts`) when a concurrent pull-to-refresh
            // reaches it here. Deleting the model out from under that still-
            // running call is the same race `delete(_:)` itself guards
            // against; only the in-flight call's own `defer` may finish a
            // pending deletion once it is truly the last one (PR #12 review,
            // Codex P1 — fifth round). Nothing else to do here either way:
            // `process` must not be started for a page marked for deletion.
            if page.pendingDeletion {
                if (inFlightPageCounts[page.id] ?? 0) == 0 {
                    performDelete(page)
                }
                continue
            }
            guard shouldProcess(page) else { continue }
            pendingIDs.append(page.id)
        }

        await processConcurrently(pendingIDs)
        scheduleRetryDrain()
    }

    /// Runs the given pages with at most `maxConcurrentPages` in flight,
    /// starting the next one the moment any slot frees rather than waiting for
    /// the whole batch — a page that answers in 40 s must not be held behind one
    /// that takes four minutes.
    ///
    /// Ids rather than models cross the task boundary: `CapturedPage` is a
    /// SwiftData model and not `Sendable`, and re-fetching on the main context
    /// inside each child also means a page the user deleted while the batch was
    /// running is simply not found instead of resurfacing as a faulted object.
    private func processConcurrently(_ pendingIDs: [UUID]) async {
        guard !pendingIDs.isEmpty else { return }

        await withTaskGroup(of: UUID.self) { group in
            var nextIndex = 0

            while nextIndex < Self.maxConcurrentPages && nextIndex < pendingIDs.count {
                let id = pendingIDs[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor in
                    await self.process(pageID: id)
                    return id
                }
            }

            while await group.next() != nil {
                guard nextIndex < pendingIDs.count else { continue }
                let id = pendingIDs[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor in
                    await self.process(pageID: id)
                    return id
                }
            }
        }
    }

    private func process(pageID: UUID) async {
        let context = container.mainContext
        var descriptor = FetchDescriptor<CapturedPage>(
            predicate: #Predicate { $0.id == pageID }
        )
        descriptor.fetchLimit = 1
        // Gone means deleted while the batch was in flight — nothing to do, and
        // nothing to report: the user asked for exactly that.
        guard let page = try? context.fetch(descriptor).first else { return }
        guard !page.pendingDeletion else { return }
        // Re-asked at start time, not only at selection time: this call may
        // have waited behind a full batch, and in that window the user can
        // cancel the page or a manual "Tekrar dene" can run it to `.ready`
        // first. Starting a second run then meant a duplicate generation.
        guard shouldProcess(page) else { return }
        await process(page)
    }

    /// A page that fails transiently is given a `nextAttemptAt`, but until now
    /// nothing ever honoured it: the queue only ran again when the user reopened
    /// the app or pulled to refresh. In a multi-page batch that meant one
    /// dropped connection left those cards unmade until the user happened to
    /// look. One follow-up pass is scheduled at the earliest due time; the
    /// existing attempt ceiling (`RetryPolicy.maxAttempts`) is what terminates
    /// the chain, since an exhausted page becomes `.permanentFailure` and
    /// `shouldProcess` stops selecting it.
    private func scheduleRetryDrain() {
        retryDrainTask?.cancel()
        retryDrainTask = nil

        let context = container.mainContext
        let descriptor = FetchDescriptor<CapturedPage>()
        guard let pages = try? context.fetch(descriptor) else { return }

        let due = pages
            .filter { $0.processingState == .temporaryFailure && !$0.pendingDeletion }
            .filter { retryPolicy.shouldRetry(attempt: $0.retryCount) }
            .compactMap(\.nextAttemptAt)
            .min()
        guard let due else { return }

        // At least a second even when the deadline has already passed, so a
        // page that keeps failing instantly cannot spin this into a tight loop.
        let delay = max(1, due.timeIntervalSinceNow)
        retryDrainTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Dropped before the pass runs, so the `scheduleRetryDrain` at the
            // end of it cannot cancel the task it is itself running inside.
            self.retryDrainTask = nil
            await self.processPending()
        }
    }

    /// Retries an image deletion left over from a previous launch: `apply`
    /// may have exited between persisting `pendingOriginalImageDeletion` and
    /// actually removing the file, or a later, unrelated save may be what
    /// flushed that flag to disk. `shouldProcess` never revisits a `.ready`
    /// page, so this is the only place that gets another chance at it.
    ///
    /// Uses a fresh `ModelContext` rather than `container.mainContext`: a
    /// failed `save()` in `apply` can leave `pendingOriginalImageDeletion =
    /// true` mutated in memory on the shared main context without it ever
    /// reaching disk, and a fetch on that same context would still return
    /// it — deleting the image before anything durable says that's safe.
    /// A brand-new context has no unsaved changes of its own, so its fetch
    /// only sees flags that actually made it to the persistent store.
    private func reconcilePendingImageDeletions() {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<CapturedPage>(
            predicate: #Predicate { $0.pendingOriginalImageDeletion }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }
        for page in pending {
            do {
                try imageStore.remove(relativePath: page.originalImagePath)
                page.pendingOriginalImageDeletion = false
            } catch {
                // Leave the flag set; try again on the next launch/foreground.
            }
        }
        try? context.save()
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

    /// Runs one page through the vision pipeline.
    func process(_ page: CapturedPage, forceResubmit: Bool = false) async {
        let context = container.mainContext
        let imageURL = imageStore.url(forRelativePath: page.originalImagePath)
        let pageID = page.id

        // Read the settings per run rather than caching them at init, so
        // changing "Sayfa başına kart" or "Beş şıklı kart" in Ayarlar takes
        // effect on the next page instead of the next launch (§6.7).
        // UserDefaults is the single stored copy, so this cannot drift from
        // what the screen shows.
        let settings = AppSettings.load()
        let effectivePipeline = pipeline
            .withMaxCards(settings.maxCardsPerPage)
            .withMultipleChoiceMode(settings.multipleChoiceMode)

        page.processingState = .localOCR
        try? context.save()

        // Marks the window `delete(_:)` has to check before touching this
        // page's SwiftData model — `run` below awaits network/OCR calls, and
        // this actor is free to run a queued delete tap (or a second,
        // overlapping `process` call for the same page) in between.
        inFlightPageCounts[pageID, default: 0] += 1
        beginProcessingActivity()
        defer {
            let remaining = (inFlightPageCounts[pageID] ?? 1) - 1
            if remaining > 0 {
                inFlightPageCounts[pageID] = remaining
            } else {
                inFlightPageCounts[pageID] = nil
                // Only the call that brings the count to zero may act on a
                // pending deletion (PR #12 review, Codex P1 — third round).
                // `apply` below runs unconditionally and may persist a full
                // result for `page` even though deletion was requested mid-run
                // — wasted work in that rare race, but safe: an earlier call
                // finishing first must never delete the model while a later,
                // still-in-flight call for the same page is going to read or
                // write it in its own `apply`.
                if page.pendingDeletion {
                    performDelete(page)
                }
            }
            endProcessingActivityIfIdle()
        }

        let outcome = await effectivePipeline.run(
            jobId: page.id.uuidString,
            imageURL: imageURL,
            subject: page.source?.subject,
            forceResubmit: forceResubmit
        )

        apply(outcome, to: page, context: context)
    }

    /// Keeps the phone from throwing the run away underneath itself.
    ///
    /// Two separate causes of the "çoklu fotoğrafta timeout" report, one line
    /// each. `isIdleTimerDisabled`: the screen auto-locks after 30 s by default,
    /// and once it does iOS suspends the app and tears down the upload — a batch
    /// that needs minutes of network time is otherwise guaranteed to hit it.
    /// `beginBackgroundTask`: the user switching away suspends the app at once;
    /// an assertion buys the roughly 30 s iOS grants, enough for a call that was
    /// about to answer to land instead of being lost.
    ///
    /// Neither survives a *long* backgrounding — that needs a background
    /// `URLSession`, or moving the wait off the phone entirely (see the notes in
    /// docs/FAZ6-PLAN.md). These two remove the failure that actually happens in
    /// practice: the user starts a batch and puts the phone down.
    private func beginProcessingActivity() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "cizgi.page-processing") {
            // iOS is about to reclaim the assertion. Release it rather than let
            // the app be killed for holding one past its expiry; the pages still
            // in flight fail as transient and are retried from the durable queue.
            Task { @MainActor in self.releaseProcessingActivity() }
        }
    }

    private func endProcessingActivityIfIdle() {
        guard inFlightPageCounts.isEmpty else { return }
        releaseProcessingActivity()
    }

    private func releaseProcessingActivity() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Stores what the generator says it read and never carded
    /// (docs/PLAN-kapsama-sozlesmesi.md, Katman A).
    ///
    /// Only ever written on a `.ready` page and only when the server actually
    /// sent a block: a nil overwrite would erase the findings of the run that
    /// produced this page's cards, and the second run in a "Tekrar dene" race
    /// arrives with the same result anyway.
    ///
    /// Dismissals are preserved across a regeneration, which is why this merges
    /// rather than assigns: the owner already decided about those passages, and
    /// a fresh generation re-reporting them would ask the same question again.
    /// Identities are derived from the mark's text, so they survive the model
    /// renumbering its own register (`PageMark.id`).
    private func recordCoverage(_ coverage: PageCoverage?, on page: CapturedPage) {
        guard let coverage else { return }
        var merged = coverage
        merged.dismissedMarkIds = PageCoverage.fromStorage(page.coverageJSON).dismissedMarkIds
        // An audit belongs to the cards it was run against; a regeneration
        // invalidates it, so it is deliberately not carried over.
        page.coverageJSON = merged.storageValue
    }

    private func apply(_ outcome: PipelineOutcome, to page: CapturedPage, context: ModelContext) {
        // The user's explicit stop wins over a result arriving late. `cancel`
        // is guarded by `canTransition` and "cancelled never moves again"
        // (StateMachine.swift), but this write path used to ignore both: a page
        // cancelled while its run was in flight would be resurrected as
        // `.ready`, cards and all. Wasted work in that rare race — same
        // trade-off `pendingDeletion` makes in `process` — but the state the
        // user chose stays chosen.
        guard page.processingState != .cancelled else { return }

        // Before the branch, deliberately: what the calls cost is true on every
        // path through this method, and the failure paths are the ones the old
        // success-only accounting was blind to.
        recordAccounting(outcome.modelRuns, for: page, context: context)
        // Same reasoning, same place: a page that produced *no* cards still has
        // a mark register worth keeping, and it is the page where every mark is
        // uncovered (docs/PLAN-kapsama-sozlesmesi.md).
        recordCoverage(outcome.coverage, on: page)

        // Keep completed groups before returning a retryable failure. A later
        // retry receives their ids and generates only the unfinished groups.
        if outcome.finalState != .ready {
            for generated in outcome.generatedGroups where !hasPersistedGroup(generated.group, on: page) {
                persist(generated: generated, outcome: outcome, page: page, context: context)
            }
        }

        switch outcome.finalState {
        case .ready:
            // Filtered exactly like the non-ready branch above. Two runs for
            // one page genuinely overlap (a manual "Tekrar dene" racing a
            // pull-to-refresh — the comment in `process` documents it), both
            // poll the same job id, and both arrive here with the same server
            // result; without the filter the second one persisted a complete
            // duplicate set of regions, cards and ModelRuns (§17: re-processing
            // must not produce a second set of cards).
            if !outcome.generatedGroups.isEmpty {
                for generated in outcome.generatedGroups where !hasPersistedGroup(generated.group, on: page) {
                    persist(generated: generated, outcome: outcome, page: page, context: context)
                }
            } else if let knowledge = outcome.knowledge, let group = outcome.annotationGroups.first,
                      !hasPersistedGroup(group, on: page) {
                persist(
                    generated: GeneratedAnnotationGroup(group: group, knowledge: knowledge),
                    outcome: outcome,
                    page: page,
                    context: context
                )
            }
            page.processingState = .ready
            // Cleared for hygiene on rows written before the ADR-005 trim; the
            // vision flow itself never writes a snapshot.
            page.ocrSnapshotData = nil
            page.lastError = nil
            page.retryCount = 0
            page.nextAttemptAt = nil
            if !AppSettings.load().keepOriginalPage {
                page.pendingOriginalImageDeletion = true
            }

        case .temporaryFailure:
            page.retryCount += 1
            page.nextAttemptAt = Date().addingTimeInterval(
                retryPolicy.delay(forAttempt: page.retryCount)
            )
            page.processingState = retryPolicy.shouldRetry(attempt: page.retryCount)
                ? .temporaryFailure
                : .permanentFailure
            page.lastError = FailureDiagnosis.text(detail: outcome.failureDetail, kind: outcome.failure)

        case .permanentFailure:
            page.processingState = .permanentFailure
            page.lastError = FailureDiagnosis.text(detail: outcome.failureDetail, kind: outcome.failure)

        default:
            page.processingState = outcome.finalState
        }

        // The original image is the only source if `context.save()` fails
        // (e.g. storage full) — deleting it before persistence is confirmed
        // would leave the page pointing at a file that no longer exists with
        // none of the generated cards actually saved. `pendingOriginalImageDeletion`
        // travels with the same save as the `.ready` transition, so even if
        // this process exits before the removal below runs — or a later,
        // unrelated save is what actually flushes this page — the flag is
        // already durable and `reconcilePendingImageDeletions` retries it.
        do {
            try context.save()
            if page.pendingOriginalImageDeletion {
                do {
                    try imageStore.remove(relativePath: page.originalImagePath)
                    page.pendingOriginalImageDeletion = false
                    try? context.save()
                } catch {
                    // Leave the flag set; reconcilePendingImageDeletions retries later.
                }
            }
        } catch {}
    }

    private func persist(
        generated: GeneratedAnnotationGroup,
        outcome: PipelineOutcome,
        page: CapturedPage,
        context: ModelContext
    ) {
        let group = generated.group
        let knowledge = generated.knowledge
        let box = group.boundingBox
        let sourceCropPath = cropPath(for: page, group: group)
        let region = TextRegion(
            boundingBox: (box.x, box.y, box.width, box.height),
            lineIds: group.contextLineIds,
            tokenIds: group.contextTokenIds,
            evidenceIds: group.evidenceIds,
            finalText: group.contextText,
            selectedText: group.selectedText,
            contextText: group.contextText,
            handwrittenNotes: group.handwrittenNotes,
            layoutKind: Self.persistedLayoutKind(group.layoutKind),
            sourceCropPath: sourceCropPath,
            confidence: group.confidence,
            isHandwritten: !group.handwrittenNotes.isEmpty,
            selectionType: Self.persistedSelectionType(group.selectionType),
            requiresConfirmation: group.needsConfirmation
        )
        region.page = page
        context.insert(region)

        // One `KnowledgeUnit` per topic rather than one per page (schema
        // v2.2): the unit is where subject/topic live, so this is what makes
        // a card's topic exact without touching the SwiftData schema. All
        // units share the page's single `TextRegion`; a page whose cards
        // carry no topics degrades to the old one-unit shape.
        let subject = page.source?.subject
        let schema = try? SubjectTopicSchema.bundled()
        for topicGroup in TopicGrouping.partition(knowledge.cards, subject: subject, schema: schema) {
            let unit = KnowledgeUnit(
                canonicalClaim: knowledge.canonicalClaim,
                subject: subject,
                topic: topicGroup.topic,
                tags: knowledge.tags,
                sourceConcern: knowledge.sourceConcern
            )
            unit.region = region
            context.insert(unit)

            for generated in topicGroup.cards {
                let card = Card(
                    // Not `generated.type` directly: if the options did not survive
                    // validation, storing the card as `multipleChoice` would leave a
                    // five-option card with nothing to choose from (Codex, PR #29).
                    type: MultipleChoice.resolvedType(current: generated.type, options: generated.options),
                    front: generated.front,
                    back: generated.back,
                    explanation: generated.explanation,
                    sourceQuote: generated.sourceQuote,
                    riskFlags: generated.riskFlags,
                    // Faz 1 cards come from the mock, so they start as drafts the
                    // user activates — nothing auto-enters the deck (§19.1).
                    status: generated.requiresUserApproval ? .needsReview : .active,
                    options: generated.options,
                    lowConfidence: generated.lowConfidence
                )
                card.knowledgeUnit = unit
                context.insert(card)
            }
        }

    }

    /// Writes down every provider call the server reports for this page.
    ///
    /// Moved out of `persist` and up into `apply`, which is the whole fix:
    /// `persist` runs only from the `.ready` branch and only per generated
    /// group, so accounting written there could only ever record successes —
    /// and would record one row per group if a page ever produced two. A
    /// generation that burns its output budget and fails costs the same as one
    /// that works, so the ledger has to be written wherever the run ends.
    ///
    /// De-duplicated on `(purpose, attempt)` because the server reports its
    /// whole ledger on every poll and a page is polled many times — and
    /// because two runs for one page genuinely overlap (a manual "Tekrar dene"
    /// racing a pull-to-refresh, documented in `process`), so both arrive here
    /// with the same entries.
    private func recordAccounting(
        _ runs: [ModelRunMetadata],
        for page: CapturedPage,
        context: ModelContext
    ) {
        guard !runs.isEmpty else { return }
        let jobId = page.id.uuidString
        let descriptor = FetchDescriptor<ModelRun>(predicate: #Predicate { $0.jobId == jobId })
        let existing = (try? context.fetch(descriptor)) ?? []
        var seen = Set(existing.map { "\($0.purpose)#\($0.attempt)" })

        for metadata in runs {
            let key = "\(metadata.purpose)#\(metadata.attempt)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            context.insert(
                ModelRun(
                    requestId: metadata.requestId,
                    jobId: jobId,
                    attempt: metadata.attempt,
                    provider: metadata.provider,
                    model: metadata.model,
                    purpose: metadata.purpose,
                    promptVersion: metadata.promptVersion,
                    latencyMs: metadata.latencyMs,
                    inputTokens: metadata.inputTokens,
                    cachedInputTokens: metadata.cachedInputTokens,
                    outputTokens: metadata.outputTokens,
                    reasoningTokens: metadata.reasoningTokens,
                    estimatedCostUSD: metadata.estimatedCostUSD,
                    success: metadata.success,
                    billing: metadata.billing,
                    failureReason: metadata.failureReason
                )
            )
        }
    }

    private func hasPersistedGroup(_ group: AnnotationGroup, on page: CapturedPage) -> Bool {
        let key = group.evidenceIds.sorted().joined(separator: ":")
        return page.regions.contains { $0.evidenceIds.sorted().joined(separator: ":") == key }
    }

    private static func persistedSelectionType(_ type: AnnotationType) -> SelectionType {
        switch type {
        case .highlight: return .highlight
        case .underline: return .underline
        case .marginMark: return .marginMark
        case .handwriting: return .handwriting
        case .manual: return .manual
        }
    }

    private static func persistedLayoutKind(_ kind: AnnotationLayoutKind) -> LayoutKind {
        switch kind {
        case .paragraph: return .paragraph
        case .block: return .paragraph
        case .bullet: return .bullet
        case .column: return .column
        case .tableCandidate: return .tableCandidate
        case .unknown: return .unknown
        }
    }

    /// Stores the selected source region, never the whole page under a crop
    /// label. A failure leaves the region usable through its original page;
    /// it must not turn a successful card into a failed capture.
    private func cropPath(for page: CapturedPage, group: AnnotationGroup) -> String? {
        // Faz 6 (docs/FAZ6-PLAN.md): the vision flow produces one synthetic
        // full-page group (box ≈ 0,0,1,1). Cropping that just re-saves the whole
        // page under a crop label — wasted disk. The original page already
        // stands in for it, so skip the crop when the box covers the page.
        let box = group.boundingBox
        if box.width >= 0.9 && box.height >= 0.9 {
            return nil
        }

        guard
            let image = UIImage(contentsOfFile: imageStore.url(forRelativePath: page.originalImagePath).path),
            let cgImage = image.cgImage
        else { return nil }

        let padding = 0.015
        let x = max(0, box.x - padding)
        let y = max(0, box.y - padding)
        let right = min(1, box.x + box.width + padding)
        let bottom = min(1, box.y + box.height + padding)
        let pixelRect = CGRect(
            x: x * Double(cgImage.width),
            y: y * Double(cgImage.height),
            width: max(1, (right - x) * Double(cgImage.width)),
            height: max(1, (bottom - y) * Double(cgImage.height))
        ).integral
        guard let crop = cgImage.cropping(to: pixelRect) else { return nil }
        guard let data = UIImage(cgImage: crop).jpegData(compressionQuality: 0.92) else { return nil }
        return try? imageStore.store(data, id: UUID(), kind: .crop)
    }

    func cancel(_ page: CapturedPage) {
        guard PipelineStateMachine.canTransition(from: page.processingState, to: .cancelled) else { return }
        page.processingState = .cancelled
        try? container.mainContext.save()
    }

    /// Removes a queue entry entirely, unlike `cancel` which only marks it
    /// `.cancelled` and leaves it in the list forever.
    ///
    /// If `page` is mid-`pipeline.run` (PR #12 review, Codex P1, both
    /// rounds), deleting its SwiftData model out from under that in-flight
    /// `process(_:)` call — or from under a *second*, overlapping one for the
    /// same page (manual retry racing a pull-to-refresh) — would hand `apply`
    /// a faulted object once its `await`s resume. This just records the
    /// request; `apply` performs the real deletion once every in-flight call
    /// for this page has finished, so the tap is honored rather than raced.
    func delete(_ page: CapturedPage) {
        guard (inFlightPageCounts[page.id] ?? 0) == 0 else {
            page.pendingDeletion = true
            try? container.mainContext.save()
            return
        }
        performDelete(page)
    }

    /// SwiftData cascades the model delete to `regions`/`knowledgeUnits`/
    /// `cards` (`deleteRule: .cascade`), but the crop and original page files
    /// it stored on disk are its own.
    ///
    /// The model delete is saved *before* any file is removed (PR #12
    /// review, Codex P2) — the reverse of `pendingOriginalImageDeletion`'s
    /// order elsewhere in this file, and deliberately so: there, the record
    /// itself is the durable intent and a crash before the file goes just
    /// means a retry. Here there is no separate durable flag once this
    /// returns, so if `context.save()` failed after the files were already
    /// gone, the surviving record would point at nothing and no code path
    /// would ever revisit it. Saving first means a failed save simply leaves
    /// both the record and its files in place, exactly as they were.
    private func performDelete(_ page: CapturedPage) {
        let context = container.mainContext
        let originalPath = page.originalImagePath
        let cropPaths = page.regions.compactMap(\.sourceCropPath)
        context.delete(page)
        do {
            try context.save()
        } catch {
            return
        }
        try? imageStore.remove(relativePath: originalPath)
        for path in cropPaths {
            try? imageStore.remove(relativePath: path)
        }
    }

    /// The user pressing "Tekrar dene" — not the queue retrying by itself.
    ///
    /// That distinction is what `forceResubmit` carries: only a person can know
    /// something the server's own "do not retry this" verdict does not, and
    /// without it a page the server gave up on stayed stuck no matter how many
    /// times this was tapped (§17; `CardGenerationRequest.forceResubmit`).
    func retry(_ page: CapturedPage) async {
        guard page.processingState == .temporaryFailure || page.processingState == .permanentFailure else { return }
        // A run already in flight for this page will finish and write its own
        // outcome; resetting the state under it and starting a second run only
        // sets up the duplicate-generation race `process`'s comment describes.
        guard (inFlightPageCounts[page.id] ?? 0) == 0 else { return }
        page.retryCount = 0
        page.nextAttemptAt = nil
        page.processingState = .captured
        try? container.mainContext.save()
        await process(page, forceResubmit: true)
        // A manual retry that fails transiently sets `nextAttemptAt` like any
        // other run, but nothing was honouring it: `scheduleRetryDrain` only ran
        // at the end of `processPending`, so "kendiliğinden yeniden denenecek"
        // meant "when you next open the app".
        scheduleRetryDrain()
    }
}
