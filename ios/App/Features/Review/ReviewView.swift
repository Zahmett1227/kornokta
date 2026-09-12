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
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    /// Read for one decision: whether the four grades still fit on one row.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Query private var allCards: [Card]
    @AppStorage(CardScope.storageKey) private var collectionRaw = CardScope.fallback.rawValue

    /// `nil` before the user has chosen a session — §6.5 asks for the count and
    /// an estimate *before* the first card, not after it.
    @State private var session: ReviewSession?
    @State private var isAnswerVisible = false
    /// Which option the user tapped on a five-option card, as an index into the
    /// card's canonical option list. `nil` before they answer — and also after
    /// an undo, where the answer is on screen but nobody picked anything.
    @State private var selectedOption: Int?
    @State private var shownAt = Date()
    /// The one grade that can be taken back. Only ever the last one.
    @State private var lastGrade: GradeSnapshot?
    /// Non-nil while the edit sheet is up, for the card being corrected.
    @State private var editingCard: Card?
    @State private var ledger = DailyNewCardLedger()
    @State private var secondsPerCard = ReviewPace.fallbackSecondsPerCard

    private var collection: CardCollection { CardScope.collection(fromStored: collectionRaw) }

    /// The active deck. Every listing on this screen goes through here; a card
    /// the session already chose is fetched by id (`card(withId:)`), never
    /// found by scanning this.
    private var scopedCards: [Card] { CardScope.cards(allCards, in: collection) }

    /// Everything the planner needs, read once per render from the store.
    private var plannableCards: [PlannableCard] {
        scopedCards.map {
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
            newCardLimit: effectiveNewCardLimit,
            alreadyIntroducedToday: ledger.count(on: .now)
        )
    }

    /// How many new cards this deck may introduce today.
    ///
    /// The two decks are paced by different mechanisms and a single number
    /// cannot serve both (2026-09-10). Captures arrive a page at a time, so a
    /// daily ceiling is the right shape and Ayarlar's stepper sets it. Concepts
    /// arrive thousands at a time and are paced at the other end: nothing leaves
    /// the queue until the owner presses a batch button, which is itself the
    /// decision "today I want this many". Applying the stepper on top would
    /// overrule him — press `+50` and see 20 — so the cards he has explicitly
    /// released are not held back again here.
    private var effectiveNewCardLimit: Int {
        switch collection {
        case .capture: return environment.settings.dailyNewCardLimit
        case .concept: return .max
        }
    }

    private var quickSessionCardCount: Int {
        ReviewPace.cardCount(
            forMinutes: environment.settings.quickSessionMinutes,
            secondsPerCard: secondsPerCard
        )
    }

    /// Fetched by id, not found by scanning `allCards` — see the matching
    /// comment in `ExerciseView.currentCard` for what that scan cost.
    private var currentCard: Card? {
        guard let id = session?.current else { return nil }
        return card(withId: id)
    }

    private func card(withId id: UUID) -> Card? {
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// A sitting is in progress — the screen is a card, not a menu.
    ///
    /// Everything that makes this screen focused reads from here: the large
    /// title collapses, the deck switcher goes away, the tab bar hides and
    /// "Bitir" appears in its place.
    private var isSessionActive: Bool {
        guard let session else { return false }
        return !session.isFinished
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Cizgi.paper.ignoresSafeArea()
                Group {
                    if let session, !session.isFinished {
                        if let card = currentCard {
                            // Keyed on the card for the reason in ExerciseView:
                            // without it the answer-hide in `grade` animated
                            // across the swap and leaked the previous answer.
                            cardBody(card, session: session)
                                .id(card.id)
                        } else {
                            // The card was deleted from Bilgilerim mid-session.
                            // Skipping is the only sensible move; it must not
                            // strand the session on a blank screen.
                            //
                            // Keyed on the position so that a *run* of deleted
                            // cards is skipped one by one: without a changing
                            // identity SwiftUI reuses this view and `onAppear`
                            // never fires again, leaving the session parked on
                            // the second missing card for ever.
                            Color.clear
                                .onAppear { skipCurrentCard() }
                                .id(session.completed)
                        }
                    } else if navigator.selectedTab != .review {
                        // Not on screen. Both screens below plan the whole deck
                        // (`pendingIds`), and TabView re-evaluates this body on
                        // every card change even while another tab is up: ~40%
                        // of main-thread time per Egzersiz answer before this
                        // guard (Time Profiler, 2026-09-11). Switching back
                        // re-plans in the same transaction that shows the tab,
                        // so the counts are never stale when seen.
                        Color.clear
                    } else if session != nil {
                        completionScreen
                    } else {
                        startScreen
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Hidden mid-session: the switcher would be a second way to
                // end a run, next to a progress counter that says one is in
                // flight. `onChange` below covers the case where it is flipped
                // from another screen while this one is alive.
                if !isSessionActive {
                    CardScopePicker().background(Cizgi.paper)
                }
            }
            .rootTabBarInset()
            .navigationTitle("Tekrar")
            // Mid-session the title is ~90pt of chrome telling the user
            // something the card in front of them already says. Collapsing it
            // is what gives the card room to sit in the middle of the screen
            // instead of against the top of it.
            .navigationBarTitleDisplayMode(isSessionActive ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The only exit while the tab bar is hidden — the rule at
                    // `AppNavigator.isTabBarHidden`. Tekrar is a tab root, so
                    // there is no back button either.
                    if isSessionActive {
                        Button("Bitir") { endSession() }
                            .tint(Cizgi.accent)
                            .accessibilityLabel("Tekrarı bitir")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if let session, !session.isFinished {
                        Text("\(session.completed + 1) / \(session.total)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if lastGrade != nil {
                        Button {
                            undoLastGrade()
                        } label: {
                            Label("Geri al", systemImage: "arrow.uturn.backward")
                        }
                        .tint(Cizgi.accent)
                    }
                    // §6.5 asks for "Kartı düzenle/askıya al" from the review
                    // screen, and this is where a bad card is actually noticed —
                    // having to remember it and find it in Bilgilerim afterwards
                    // is how a wrong card survives.
                    if let card = currentCard {
                        Menu {
                            Button {
                                editingCard = card
                            } label: {
                                Label("Kartı düzenle", systemImage: "pencil")
                            }
                            Button {
                                suspend(card)
                            } label: {
                                Label("Askıya al", systemImage: "pause.circle")
                            }
                        } label: {
                            Label("Kart işlemleri", systemImage: "ellipsis.circle")
                        }
                        .tint(Cizgi.accent)
                    }
                }
            }
        }
        .tint(Cizgi.accent)
        .onAppear {
            refreshMeasurements()
            navigator.isTabBarHidden = isSessionActive
        }
        // Focus, and the reason "Bitir" exists above: a grade row and a tab bar
        // stacked on top of each other are two rows of controls under the same
        // thumb, and the tab bar is the one that loses the user's place.
        .onChange(of: isSessionActive) { _, active in
            navigator.isTabBarHidden = active
        }
        .onDisappear { navigator.isTabBarHidden = false }
        // A queue built from one deck must not outlive a switch to the other:
        // its ids still resolve through `allCards`, so the session would go on
        // showing cards the active scope hides. Ending it is the honest
        // reading of "I am studying the other deck now".
        .onChange(of: collectionRaw) {
            session = nil
            isAnswerVisible = false
            selectedOption = nil
            lastGrade = nil
            // Each deck keeps its own day's tally, so the one held in `@State`
            // belongs to the deck we just left. Without this the start screen
            // would count the other deck's new cards against this one.
            ledger = DailyNewCardLedger.load(for: collection)
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(card: card)
        }
    }

    // MARK: Start

    @ViewBuilder
    private var startScreen: some View {
        let pending = pendingIds.count
        if pending == 0 {
            VStack(spacing: Cizgi.Space.lg) {
                emptyState(
                    title: "Bugünlük bitti",
                    icon: "checkmark.circle",
                    message: "Şu an tekrar bekleyen kart yok."
                )
                // Offered here too, not only above: with nothing due this is
                // exactly when someone wants to go over a subject anyway.
                exerciseLink
            }
        } else {
            VStack(spacing: Cizgi.Space.xl) {
                VStack(spacing: Cizgi.Space.xs) {
                    // Serifin üç yerinden biri: büyük sayı. Buradaki
                    // `.system(design: .rounded)` tasarım dilinden önce
                    // kalmıştı ve temanın kendi kuralını çiğniyordu.
                    Text("\(pending)")
                        .font(Cizgi.serif(56, relativeTo: .largeTitle))
                        .foregroundStyle(Cizgi.ink)
                    Text("kart tekrar bekliyor")
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.muted)
                    Text("≈ \(ReviewIntervalLabel.sessionEstimate(minutes: estimatedMinutes(for: pending)))")
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

                    exerciseLink
                }
            }
            .padding(Cizgi.Space.xl)
        }
    }

    /// Free practice, deliberately a secondary control: it changes no
    /// scheduling state, so it must not compete with the real review session.
    private var exerciseLink: some View {
        Button {
            navigator.openExercise()
        } label: {
            Label("Egzersiz · karışık, puansız", systemImage: "shuffle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.accent)
        }
        .buttonStyle(.plain)
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
        VStack(spacing: Cizgi.Space.md) {
            progressBar(session)

            // Anchored to the top, which centring briefly was not.
            //
            // Centring was the right fix for a floating box stranded in an
            // empty screen, and the wrong one for a page: it moved the question
            // upward at the moment the answer appeared, so the line being read
            // jumped under the eye on every single card. A page starts at the
            // top and grows down, and the space left below a short card is
            // margin rather than a void now that nothing is drawn around it.
            ScrollView {
                flashcard(card)
                    .padding(.horizontal, Cizgi.Space.lg)
                    .padding(.top, Cizgi.Space.md)
            }
            .scrollBounceBehavior(.basedOnSize)

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
                    // On the first card of a twenty-card queue the filled part
                    // is a couple of points wide and reads as a rendering
                    // fault rather than as progress. The floor is a starting
                    // mark, not a claim about how far in the user is.
                    .frame(width: max(10, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, Cizgi.Space.lg)
        .accessibilityElement()
        .accessibilityLabel("İlerleme")
        .accessibilityValue("\(session.total) karttan \(session.completed) tanesi bitti")
    }

    private func flashcard(_ card: Card) -> some View {
        ReviewCardFace(card: card, isAnswerVisible: isAnswerVisible) {
            if let options = card.options {
                optionList(card, options: options)
            }
        } footer: {
            // §5.5. The old gate was `card.sourceQuote`, which the Faz 6
            // contract never fills — so on every card the app now makes,
            // "Kaynağı göster" was unreachable. Resolved from the page the
            // card actually came from instead.
            let source = CardSourceView.material(for: card, imageStore: environment.imageStore)
            if !source.isEmpty {
                DisclosureGroup("Kaynağı göster") {
                    CardSourceView(material: source, imageStore: environment.imageStore)
                        .padding(.top, Cizgi.Space.sm)
                }
                .font(.subheadline)
                .tint(Cizgi.accent)
            }
        }
    }

    @ViewBuilder
    private func actionArea(_ card: Card) -> some View {
        if isAnswerVisible {
            // Picking a wrong option *is* "Unuttum". Offering the four grades
            // there would let the user mark a card they demonstrably could not
            // answer as "İyi", and FSRS would believe it — a lie written into
            // the card's history for weeks (§18.2).
            if let picked = selectedOption, let options = card.options {
                if options[picked].isCorrect {
                    gradeButtons(for: card, ratings: [.hard, .good, .easy])
                } else {
                    Button("Devam") { grade(card, .again) }
                        .buttonStyle(CizgiPrimaryButtonStyle())
                }
            } else {
                gradeButtons(for: card, ratings: ReviewRating.allCases)
            }
        } else if card.options != nil {
            // The options are the button: a "Cevabı göster" here would let the
            // user see the answer before committing to one, which is the whole
            // point of asking.
            Text("Bir şık seç")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
                .frame(maxWidth: .infinity)
        } else {
            Button("Cevabı göster") {
                withAnimation { isAnswerVisible = true }
            }
            .buttonStyle(CizgiPrimaryButtonStyle())
        }
    }

    /// The five options, in an order that is stable for this sitting but not
    /// for ever (`MultipleChoice.presentationOrder`).
    @ViewBuilder
    private func optionList(_ card: Card, options: [CardOption]) -> some View {
        let order = MultipleChoice.presentationOrder(
            cardId: card.id,
            reviewCount: card.reviewCount,
            count: options.count
        )
        VStack(spacing: Cizgi.Space.sm) {
            ForEach(order, id: \.self) { index in
                optionRow(card, options: options, index: index)
            }
        }
    }

    private func optionRow(_ card: Card, options: [CardOption], index: Int) -> some View {
        let option = options[index]
        let picked = selectedOption == index
        let revealed = isAnswerVisible
        // Colour never carries the meaning on its own (§29): every revealed row
        // also gets an icon, and the wrong pick gets its reason in words.
        let tint: Color = revealed ? (option.isCorrect ? Cizgi.success : (picked ? Cizgi.danger : Cizgi.muted)) : Cizgi.ink
        let icon: String? = revealed
            ? (option.isCorrect ? "checkmark.circle.fill" : (picked ? "xmark.circle.fill" : nil))
            : nil

        return Button {
            guard !isAnswerVisible else { return }
            withAnimation {
                selectedOption = index
                isAnswerVisible = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Cizgi.Space.sm) {
                    if let icon {
                        Image(systemName: icon).foregroundStyle(tint)
                    }
                    Text(option.text)
                        .font(.body)
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // §13.3's own requirement, and the part that teaches: knowing
                // *why* the option you picked was wrong.
                if revealed, !option.isCorrect, let why = option.why, !why.isEmpty {
                    Text(why)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Cizgi.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .stroke(revealed && (option.isCorrect || picked) ? tint : Cizgi.hairline,
                            lineWidth: revealed && (option.isCorrect || picked) ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAnswerVisible)
        .accessibilityLabel(
            revealed
                ? "\(option.text), \(option.isCorrect ? "doğru cevap" : (picked ? "senin seçimin, yanlış" : "yanlış"))"
                : option.text
        )
    }

    @ViewBuilder
    private func gradeButtons(for card: Card, ratings: [ReviewRating]) -> some View {
        let previews = intervalPreviews(for: card, ratings: ratings)
        if dynamicTypeSize.isAccessibilitySize {
            // Four columns leave about 86pt each, and at the accessibility
            // sizes every label truncates — "Unut…" over "oturu…" (simulator,
            // AX5). A grade button whose word cannot be read is worse than one
            // with no interval under it, so the row breaks into two columns
            // rather than shrinking further.
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Cizgi.Space.sm),
                    GridItem(.flexible(), spacing: Cizgi.Space.sm)
                ],
                spacing: Cizgi.Space.sm
            ) {
                ForEach(ratings, id: \.self) { gradeButton(card, $0, previews) }
            }
        } else {
            HStack(spacing: Cizgi.Space.sm) {
                ForEach(ratings, id: \.self) { gradeButton(card, $0, previews) }
            }
        }
    }

    private func gradeButton(
        _ card: Card,
        _ rating: ReviewRating,
        _ previews: [ReviewRating: (short: String, spoken: String)]
    ) -> some View {
        CizgiChoiceButton(
            title: rating.label,
            detail: previews[rating]?.short,
            spokenDetail: previews[rating]?.spoken,
            tint: rating.tint
        ) {
            grade(card, rating)
        }
    }

    /// What each grade would do to this card, asked of the same scheduler the
    /// tap is about to use.
    ///
    /// Until now the four buttons were unlabelled bets: FSRS's whole value is
    /// that "Zor" and "İyi" move the card by very different amounts, and the
    /// screen was hiding the one number that makes the choice meaningful.
    /// `schedule` is pure (ANA-PLAN §0.8 — deterministic, offline), so asking
    /// it four times per card is four arithmetic passes and no state: nothing
    /// here writes, and the previews are thrown away when the card advances.
    ///
    /// "Unuttum" is the one grade whose interval is not what happens next. The
    /// scheduler's date *is* written to the card, but while the card still has
    /// requeue budget it comes back before this sitting ends — so a day count
    /// there would be contradicted within minutes, and the label says
    /// `oturumda` instead. Once the repeats are spent the interval is the truth
    /// again and it is shown (`ReviewSession.wouldRequeueOnAgain`).
    private func intervalPreviews(
        for card: Card,
        ratings: [ReviewRating]
    ) -> [ReviewRating: (short: String, spoken: String)] {
        let state = SchedulingState(
            stability: card.stability,
            difficulty: card.difficulty,
            reviewCount: card.reviewCount,
            lapseCount: card.lapseCount,
            lastReviewedAt: card.lastReviewedAt
        )
        let now = Date()
        var previews: [ReviewRating: (short: String, spoken: String)] = [:]
        for rating in ratings {
            if rating == .again, session?.wouldRequeueOnAgain(card.id) == true {
                previews[rating] = (ReviewIntervalLabel.sameSession, "bu oturumda yeniden")
            } else {
                let days = environment.scheduler
                    .schedule(rating: rating, state: state, now: now)
                    .scheduledDays
                previews[rating] = (
                    ReviewIntervalLabel.short(days: days),
                    ReviewIntervalLabel.spoken(days: days)
                )
            }
        }
        return previews
    }

    // MARK: Session control

    /// Reads the two measured inputs the start screen needs. Never touches
    /// `session`: coming back to this tab mid-session must resume, not restart.
    private func refreshMeasurements() {
        ledger = DailyNewCardLedger.load(for: collection)
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

    /// Silent on failure for the same reason `RootView`'s copy is: a throw here
    /// means notification permission was revoked outside the app, which Ayarlar
    /// reports the next time the toggle is touched.
    private func refreshReminders() async {
        try? await ReviewNotificationManager.reschedule(
            enabled: environment.settings.notificationsEnabled,
            hour: environment.settings.notificationHour,
            dueDates: scopedCards.filter { $0.status == .active }.map(\.dueDate)
        )
    }

    private func estimatedMinutes(for cardCount: Int) -> Int {
        max(1, Int((Double(cardCount) * secondsPerCard / 60).rounded()))
    }

    private func startSession(cap: Int?) {
        ledger = DailyNewCardLedger.load(for: collection)
        let queue = ReviewSessionPlanner.session(
            cards: plannableCards,
            now: .now,
            newCardLimit: effectiveNewCardLimit,
            alreadyIntroducedToday: ledger.count(on: .now),
            cap: cap
        )
        session = ReviewSession(queue: queue)
        isAnswerVisible = false
        selectedOption = nil
        lastGrade = nil
        shownAt = .now
    }

    /// Ends the sitting early, from "Bitir".
    ///
    /// Nothing is asked and nothing is lost, which is why — unlike Egzersiz —
    /// there is no confirmation here. Every grade was written to its card and
    /// its `ReviewLog` at the moment it was given, and there is no open record
    /// to close: Egzersiz's dialog exists because an `ExerciseRun` with a nil
    /// `finishedAt` is reopened on the next launch. The cards that were left
    /// are still due, so the start screen simply plans them again.
    private func endSession() {
        session = nil
        isAnswerVisible = false
        selectedOption = nil
        lastGrade = nil
    }

    /// Moves past the current card without grading it: it was deleted from
    /// Bilgilerim while this session was open, or just suspended.
    ///
    /// `lastGrade` is cleared because the undo it describes no longer makes
    /// sense once the queue has moved on for a reason that was not a grade.
    private func skipCurrentCard() {
        guard var working = session else { return }
        working.advance()
        session = working
        lastGrade = nil
        isAnswerVisible = false
        selectedOption = nil
        shownAt = .now
    }

    /// A suspended card is no longer active, so leaving it on screen would ask
    /// the user to grade something they have just taken out of rotation.
    private func suspend(_ card: Card) {
        card.status = .suspended
        card.updatedAt = .now
        try? context.save()
        skipCurrentCard()
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
        /// FES sicili (docs/ADR-008) — grade'den önceki değerler, undo için.
        let fesScore: Int
        let fesNegativeCount: Int
        let fesInitializedAt: Date?
        /// Whether this grade spent one of today's new-card allowances.
        let countedAsNew: Bool
        /// Which option was picked, on a five-option card.
        ///
        /// Undo used to drop this, and the screen then looked like a card whose
        /// answer was showing with nothing picked — which offers all four
        /// grades. A card just answered *wrong* could then be graded "Kolay",
        /// quietly breaking the wrong-option-is-always-`again` rule this screen
        /// exists to enforce (Codex, PR #29).
        let selectedOption: Int?
        /// The card's option list as it stood when the grade was given.
        ///
        /// An index means nothing on its own: the user can leave for Bilgilerim
        /// mid-session, reword the options, move the tick or remove them
        /// entirely, and come back. Replaying the old index against a new list
        /// would mark an option nobody chose — and, if it now happens to be the
        /// correct one, hand back the grades a wrong answer is not allowed
        /// (Codex, PR #29, second round).
        let optionsFingerprint: String?
    }

    private func grade(_ card: Card, _ rating: ReviewRating) {
        guard var working = session else { return }

        // Read before the screen resets it, so undo can put the answer back
        // exactly as it stood.
        let pickedOption = selectedOption

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
            updatedAt: card.updatedAt,
            fesScore: card.fesScore,
            fesNegativeCount: card.fesNegativeCount,
            fesInitializedAt: card.fesInitializedAt
        )

        card.dueDate = result.dueDate
        card.stability = result.stability
        card.difficulty = result.difficulty
        card.reviewCount += 1
        if rating == .again { card.lapseCount += 1 }
        card.lastReviewedAt = now
        card.updatedAt = now

        // FES sicili (docs/ADR-008): Tekrar'ın dört derecesi de besler, FSRS
        // durumundan bağımsız muhasebe. "Zor" Egzersiz'in "Kararsızdım"ı gibi
        // okunur — ikisi de kısmi puan.
        let fesSignal = FesScore.signal(for: rating)
        card.fesScore = FesScore.apply(fesSignal, to: card.fesScore)
        if fesSignal.isNegative { card.fesNegativeCount += 1 }
        // A live update is itself authoritative — it need not wait for
        // `FesBackfillMigration` to say so. Without this, a card graded
        // between one launch and the next carries a real, nonzero score next
        // to a `nil` marker; exporting it in that window and restoring
        // elsewhere replays an empty history and silently zeroes the score
        // right back out (Codex review, PR #41).
        card.fesInitializedAt = now

        try? context.save()

        if wasNew {
            ledger.record(on: now)
            ledger.save(for: collection)
        }

        // A forgotten card goes back into this session rather than waiting for
        // the next one — the scheduler just gave it a ten-minute interval, and
        // a frozen queue had nothing to act on it with.
        let step = working.advance(relearn: rating == .again)
        session = working

        // Grading moved due dates, so the reminders scheduled from the old ones
        // are now wrong. Rescheduling otherwise happens only at launch, in
        // Ayarlar and on backgrounding — so a user who cleared their reviews at
        // 19:50 and stayed in the app would get a banner at 20:00 announcing
        // cards that no longer exist, which is the exact failure this reminder
        // rewrite was for (Codex, PR #27). Done once the session ends rather
        // than per grade: withdrawing and re-adding a week of requests after
        // every card would be pure churn.
        if working.isFinished {
            Task { await refreshReminders() }
        }

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
                fesScore: snapshotFields.fesScore,
                fesNegativeCount: snapshotFields.fesNegativeCount,
                fesInitializedAt: snapshotFields.fesInitializedAt,
                countedAsNew: wasNew,
                selectedOption: pickedOption,
                optionsFingerprint: card.optionsRaw
            )
        }

        withAnimation {
            isAnswerVisible = false
            selectedOption = nil
        }
        shownAt = .now
    }

    /// Puts the last grade back: the card's scheduling state, the review log,
    /// today's new-card allowance and the queue position.
    ///
    /// Without this a mis-tap on "Kolay" was permanent — FSRS would not show
    /// that card again for weeks and there was no way to say so.
    private func undoLastGrade() {
        guard var working = session, let snapshot = lastGrade else { return }
        guard let card = self.card(withId: snapshot.step.cardId) else {
            lastGrade = nil
            return
        }

        // A throw and an empty result mean opposite things and must not be
        // collapsed with `try?`. Empty is fine — the log's own insert may have
        // failed, so there is nothing to remove. A throw leaves the log's fate
        // unknown, and undoing anyway would restore the card's scheduling state
        // while a `ReviewLog` still claims the review happened: a history that
        // contradicts the card, exported into every backup from then on.
        let logId = snapshot.logId
        var descriptor = FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.id == logId })
        descriptor.fetchLimit = 1
        let storedLog: ReviewLog?
        do {
            storedLog = try context.fetch(descriptor).first
        } catch {
            // `lastGrade` is deliberately kept, so the button stays and the user
            // can try again rather than silently losing the ability to undo.
            return
        }
        if let storedLog {
            context.delete(storedLog)
        }

        card.dueDate = snapshot.dueDate
        card.stability = snapshot.stability
        card.difficulty = snapshot.difficulty
        card.reviewCount = snapshot.reviewCount
        card.lapseCount = snapshot.lapseCount
        card.lastReviewedAt = snapshot.lastReviewedAt
        card.updatedAt = snapshot.updatedAt
        card.fesScore = snapshot.fesScore
        card.fesNegativeCount = snapshot.fesNegativeCount
        card.fesInitializedAt = snapshot.fesInitializedAt

        try? context.save()

        if snapshot.countedAsNew {
            ledger.undoRecord(on: .now)
            ledger.save(for: collection)
        }

        working.rewind(snapshot.step)
        session = working
        lastGrade = nil
        if snapshot.optionsFingerprint == card.optionsRaw {
            // The answer was on screen when they graded; putting it back hidden
            // would make them recall a card they have just seen the answer to.
            isAnswerVisible = true
            // Restored, not cleared: the grade buttons on a five-option card
            // depend on what was picked, and dropping it would hand back all
            // four.
            selectedOption = snapshot.selectedOption
        } else {
            // The options changed under the session, so there is no honest way
            // to show the old answer: the stored index points into a list that
            // no longer exists. The card is presented unanswered — which for a
            // five-option card means picking again, and for a plain one means
            // "Cevabı göster". The scheduling state is still rolled back; only
            // the display cannot be reconstructed.
            isAnswerVisible = false
            selectedOption = nil
        }
        shownAt = .now
    }
}
