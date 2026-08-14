import SwiftUI
import SwiftData
import CizgiCore

/// Egzersiz modu — free practice over the whole deck.
///
/// Same question → "Cevabı göster" → answer rhythm as `ReviewView`, and the
/// same card-edit affordance. An `ExerciseRun`/`ExerciseAttempt` history is
/// written; `ReviewLog` and the daily new-card ledger are never touched. Since
/// docs/ADR-007 an answer *may* also adjust a card's FSRS state, but only
/// through the guarded `EarlyPractice` bridge in `applyEarlyPractice` below —
/// partial credit early, soft lapse on an early miss, a real lapse only close
/// to due; due cards and "Kararsızdım" never. Anything beyond that would
/// disturb a spaced-repetition history that took months to build.
///
/// The queue itself (shuffle, position, finish) lives in `ExerciseSession` so
/// `swift test` covers it; this file is the shell.
struct ExerciseView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context

    @Query(sort: \Card.createdAt, order: .reverse) private var allCards: [Card]
    @Query(sort: \ExerciseRun.startedAt, order: .reverse) private var exerciseRuns: [ExerciseRun]

    @State private var session: ExerciseSession?
    @State private var currentRun: ExerciseRun?
    @State private var isAnswerVisible = false
    @State private var selectedOption: Int?
    @State private var shownAt = Date()
    @State private var editingCard: Card?
    /// The six-dimension filter (docs/ADR-008); ders/konu keep the same
    /// `TopicFilter` contract Bilgilerim uses.
    @State private var filter = ExerciseFilter()
    @State private var isShowingSetupSheet = false
    /// How many cards (or how much time) "Egzersize başla" should draw.
    @State private var budget: ExerciseBudget = .cards(20)
    @State private var secondsPerCard = ReviewPace.fallbackSecondsPerCard
    @State private var isConfirmingEarlyFinish = false
    /// A filter requested from another screen that arrived mid-run, parked
    /// until the user says what should happen to the run.
    @State private var pendingTarget: AppNavigator.ExerciseTarget.Filter?
    /// How many cards crossed the FES threshold (either way) this session —
    /// reset per session, not read from `Card` after the fact, since nothing
    /// else records a card's FES status *before* the run started.
    @State private var fesEnteredCount = 0
    @State private var fesLeftCount = 0

    /// Suspended cards stay out — the user has said they do not want to see
    /// them. Everything else is fair game regardless of its due date, which is
    /// the whole difference from `ReviewView`.
    private var eligibleCards: [Card] {
        let now = Date()
        return allCards.filter { card in
            card.status != .suspended && filter.matches(candidate(for: card), now: now)
        }
    }

    private func candidate(for card: Card) -> ExerciseCandidate {
        ExerciseCandidate(
            id: card.id,
            subject: card.knowledgeUnit?.subject,
            topic: card.knowledgeUnit?.topic,
            type: card.type,
            reviewCount: card.reviewCount,
            dueDate: card.dueDate,
            lowConfidence: card.lowConfidence,
            createdAt: card.createdAt,
            fesScore: card.fesScore
        )
    }

    private var currentCard: Card? {
        guard let id = session?.current else { return nil }
        return allCards.first { $0.id == id }
    }

    private var practiceOutcomes: [ExerciseOutcome] {
        exerciseRuns.flatMap(\.attempts).map {
            ExerciseOutcome(cardId: $0.cardId, result: $0.result, answeredAt: $0.answeredAt)
        }
    }

    /// FES cards (docs/ADR-008), most urgent first. Membership is
    /// `Card.fesScore` — durable, never decays. Ordering reuses
    /// `WeakPointRanking.rank` (recency-weighted practice evidence) without
    /// its own decaying `isWeak` filter overriding FES's membership rule: a
    /// card whose last miss fell outside `ExercisePracticeWeight`'s 30-day
    /// window would otherwise silently drop out of a list FES exists to
    /// keep durable.
    private var fesCards: [Card] {
        let cards = eligibleCards.filter { FesScore.isFes(score: $0.fesScore) }
        let ranked = WeakPointRanking.rank(
            cards.map {
                WeakPointCandidate(
                    cardId: $0.id,
                    lapseCount: $0.lapseCount,
                    lowConfidence: $0.lowConfidence,
                    stability: $0.stability,
                    updatedAt: $0.updatedAt
                )
            },
            outcomes: practiceOutcomes,
            now: .now
        )
        let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byId[$0.cardId] }
    }

    /// Bilgilerim's "Gözden geçir" set, narrowed by the active filter — the
    /// same cards, reachable as a quick start here too.
    private var reviewCards: [Card] {
        eligibleCards.filter(\.lowConfidence)
    }

    private var pendingTargetMessage: String {
        guard let pendingTarget else { return "" }
        let requested: String
        switch pendingTarget.topic {
        case .all: requested = pendingTarget.subject
        case .none: requested = "\(pendingTarget.subject) · Konusuz"
        case .topic(let name): requested = "\(pendingTarget.subject) · \(name)"
        }
        return "\(requested) için Egzersiz istedin. Baştan başlarsan bu oturum "
            + "yanıtladıklarınla birlikte kapanır."
    }

    private var isSessionActive: Bool {
        guard let session else { return false }
        return !session.isFinished
    }

    var body: some View {
        NavigationStack(path: $navigator.exercisePath) {
            ZStack {
                Cizgi.paper.ignoresSafeArea()
                Group {
                    if let session, !session.isFinished {
                        if let card = currentCard {
                            cardBody(card, session: session)
                        } else {
                            // Deleted from the editor mid-session. Keyed on `total`
                            // and not `completed`, unlike ReviewView: dropping a
                            // missing card shrinks the queue without moving the
                            // cursor, so `completed` would stay put, SwiftUI would
                            // reuse this view, `onAppear` would never fire again
                            // and a *run* of deleted cards would park the session
                            // on a blank screen.
                            Color.clear
                                .onAppear { skipCurrentCard() }
                                .id(session.total)
                        }
                    } else if session != nil {
                        completionScreen
                    } else {
                        startScreen
                    }
                }
            }
            .rootTabBarInset()
            .navigationTitle("Egzersiz")
            .navigationBarTitleDisplayMode(isSessionActive ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The only exit from an active run. Egzersiz is a tab root,
                    // so there is no back button, and the run hides the tab bar
                    // to stay focused: without this the user is held here until
                    // the last card of a queue that may be the whole deck — and
                    // because an unfinished run is restored on launch, killing
                    // the app would drop them straight back into it.
                    if isSessionActive {
                        Button("Bitir") { isConfirmingEarlyFinish = true }
                            .tint(Cizgi.accent)
                            .accessibilityLabel("Egzersizi bitir")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if let session, !session.isFinished {
                        Text("\(session.completed + 1) / \(session.total)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let card = currentCard {
                        // Kept from the review screen on purpose: the exercise run
                        // is exactly where a wrong card gets noticed.
                        Button {
                            editingCard = card
                        } label: {
                            Label("Kartı düzenle", systemImage: "pencil")
                        }
                        .tint(Cizgi.accent)
                        .disabled(session?.isFinished ?? true)
                        .accessibilityLabel("Kartı düzenle")
                    } else if session == nil {
                        Button {
                            isShowingSetupSheet = true
                        } label: {
                            Label(
                                "Filtrele",
                                systemImage: filter.isActive
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle"
                            )
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(card: card)
        }
        .sheet(isPresented: $isShowingSetupSheet) {
            ExerciseSetupSheet(filter: $filter, allCards: allCards)
        }
        .confirmationDialog(
            "Egzersizi bitir?",
            isPresented: $isConfirmingEarlyFinish,
            titleVisibility: .visible
        ) {
            Button("Bitir", role: .destructive) { finishEarly() }
            Button("Devam et", role: .cancel) {}
        } message: {
            Text("Yanıtladığın kartların özeti kalır; verdiğin yanıtların etkisi (ADR-007) geri alınmaz.")
        }
        .confirmationDialog(
            "Devam eden bir Egzersiz var",
            isPresented: Binding(
                get: { pendingTarget != nil },
                set: { if !$0 { pendingTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Yeni seçimle baştan başla", role: .destructive) { restartWithPendingTarget() }
            Button("Bu oturuma devam et", role: .cancel) { pendingTarget = nil }
        } message: {
            Text(pendingTargetMessage)
        }
        .tint(Cizgi.accent)
        .onAppear {
            pruneExpiredHistory()
            restoreActiveRunIfNeeded()
            secondsPerCard = measuredSecondsPerCard()
            navigator.isTabBarHidden = isSessionActive
            applyIncomingTarget()
        }
        .onChange(of: navigator.exerciseTarget?.id) { _, _ in
            applyIncomingTarget()
        }
        .onChange(of: isSessionActive) { _, active in
            navigator.isTabBarHidden = active
        }
        .onDisappear { navigator.isTabBarHidden = false }
    }

    // MARK: Start

    @ViewBuilder
    private var startScreen: some View {
        let count = eligibleCards.count
        // Computed once per render on purpose: `fesCards`/`reviewCards` walk
        // the filtered deck, and the start screen reads each for its count,
        // its disabled state and its tap.
        let fes = fesCards
        let review = reviewCards
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                ScreenHero(
                    eyebrow: "Günlük çalışma alanı",
                    title: "Bilgiyi aktif kullan",
                    subtitle: "Dilediğin konuyu karışık çalış. Yanıtların FSRS'i yalnız "
                        + "korumalı bir köprüyle, sınırlı biçimde etkiler (ADR-007).",
                    systemImage: "brain.head.profile"
                )

                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    CizgiSectionTitle(
                        "Hızlı başlangıç",
                        subtitle: "Hazırlık ekranı olmadan doğrudan çalışmaya geç."
                    )
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Cizgi.Space.md) {
                        FeatureActionCard(
                            title: "Hızlı 10",
                            subtitle: "Seçiminden 10 karışık kart",
                            systemImage: "bolt.fill",
                            isProminent: true
                        ) {
                            start(cards: eligibleCards, limit: 10, mode: .quick)
                        }
                        .disabled(count == 0)
                        .opacity(count == 0 ? 0.45 : 1)

                        // Offered only when the deck actually has FES cards
                        // (docs/ADR-008). Padding the run out with cards the
                        // user has never got wrong would make the label a lie
                        // and bury the few that actually need work.
                        FeatureActionCard(
                            title: "FES kartlar",
                            subtitle: fes.isEmpty
                                ? "Şimdilik FES kart yok"
                                : "\(fes.count) kart seni zorluyor",
                            systemImage: "flame.fill"
                        ) {
                            start(cards: fes, limit: nil, mode: .weak)
                        }
                        .disabled(fes.isEmpty)
                        .opacity(fes.isEmpty ? 0.45 : 1)

                        FeatureActionCard(
                            title: "Gözden geçir",
                            subtitle: review.isEmpty
                                ? "Gözden geçirilecek kart yok"
                                : "\(review.count) şüpheli kart",
                            systemImage: "exclamationmark.triangle.fill"
                        ) {
                            start(cards: review, limit: nil, mode: .free)
                        }
                        .disabled(review.isEmpty)
                        .opacity(review.isEmpty ? 0.45 : 1)
                    }
                }

                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        CizgiSectionTitle(
                            "Egzersizini kur",
                            subtitle: filter.isActive
                                ? "Uyguladığın filtreler aşağıda."
                                : "İstersen ders, konu, kart tipi, durum, tarih ya da FES'e göre daralt."
                        )
                        Spacer()
                        Button("Filtreleri düzenle") { isShowingSetupSheet = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Cizgi.accent)
                    }

                    ExerciseFilterChips(filter: $filter)

                    CardSurface {
                        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                            Label("\(count) kart hazır", systemImage: "rectangle.stack.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Cizgi.ink)

                            Picker("Bütçe türü", selection: budgetKindBinding) {
                                Text("Kart").tag(BudgetKind.cards)
                                Text("Süre").tag(BudgetKind.minutes)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            ChipFlowRow(budgetOptions) { option in
                                SelectableChip(title: budgetLabel(option), isSelected: budget == option) {
                                    budget = option
                                }
                            }

                            if budgetKind == .minutes, let estimated = budget.limit(secondsPerCard: secondsPerCard) {
                                Text("≈ \(estimated) kart")
                                    .font(.caption)
                                    .foregroundStyle(Cizgi.muted)
                            }

                            if count == 0 {
                                Text("Bu filtreye uyan kart yok.")
                                    .font(.subheadline)
                                    .foregroundStyle(Cizgi.muted)
                            } else {
                                Button("Egzersize başla") {
                                    start(
                                        cards: eligibleCards,
                                        limit: budget.limit(secondsPerCard: secondsPerCard),
                                        mode: .free
                                    )
                                }
                                .buttonStyle(CizgiPrimaryButtonStyle())
                            }

                            // Rewritten more than once, each time because the
                            // screen promised more independence than the code
                            // delivered (Codex, PR #36: the ADR-007 bridge
                            // really can adjust scheduling). Say what actually
                            // happens — a false "nothing changes" is a
                            // guarantee the user opts in under.
                            Text(
                                "Yanıtların ayrı bir Egzersiz geçmişine yazılır ve \"FES kartlar\" "
                                    + "seçimini besler. Erken doğrular kartı sessizce güçlendirebilir, "
                                    + "erken yanlışlar kartı öne çekebilir (ADR-007); tekrar geçmişin "
                                    + "(ReviewLog) hiç değişmez."
                            )
                            .font(.caption)
                            .foregroundStyle(Cizgi.muted)
                        }
                    }
                }

                if !completedRuns.isEmpty {
                    VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                        CizgiSectionTitle(
                            "Son Egzersizler",
                            subtitle: "Tekrar geçmişinden ayrı tutulan çalışma kayıtların."
                        )
                        ForEach(completedRuns.prefix(3)) { run in
                            runHistoryCard(run)
                        }
                    }
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
    }

    private enum BudgetKind: Hashable {
        case cards, minutes
    }

    private var budgetKind: BudgetKind {
        if case .minutes = budget { return .minutes }
        return .cards
    }

    /// Switching segments picks a sensible default for the new kind rather
    /// than leaving `budget` pointing at a value the presets row below no
    /// longer shows as selected.
    private var budgetKindBinding: Binding<BudgetKind> {
        Binding(
            get: { budgetKind },
            set: { newKind in
                switch newKind {
                case .cards: budget = .cards(ExerciseBudget.cardPresets[1])
                case .minutes: budget = .minutes(ExerciseBudget.minutePresets[0])
                }
            }
        )
    }

    private var budgetOptions: [ExerciseBudget] {
        switch budgetKind {
        case .cards: return ExerciseBudget.cardPresets.map { .cards($0) } + [.all]
        case .minutes: return ExerciseBudget.minutePresets.map { .minutes($0) } + [.all]
        }
    }

    private func budgetLabel(_ budget: ExerciseBudget) -> String {
        switch budget {
        case .cards(let count): return "\(count)"
        case .minutes(let minutes): return "\(minutes) dk"
        case .all: return "Tümü"
        }
    }

    private var completedRuns: [ExerciseRun] {
        exerciseRuns.filter { $0.finishedAt != nil }
    }

    private func runHistoryCard(_ run: ExerciseRun) -> some View {
        let knew = run.attempts.filter { $0.result == .knew }.count
        let unsure = run.attempts.filter { $0.result == .unsure }.count
        let missed = run.attempts.filter { $0.result == .missed }.count
        return CardSurface {
            HStack(spacing: Cizgi.Space.md) {
                Image(systemName: modeIcon(run.mode))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Cizgi.accent)
                    .frame(width: 42, height: 42)
                    .background(Cizgi.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(modeTitle(run.mode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.ink)
                    Text(run.startedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(Cizgi.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(knew) / \(run.attempts.count)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Cizgi.ink)
                    Text("\(unsure) kararsız · \(missed) yanlış")
                        .font(.caption2)
                        .foregroundStyle(Cizgi.muted)
                }
            }
        }
    }

    private func modeTitle(_ mode: ExerciseMode) -> String {
        switch mode {
        case .free: return "Serbest Egzersiz"
        case .quick: return "Hızlı Egzersiz"
        case .weak: return "FES Egzersizi"
        }
    }

    private func modeIcon(_ mode: ExerciseMode) -> String {
        switch mode {
        case .free: return "shuffle"
        case .quick: return "bolt.fill"
        case .weak: return "flame.fill"
        }
    }

    @ViewBuilder
    private var completionScreen: some View {
        let summary = session?.summary ?? ExerciseSummary(knew: 0, unsure: 0, missed: 0)
        let accuracy = summary.answered > 0 ? Double(summary.knew) / Double(summary.answered) : 0
        VStack(spacing: Cizgi.Space.xl) {
            VStack(spacing: Cizgi.Space.md) {
                ZStack {
                    RingGauge(progress: accuracy, tint: Cizgi.accent, lineWidth: 10)
                        .frame(width: 96, height: 96)
                    VStack(spacing: 0) {
                        Text("\(Int((accuracy * 100).rounded()))%")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Cizgi.ink)
                        Text("doğru")
                            .font(.caption2)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                Text("Egzersiz bitti")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Cizgi.ink)
                Text("\(summary.answered) kart yanıtlandı.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
                // FES sicilinin bu oturumda gerçekten hareket ettiğini
                // göstermek için — sicilin kendisi görünmez kalırsa neden
                // tutulduğu hissedilmez.
                if fesEnteredCount > 0 || fesLeftCount > 0 {
                    Text(fesDeltaText)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }

            HStack(spacing: Cizgi.Space.sm) {
                StatTile(value: "\(summary.knew)", label: "Biliyordum")
                StatTile(value: "\(summary.unsure)", label: "Kararsız")
                StatTile(value: "\(summary.missed)", label: "Bilemedim")
            }

            Button("Baştan karıştır") { restart() }
                .buttonStyle(CizgiPrimaryButtonStyle())
            Button("Bitir") { finish() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.accent)
        }
        .padding(.horizontal, Cizgi.Space.xl)
        .padding(Cizgi.Space.xl)
    }

    private var fesDeltaText: String {
        var parts: [String] = []
        if fesEnteredCount > 0 { parts.append("\(fesEnteredCount) kart FES'e girdi") }
        if fesLeftCount > 0 { parts.append("\(fesLeftCount) kart FES'ten çıktı") }
        return parts.joined(separator: " · ")
    }

    // MARK: Card

    private func cardBody(_ card: Card, session: ExerciseSession) -> some View {
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

    private func progressBar(_ session: ExerciseSession) -> some View {
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
                HStack(spacing: Cizgi.Space.sm) {
                    CardTypeBadge(type: card.type)
                    if let topic = card.knowledgeUnit?.topic {
                        TagChip(topic, systemImage: "tag")
                    }
                    if card.lowConfidence {
                        TagChip("Gözden geçir", systemImage: "exclamationmark.triangle.fill")
                    }
                    // Only after the answer is revealed — showing it earlier
                    // would hint "this one's hard" before the user has tried
                    // to recall it, which is exactly the measurement FES's
                    // own signal depends on not being contaminated.
                    if isAnswerVisible, FesScore.isFes(score: card.fesScore) {
                        TagChip("FES", systemImage: "flame.fill")
                    }
                }

                Text(card.front)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let options = card.options {
                    optionList(card, options: options)
                }

                if isAnswerVisible {
                    Rectangle().fill(Cizgi.hairline).frame(height: 1)

                    if card.options == nil {
                        Text(card.back)
                            .font(.title3)
                            .foregroundStyle(Cizgi.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let explanation = card.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(Cizgi.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
        }
        .animation(.easeInOut(duration: 0.2), value: isAnswerVisible)
    }

    @ViewBuilder
    private func actionArea(_ card: Card) -> some View {
        if isAnswerVisible {
            if let options = card.options, let selectedOption {
                let result: ExerciseResult = options[selectedOption].isCorrect ? .knew : .missed
                Button("Sıradaki") { recordAndAdvance(result, selectedOption: selectedOption) }
                    .buttonStyle(CizgiPrimaryButtonStyle())
            } else {
                VStack(spacing: Cizgi.Space.sm) {
                    Text("Nasıldı?")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Cizgi.muted)
                    HStack(spacing: Cizgi.Space.sm) {
                        resultButton("Bilemedim", result: .missed, tint: Cizgi.danger)
                        resultButton("Kararsızdım", result: .unsure, tint: Cizgi.warning)
                        resultButton("Biliyordum", result: .knew, tint: Cizgi.success)
                    }
                }
            }
        } else if card.options != nil {
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
        let tint: Color = revealed
            ? (option.isCorrect ? Cizgi.success : (picked ? Cizgi.danger : Cizgi.muted))
            : Cizgi.ink
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

    // MARK: Actions

    /// `.weak` is the only mode whose incoming order carries meaning, so it is
    /// the only one that takes a prefix. The rest are sampled: `eligibleCards`
    /// is `createdAt` descending, and a prefix of that is the same newest N
    /// cards every single time — "Hızlı 10" would never show card eleven.
    private func start(cards: [Card], limit: Int?, mode: ExerciseMode) {
        var generator = SystemRandomNumberGenerator()
        let selected = ExerciseSelection.pick(
            from: cards.map(\.id),
            limit: limit,
            ranked: mode == .weak,
            using: &generator
        )
        let newSession = ExerciseSession(cardIds: selected, using: &generator)
        session = newSession
        fesEnteredCount = 0
        fesLeftCount = 0
        beginRun(for: newSession, mode: mode)
        resetCardState()
    }

    private func restart() {
        guard var restarted = session else { return }
        var generator = SystemRandomNumberGenerator()
        restarted.restart(using: &generator)
        session = restarted
        fesEnteredCount = 0
        fesLeftCount = 0
        beginRun(for: restarted, mode: currentRun?.mode ?? .free)
        resetCardState()
    }

    /// Stops the run where it stands and shows the finish screen for what was
    /// answered. The run is closed in the same breath: an `ExerciseRun` with no
    /// `finishedAt` is what `restoreActiveRunIfNeeded` reopens on launch, so
    /// leaving one behind would put the user back inside the session they just
    /// asked to leave.
    private func finishEarly() {
        guard var working = session else { return }
        working.finishEarly()
        session = working
        currentRun?.position = working.position
        currentRun?.finishedAt = .now
        try? context.save()
        resetCardState()
    }

    private func finish() {
        // Belt and braces for the same reason as `finishEarly`: every path off
        // the completion screen must leave a closed run behind.
        if let currentRun, currentRun.finishedAt == nil {
            currentRun.finishedAt = .now
            try? context.save()
        }
        session = nil
        currentRun = nil
        resetCardState()
    }

    private func recordAndAdvance(_ result: ExerciseResult, selectedOption: Int? = nil) {
        guard var working = session, let cardId = working.current else { return }
        let answeredAt = Date()
        if let currentRun {
            let attempt = ExerciseAttempt(
                cardId: cardId,
                result: result,
                selectedOption: selectedOption,
                responseTimeMs: max(0, Int(answeredAt.timeIntervalSince(shownAt) * 1_000)),
                answeredAt: answeredAt
            )
            attempt.run = currentRun
            context.insert(attempt)
        }

        // The guarded FSRS bridge (docs/ADR-007): a practice answer may earn
        // partial stability credit, pull a missed card forward, or — close
        // enough to due — count as a real lapse. All policy lives in
        // `EarlyPractice`; the card is only ever touched with what it returns.
        if let card = allCards.first(where: { $0.id == cardId }) {
            applyFesScore(result: result, to: card)
            applyEarlyPractice(result: result, to: card, at: answeredAt)
        }

        working.record(result)
        session = working
        currentRun?.position = working.position
        if working.isFinished {
            currentRun?.finishedAt = answeredAt
        }
        try? context.save()
        resetCardState()
    }

    /// FES sicili (docs/ADR-008): every answer counts, `unsure` included, and
    /// independent of `EarlyPractice`'s due/frozen gates — pure bookkeeping
    /// that never touches FSRS state. The save rides `recordAndAdvance`'s
    /// existing `context.save()`.
    private func applyFesScore(result: ExerciseResult, to card: Card) {
        let wasFes = FesScore.isFes(score: card.fesScore)
        let signal = FesScore.signal(for: result)
        card.fesScore = FesScore.apply(signal, to: card.fesScore)
        if signal.isNegative { card.fesNegativeCount += 1 }

        let isFesNow = FesScore.isFes(score: card.fesScore)
        if !wasFes, isFesNow { fesEnteredCount += 1 }
        if wasFes, !isFesNow { fesLeftCount += 1 }
    }

    /// Applies exactly what `EarlyPractice.update` allows, nothing more. The
    /// save rides `recordAndAdvance`'s existing `context.save()`.
    private func applyEarlyPractice(result: ExerciseResult, to card: Card, at now: Date) {
        let update = EarlyPractice.update(
            result: result,
            state: SchedulingState(
                stability: card.stability,
                difficulty: card.difficulty,
                reviewCount: card.reviewCount,
                lapseCount: card.lapseCount,
                lastReviewedAt: card.lastReviewedAt
            ),
            dueDate: card.dueDate,
            lastPracticedAt: card.lastPracticedAt,
            scheduler: environment.scheduler,
            now: now
        )
        guard update.touchesCard else { return }
        if let stability = update.stability { card.stability = stability }
        if let difficulty = update.difficulty { card.difficulty = difficulty }
        if let dueDate = update.dueDate { card.dueDate = dueDate }
        if let lastReviewedAt = update.lastReviewedAt { card.lastReviewedAt = lastReviewedAt }
        if let lastPracticedAt = update.lastPracticedAt { card.lastPracticedAt = lastPracticedAt }
        card.reviewCount += update.reviewCountDelta
        card.lapseCount += update.lapseCountDelta
        card.softLapseCount += update.softLapseCountDelta
        card.updatedAt = now
    }

    private func resultButton(_ title: String, result: ExerciseResult, tint: Color) -> some View {
        Button(title) { recordAndAdvance(result) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Cizgi.Space.md)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .stroke(tint.opacity(0.55), lineWidth: 1.5)
            )
    }

    private func skipCurrentCard() {
        guard let id = session?.current else { return }
        session?.remove(id)
        if let session {
            currentRun?.queuedCardIds = session.queue.map(\.uuidString)
            currentRun?.position = session.position
            if session.isFinished { currentRun?.finishedAt = .now }
            try? context.save()
        }
        resetCardState()
    }

    /// The pace this user actually practises at, from `ExerciseAttempt`'s own
    /// response times — `ReviewView.measuredSecondsPerCard`'s counterpart,
    /// same sample size and fallback, different table. Kept separate from
    /// Tekrar's measurement on purpose: practice and graded review are
    /// different rhythms, and mixing the two samples would let a fast
    /// practice streak understate a genuinely slower review pace or the
    /// other way round.
    private func measuredSecondsPerCard() -> Double {
        var descriptor = FetchDescriptor<ExerciseAttempt>(
            sortBy: [SortDescriptor(\.answeredAt, order: .reverse)]
        )
        descriptor.fetchLimit = ReviewPace.sampleSize
        let recent = (try? context.fetch(descriptor)) ?? []
        return ReviewPace.secondsPerCard(recentResponseTimesMs: recent.map(\.responseTimeMs))
    }

    private func resetCardState() {
        isAnswerVisible = false
        selectedOption = nil
        shownAt = .now
    }

    private func beginRun(for session: ExerciseSession, mode: ExerciseMode) {
        let run = ExerciseRun(mode: mode, queuedCardIds: session.queue)
        // Single assignment so `subject`/`topicFilterRaw` and `filterJSON`
        // can never drift apart — see `ExerciseRun.filter`'s setter.
        run.filter = filter
        context.insert(run)
        try? context.save()
        currentRun = run
    }

    /// Runs before the restore so a stale row can never be the one reopened.
    /// Cascade delete takes the attempts with the run.
    private func pruneExpiredHistory() {
        let now = Date()
        let expired = exerciseRuns.filter {
            ExerciseHistory.isExpired(finishedAt: $0.finishedAt, now: now)
        }
        guard !expired.isEmpty else { return }
        expired.forEach(context.delete)
        try? context.save()
    }

    private func restoreActiveRunIfNeeded() {
        guard session == nil,
              let run = exerciseRuns.first(where: { $0.finishedAt == nil }),
              !run.queue.isEmpty else { return }
        // A SwiftData relationship has no defined order, so "keep the second
        // one" would not have meant "keep the newest". Sort first, then let the
        // last write win.
        let results = run.attempts
            .sorted { $0.answeredAt < $1.answeredAt }
            .reduce(into: [UUID: ExerciseResult]()) { $0[$1.cardId] = $1.result }
        let restored = ExerciseSession(
            queue: run.queue,
            position: run.position,
            results: results
        )
        session = restored
        currentRun = run
        filter = run.filter
        if restored.isFinished {
            run.finishedAt = .now
            try? context.save()
        }
        resetCardState()
    }

    private func applyIncomingTarget() {
        guard let target = navigator.exerciseTarget else { return }
        // Consume exactly once. A later visit to Egzersiz should keep whatever
        // filter the user chose here, not reapply an old cross-feature jump.
        navigator.exerciseTarget = nil

        // A jump with no filter (the link on the review screen) is only asking
        // to be taken here.
        guard let requestedFilter = target.filter else { return }

        // With a run in progress, applying the filter alone would be a lie: the
        // chips would read "Farmakoloji" over a queue of Patoloji cards the
        // session was built from. The two honest options are the user's to
        // pick, so ask rather than silently dropping either their request or
        // the run they are in the middle of.
        if isSessionActive {
            pendingTarget = requestedFilter
        } else {
            apply(requestedFilter)
        }
    }

    /// A cross-feature jump replaces the whole filter, not just ders/konu:
    /// leftover kart tipi/durum/tarih/FES selections from a previous session
    /// would make "bu dersten Egzersiz" from Bilgi Haritası silently narrower
    /// than what was asked for.
    private func apply(_ target: AppNavigator.ExerciseTarget.Filter) {
        filter = ExerciseFilter(subject: target.subject, topic: target.topic)
    }

    /// Closes the current run and lands on the start screen with the requested
    /// filter, ready to begin. `finishEarly` first so the abandoned run is
    /// stored complete and never reopened on the next launch.
    private func restartWithPendingTarget() {
        guard let requestedFilter = pendingTarget else { return }
        pendingTarget = nil
        finishEarly()
        session = nil
        currentRun = nil
        apply(requestedFilter)
        resetCardState()
    }
}
