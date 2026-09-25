import SwiftUI
import SwiftData
import CizgiCore

/// Egzersiz → "Çıkmış" (plan §7.4 b): Pratik, Deneme (a real paper or a
/// mixed one, timed), Yanlışlarım, Kitaba dönünce, and the last few runs.
///
/// A past question is not a card (docs/ADR-012): nothing here touches Tekrar,
/// FSRS or the deck's counts. The only thing that reaches a card is the
/// bridge, after a miss, and only onto the card the owner names.
struct ExamHomeView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    @Query private var states: [ExamQuestionState]
    @Query(sort: \ExamRun.startedAt, order: .reverse) private var runs: [ExamRun]
    @Query private var cards: [Card]

    @State private var filter = ExamFilterMemory.load()
    @State private var budget: ExamBudget = .questions(20)
    @State private var budgetKind: BudgetKind = .questions
    @State private var secondsPerQuestion = ExamPace.fallbackSecondsPerQuestion
    @State private var isShowingSetup = false
    @State private var isShowingMixedMock = false
    @State private var emptyMessage: String?

    private enum BudgetKind: Hashable { case questions, minutes }

    private var progress: [String: ExamProgress] { ExamRunLauncher.progressMap(states) }

    private var openRun: ExamRun? {
        runs.first { $0.finishedAt == nil && $0.position < $0.queuedQuestionIds.count }
    }

    var body: some View {
        Group {
            if let bank = examLibrary.bank {
                content(bank)
            } else {
                noBank
            }
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("Çıkmış")
        .toolbar {
            if examLibrary.bank != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingSetup = true
                    } label: {
                        Label("Filtrele", systemImage: filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSetup) {
            if let bank = examLibrary.bank {
                ExamSetupSheet(filter: $filter, bank: bank, progress: progress)
            }
        }
        .sheet(isPresented: $isShowingMixedMock) {
            if let bank = examLibrary.bank {
                ExamMixedMockSheet(bank: bank, progress: progress) { run in
                    navigator.exercisePath.append(AppNavigator.ExamRoute.mock(run.id))
                }
            }
        }
        .onChange(of: filter) { _, newValue in ExamFilterMemory.save(newValue) }
        .onAppear {
            secondsPerQuestion = ExamRunLauncher.secondsPerQuestion(context: context)
            reconcileGaps()
        }
    }

    // MARK: No bank

    private var noBank: some View {
        VStack(spacing: Cizgi.Space.lg) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(Cizgi.accent)
            Text(examLibrary.phase == .loading ? "Soru bankası okunuyor…" : "Soru bankası yok")
                .font(Cizgi.serif(22, relativeTo: .title2))
                .foregroundStyle(Cizgi.ink)
            if case .failed(let message) = examLibrary.phase {
                Text(message).font(.footnote).foregroundStyle(Cizgi.danger).multilineTextAlignment(.center)
            }
            if examLibrary.phase != .loading {
                Text("Mac'te üretilen \"CizgiSoruBankasi\" klasörünü Ayarlar'dan içe aktar.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
                    .multilineTextAlignment(.center)
                NavigationLink(value: AppNavigator.ExamRoute.bankSettings) {
                    Text("İçe aktar")
                }
                .buttonStyle(CizgiPrimaryButtonStyle())
            }
        }
        .padding(Cizgi.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Content

    private func content(_ bank: ExamBank) -> some View {
        let progress = self.progress
        let eligible = bank.questions(matching: filter, progress: progress)
        let unsolved = bank.scoreableIds.filter { !(progress[$0]?.isAttempted ?? false) }.count
        let wrong = states.filter { $0.progress.isWrong && bank.scoreableIds.contains($0.questionId) }.count
        let gaps = states.filter { $0.gap.status == .open && bank.questionsById[$0.questionId] != nil }.count

        return ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                HStack(spacing: Cizgi.Space.sm) {
                    StatTile(value: unsolved.formatted(), label: "Çözülmemiş")
                    StatTile(value: wrong.formatted(), label: "Yanlışlarım")
                    StatTile(value: gaps.formatted(), label: "Açık")
                }

                if let openRun {
                    resumeCard(openRun)
                }

                practiceSection(eligibleCount: eligible.count, bank: bank)

                mockSection(bank)

                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    CizgiSectionTitle("Tekrar çöz", index: 3,
                                      subtitle: "Yanlış yaptıkların ve destende kartı olmayanlar.")
                    NumeralActionRow(
                        numeral: "\(wrong)",
                        title: "Yanlışlarım",
                        subtitle: wrong == 0 ? "Yanlış ya da boş bıraktığın soru yok"
                            : "Son cevabı yanlış ya da boş olanlar, en eskiden"
                    ) {
                        start(.wrongOnly, filter: ExamFilter(progress: .wrong), order: .oldestFirst, bank: bank)
                    }
                    .disabled(wrong == 0)
                    .opacity(wrong == 0 ? 0.45 : 1)

                    NumeralActionRow(
                        numeral: "\(gaps)",
                        title: "Kitaba dönünce",
                        subtitle: gaps == 0 ? "Açık yok" : "Destende kartı olmayan sorular"
                    ) {
                        navigator.exercisePath.append(AppNavigator.ExamRoute.gaps)
                    }
                }

                if !finishedRuns.isEmpty {
                    VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                        CizgiSectionTitle("Son oturumlar", index: 4)
                        ForEach(finishedRuns.prefix(5)) { run in
                            NavigationLink(value: AppNavigator.ExamRoute.result(run.id)) {
                                runRow(run, bank: bank)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Sorular kart değildir: Tekrar'a ve FSRS'e girmez. Yanlış yaptığında "
                     + "\"Bu soruyu karşılayan bir kartın var mı?\" diye sorulur; yalnız seçtiğin "
                     + "kartın FES'i işlenir (ADR-012).")
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
    }

    private func resumeCard(_ run: ExamRun) -> some View {
        CardSurface(highlighted: true) {
            VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                Text("Yarım kalan oturum")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                Text(resumeLine(run))
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
                HStack(spacing: Cizgi.Space.sm) {
                    Button("Devam et") {
                        navigator.exercisePath.append(
                            run.mode == .mock ? AppNavigator.ExamRoute.mock(run.id) : AppNavigator.ExamRoute.session(run.id)
                        )
                    }
                    .buttonStyle(CizgiPrimaryButtonStyle())
                    Button(run.mode == .mock ? "Teslim et" : "Kapat") {
                        // A mock is handed in as it stands, never dropped.
                        if let bank = examLibrary.bank {
                            ExamRunLauncher(context: context, bank: bank).close(run)
                            try? context.save()
                        }
                    }
                    .buttonStyle(CizgiSecondaryButtonStyle())
                }
            }
        }
    }

    private func resumeLine(_ run: ExamRun) -> String {
        let count = run.queuedQuestionIds.count
        guard run.mode == .mock else {
            return "\(ExamText.mode(run.mode)) · soru \(min(run.position + 1, count)) / \(count)"
        }
        let title = examLibrary.bank.map { ExamRunScore.title(for: run, bank: $0) } ?? "Deneme"
        guard let remaining = run.clock.remainingSeconds(at: .now) else { return title }
        return remaining > 0
            ? "\(title) · kalan \(ExamText.duration(remaining))\(run.clock.isPaused ? " (duraklatıldı)" : "")"
            : "\(title) · süre doldu"
    }

    private func mockSection(_ bank: ExamBank) -> some View {
        let papers = bank.papers.filter {
            ExamMockComposer.scoreableCount(bank, queue: ExamMockComposer.paperQueue(bank, paper: $0)) > 0
        }.count
        return VStack(alignment: .leading, spacing: Cizgi.Space.md) {
            CizgiSectionTitle("Deneme", index: 2,
                              subtitle: "Süreli; cevaplar sen bitirene kadar açılmaz, net ve ders bazında sonuç çıkar.")
            NumeralActionRow(
                numeral: "\(papers)",
                title: "Kağıt denemesi",
                subtitle: "Gerçek bir kitapçık, ÖSYM'nin sırası ve süresiyle"
            ) {
                navigator.exercisePath.append(AppNavigator.ExamRoute.mockPapers)
            }
            NumeralActionRow(
                numeral: "40",
                title: "Karma deneme",
                subtitle: "Gerçek bir kağıdın ders dağılımıyla, çözmediklerinden"
            ) {
                isShowingMixedMock = true
            }
        }
    }

    private func practiceSection(eligibleCount: Int, bank: ExamBank) -> some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                CizgiSectionTitle(
                    "Pratik",
                    index: 1,
                    subtitle: filter.isActive ? "Uyguladığın filtreler aşağıda."
                        : "Gerçek sorular; cevabını seçince doğrusu açılır."
                )
                Spacer()
                Button("Filtreler") { isShowingSetup = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Cizgi.accent)
            }

            ExamFilterChips(filter: $filter)

            CardSurface {
                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    Label("\(eligibleCount.formatted()) soru hazır", systemImage: "doc.text.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.ink)

                    Picker("Bütçe türü", selection: $budgetKind) {
                        Text("Soru").tag(BudgetKind.questions)
                        Text("Süre").tag(BudgetKind.minutes)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: budgetKind) { _, kind in
                        budget = kind == .questions ? .questions(20) : .minutes(20)
                    }

                    ChipFlowRow(budgetOptions) { option in
                        SelectableChip(title: option.label, isSelected: budget == option) { budget = option }
                    }

                    if budgetKind == .minutes, let estimated = budget.limit(secondsPerQuestion: secondsPerQuestion) {
                        Text("≈ \(estimated) soru (soru başına \(Int(secondsPerQuestion.rounded())) sn)")
                            .font(.caption)
                            .foregroundStyle(Cizgi.muted)
                    }

                    if eligibleCount == 0 {
                        Text("Bu filtreye uyan soru yok.")
                            .font(.subheadline)
                            .foregroundStyle(Cizgi.muted)
                    } else {
                        Button("Pratiğe başla") {
                            start(.practice, filter: filter, order: .fresh, bank: bank)
                        }
                        .buttonStyle(CizgiPrimaryButtonStyle())
                    }
                    if let emptyMessage {
                        Text(emptyMessage).font(.footnote).foregroundStyle(Cizgi.danger)
                    }
                }
            }
        }
    }

    private var budgetOptions: [ExamBudget] {
        switch budgetKind {
        case .questions: return ExamBudget.questionPresets.map { .questions($0) } + [.all]
        case .minutes: return ExamBudget.minutePresets.map { .minutes($0) } + [.all]
        }
    }

    private var finishedRuns: [ExamRun] {
        runs.filter { $0.finishedAt != nil && !$0.attempts.isEmpty }
    }

    private func runRow(_ run: ExamRun, bank: ExamBank) -> some View {
        let score = ExamRunScore.score(for: run, attempts: run.attempts, bank: bank)
        return CardSurface {
            HStack(spacing: Cizgi.Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ExamRunScore.title(for: run, bank: bank))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.ink)
                    Text(run.startedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(Cizgi.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("net \(ExamText.net(score.net))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Cizgi.ink)
                    Text("D \(score.correct) · Y \(score.wrong) · B \(score.blank)")
                        .font(.caption2)
                        .foregroundStyle(Cizgi.muted)
                }
            }
        }
    }

    // MARK: Actions

    private func start(_ mode: ExamRunMode, filter: ExamFilter, order: ExamSelection.Order, bank: ExamBank) {
        emptyMessage = nil
        let launcher = ExamRunLauncher(context: context, bank: bank)
        guard let run = launcher.start(
            mode: mode,
            filter: filter,
            progress: progress,
            limit: budget.limit(secondsPerQuestion: secondsPerQuestion),
            order: order
        ) else {
            emptyMessage = "Bu seçime uyan soru kalmadı."
            return
        }
        navigator.exercisePath.append(AppNavigator.ExamRoute.session(run.id))
    }

    /// "Yeniden açılır" (plan §7.6): a gap closed by a card since deleted is
    /// open again. Deterministic and cheap, so it runs whenever the screen
    /// that counts gaps appears.
    private func reconcileGaps() {
        let recorder = ExamRecorder(context: context)
        if recorder.reconcile(existingCardIds: Set(cards.map(\.id))) > 0 {
            try? context.save()
        }
    }
}

/// The active Pratik filter as removable chips — `ExerciseFilterChips`'
/// counterpart.
struct ExamFilterChips: View {
    @Binding var filter: ExamFilter

    private struct Chip: Hashable {
        let label: String
        let icon: String
        let clear: Int
    }

    private var chips: [Chip] {
        var result: [Chip] = []
        if let subject = filter.subject { result.append(Chip(label: subject, icon: "books.vertical", clear: 0)) }
        switch filter.topic {
        case .all: break
        case .none: result.append(Chip(label: "Konusuz", icon: "tag", clear: 1))
        case .topic(let name): result.append(Chip(label: name, icon: "tag", clear: 1))
        }
        if filter.minYear != nil || filter.maxYear != nil {
            let from = filter.minYear.map(String.init) ?? "…"
            let to = filter.maxYear.map(String.init) ?? "…"
            result.append(Chip(label: "\(from)–\(to)", icon: "calendar", clear: 2))
        }
        if !filter.sessions.isEmpty {
            result.append(Chip(label: filter.sessions.sorted().map(ExamText.session).joined(separator: ", "),
                               icon: "leaf", clear: 3))
        }
        if !filter.testGroups.isEmpty {
            result.append(Chip(label: ExamTestGroup.allCases.filter(filter.testGroups.contains)
                .map(ExamText.testGroup).joined(separator: ", "), icon: "doc", clear: 4))
        }
        if !filter.sourceKinds.isEmpty {
            result.append(Chip(label: ExamSourceKind.allCases.filter(filter.sourceKinds.contains)
                .map(ExamText.sourceKind).joined(separator: ", "), icon: "building.columns", clear: 5))
        }
        switch filter.progress {
        case .all: break
        case .unsolved: result.append(Chip(label: "Çözülmemiş", icon: "circle", clear: 6))
        case .wrong: result.append(Chip(label: "Yanlışlarım", icon: "xmark.circle", clear: 6))
        case .gaps: result.append(Chip(label: "Açıklar", icon: "book", clear: 6))
        }
        if !filter.includeFigures { result.append(Chip(label: "Görselsiz", icon: "photo", clear: 7)) }
        if !filter.includeOld { result.append(Chip(label: "2013 ve sonrası", icon: "clock", clear: 8)) }
        if filter.includeKeyless { result.append(Chip(label: "Anahtarsızlar dahil", icon: "key", clear: 9)) }
        return result
    }

    var body: some View {
        let chips = self.chips
        if !chips.isEmpty {
            ChipFlowRow(chips) { chip in
                Button {
                    clear(chip.clear)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: chip.icon)
                        Text(chip.label).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Cizgi.muted)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Cizgi.ink)
                    .padding(.horizontal, Cizgi.Space.sm)
                    .padding(.vertical, Cizgi.Space.xs)
                    .background(Cizgi.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func clear(_ dimension: Int) {
        let defaults = ExamFilter()
        switch dimension {
        case 0:
            filter.subject = nil
            filter.topic = .all
        case 1: filter.topic = .all
        case 2:
            filter.minYear = nil
            filter.maxYear = nil
        case 3: filter.sessions = []
        case 4: filter.testGroups = []
        case 5: filter.sourceKinds = []
        case 6: filter.progress = defaults.progress
        case 7: filter.includeFigures = defaults.includeFigures
        case 8: filter.includeOld = defaults.includeOld
        case 9: filter.includeKeyless = defaults.includeKeyless
        default: break
        }
    }
}
