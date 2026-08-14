import SwiftUI
import CizgiCore

/// Egzersiz'in altı boyutlu kurulum ekranı: ders/konu (Bilgilerim'le
/// paylaşılan aynı `TopicFilter` sözleşmesi), kart tipi, kart durumu,
/// eklenme tarihi, FES (docs/ADR-008).
///
/// Bir taslak üzerinde çalışır ve yalnız "Uygula"da gerçek filtreye yazar —
/// kullanıcı "beş şıklı + FES" gibi bir kombinasyonu deneyip "0 kart"
/// gördüğünde vazgeçebilsin, ve vazgeçmesi arkada yarım kalmış bir filtre
/// bırakmasın.
struct ExerciseSetupSheet: View {
    @Binding var filter: ExerciseFilter
    let allCards: [Card]
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ExerciseFilter

    init(filter: Binding<ExerciseFilter>, allCards: [Card]) {
        self._filter = filter
        self.allCards = allCards
        self._draft = State(initialValue: filter.wrappedValue)
    }

    private var schema: SubjectTopicSchema? { SubjectTopicSchema.shared }

    private var matchingCount: Int {
        let now = Date()
        return allCards.reduce(into: 0) { count, card in
            guard card.status != .suspended else { return }
            if draft.matches(candidate(for: card), now: now) { count += 1 }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                subjectTopicSection
                cardTypeSection
                stateSection
                recencySection
                fesSection
            }
            .navigationTitle("Egzersizi kur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Sıfırla") { draft = ExerciseFilter() }
                        .disabled(!draft.isActive)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Cizgi.Space.sm) {
                    Text(matchingCount == 0 ? "Bu filtreye uyan kart yok" : "\(matchingCount) kart hazır")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(matchingCount == 0 ? Cizgi.danger : Cizgi.ink)
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

    @ViewBuilder
    private var subjectTopicSection: some View {
        if let schema {
            Section("Ders & konu") {
                Picker("Ders", selection: subjectBinding) {
                    Text("Tüm dersler").tag("")
                    ForEach(schema.subjectNames, id: \.self) { Text($0).tag($0) }
                }
                if let subject = draft.subject, let topics = schema.topics(for: subject) {
                    Picker("Konu", selection: topicBinding) {
                        Text("Tüm konular").tag(TopicFilter.all)
                        Text("Konusuz").tag(TopicFilter.none)
                        ForEach(topics, id: \.self) { Text($0).tag(TopicFilter.topic($0)) }
                    }
                }
            }
        }
    }

    /// Mirrors `SubjectTopicFilterMenu.subjectBinding`: a topic only means
    /// something inside its subject, and names are not unique across
    /// subjects, so changing the subject resets the topic.
    private var subjectBinding: Binding<String> {
        Binding(
            get: { draft.subject ?? "" },
            set: { newValue in
                draft.subject = newValue.isEmpty ? nil : newValue
                draft.topic = .all
            }
        )
    }

    private var topicBinding: Binding<TopicFilter> {
        Binding(get: { draft.topic }, set: { draft.topic = $0 })
    }

    // MARK: Kart tipi

    private var cardTypeSection: some View {
        Section {
            ChipFlowRow(CardType.allCases) { type in
                SelectableChip(
                    title: type.displayName,
                    systemImage: type.icon,
                    isSelected: draft.cardTypes.contains(type)
                ) {
                    toggle(type, in: &draft.cardTypes)
                }
            }
        } header: {
            Text("Kart tipi")
        } footer: {
            Text("Hiçbiri seçilmezse tüm tipler dahil olur.")
        }
    }

    // MARK: Kart durumu

    private var stateSection: some View {
        Section {
            ChipFlowRow(CardStateFilter.allCases) { state in
                SelectableChip(
                    title: state.displayName,
                    systemImage: state.icon,
                    isSelected: draft.states.contains(state)
                ) {
                    toggle(state, in: &draft.states)
                }
            }
        } header: {
            Text("Kart durumu")
        } footer: {
            Text("Birden fazla seçim birlikte (VEYA) uygulanır.")
        }
    }

    // MARK: Eklenme tarihi

    private var recencySection: some View {
        Section("Eklenme tarihi") {
            Picker("Eklenme tarihi", selection: $draft.recency) {
                ForEach(CardRecency.allCases, id: \.self) { recency in
                    Text(recency.displayName).tag(recency)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: FES

    private var fesSection: some View {
        Section {
            Toggle(isOn: $draft.fesOnly) {
                Label("Yalnızca FES kartlar", systemImage: "flame.fill")
            }
        } footer: {
            Text("FES: Tekrar'da ya da Egzersiz'de birkaç kez yanlış ya da kararsız işaretlenmiş kartlar.")
        }
    }

    private func toggle<T>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
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
}

/// Egzersiz'in altı boyutlu filtresini tek tek silinebilir chip'ler halinde
/// gösterir — `ActiveFilterChips`'in (Bilgilerim, yalnız ders/konu) Egzersiz'e
/// genişletilmiş hali. Ayrı tutulmasının nedeni tam olarak bu: Bilgilerim'in
/// filtre sözleşmesi büyümesin.
struct ExerciseFilterChips: View {
    @Binding var filter: ExerciseFilter

    var body: some View {
        let dimensions = filter.activeDimensions
        if !dimensions.isEmpty {
            ChipFlowRow(dimensions) { dimension in
                Button {
                    filter = filter.removing(dimension)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: dimension.icon)
                        Text(dimension.label)
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Cizgi.muted)
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
}
