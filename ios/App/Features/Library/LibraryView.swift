import SwiftUI
import SwiftData
import CizgiCore

/// "Bilgilerim" (ANA-PLAN §6.6). No charts in the MVP — the section explicitly
/// says complex graphics are not required.
///
/// Faz 6 (docs/FAZ6-PLAN.md): cards enter the active deck with no approval step,
/// so the old "Onay bekliyor" section is gone. Any legacy `needsReview` card
/// still appears in "Son eklenenler" and can be managed from its detail screen.
struct LibraryView: View {
    private enum ContentMode: String, CaseIterable {
        case cards = "Kartlar"
        case map = "Bilgi Haritası"
    }

    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.createdAt, order: .reverse) private var allCards: [Card]
    @State private var searchText = ""
    @State private var subjectFilter: String?
    @State private var topicFilter: TopicFilter = .all
    @State private var contentMode: ContentMode = .cards

    /// Everything below counts and lists from here, not from the raw query: a
    /// filtered screen that still showed unfiltered totals and "en çok
    /// unutulanlar" would be reporting on a deck the user is not looking at.
    ///
    /// Filtered in memory rather than with `#Predicate`, on purpose: subject
    /// and topic live on an optional relationship, and this deck is hundreds
    /// of cards — the same choice the existing text search already makes.
    private var cards: [Card] {
        allCards.filter {
            LibraryCardFilter.matches(
                subject: $0.knowledgeUnit?.subject,
                topic: $0.knowledgeUnit?.topic,
                subjectFilter: subjectFilter,
                topicFilter: topicFilter
            )
        }
    }

    private var filtered: [Card] {
        guard !searchText.isEmpty else { return cards }
        return cards.filter {
            $0.front.localizedCaseInsensitiveContains(searchText)
                || $0.back.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var activeCount: Int { cards.filter { $0.status == .active }.count }
    private var suspendedCount: Int { cards.filter { $0.status == .suspended }.count }
    /// Cards the server could not fully vouch for (§13.3 rule 6).
    ///
    /// Faz 6 removed the approval gate and §13.3 wants one on a suspicious
    /// question. This is the compromise the plan settled on: the card is active
    /// and reviewable, and it is *listed* here rather than held back — flagging
    /// instead of blocking (docs/FAZ7-PLAN-coktan-secmeli.md §9).
    private var needsSecondLook: [Card] {
        cards.filter { $0.lowConfidence && $0.status != .suspended }
    }

    private var mostForgotten: [Card] {
        cards.filter { $0.lapseCount > 0 }
            .sorted { $0.lapseCount > $1.lapseCount }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack(path: $navigator.libraryPath) {
            VStack(spacing: 0) {
                Picker("Görünüm", selection: $contentMode) {
                    ForEach(ContentMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.vertical, Cizgi.Space.sm)

                Group {
                    switch contentMode {
                    case .cards:
                        if allCards.isEmpty { emptyState } else { list }
                    case .map:
                        KnowledgeMapView(cards: allCards)
                    }
                }
            }
            .background(Cizgi.paper.ignoresSafeArea())
            .navigationTitle("Bilgilerim")
            .searchable(text: $searchText, prompt: "Kartlarda ara")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if contentMode == .cards {
                        SubjectTopicFilterMenu(subjectFilter: $subjectFilter, topicFilter: $topicFilter)
                    }
                }
            }
        }
        .tint(Cizgi.accent)
    }

    private var emptyState: some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundStyle(Cizgi.accent)
            Text("Henüz bilgi yok")
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text("Bir sayfa çektiğinde üretilen kartlar burada birikir.")
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
        }
        .padding(Cizgi.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                    ActiveFilterChips(subjectFilter: $subjectFilter, topicFilter: $topicFilter)
                    HStack(spacing: Cizgi.Space.sm) {
                        StatTile(value: "\(cards.count)", label: "Toplam")
                        StatTile(value: "\(activeCount)", label: "Aktif")
                        StatTile(value: "\(suspendedCount)", label: "Askıda")
                    }
                }
                .listRowInsets(EdgeInsets(top: Cizgi.Space.sm, leading: Cizgi.Space.lg,
                                          bottom: Cizgi.Space.sm, trailing: Cizgi.Space.lg))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if cards.isEmpty {
                Section {
                    Text("Bu filtreye uyan kart yok.")
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.muted)
                }
            }

            if !needsSecondLook.isEmpty {
                Section {
                    ForEach(needsSecondLook) { card in
                        row(card)
                    }
                    .onDelete { deleteCards(needsSecondLook, at: $0) }
                } header: {
                    sectionHeader("Gözden geçir")
                } footer: {
                    Text("Model ya da sunucu bu kartlarda emin olamadı — okunamayan "
                         + "bir el yazısı, ya da birbirini kapsayan şıklar. Kart "
                         + "desteye girdi; doğruluğunu bir kez kontrol et.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }

            if !mostForgotten.isEmpty {
                Section {
                    ForEach(mostForgotten) { card in
                        row(card)
                    }
                    .onDelete { deleteCards(mostForgotten, at: $0) }
                } header: {
                    sectionHeader("En çok unutulanlar")
                }
            }

            Section {
                ForEach(filtered) { card in
                    row(card)
                }
                .onDelete { deleteCards(filtered, at: $0) }
            } header: {
                sectionHeader("Son eklenenler")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Cizgi.ink)
            .textCase(nil)
    }

    private func row(_ card: Card) -> some View {
        NavigationLink { CardDetailView(card: card) } label: {
            CardRow(card: card)
        }
        .listRowBackground(Cizgi.surface)
    }

    private func deleteCards(_ source: [Card], at offsets: IndexSet) {
        for index in offsets {
            context.delete(source[index])
        }
        try? context.save()
    }
}

struct CardRow: View {
    let card: Card

    private var tags: [String] { Array((card.knowledgeUnit?.tags ?? []).prefix(2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
            Text(card.front)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Cizgi.ink)
                .lineLimit(2)
            HStack(spacing: Cizgi.Space.sm) {
                CardTypeBadge(type: card.type)
                ForEach(tags, id: \.self) { TagChip($0) }
                Spacer(minLength: 0)
                if card.status == .suspended {
                    Label("Askıda", systemImage: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(Cizgi.muted)
                }
                if card.lapseCount > 0 {
                    Label("\(card.lapseCount)", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                        .foregroundStyle(Cizgi.warning)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct CardDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var isEditing = false

    /// Resolved once per render, and by the same helper the review screen uses,
    /// so a card cannot show one provenance here and another there.
    private var source: CardSourceMaterial {
        CardSourceView.material(for: card, imageStore: environment.imageStore)
    }

    var body: some View {
        List {
            Section { Text(card.front).font(.body.weight(.medium)).foregroundStyle(Cizgi.ink) }
                header: { sectionHeader("Soru") }
            Section { Text(card.back).foregroundStyle(Cizgi.ink) }
                header: { sectionHeader("Cevap") }

            if let explanation = card.explanation, !explanation.isEmpty {
                Section { Text(explanation).foregroundStyle(Cizgi.muted) }
                    header: { sectionHeader("Açıklama") }
            }

            // §5.5. Previously gated on `card.sourceQuote`, which the Faz 6
            // contract never fills, so this section was invisible on every card
            // the app now makes — while the page photograph it should have been
            // showing sat on disk one relationship hop away.
            if !source.isEmpty {
                Section {
                    CardSourceView(material: source, imageStore: environment.imageStore)
                } header: { sectionHeader("Kaynak") }
            }

            // §13.3: the answer key is part of the card, so it is readable
            // outside the review screen too.
            if let options = card.options {
                Section {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        HStack(alignment: .top, spacing: Cizgi.Space.sm) {
                            Image(systemName: option.isCorrect ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(option.isCorrect ? Cizgi.success : Cizgi.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.text).foregroundStyle(Cizgi.ink)
                                if !option.isCorrect, let why = option.why, !why.isEmpty {
                                    Text(why).font(.footnote).foregroundStyle(Cizgi.muted)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(option.text), \(option.isCorrect ? "doğru" : "yanlış")")
                    }
                } header: { sectionHeader("Şıklar") }
            }

            Section {
                LabeledContent("Ders", value: card.knowledgeUnit?.subject ?? "Seçilmedi")
                LabeledContent("Konu", value: card.knowledgeUnit?.topic ?? "Konusuz")
            } header: { sectionHeader("Sınıflandırma") }

            if !(card.knowledgeUnit?.tags ?? []).isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Cizgi.Space.sm) {
                            ForEach(card.knowledgeUnit?.tags ?? [], id: \.self) { TagChip($0) }
                        }
                    }
                } header: { sectionHeader("Etiketler") }
            }

            Section {
                LabeledContent("Sonraki", value: card.dueDate.formatted(.dateTime.day().month().year()))
                LabeledContent("Tekrar sayısı", value: "\(card.reviewCount)")
                LabeledContent("Unutma", value: "\(card.lapseCount)")
            } header: { sectionHeader("Tekrar") }

            // Legacy safety: a card left as needsReview from before Faz 6 can
            // still be activated. New cards never land here.
            if card.status == .needsReview {
                Section {
                    Button("Etkinleştir") {
                        card.status = .active
                        card.updatedAt = .now
                        try? context.save()
                    }
                }
            } else {
                Section {
                    Button(card.status == .suspended ? "Askıdan çıkar" : "Askıya al") {
                        card.status = card.status == .suspended ? .active : .suspended
                        card.updatedAt = .now
                        try? context.save()
                    }
                }
            }

            Section {
                Button("Sil", role: .destructive) {
                    context.delete(card)
                    try? context.save()
                    dismiss()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("Kart")
        .homeButtonToolbar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isEditing = true } label: {
                    Label("Düzenle", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            CardEditorView(card: card)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Cizgi.ink)
            .textCase(nil)
    }
}
