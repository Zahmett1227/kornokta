import SwiftUI
import SwiftData
import CizgiCore

/// Egzersiz modu — free practice over the whole deck, independent of FSRS.
///
/// Same question → "Cevabı göster" → answer rhythm as `ReviewView`, and the
/// same card-edit affordance. Only an `ExerciseRun`/`ExerciseAttempt` history is
/// written: no `ReviewLog`, scheduling update or daily new-card ledger entry.
/// Going over a subject before an exam must not disturb a spaced-repetition
/// history that took months to build.
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
    @State private var subjectFilter: String?
    @State private var topicFilter: TopicFilter = .all
    /// 0 means every eligible card; the other values are quick, predictable
    /// session sizes rather than a free-form number field.
    @State private var requestedCardCount = 20

    /// Suspended cards stay out — the user has said they do not want to see
    /// them. Everything else is fair game regardless of its due date, which is
    /// the whole difference from `ReviewView`.
    private var eligibleCards: [Card] {
        allCards.filter { card in
            card.status != .suspended
                && LibraryCardFilter.matches(
                    subject: card.knowledgeUnit?.subject,
                    topic: card.knowledgeUnit?.topic,
                    subjectFilter: subjectFilter,
                    topicFilter: topicFilter
                )
        }
    }

    private var currentCard: Card? {
        guard let id = session?.current else { return nil }
        return allCards.first { $0.id == id }
    }

    private var weakCards: [Card] {
        let practiceWeight = exerciseRuns
            .flatMap(\.attempts)
            .reduce(into: [UUID: Int]()) { scores, attempt in
                switch attempt.result {
                case .knew: break
                case .unsure: scores[attempt.cardId, default: 0] += 1
                case .missed: scores[attempt.cardId, default: 0] += 3
                }
            }
        return eligibleCards.sorted { left, right in
            let leftPractice = practiceWeight[left.id, default: 0]
            let rightPractice = practiceWeight[right.id, default: 0]
            if leftPractice != rightPractice {
                return leftPractice > rightPractice
            }
            if left.lapseCount != right.lapseCount {
                return left.lapseCount > right.lapseCount
            }
            if left.lowConfidence != right.lowConfidence {
                return left.lowConfidence && !right.lowConfidence
            }
            if left.stability != right.stability {
                return left.stability < right.stability
            }
            return left.updatedAt < right.updatedAt
        }
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
            .navigationTitle("Egzersiz")
            .navigationBarTitleDisplayMode(isSessionActive ? .inline : .large)
            .toolbar {
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
                        SubjectTopicFilterMenu(subjectFilter: $subjectFilter, topicFilter: $topicFilter)
                    }
                }
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(card: card)
        }
        .tint(Cizgi.accent)
        .onAppear {
            restoreActiveRunIfNeeded()
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
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                ScreenHero(
                    eyebrow: "Günlük çalışma alanı",
                    title: "Bilgiyi aktif kullan",
                    subtitle: "Dilediğin konuyu karışık çalış. Egzersiz sonuçları tekrar planını değiştirmez.",
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

                        FeatureActionCard(
                            title: "Zayıf noktalar",
                            subtitle: "Unutulan ve düşük güvenli kartlar",
                            systemImage: "scope"
                        ) {
                            start(cards: weakCards, limit: 20, mode: .weak)
                        }
                        .disabled(count == 0)
                        .opacity(count == 0 ? 0.45 : 1)
                    }
                }

                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    CizgiSectionTitle(
                        "Egzersizini kur",
                        subtitle: "Ders ve konu filtresini sağ üstteki menüden değiştirebilirsin."
                    )

                    ActiveFilterChips(subjectFilter: $subjectFilter, topicFilter: $topicFilter)

                    CardSurface {
                        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                            HStack {
                                Label("\(count) kart hazır", systemImage: "rectangle.stack.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Cizgi.ink)
                                Spacer()
                                if let subjectFilter {
                                    TagChip(subjectFilter, systemImage: "book")
                                }
                            }

                            Picker("Kart sayısı", selection: $requestedCardCount) {
                                Text("10").tag(10)
                                Text("20").tag(20)
                                Text("Tümü").tag(0)
                            }
                            .pickerStyle(.segmented)

                            if count == 0 {
                                Text("Bu filtreye uyan kart yok.")
                                    .font(.subheadline)
                                    .foregroundStyle(Cizgi.muted)
                            } else {
                                Button("Egzersize başla") {
                                    start(
                                        cards: eligibleCards,
                                        limit: requestedCardCount == 0 ? nil : requestedCardCount,
                                        mode: .free
                                    )
                                }
                                .buttonStyle(CizgiPrimaryButtonStyle())
                            }
                        }
                    }
                }

                Label(
                    "Puanlama yalnız bu oturumun özetini oluşturur; FSRS ve tekrar tarihleri aynı kalır.",
                    systemImage: "checkmark.shield"
                )
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)

                if !completedRuns.isEmpty {
                    VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                        CizgiSectionTitle(
                            "Son Egzersizler",
                            subtitle: "FSRS'den bağımsız çalışma geçmişin."
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
        case .weak: return "Zayıf Noktalar"
        }
    }

    private func modeIcon(_ mode: ExerciseMode) -> String {
        switch mode {
        case .free: return "shuffle"
        case .quick: return "bolt.fill"
        case .weak: return "scope"
        }
    }

    @ViewBuilder
    private var completionScreen: some View {
        let summary = session?.summary ?? ExerciseSummary(knew: 0, unsure: 0, missed: 0)
        VStack(spacing: Cizgi.Space.xl) {
            VStack(spacing: Cizgi.Space.md) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Cizgi.accent)
                Text("Egzersiz bitti")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Cizgi.ink)
                Text("\(summary.answered) kart yanıtlandı.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
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

    private func start(cards: [Card], limit: Int?, mode: ExerciseMode) {
        let selected = limit.map { Array(cards.prefix($0)) } ?? cards
        var generator = SystemRandomNumberGenerator()
        let newSession = ExerciseSession(cardIds: selected.map(\.id), using: &generator)
        session = newSession
        beginRun(for: newSession, mode: mode)
        resetCardState()
    }

    private func restart() {
        guard var restarted = session else { return }
        var generator = SystemRandomNumberGenerator()
        restarted.restart(using: &generator)
        session = restarted
        beginRun(for: restarted, mode: currentRun?.mode ?? .free)
        resetCardState()
    }

    private func finish() {
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

        working.record(result)
        session = working
        currentRun?.position = working.position
        if working.isFinished {
            currentRun?.finishedAt = answeredAt
        }
        try? context.save()
        resetCardState()
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

    private func resetCardState() {
        isAnswerVisible = false
        selectedOption = nil
        shownAt = .now
    }

    private func beginRun(for session: ExerciseSession, mode: ExerciseMode) {
        let run = ExerciseRun(
            mode: mode,
            subject: subjectFilter,
            topic: topicFilter.topicName,
            queuedCardIds: session.queue
        )
        context.insert(run)
        try? context.save()
        currentRun = run
    }

    private func restoreActiveRunIfNeeded() {
        guard session == nil,
              let run = exerciseRuns.first(where: { $0.finishedAt == nil }),
              !run.queue.isEmpty else { return }
        let results = Dictionary(
            run.attempts.map { ($0.cardId, $0.result) },
            uniquingKeysWith: { _, latest in latest }
        )
        let restored = ExerciseSession(
            queue: run.queue,
            position: run.position,
            results: results
        )
        session = restored
        currentRun = run
        subjectFilter = run.subject
        topicFilter = run.topic.map(TopicFilter.topic) ?? .all
        if restored.isFinished {
            run.finishedAt = .now
            try? context.save()
        }
        resetCardState()
    }

    private func applyIncomingTarget() {
        guard let target = navigator.exerciseTarget else { return }
        subjectFilter = target.subject
        topicFilter = target.topic.map(TopicFilter.topic) ?? .all
        // Consume exactly once. A later visit to Egzersiz should keep whatever
        // filter the user chose here, not reapply an old cross-feature jump.
        navigator.exerciseTarget = nil
    }
}
