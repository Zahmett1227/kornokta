import SwiftUI
import SwiftData
import CizgiCore

/// Daily review (ANA-PLAN §5.4, §6.5).
///
/// No network and no model call anywhere in this screen — §11.4 lists review as
/// a place that must never hit an API, and §24.5 requires it to work offline.
///
/// The queue itself lives in `ReviewSession` (CizgiCore) so the parts that can
/// go wrong quietly — the limits, relearning, undo — are covered by `swift test`
/// rather than only by tapping through on a device. This file is the shell: what
/// is on screen, and what a tap means.
struct ReviewView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context

    @Query private var allCards: [Card]

    /// `nil` before the user has chosen a session — §6.5 asks for the count and
    /// an estimate *before* the first card, not after it.
    @State private var session: ReviewSession?
    @State private var isAnswerVisible = false
    @State private var shownAt = Date()
    /// The one grade that can be taken back. Only ever the last one.
    @State private var lastGrade: GradeSnapshot?
    @State private var ledger = DailyNewCardLedger()
    @State private var secondsPerCard = ReviewPace.fallbackSecondsPerCard

    /// Everything the planner needs, read once per render from the store.
    private var plannableCards: [PlannableCard] {
        allCards.map {
            PlannableCard(
                id: $0.id,
                dueDate: $0.dueDate,
                knowledgeUnitId: $0.knowledgeUnit?.id,
                status: $0.status,
                reviewCount: $0.reviewCount
            )
        }
    }

    /// What a full session would contain right now. Recomputed rather than
    /// cached so the start and completion screens both tell the truth about
    /// cards that fell due while the user was here.
    private var pendingIds: [UUID] {
        ReviewSessionPlanner.session(
            cards: plannableCards,
            now: .now,
            newCardLimit: environment.settings.dailyNewCardLimit,
            alreadyIntroducedToday: ledger.count(on: .now)
        )
    }

    private var quickSessionCardCount: Int {
        ReviewPace.cardCount(
            forMinutes: environment.settings.quickSessionMinutes,
            secondsPerCard: secondsPerCard
        )
    }

    private var currentCard: Card? {
        guard let id = session?.current else { return nil }
        return allCards.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Cizgi.paper.ignoresSafeArea()
                Group {
                    if let session, !session.isFinished {
                        if let card = currentCard {
                            cardBody(card, session: session)
                        } else {
                            // The card was deleted from Bilgilerim mid-session.
                            // Skipping is the only sensible move; it must not
                            // strand the session on a blank screen.
                            Color.clear.onAppear { skipMissingCard() }
                        }
                    } else if session != nil {
                        completionScreen
                    } else {
                        startScreen
                    }
                }
            }
            .navigationTitle("Tekrar")
            .homeButtonToolbar()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let session, !session.isFinished {
                        Text("\(session.completed + 1) / \(session.total)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if lastGrade != nil {
                        Button {
                            undoLastGrade()
                        } label: {
                            Label("Geri al", systemImage: "arrow.uturn.backward")
                        }
                        .tint(Cizgi.accent)
                    }
                }
            }
        }
        .tint(Cizgi.accent)
        .onAppear(perform: refreshMeasurements)
    }

    // MARK: Start

    @ViewBuilder
    private var startScreen: some View {
        let pending = pendingIds.count
        if pending == 0 {
            emptyState(
                title: "Bugünlük bitti",
                icon: "checkmark.circle",
                message: "Şu an tekrar bekleyen kart yok."
            )
        } else {
            VStack(spacing: Cizgi.Space.xl) {
                VStack(spacing: Cizgi.Space.xs) {
                    Text("\(pending)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(Cizgi.ink)
                    Text("kart tekrar bekliyor")
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.muted)
                    Text("≈ \(estimatedMinutes(for: pending)) dk")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }

                VStack(spacing: Cizgi.Space.sm) {
                    Button("Tekrara başla") { startSession(cap: nil) }
                        .buttonStyle(CizgiPrimaryButtonStyle())

                    // Offered only when it would actually be shorter — a "quick"
                    // session that is the whole queue is just a confusing second
                    // name for the button above it.
                    if quickSessionCardCount < pending {
                        Button("Hızlı oturum · \(environment.settings.quickSessionMinutes) dk") {
                            startSession(cap: quickSessionCardCount)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.accent)
                    }
                }
            }
            .padding(Cizgi.Space.xl)
        }
    }

    @ViewBuilder
    private var completionScreen: some View {
        let reviewed = session?.total ?? 0
        let pending = pendingIds.count
        VStack(spacing: Cizgi.Space.lg) {
            emptyState(
                title: "Oturum tamamlandı",
                icon: "checkmark.seal.fill",
                message: "\(reviewed) kart tekrar edildi."
            )
            if pending > 0 {
                // Reachable again without relaunching the app: the old screen
                // refused to rebuild a non-empty queue, so a finished session
                // was final until the process restarted.
                Button("Yeni oturum · \(pending) kart") { startSession(cap: nil) }
                    .buttonStyle(CizgiPrimaryButtonStyle())
                    .padding(.horizontal, Cizgi.Space.xl)
            } else {
                Text("Bugünlük bitti.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
            }
        }
    }

    private func emptyState(title: String, icon: String, message: String) -> some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(Cizgi.accent)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
        }
        .padding(Cizgi.Space.xl)
    }

    // MARK: Card

    private func cardBody(_ card: Card, session: ReviewSession) -> some View {
        VStack(spacing: Cizgi.Space.lg) {
            progressBar(session)

            ScrollView {
                flashcard(card)
                    .padding(.horizontal, Cizgi.Space.lg)
                    .padding(.top, Cizgi.Space.sm)
            }

            actionArea(card)
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.bottom, Cizgi.Space.md)
        }
        .padding(.top, Cizgi.Space.sm)
    }

    private func progressBar(_ session: ReviewSession) -> some View {
        GeometryReader { geo in
            let fraction = session.total == 0 ? 0 : Double(session.completed) / Double(session.total)
            ZStack(alignment: .leading) {
                Capsule().fill(Cizgi.hairline)
                Capsule().fill(Cizgi.highlighter)
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .padding(.horizontal, Cizgi.Space.lg)
    }

    private func flashcard(_ card: Card) -> some View {
        CardSurface(highlighted: true, padding: Cizgi.Space.xl) {
            VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                CardTypeBadge(type: card.type)

                Text(card.front)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if isAnswerVisible {
                    Rectangle().fill(Cizgi.hairline).frame(height: 1)

                    Text(card.back)
                        .font(.title3)
                        .foregroundStyle(Cizgi.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    if let explanation = card.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(Cizgi.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let quote = card.sourceQuote, !quote.isEmpty {
                        DisclosureGroup("Kaynağı göster") {
                            Text(quote)
                                .font(.footnote)
                                .foregroundStyle(Cizgi.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline)
                        .tint(Cizgi.accent)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isAnswerVisible)
    }

    @ViewBuilder
    private func actionArea(_ card: Card) -> some View {
        if isAnswerVisible {
            gradeButtons(for: card)
        } else {
            Button("Cevabı göster") {
                withAnimation { isAnswerVisible = true }
            }
            .buttonStyle(CizgiPrimaryButtonStyle())
        }
    }

    private func gradeButtons(for card: Card) -> some View {
        HStack(spacing: Cizgi.Space.sm) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button {
                    grade(card, rating)
                } label: {
                    Text(rating.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Cizgi.Space.md)
                        .background(rating.tint)
                        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Session control

    /// Reads the two measured inputs the start screen needs. Never touches
    /// `session`: coming back to this tab mid-session must resume, not restart.
    private func refreshMeasurements() {
        ledger = DailyNewCardLedger.load()
        secondsPerCard = measuredSecondsPerCard()
    }

    /// The pace this user actually works at, from the response times every
    /// `ReviewLog` has been recording since Faz 1 and nothing ever read.
    private func measuredSecondsPerCard() -> Double {
        var descriptor = FetchDescriptor<ReviewLog>(
            sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)]
        )
        descriptor.fetchLimit = ReviewPace.sampleSize
        let recent = (try? context.fetch(descriptor)) ?? []
        return ReviewPace.secondsPerCard(recentResponseTimesMs: recent.map(\.responseTimeMs))
    }

    private func estimatedMinutes(for cardCount: Int) -> Int {
        max(1, Int((Double(cardCount) * secondsPerCard / 60).rounded()))
    }

    private func startSession(cap: Int?) {
        ledger = DailyNewCardLedger.load()
        let queue = ReviewSessionPlanner.session(
            cards: plannableCards,
            now: .now,
            newCardLimit: environment.settings.dailyNewCardLimit,
            alreadyIntroducedToday: ledger.count(on: .now),
            cap: cap
        )
        session = ReviewSession(queue: queue)
        isAnswerVisible = false
        lastGrade = nil
        shownAt = .now
    }

    /// A card deleted from Bilgilerim while this session was open.
    private func skipMissingCard() {
        guard var working = session else { return }
        working.advance()
        session = working
        lastGrade = nil
        isAnswerVisible = false
        shownAt = .now
    }

    // MARK: Grading

    /// Everything needed to put one grade back exactly as it was.
    private struct GradeSnapshot {
        let step: ReviewSession.Step
        let logId: UUID
        let dueDate: Date
        let stability: Double
        let difficulty: Double
        let reviewCount: Int
        let lapseCount: Int
        let lastReviewedAt: Date?
        let updatedAt: Date
        /// Whether this grade spent one of today's new-card allowances.
        let countedAsNew: Bool
    }

    private func grade(_ card: Card, _ rating: ReviewRating) {
        guard var working = session else { return }

        let state = SchedulingState(
            stability: card.stability,
            difficulty: card.difficulty,
            reviewCount: card.reviewCount,
            lapseCount: card.lapseCount,
            lastReviewedAt: card.lastReviewedAt
        )
        let now = Date()
        let result = environment.scheduler.schedule(rating: rating, state: state, now: now)

        let elapsedDays = card.lastReviewedAt.map {
            now.timeIntervalSince($0) / 86_400
        } ?? 0

        let log = ReviewLog(
            reviewedAt: now,
            rating: rating,
            responseTimeMs: Int(now.timeIntervalSince(shownAt) * 1000),
            scheduledDays: result.scheduledDays,
            elapsedDays: elapsedDays,
            stabilityBefore: card.stability,
            stabilityAfter: result.stability,
            difficultyBefore: card.difficulty,
            difficultyAfter: result.difficulty
        )
        log.card = card
        context.insert(log)

        // Captured before the card is mutated — this is the only record of what
        // it was, and `undo` has nowhere else to read it from.
        let wasNew = card.reviewCount == 0
        let snapshotFields = (
            dueDate: card.dueDate,
            stability: card.stability,
            difficulty: card.difficulty,
            reviewCount: card.reviewCount,
            lapseCount: card.lapseCount,
            lastReviewedAt: card.lastReviewedAt,
            updatedAt: card.updatedAt
        )

        card.dueDate = result.dueDate
        card.stability = result.stability
        card.difficulty = result.difficulty
        card.reviewCount += 1
        if rating == .again { card.lapseCount += 1 }
        card.lastReviewedAt = now
        card.updatedAt = now

        try? context.save()

        if wasNew {
            ledger.record(on: now)
            ledger.save()
        }

        // A forgotten card goes back into this session rather than waiting for
        // the next one — the scheduler just gave it a ten-minute interval, and
        // a frozen queue had nothing to act on it with.
        let step = working.advance(relearn: rating == .again)
        session = working

        if let step {
            lastGrade = GradeSnapshot(
                step: step,
                logId: log.id,
                dueDate: snapshotFields.dueDate,
                stability: snapshotFields.stability,
                difficulty: snapshotFields.difficulty,
                reviewCount: snapshotFields.reviewCount,
                lapseCount: snapshotFields.lapseCount,
                lastReviewedAt: snapshotFields.lastReviewedAt,
                updatedAt: snapshotFields.updatedAt,
                countedAsNew: wasNew
            )
        }

        withAnimation { isAnswerVisible = false }
        shownAt = .now
    }

    /// Puts the last grade back: the card's scheduling state, the review log,
    /// today's new-card allowance and the queue position.
    ///
    /// Without this a mis-tap on "Kolay" was permanent — FSRS would not show
    /// that card again for weeks and there was no way to say so.
    private func undoLastGrade() {
        guard var working = session, let snapshot = lastGrade else { return }
        guard let card = allCards.first(where: { $0.id == snapshot.step.cardId }) else {
            lastGrade = nil
            return
        }

        let logId = snapshot.logId
        var descriptor = FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.id == logId })
        descriptor.fetchLimit = 1
        if let log = try? context.fetch(descriptor).first {
            context.delete(log)
        }

        card.dueDate = snapshot.dueDate
        card.stability = snapshot.stability
        card.difficulty = snapshot.difficulty
        card.reviewCount = snapshot.reviewCount
        card.lapseCount = snapshot.lapseCount
        card.lastReviewedAt = snapshot.lastReviewedAt
        card.updatedAt = snapshot.updatedAt

        try? context.save()

        if snapshot.countedAsNew {
            ledger.undoRecord(on: .now)
            ledger.save()
        }

        working.rewind(snapshot.step)
        session = working
        lastGrade = nil
        // The answer was on screen when they graded; putting it back hidden
        // would make them recall a card they have just seen the answer to.
        isAnswerVisible = true
        shownAt = .now
    }
}
