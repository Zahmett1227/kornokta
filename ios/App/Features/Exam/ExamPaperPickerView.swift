import SwiftUI
import SwiftData
import CizgiCore

/// Deneme → a real paper (plan §7.4 b): year, then session and test, each row
/// with its question count, its time and whose key it carries. A paper with
/// no key at all is grey — a mock nobody can mark is not a mock.
struct ExamPaperPickerView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ExamRun> { $0.modeRaw == "mock" && $0.finishedAt != nil }) private var mocks: [ExamRun]
    @State private var pending: Entry?

    struct Entry: Identifiable, Hashable {
        let paper: ExamPaper
        let questionCount: Int
        let scoreableCount: Int
        let minutes: Int
        var id: String { paper.id }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private func entries(_ bank: ExamBank) -> [(year: Int, entries: [Entry])] {
        let all = bank.papers.compactMap { paper -> Entry? in
            let queue = ExamMockComposer.paperQueue(bank, paper: paper)
            guard !queue.isEmpty else { return nil }
            return Entry(
                paper: paper,
                questionCount: queue.count,
                scoreableCount: ExamMockComposer.scoreableCount(bank, queue: queue),
                minutes: Int((Double(ExamMockComposer.timeLimitSeconds(bank, paper: paper, questionCount: queue.count)) / 60).rounded())
            )
        }
        let testOrder: [ExamTest: Int] = [.temel: 0, .temel2: 1, .klinik: 2]
        return Dictionary(grouping: all, by: \.paper.year)
            .map { year, entries in
                (year, entries.sorted {
                    ($0.paper.session, testOrder[$0.paper.test] ?? 9) < ($1.paper.session, testOrder[$1.paper.test] ?? 9)
                })
            }
            .sorted { $0.year > $1.year }
    }

    var body: some View {
        Group {
            if let bank = examLibrary.bank {
                List {
                    Section {
                        Text("Kağıt ÖSYM'nin sırasıyla ve kendi süresiyle gelir; cevaplar sen bitirene kadar "
                             + "açılmaz. Süre sen duraklatmadıkça işler — uygulama kapalıyken de.")
                            .font(.footnote)
                            .foregroundStyle(Cizgi.muted)
                    }
                    ForEach(entries(bank), id: \.year) { group in
                        Section(String(group.year)) {
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                Text("Soru bankası yok.").foregroundStyle(Cizgi.muted)
            }
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("Kağıt seç")
        .confirmationDialog(
            pending.map { "\(ExamText.paperName($0.paper)) denemesi" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { entry in
            Button("Başla") { start(entry) }
            Button("Vazgeç", role: .cancel) {}
        } message: { entry in
            Text("\(entry.questionCount) soru, \(entry.minutes) dakika. Açık bir oturum varsa bitirilir.")
        }
    }

    private func row(_ entry: Entry) -> some View {
        let disabled = entry.scoreableCount == 0
        let sittings = mocks.filter { $0.paperId == entry.paper.id }.count
        return Button {
            pending = entry
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(ExamText.session(entry.paper.session)) · \(ExamText.test(entry.paper.test))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(disabled ? Cizgi.faint : Cizgi.ink)
                    if entry.paper.year <= ExamQuestion.lastOldYear {
                        TagChip("eski", systemImage: "clock.arrow.circlepath")
                    }
                    Spacer()
                    if sittings > 0 {
                        Text("\(sittings) kez")
                            .font(.caption)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                Text(detail(entry))
                    .font(.caption)
                    .foregroundStyle(disabled ? Cizgi.faint : Cizgi.muted)
            }
        }
        .disabled(disabled)
    }

    private func detail(_ entry: Entry) -> String {
        var parts = ["\(entry.questionCount) soru"]
        if entry.paper.sourceKind == .osymPartial { parts[0] += " (ÖSYM kısmi)" }
        parts.append("\(entry.minutes) dk")
        if entry.scoreableCount == 0 {
            parts.append("anahtarsız")
        } else {
            parts.append("anahtar: \(ExamText.keySource(entry.paper.keySource))")
            if entry.scoreableCount < entry.questionCount {
                parts.append("\(entry.scoreableCount) puanlanır")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func start(_ entry: Entry) {
        guard let bank = examLibrary.bank,
              let run = ExamRunLauncher(context: context, bank: bank).startMock(paper: entry.paper) else { return }
        // The picker makes way for the mock: "Çıkmış'a dön" from its result
        // lands on the home screen, not back in this list.
        navigator.openExam([.home, .mock(run.id)])
    }
}

/// "Karma deneme" (plan §7.4 b): N questions with a real paper's subject
/// distribution, timed at that paper's rate.
struct ExamMixedMockSheet: View {
    let bank: ExamBank
    let progress: [String: ExamProgress]
    let onStart: (ExamRun) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var group: ExamTestGroup = .temel
    @State private var count = 40
    @State private var failed = false

    static let counts = [20, 40, 60, 120]

    var body: some View {
        let template = ExamMockComposer.template(bank, group: group)
        NavigationStack {
            Form {
                Section {
                    Picker("Test", selection: $group) {
                        ForEach(ExamTestGroup.allCases, id: \.self) { Text(ExamText.testGroup($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ChipFlowRow(Self.counts) { value in
                        SelectableChip(title: "\(value) soru", isSelected: count == value) { count = value }
                    }
                } footer: {
                    if let template {
                        let minutes = Int((Double(ExamMockComposer.timeLimitSeconds(bank, paper: template, questionCount: count)) / 60).rounded())
                        Text("Ders dağılımı \(ExamText.paperName(template)) kağıdından; süre \(minutes) dakika. "
                             + "Her dersten önce hiç çözmediğin sorular gelir.")
                    } else {
                        Text("Bu test için bankada tam bir kağıt yok.")
                    }
                }
                if let template {
                    Section("Dağılım") {
                        let shares = ExamMockComposer.subjectCounts(bank, paper: template)
                        let quotas = ExamMockComposer.apportion(count, weights: shares.map(\.count))
                        ForEach(Array(zip(shares, quotas).enumerated()), id: \.offset) { _, pair in
                            LabeledContent(pair.0.subject, value: "\(pair.1)")
                        }
                    }
                }
                if failed {
                    Text("Bu seçime uyan soru bulunamadı.").foregroundStyle(Cizgi.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Cizgi.paper)
            .navigationTitle("Karma deneme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Başla") { start() }
                    .buttonStyle(CizgiPrimaryButtonStyle())
                    .disabled(template == nil)
                    .padding(Cizgi.Space.lg)
                    .background(.bar)
            }
        }
    }

    private func start() {
        guard let run = ExamRunLauncher(context: context, bank: bank)
            .startMixedMock(group: group, count: count, progress: progress) else {
            failed = true
            return
        }
        dismiss()
        onStart(run)
    }
}
