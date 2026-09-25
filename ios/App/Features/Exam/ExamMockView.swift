import SwiftUI
import SwiftData
import CizgiCore

/// Deneme (plan §7.4 e): a paper under its own clock. Nothing is revealed and
/// the bridge is never asked until the paper is handed in — then the result
/// screen and its review take over.
///
/// The clock is wall-clock (`ExamMockClock`): it runs in the background and
/// while the app is closed, like the exam hall. The pause button is the one
/// way to stop it, it hides the questions while it holds, and the result
/// reports every paused minute. If the time runs out — on screen, or while
/// the app was away — the paper is handed in as it stands, at the moment the
/// time ran out.
///
/// Durable like Pratik: every mark and the current position are in SwiftData
/// the moment they change, so a relaunch returns to the same question.
struct ExamMockView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Query private var runs: [ExamRun]
    @Query private var attempts: [ExamAttempt]

    @State private var shownAt = Date()
    @State private var isConfirmingFinish = false
    @State private var isShowingNavigator = false
    /// See `ExamSessionView.revision`: the redraw must not depend on
    /// SwiftData noticing a change to the run's own fields.
    @State private var revision = 0

    init(runId: UUID) {
        _runs = Query(filter: #Predicate<ExamRun> { $0.id == runId })
        _attempts = Query(filter: #Predicate<ExamAttempt> { $0.run?.id == runId })
    }

    private var run: ExamRun? { runs.first }
    private var isActive: Bool { run?.finishedAt == nil && run != nil }

    private var marks: [String: Int] {
        var result: [String: Int] = [:]
        for attempt in attempts {
            if let option = attempt.selectedOption { result[attempt.questionId] = option }
        }
        return result
    }

    var body: some View {
        let _ = revision
        Group {
            if let run, let bank = examLibrary.bank {
                if run.finishedAt != nil {
                    ExamResultView(run: run, bank: bank) { dismiss() }
                } else if run.clock.isPaused {
                    pausedScreen(run)
                } else {
                    questionArea(run, bank: bank)
                }
            } else if examLibrary.phase == .loading {
                ProgressView()
            } else {
                Text("Deneme bulunamadı.").foregroundStyle(Cizgi.muted)
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
                    Button("Bitir") {
                        flushTime()
                        isConfirmingFinish = true
                    }
                    .tint(Cizgi.accent)
                    .accessibilityLabel("Sınavı bitir")
                }
                ToolbarItem(placement: .principal) {
                    ExamMockTimer(clock: run.clock)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        togglePause(run)
                    } label: {
                        Label(run.clock.isPaused ? "Devam et" : "Duraklat",
                              systemImage: run.clock.isPaused ? "play.fill" : "pause.fill")
                    }
                    .tint(Cizgi.accent)
                }
            }
        }
        .confirmationDialog("Sınavı bitir?", isPresented: $isConfirmingFinish, titleVisibility: .visible) {
            Button("Sınavı bitir", role: .destructive) { submit(byTimeLimit: false, at: .now) }
            Button("Devam et", role: .cancel) {}
        } message: {
            Text(finishSummary)
        }
        .sheet(isPresented: $isShowingNavigator) {
            if let run {
                ExamMockNavigator(
                    queue: run.queuedQuestionIds,
                    marked: Set(marks.keys),
                    flagged: Set(run.flaggedQuestionIds),
                    current: run.position
                ) { go(to: $0) }
            }
        }
        // Sleeps until the deadline; re-armed whenever it moves (a pause
        // lifts it, a resume sets a later one).
        .task(id: run?.clock.deadline) {
            guard let deadline = run?.clock.deadline else { return }
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            submitIfExpired()
        }
        .onAppear {
            submitIfExpired()
            shownAt = .now
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                submitIfExpired()
                shownAt = .now
            default:
                flushTime()
            }
        }
        .onDisappear { flushTime() }
    }

    // MARK: Screens

    @ViewBuilder
    private func questionArea(_ run: ExamRun, bank: ExamBank) -> some View {
        let queue = run.queuedQuestionIds
        let index = min(max(run.position, 0), max(queue.count - 1, 0))
        let id = queue.isEmpty ? nil : queue[index]
        let marks = self.marks
        VStack(spacing: Cizgi.Space.md) {
            progressBar(marked: marks.count, total: queue.count)

            if let id, let question = bank.question(id) {
                ScrollView {
                    ReviewCardFace(
                        content: StudyFaceContent(question: question, reportedIssue: nil),
                        isAnswerVisible: false
                    ) {
                        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                            if question.hasFigure { ExamFigureView(question: question) }
                            ExamOptionList(
                                question: question,
                                selected: marks[id],
                                isRevealed: false,
                                allowsChange: true
                            ) { option in
                                mark(option == marks[id] ? nil : option, on: question, in: run)
                            }
                        }
                    } footer: {
                        EmptyView()
                    }
                    .padding(.horizontal, Cizgi.Space.lg)
                    .padding(.top, Cizgi.Space.sm)
                    .padding(.bottom, Cizgi.Space.xl)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(id)
            } else {
                Text("Bu soru banka sürümünde yok; sonraki soruya geç.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            bottomBar(run, index: index, id: id, markedCount: marks.count)
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.bottom, Cizgi.Space.md)
        }
    }

    private func progressBar(marked: Int, total: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Cizgi.hairline)
                Capsule().fill(Cizgi.highlighter)
                    .frame(width: max(6, geo.size.width * Double(marked) / Double(max(total, 1))))
            }
        }
        .frame(height: 5)
        .padding(.horizontal, Cizgi.Space.lg)
        .padding(.top, Cizgi.Space.sm)
        .accessibilityLabel("\(marked) / \(total) soru cevaplandı")
    }

    private func bottomBar(_ run: ExamRun, index: Int, id: String?, markedCount: Int) -> some View {
        let count = run.queuedQuestionIds.count
        let flagged = id.map { run.flaggedQuestionIds.contains($0) } ?? false
        return HStack(spacing: Cizgi.Space.sm) {
            Button {
                go(to: index - 1)
            } label: {
                Image(systemName: "chevron.left").frame(maxWidth: .infinity)
            }
            .buttonStyle(CizgiSecondaryButtonStyle())
            .disabled(index == 0)
            .opacity(index == 0 ? 0.45 : 1)
            .accessibilityLabel("Önceki soru")

            Button {
                guard let id else { return }
                ExamRecorder(context: context).toggleFlag(id, in: run)
                try? context.save()
                revision += 1
            } label: {
                Image(systemName: flagged ? "flag.fill" : "flag").frame(maxWidth: .infinity)
            }
            .buttonStyle(CizgiSecondaryButtonStyle(tint: flagged ? Cizgi.warning : Cizgi.ink))
            .accessibilityLabel(flagged ? "İşareti kaldır" : "Soruyu işaretle")

            Button {
                flushTime()
                isShowingNavigator = true
            } label: {
                Text("\(index + 1) / \(count)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CizgiSecondaryButtonStyle())
            .accessibilityLabel("Soru gezgini, \(index + 1). soru, \(markedCount) cevaplı")

            Button {
                go(to: index + 1)
            } label: {
                Image(systemName: "chevron.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(CizgiPrimaryButtonStyle())
            .disabled(index + 1 >= count)
            .opacity(index + 1 >= count ? 0.45 : 1)
            .accessibilityLabel("Sonraki soru")
        }
    }

    private func pausedScreen(_ run: ExamRun) -> some View {
        VStack(spacing: Cizgi.Space.lg) {
            Image(systemName: "pause.circle")
                .font(.system(size: 52))
                .foregroundStyle(Cizgi.accent)
            Text("Duraklatıldı")
                .font(Cizgi.serif(26, relativeTo: .title2))
                .foregroundStyle(Cizgi.ink)
            if let remaining = run.clock.remainingSeconds(at: .now) {
                Text("Kalan süre \(ExamText.clock(remaining))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Cizgi.ink)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Toplam duraklama \(ExamText.duration(run.clock.totalPausedSeconds(at: context.date)))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Cizgi.muted)
            }
            Text("Duraklamada sorular gizli. Toplam duraklama sonuçta yazılır.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
            Button("Devam et") { togglePause(run) }
                .buttonStyle(CizgiPrimaryButtonStyle())
        }
        .padding(Cizgi.Space.xl)
    }

    private var finishSummary: String {
        guard let run else { return "" }
        let marked = marks.count
        let blank = run.queuedQuestionIds.count - marked
        let flagged = run.flaggedQuestionIds.count
        var text = "Cevaplı \(marked) · boş \(blank)"
        if flagged > 0 { text += " · işaretli \(flagged)" }
        return text + ". Bitirince cevapların kesinleşir ve sonuç açılır."
    }

    // MARK: Actions

    private func mark(_ option: Int?, on question: ExamQuestion, in run: ExamRun) {
        ExamRecorder(context: context).setMockAnswer(option, to: question, in: run, at: .now)
        try? context.save()
        revision += 1
    }

    private func go(to index: Int) {
        guard let run, run.queuedQuestionIds.indices.contains(index) else { return }
        flushTime()
        run.position = index
        try? context.save()
        shownAt = .now
        revision += 1
    }

    /// Adds the time spent on the question on screen to its row. Called on
    /// every way off it — next, the navigator, pause, background, hand-in.
    private func flushTime() {
        guard let run, run.finishedAt == nil, !run.clock.isPaused, let bank = examLibrary.bank,
              let id = run.currentQuestionId, let question = bank.question(id) else { return }
        let now = Date()
        let milliseconds = Int(now.timeIntervalSince(shownAt) * 1_000)
        shownAt = now
        guard milliseconds > 250 else { return }
        ExamRecorder(context: context).addMockTime(milliseconds, to: question, in: run, at: now)
        try? context.save()
    }

    private func togglePause(_ run: ExamRun) {
        let now = Date()
        if run.clock.isPaused {
            run.clock = run.clock.resuming(at: now)
            shownAt = now
        } else {
            flushTime()
            run.clock = run.clock.pausing(at: now)
        }
        try? context.save()
        revision += 1
    }

    private func submitIfExpired() {
        guard let run, run.finishedAt == nil, let deadline = run.clock.deadline, deadline <= .now else { return }
        submit(byTimeLimit: true, at: deadline)
    }

    private func submit(byTimeLimit: Bool, at date: Date) {
        guard let run, let bank = examLibrary.bank else { return }
        if !byTimeLimit { flushTime() }
        ExamRecorder(context: context).submitMock(run, bank: bank, at: date, byTimeLimit: byTimeLimit)
        try? context.save()
        revision += 1
    }
}

/// The countdown in the navigation bar. Red in the last five minutes.
///
/// An `HStack`, not a `Label`: in the toolbar's principal slot a `Label`
/// collapses to its icon, and a timer without its numbers is a clock face
/// that tells no time (simulator, 2026-09-26).
struct ExamMockTimer: View {
    let clock: ExamMockClock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = clock.remainingSeconds(at: context.date)
            let tint = remaining.map { $0 < 300 ? Cizgi.danger : Cizgi.ink } ?? Cizgi.muted
            HStack(spacing: 5) {
                Image(systemName: remaining == nil ? "stopwatch" : "timer")
                Text(ExamText.clock(remaining ?? clock.activeSeconds(at: context.date)))
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(remaining.map { "Kalan süre \(ExamText.duration($0))" }
                                ?? "Geçen süre \(ExamText.duration(clock.activeSeconds(at: context.date)))")
        }
    }
}

/// The question grid (plan §7.4 e): answered, flagged, still blank — and a
/// tap goes there.
struct ExamMockNavigator: View {
    let queue: [String]
    let marked: Set<String>
    let flagged: Set<String>
    let current: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                    HStack(spacing: Cizgi.Space.lg) {
                        legend("Cevaplı \(marked.count)", fill: Cizgi.accent)
                        legend("Boş \(queue.count - marked.count)", fill: Cizgi.surface)
                        Label("İşaretli \(flagged.count)", systemImage: "flag.fill")
                            .foregroundStyle(Cizgi.warning)
                    }
                    .font(.caption)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: Cizgi.Space.sm)], spacing: Cizgi.Space.sm) {
                        ForEach(Array(queue.enumerated()), id: \.offset) { index, id in
                            cell(index: index, id: id)
                        }
                    }
                }
                .padding(Cizgi.Space.lg)
            }
            .background(Cizgi.paper)
            .navigationTitle("Sorular")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func legend(_ title: String, fill: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Cizgi.hairline, lineWidth: 1))
            Text(title).foregroundStyle(Cizgi.ink)
        }
    }

    private func cell(index: Int, id: String) -> some View {
        let isMarked = marked.contains(id)
        let isFlagged = flagged.contains(id)
        let isCurrent = index == current
        return Button {
            onPick(index)
            dismiss()
        } label: {
            Text("\(index + 1)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(isMarked ? Cizgi.surface : Cizgi.ink)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(isMarked ? Cizgi.accent : Cizgi.surface,
                            in: RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                        .stroke(isCurrent ? Cizgi.ink : Cizgi.hairline, lineWidth: isCurrent ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Cizgi.warning)
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(index + 1). soru\(isMarked ? ", cevaplı" : ", boş")\(isFlagged ? ", işaretli" : "")")
    }
}
