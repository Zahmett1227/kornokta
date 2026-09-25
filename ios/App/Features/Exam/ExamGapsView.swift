import SwiftUI
import SwiftData
import CizgiCore

/// "Kitaba dönünce" (plan §7.6): the questions the owner missed and has no
/// card for — the book's pages the real exam says to go back to.
///
/// One line per question, never a topic-level summary: "Farmakoloji · Otonom
/// — 2019/1 Temel 45" says exactly what to look up. A gap closes only when the
/// owner names a card; a new card in the same topic merely *suggests* it
/// ("muhtemelen kapandı"), because a card that happens to share a topic may
/// not answer the question.
struct ExamGapsView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ExamQuestionState> { $0.gapStatusRaw == "open" }) private var openStates: [ExamQuestionState]
    @Query private var cards: [Card]
    @Query private var allStates: [ExamQuestionState]

    private struct Row: Identifiable {
        let state: ExamQuestionState
        let question: ExamQuestion
        let hasLikelyCloser: Bool
        var id: String { question.id }
    }

    private struct GapGroup: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    private func groups(_ bank: ExamBank) -> [GapGroup] {
        let gapCards = cards.filter { $0.status == .active }.map {
            ExamGapCard(id: $0.id, subject: $0.knowledgeUnit?.subject, topic: $0.knowledgeUnit?.topic, createdAt: $0.createdAt)
        }
        let rows = openStates.compactMap { state -> Row? in
            guard let question = bank.question(state.questionId) else { return nil }
            let closers = ExamGapLedger.likelyClosers(state.gap, subject: question.subject, topic: question.topic, cards: gapCards)
            return Row(state: state, question: question, hasLikelyCloser: !closers.isEmpty)
        }
        let order = Dictionary(uniqueKeysWithValues: ExamQuestion.osymSubjects.enumerated().map { ($1, $0) })
        let grouped = Dictionary(grouping: rows) { row in
            [row.question.osymSubject ?? "Dersi belirsiz", row.question.topic ?? "Konusuz"].joined(separator: " · ")
        }
        return grouped
            .map { GapGroup(title: $0.key, rows: $0.value.sorted { ($0.state.gapOpenedAt ?? .distantPast) < ($1.state.gapOpenedAt ?? .distantPast) }) }
            .sorted { left, right in
                let l = order[left.rows[0].question.osymSubject ?? ""] ?? Int.max
                let r = order[right.rows[0].question.osymSubject ?? ""] ?? Int.max
                return l != r ? l < r : left.title < right.title
            }
    }

    var body: some View {
        Group {
            if let bank = examLibrary.bank {
                let groups = self.groups(bank)
                if groups.isEmpty {
                    empty
                } else {
                    list(groups, bank: bank)
                }
            } else {
                Text("Soru bankası yok.")
                    .foregroundStyle(Cizgi.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("Kitaba dönünce")
        .onAppear {
            if ExamRecorder(context: context).reconcile(existingCardIds: Set(cards.map(\.id))) > 0 {
                try? context.save()
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(Cizgi.accent)
            Text("Açık yok")
                .font(Cizgi.serif(22, relativeTo: .title2))
                .foregroundStyle(Cizgi.ink)
            Text("Pratikte yanlış yaptığın bir soru için \"Hiçbiri — destemde yok\" dediğinde buraya düşer.")
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
        }
        .padding(Cizgi.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ groups: [GapGroup], bank: ExamBank) -> some View {
        List {
            Section {
                Button {
                    solveAll(bank)
                } label: {
                    Label("Bu soruları şimdi çöz", systemImage: "play.circle")
                }
                .tint(Cizgi.accent)
            } footer: {
                Text("Kart ekledikten sonra \"şimdi yapabiliyor muyum?\" diye bak. Sola kaydırmak "
                     + "açığı yoksayar; bir daha sorulmaz.")
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        NavigationLink(value: AppNavigator.ExamRoute.question(row.question.id)) {
                            rowLabel(row)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                ExamRecorder(context: context).dismissGap(questionId: row.question.id)
                                try? context.save()
                            } label: {
                                Label("Yoksay", systemImage: "eye.slash")
                            }
                            .tint(Cizgi.muted)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func rowLabel(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Cizgi.Space.sm) {
                Text(ExamText.shortName(row.question))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                if row.hasLikelyCloser {
                    TagChip("muhtemelen kapandı", systemImage: "sparkles")
                }
            }
            Text(row.question.stem)
                .font(.caption)
                .foregroundStyle(Cizgi.muted)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func solveAll(_ bank: ExamBank) {
        let launcher = ExamRunLauncher(context: context, bank: bank)
        guard let run = launcher.start(
            mode: .gaps,
            filter: ExamFilter(progress: .gaps),
            progress: ExamRunLauncher.progressMap(allStates),
            limit: nil,
            order: .oldestFirst
        ) else { return }
        navigator.openExam([.home, .session(run.id)])
    }
}

/// One question outside a run: the text with its key, the figure, the
/// booklet page — and, when it is on "Kitaba dönünce", closing or dismissing
/// the gap (plan §7.6).
struct ExamQuestionDetailView: View {
    let questionId: String

    @EnvironmentObject private var examLibrary: ExamLibrary
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var states: [ExamQuestionState]
    @Query private var cards: [Card]
    @State private var isChoosingCard = false

    init(questionId: String) {
        self.questionId = questionId
        _states = Query(filter: #Predicate<ExamQuestionState> { $0.questionId == questionId })
    }

    private var state: ExamQuestionState? { states.first }

    var body: some View {
        Group {
            if let question = examLibrary.bank?.question(questionId) {
                content(question)
            } else {
                Text("Bu soru bankada yok.")
                    .foregroundStyle(Cizgi.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle(examLibrary.bank?.question(questionId).map(ExamText.shortName) ?? "Soru")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ExamReportMenu(questionId: questionId) }
        }
    }

    private func content(_ question: ExamQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                ReviewCardFace(
                    content: StudyFaceContent(question: question, reportedIssue: state?.reportedIssue),
                    isAnswerVisible: true
                ) {
                    VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                        if question.hasFigure { ExamFigureView(question: question) }
                        ExamOptionList(question: question, selected: nil, isRevealed: true)
                    }
                } footer: {
                    DisclosureGroup("Kaynağı göster") {
                        ExamSourceView(question: question).padding(.top, Cizgi.Space.sm)
                    }
                    .font(.subheadline)
                    .tint(Cizgi.accent)
                }

                if let state {
                    historyLine(state)
                    gapSection(question, state: state)
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
        .sheet(isPresented: $isChoosingCard) {
            ExamCardChooser(question: question, cards: chooserCards(question, state: state)) { card in
                ExamRecorder(context: context).closeGap(questionId: question.id, with: card.id, at: .now)
                try? context.save()
            }
        }
    }

    private func historyLine(_ state: ExamQuestionState) -> some View {
        Text("\(state.attemptCount) kez çözüldü · \(state.wrongCount) yanlış ya da boş")
            .font(.caption)
            .foregroundStyle(Cizgi.muted)
    }

    @ViewBuilder
    private func gapSection(_ question: ExamQuestion, state: ExamQuestionState) -> some View {
        let gap = state.gap
        switch gap.status {
        case .open:
            let closers = likelyClosers(question, gap: gap)
            CardSurface(highlighted: true) {
                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    Text("Destende bu soruyu karşılayan kart yok.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.ink)
                    if !closers.isEmpty {
                        Text("Muhtemelen kapandı — açık açıldıktan sonra bu konuya eklenen kart:")
                            .font(.caption)
                            .foregroundStyle(Cizgi.muted)
                        ForEach(closers.prefix(3)) { card in
                            Button {
                                ExamRecorder(context: context).closeGap(questionId: question.id, with: card.id, at: .now)
                                try? context.save()
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(card.front).font(.subheadline).foregroundStyle(Cizgi.ink)
                                            .multilineTextAlignment(.leading)
                                        Text("Bu kartla kapat").font(.caption.weight(.semibold)).foregroundStyle(Cizgi.accent)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: Cizgi.Space.sm) {
                        Button("Kart ekledim") { isChoosingCard = true }
                            .buttonStyle(CizgiSecondaryButtonStyle(tint: Cizgi.accent))
                        Button("Yoksay") {
                            ExamRecorder(context: context).dismissGap(questionId: question.id)
                            try? context.save()
                        }
                        .buttonStyle(CizgiSecondaryButtonStyle(tint: Cizgi.muted))
                    }
                }
            }
        case .closed:
            let closer = gap.closedByCardId.flatMap { id in cards.first { $0.id == id } }
            Label("Kapandı\(closer.map { " — \($0.front)" } ?? "")", systemImage: "checkmark.seal")
                .font(.footnote)
                .foregroundStyle(Cizgi.success)
        case .dismissed:
            Label("Yoksayıldı", systemImage: "eye.slash")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        case .noGap:
            EmptyView()
        }
    }

    private func likelyClosers(_ question: ExamQuestion, gap: ExamGap) -> [Card] {
        let active = cards.filter { $0.status == .active }
        let ids = ExamGapLedger.likelyClosers(
            gap,
            subject: question.subject,
            topic: question.topic,
            cards: active.map {
                ExamGapCard(id: $0.id, subject: $0.knowledgeUnit?.subject, topic: $0.knowledgeUnit?.topic, createdAt: $0.createdAt)
            }
        )
        let byId = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// New cards in the question's subject first (the card the owner just
    /// wrote is most likely among them), then the bridge's ranking.
    private func chooserCards(_ question: ExamQuestion, state: ExamQuestionState?) -> [Card] {
        let recent = likelyClosers(question, gap: state?.gap ?? ExamGap())
        let ranked = ExamBridgeCandidates.rank(for: question, linked: state?.linkedCards ?? [], cards: cards)
        var seen = Set<UUID>()
        return (recent + ranked).filter { seen.insert($0.id).inserted }
    }
}

/// "Kart ekledim": which card answers the question.
private struct ExamCardChooser: View {
    let question: ExamQuestion
    let cards: [Card]
    let onChoose: (Card) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if cards.isEmpty {
                    Text("Bu derste soruyla eşleşen ya da açıktan sonra eklenmiş bir kart bulunamadı.")
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.muted)
                }
                ForEach(cards) { card in
                    Button {
                        onChoose(card)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.front).font(.subheadline).foregroundStyle(Cizgi.ink)
                            Text(card.back).font(.caption).foregroundStyle(Cizgi.muted).lineLimit(2)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Cizgi.paper)
            .navigationTitle("Hangi kart?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
            }
        }
    }
}
