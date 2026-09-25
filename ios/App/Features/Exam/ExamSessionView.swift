import SwiftUI
import SwiftData
import CizgiCore

/// Pratik (plan §7.4 d): one question at a time, the answer locks on the
/// first tap, the key opens, and a miss asks the bridge question.
///
/// Pushed, not a tab root, so there is no tab bar to hide; the back button is
/// hidden instead and "Bitir" is the one way out of an unfinished run — with
/// a confirmation, because leaving would otherwise leave an `ExamRun` with no
/// `finishedAt`, which the home screen offers to resume.
///
/// The run is the durable state: the queue, the position and every answer are
/// in SwiftData the moment they happen, so a relaunch resumes on the same
/// question with the same answer shown.
struct ExamSessionView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var runs: [ExamRun]

    @State private var isConfirmingFinish = false
    /// Bumped after every write this screen or its question makes. Changes
    /// to the run's own fields did not reliably redraw it — "Bitir" set
    /// `finishedAt` and the question stayed on screen (simulator,
    /// 2026-09-25) — so the redraw does not depend on SwiftData noticing.
    @State private var revision = 0

    init(runId: UUID) {
        _runs = Query(filter: #Predicate<ExamRun> { $0.id == runId })
    }

    private var run: ExamRun? { runs.first }

    private var isActive: Bool {
        guard let run else { return false }
        return run.finishedAt == nil && run.position < run.queuedQuestionIds.count
    }

    var body: some View {
        let _ = revision
        Group {
            if let run, let bank = examLibrary.bank {
                if isActive, let id = run.currentQuestionId {
                    if let question = bank.question(id) {
                        ExamQuestionScreen(run: run, question: question, bank: bank) { revision += 1 }
                            .id(id)
                    } else {
                        // The bank was rebuilt without this question. Its
                        // history is kept (plan §7.1); the run moves on.
                        Color.clear.onAppear { advance(run) }
                    }
                } else {
                    ExamResultView(run: run, bank: bank) { dismiss() }
                }
            } else if examLibrary.phase == .loading {
                ProgressView()
            } else {
                Text("Oturum bulunamadı.")
                    .foregroundStyle(Cizgi.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationBarBackButtonHidden(isActive)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(isActive ? "" : "Sonuç")
        .toolbar {
            if isActive, let run {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Bitir") { isConfirmingFinish = true }
                        .tint(Cizgi.accent)
                        .accessibilityLabel("Oturumu bitir")
                }
                ToolbarItem(placement: .principal) {
                    Text("\(min(run.position + 1, run.queuedQuestionIds.count)) / \(run.queuedQuestionIds.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Cizgi.muted)
                }
                ToolbarItem(placement: .primaryAction) {
                    if let id = run.currentQuestionId {
                        ExamReportMenu(questionId: id)
                    }
                }
            }
        }
        .confirmationDialog("Oturumu bitir?", isPresented: $isConfirmingFinish, titleVisibility: .visible) {
            Button("Bitir", role: .destructive) {
                guard let run else { return }
                if let id = run.currentQuestionId, let pending = ExamRecorder(context: context).attempt(for: id, in: run) {
                    ExamRecorder(context: context).skipBridge(pending)
                }
                run.finishedAt = .now
                try? context.save()
                revision += 1
            }
            Button("Devam et", role: .cancel) {}
        } message: {
            Text("Cevapladığın sorular kaydedildi; özeti görürsün.")
        }
    }

    private func advance(_ run: ExamRun) {
        run.position += 1
        if run.position >= run.queuedQuestionIds.count { run.finishedAt = .now }
        try? context.save()
        revision += 1
    }
}

/// "Soruda hata bildir" (plan §7.4 d) — the question is badged "bildirildi"
/// from then on, so the owner sees it again with the report in mind.
struct ExamReportMenu: View {
    let questionId: String
    @Environment(\.modelContext) private var context
    @Query private var states: [ExamQuestionState]

    init(questionId: String) {
        self.questionId = questionId
        _states = Query(filter: #Predicate<ExamQuestionState> { $0.questionId == questionId })
    }

    var body: some View {
        let current = states.first?.reportedIssue
        Menu {
            Section("Soruda hata bildir") {
                ForEach(ExamReportedIssue.allCases, id: \.self) { issue in
                    Button {
                        ExamRecorder(context: context).report(issue, questionId: questionId)
                        try? context.save()
                    } label: {
                        if current == issue {
                            Label(ExamText.issue(issue), systemImage: "checkmark")
                        } else {
                            Text(ExamText.issue(issue))
                        }
                    }
                }
            }
            if current != nil {
                Button("Bildirimi geri al", role: .destructive) {
                    ExamRecorder(context: context).report(nil, questionId: questionId)
                    try? context.save()
                }
            }
        } label: {
            Label("Soruda hata bildir", systemImage: current == nil ? "flag" : "flag.fill")
        }
        .tint(Cizgi.accent)
    }
}

/// One question of a run. Keyed on the question id by its parent, so each
/// question starts with fresh state — the timer above all.
private struct ExamQuestionScreen: View {
    let run: ExamRun
    let question: ExamQuestion
    let bank: ExamBank
    /// Tells the session a write happened, so it redraws (see its `revision`).
    let onChange: () -> Void

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Card> { $0.statusRaw == "active" }) private var activeCards: [Card]
    @Query private var states: [ExamQuestionState]
    /// This question's answers across runs, queried rather than read off
    /// `run.attempts`: a relationship filled in through its inverse
    /// (`attempt.run = run`) does not tell SwiftUI it changed, so the answer
    /// was stored and the screen never revealed it (simulator, 2026-09-25).
    @Query private var questionAttempts: [ExamAttempt]

    @State private var shownAt = Date()
    @State private var candidates: [Card] = []
    /// Bumped after every write, so what is read through fetches (not
    /// observed properties) is read again.
    @State private var revision = 0

    init(run: ExamRun, question: ExamQuestion, bank: ExamBank, onChange: @escaping () -> Void) {
        self.run = run
        self.question = question
        self.bank = bank
        self.onChange = onChange
        let id = question.id
        _states = Query(filter: #Predicate<ExamQuestionState> { $0.questionId == id })
        _questionAttempts = Query(filter: #Predicate<ExamAttempt> { $0.questionId == id })
    }

    private var attempt: ExamAttempt? {
        let runId = run.id
        return questionAttempts.first { $0.run?.id == runId }
    }

    private var state: ExamQuestionState? { states.first }

    private var isLast: Bool { run.position + 1 >= run.queuedQuestionIds.count }

    var body: some View {
        // Read so a bump re-renders the whole screen, not only the footer.
        let _ = revision
        let attempt = self.attempt
        let isRevealed = attempt != nil
        VStack(spacing: Cizgi.Space.md) {
            progressBar

            ScrollView {
                ReviewCardFace(
                    content: StudyFaceContent(question: question, reportedIssue: state?.reportedIssue),
                    isAnswerVisible: isRevealed
                ) {
                    VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                        if question.hasFigure {
                            ExamFigureView(question: question)
                        }
                        ExamOptionList(
                            question: question,
                            selected: attempt?.selectedOption,
                            isRevealed: isRevealed,
                            onSelect: { answer($0) }
                        )
                    }
                } footer: {
                    if let attempt {
                        revealedFooter(attempt)
                    }
                }
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.top, Cizgi.Space.sm)
                .padding(.bottom, Cizgi.Space.xl)
            }
            .scrollBounceBehavior(.basedOnSize)

            actionArea(isRevealed: isRevealed)
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.bottom, Cizgi.Space.md)
        }
        .onAppear { shownAt = .now }
        .task(id: attempt?.id) { refreshCandidates() }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let total = max(1, run.queuedQuestionIds.count)
            ZStack(alignment: .leading) {
                Capsule().fill(Cizgi.hairline)
                Capsule().fill(Cizgi.highlighter)
                    .frame(width: max(6, geo.size.width * Double(run.position) / Double(total)))
            }
        }
        .frame(height: 5)
        .padding(.horizontal, Cizgi.Space.lg)
        .padding(.top, Cizgi.Space.sm)
    }

    @ViewBuilder
    private func revealedFooter(_ attempt: ExamAttempt) -> some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
            ExamResultLine(question: question, selectedOption: attempt.selectedOption)

            if bank.result(questionId: question.id, selectedOption: attempt.selectedOption).isMiss {
                ExamBridgePanel(question: question, attempt: attempt, candidates: candidates) {
                    revision += 1
                }
            } else if let linked = linkedCards, !linked.isEmpty {
                DisclosureGroup("Bağlı kartların (\(linked.count))") {
                    VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                        ForEach(linked) { card in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.front).font(.subheadline).foregroundStyle(Cizgi.ink)
                                Text(card.back).font(.caption).foregroundStyle(Cizgi.muted)
                            }
                        }
                    }
                    .padding(.top, Cizgi.Space.sm)
                }
                .font(.subheadline)
                .tint(Cizgi.accent)
            }

            DisclosureGroup("Kaynağı göster") {
                ExamSourceView(question: question)
                    .padding(.top, Cizgi.Space.sm)
            }
            .font(.subheadline)
            .tint(Cizgi.accent)
        }
        .id(revision)
    }

    /// Cards linked to this question before (the "Kartların" fold after a
    /// correct answer).
    private var linkedCards: [Card]? {
        guard let ids = state?.linkedCards, !ids.isEmpty else { return nil }
        let set = Set(ids)
        return activeCards.filter { set.contains($0.id) }
    }

    @ViewBuilder
    private func actionArea(isRevealed: Bool) -> some View {
        if isRevealed {
            Button(isLast ? "Bitir" : "Sıradaki") { next() }
                .buttonStyle(CizgiPrimaryButtonStyle())
        } else {
            HStack {
                Text("Bir şık seç")
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
                Spacer()
                Button("Boş bırak") { answer(nil) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Cizgi.accent)
            }
        }
    }

    // MARK: Actions

    private func answer(_ option: Int?) {
        guard attempt == nil else { return }
        let now = Date()
        let recorder = ExamRecorder(context: context)
        recorder.recordAnswer(
            to: question,
            selectedOption: option,
            in: run,
            responseTimeMs: Int(now.timeIntervalSince(shownAt) * 1_000),
            at: now
        )
        try? context.save()
        revision += 1
    }

    private func next() {
        if let attempt { ExamRecorder(context: context).skipBridge(attempt) }
        run.position += 1
        if run.position >= run.queuedQuestionIds.count { run.finishedAt = .now }
        try? context.save()
        onChange()
    }

    private func refreshCandidates() {
        guard let attempt, bank.result(questionId: question.id, selectedOption: attempt.selectedOption).isMiss else {
            candidates = []
            return
        }
        candidates = ExamBridgeCandidates.rank(
            for: question,
            linked: state?.linkedCards ?? [],
            cards: activeCards
        )
    }
}
