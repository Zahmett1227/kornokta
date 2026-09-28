import SwiftUI
import CizgiCore

/// Pratik's filter (plan §7.4 c) — a draft applied only on "Uygula", with a
/// live count, the `ExerciseSetupSheet` pattern: trying a combination that
/// leaves "0 soru" must be free to abandon.
struct ExamSetupSheet: View {
    @Binding var filter: ExamFilter
    let bank: ExamBank
    let progress: [String: ExamProgress]
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ExamFilter

    init(filter: Binding<ExamFilter>, bank: ExamBank, progress: [String: ExamProgress]) {
        self._filter = filter
        self.bank = bank
        self.progress = progress
        self._draft = State(initialValue: filter.wrappedValue)
    }

    private var years: ClosedRange<Int> {
        let all = bank.papers.map(\.year)
        return (all.min() ?? 2006)...(all.max() ?? 2026)
    }

    private var matchingCount: Int {
        bank.questions(matching: draft, progress: progress).count
    }

    var body: some View {
        NavigationStack {
            Form {
                subjectSection
                yearSection
                sittingSection
                progressSection
                sourceSection
                extrasSection
            }
            .scrollContentBackground(.hidden)
            .background(Cizgi.paper)
            .navigationTitle("Pratiği kur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Sıfırla") { draft = ExamFilter() }
                        .disabled(!draft.isActive)
                }
            }
            .safeAreaInset(edge: .bottom) {
                let count = matchingCount
                VStack(spacing: Cizgi.Space.sm) {
                    Text(count == 0 ? "Bu filtreye uyan soru yok" : "\(count.formatted()) soru hazır")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(count == 0 ? Cizgi.danger : Cizgi.ink)
                    Button("Uygula") {
                        filter = draft
                        dismiss()
                    }
                    .buttonStyle(CizgiPrimaryButtonStyle())
                }
                .padding(Cizgi.Space.lg)
                .background(.bar)
            }
        }
    }

    // MARK: Ders & konu

    private var subjectSection: some View {
        Section {
            Picker("Ders", selection: Binding(
                get: { draft.subject ?? "" },
                set: { value in
                    draft.subject = value.isEmpty ? nil : value
                    draft.topic = .all
                }
            )) {
                Text("Tüm dersler").tag("")
                ForEach(bank.osymSubjects, id: \.self) { Text($0).tag($0) }
            }
            if let subject = draft.subject,
               let appSubject = bank.appSubject(forOsymSubject: subject),
               let topics = SubjectTopicSchema.shared?.topics(for: appSubject) {
                Picker("Konu", selection: $draft.topic) {
                    Text("Tüm konular").tag(TopicFilter.all)
                    Text("Konusuz").tag(TopicFilter.none)
                    ForEach(topics, id: \.self) { Text($0).tag(TopicFilter.topic($0)) }
                }
            }
        } header: {
            Text("Ders & konu")
        } footer: {
            Text("ÖSYM'nin ders adları; Histoloji-Embriyoloji'nin konuları Fizyoloji listesinden.")
        }
    }

    // MARK: Yıl

    private var yearSection: some View {
        Section {
            Stepper(value: Binding(
                get: { draft.minYear ?? years.lowerBound },
                set: { draft.minYear = $0 == years.lowerBound ? nil : min($0, draft.maxYear ?? years.upperBound) }
            ), in: years) {
                LabeledContent("En eski", value: "\(draft.minYear ?? years.lowerBound)")
            }
            Stepper(value: Binding(
                get: { draft.maxYear ?? years.upperBound },
                set: { draft.maxYear = $0 == years.upperBound ? nil : max($0, draft.minYear ?? years.lowerBound) }
            ), in: years) {
                LabeledContent("En yeni", value: "\(draft.maxYear ?? years.upperBound)")
            }
            Toggle(isOn: Binding(get: { !draft.includeOld }, set: { draft.includeOld = !$0 })) {
                Label("Yalnız 2013 ve sonrası", systemImage: "clock.arrow.circlepath")
            }
        } header: {
            Text("Yıl")
        } footer: {
            Text("2012 ve öncesinin soruları \"eski\" rozetiyle gelir: cevabı o günün kılavuzlarına göre.")
        }
    }

    // MARK: Dönem & test

    private var sittingSection: some View {
        Section("Dönem ve test") {
            ChipFlowRow([1, 2]) { session in
                SelectableChip(title: ExamText.session(session), isSelected: draft.sessions.contains(session)) {
                    toggle(session, in: &draft.sessions)
                }
            }
            ChipFlowRow(ExamTestGroup.allCases) { group in
                SelectableChip(title: ExamText.testGroup(group), isSelected: draft.testGroups.contains(group)) {
                    toggle(group, in: &draft.testGroups)
                }
            }
        }
    }

    // MARK: Durum

    private var progressSection: some View {
        Section {
            Picker("Durum", selection: $draft.progress) {
                Text("Tümü").tag(ExamProgressFilter.all)
                Text("Çözülmemiş").tag(ExamProgressFilter.unsolved)
                Text("Yanlışlarım").tag(ExamProgressFilter.wrong)
                Text("Açıklar").tag(ExamProgressFilter.gaps)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("Durum")
        } footer: {
            Text("Tümü'nde de önce hiç çözmediklerin gelir.")
        }
    }

    // MARK: Kaynak

    private var sourceSection: some View {
        Section {
            ChipFlowRow(ExamSourceKind.allCases) { kind in
                SelectableChip(title: ExamText.sourceKind(kind), isSelected: draft.sourceKinds.contains(kind)) {
                    toggle(kind, in: &draft.sourceKinds)
                }
            }
        } header: {
            Text("Kaynak")
        } footer: {
            Text("Hiçbiri seçilmezse hepsi dahil.")
        }
    }

    // MARK: Görsel & anahtarsız

    private var extrasSection: some View {
        Section {
            Toggle(isOn: $draft.includeFigures) {
                Label("Görselli sorular", systemImage: "photo")
            }
            Toggle(isOn: $draft.includeKeyless) {
                Label("Anahtarsız sorular (yalnız oku)", systemImage: "key.slash")
            }
        } footer: {
            Text("Görselli sorularda kitapçıktaki görsel sorunun altında açılır. Anahtarsız sorular "
                 + "(2006–2008, 2024/1'in çoğu) çözülür ama doğru/yanlış işaretlenmez.")
        }
    }

    private func toggle<T>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}
