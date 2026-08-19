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
    /// The search text is part of that rule as of 2026-08-15, and was not
    /// before. It lived in a separate `filtered` property that only "Son
    /// eklenenler" read, so typing a word left the three tiles and the three
    /// sections above it showing the whole deck — on screen, indistinguishable
    /// from a search box that does nothing, which is exactly how it was
    /// reported.
    ///
    /// Filtered in memory rather than with `#Predicate`, on purpose: subject
    /// and topic live on an optional relationship, `CardSearch` folds Turkish
    /// case in a way SQLite will not, and this deck is hundreds of cards.
    private var cards: [Card] {
        allCards.filter { card in
            LibraryCardFilter.matches(
                subject: card.knowledgeUnit?.subject,
                topic: card.knowledgeUnit?.topic,
                subjectFilter: subjectFilter,
                topicFilter: topicFilter
            )
            && CardSearch.matches(
                query: searchText,
                front: card.front,
                back: card.back,
                explanation: card.explanation,
                tags: card.knowledgeUnit?.tags ?? [],
                subject: card.knowledgeUnit?.subject,
                topic: card.knowledgeUnit?.topic,
                // Autoclosure: `options` decodes JSON, so it is read only for
                // cards nothing cheaper matched, and never with no query.
                optionTexts: (card.options ?? []).map(\.text)
            )
        }
    }

    /// Naming what came up empty. With both a filter and a search able to empty
    /// the list, a fixed "Bu filtreye uyan kart yok." pointed at the wrong one.
    private var emptyResultMessage: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "Bu filtreye uyan kart yok." : "“\(query)” için kart yok."
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
                        // `.searchable` lives on this branch, not on the stack:
                        // in map mode the field searched nothing, and a search
                        // box that ignores what you type is worse than none.
                        Group {
                            if allCards.isEmpty { emptyState } else { list }
                        }
                        .searchable(text: $searchText, prompt: "Kartlarda ara")
                    case .map:
                        KnowledgeMapView(cards: allCards)
                    }
                }
            }
            .background(Cizgi.paper.ignoresSafeArea())
            .rootTabBarInset()
            .navigationTitle("Bilgilerim")
            // Value-based pushes so `navigator.libraryPath` really tracks depth
            // and `goHome()` really pops. Registered here, at the stack root,
            // once per value type — the links live in the card list and in
            // KnowledgeMapView.
            .navigationDestination(for: Card.self) { card in
                CardDetailView(card: card)
            }
            .navigationDestination(for: KnowledgeMapSubjectSummary.self) { summary in
                KnowledgeSubjectView(summary: summary)
            }
            .navigationDestination(for: AppNavigator.LibraryRoute.self) { route in
                switch route {
                case .darkMap: DarkMapView()
                }
            }
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
        cardList(cards)
    }

    /// The visible set arrives as a parameter rather than being read back out
    /// of `cards` per section.
    ///
    /// `cards` is a computed property, so each of the eight places this screen
    /// used to read it re-ran the whole filter. That was tolerable while the
    /// filter was two string comparisons; it is not now that it folds Turkish
    /// case and can decode a card's options, both on every keystroke.
    private func cardList(_ visible: [Card]) -> some View {
        let activeCount = visible.filter { $0.status == .active }.count
        let suspendedCount = visible.filter { $0.status == .suspended }.count

        // Cards the server could not fully vouch for (§13.3 rule 6). Faz 6
        // removed the approval gate and §13.3 wants one on a suspicious
        // question; the compromise the plan settled on is that the card is
        // active and reviewable and *listed* here rather than held back —
        // flagging instead of blocking (docs/FAZ7-PLAN-coktan-secmeli.md §9).
        let needsSecondLook = visible.filter {
            SecondLook.isPending(lowConfidence: $0.lowConfidence, status: $0.status)
        }

        // FES cards (docs/ADR-008): kept alongside "Gözden geçir" rather than
        // merged into it — a low-confidence card is the model doubting itself,
        // a FES card is *this user* repeatedly getting it wrong or unsure.
        // Same shape, different evidence.
        let fesCards = visible
            .filter { FesScore.isFes(score: $0.fesScore) && $0.status != .suspended }
            .sorted { $0.fesScore > $1.fesScore }

        let mostForgotten = visible.filter { $0.lapseCount > 0 }
            .sorted { $0.lapseCount > $1.lapseCount }
            .prefix(5)
            .map { $0 }

        return List {
            Section {
                VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                    ActiveFilterChips(subjectFilter: $subjectFilter, topicFilter: $topicFilter)
                    HStack(spacing: Cizgi.Space.sm) {
                        StatTile(value: "\(visible.count)", label: "Toplam")
                        StatTile(value: "\(activeCount)", label: "Aktif")
                        StatTile(value: "\(suspendedCount)", label: "Askıda")
                    }
                }
                .listRowInsets(EdgeInsets(top: Cizgi.Space.sm, leading: Cizgi.Space.lg,
                                          bottom: Cizgi.Space.sm, trailing: Cizgi.Space.lg))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if visible.isEmpty {
                Section {
                    Text(emptyResultMessage)
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.muted)
                }
            }

            if !needsSecondLook.isEmpty {
                Section {
                    ForEach(needsSecondLook) { card in
                        row(card)
                            // The one-gesture exit. The detail screen carries
                            // the same action spelled out, but a list the owner
                            // works through card by card should not cost four
                            // taps per card to clear.
                            .swipeActions(edge: .leading) {
                                Button {
                                    card.resolveSecondLook()
                                    try? context.save()
                                } label: {
                                    Label("Doğru", systemImage: "checkmark.seal")
                                }
                                .tint(Cizgi.success)
                            }
                    }
                    .onDelete { deleteCards(needsSecondLook, at: $0) }
                } header: {
                    sectionHeader("Gözden geçir")
                } footer: {
                    Text("Model ya da sunucu bu kartlarda emin olamadı — okunamayan "
                         + "bir el yazısı, ya da birbirini kapsayan şıklar. Kart "
                         + "desteye girdi; doğruluğunu bir kez kontrol et. "
                         + "Doğruysa sağa kaydırıp işaretle — kart listeden çıkar, "
                         + "tekrar sırasında kalır.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }

            if !fesCards.isEmpty {
                Section {
                    ForEach(fesCards) { card in
                        row(card)
                    }
                    .onDelete { deleteCards(fesCards, at: $0) }
                } header: {
                    sectionHeader("FES kartlar")
                } footer: {
                    Text("Tekrar'da ya da Egzersiz'de birkaç kez yanlış ya da kararsız "
                         + "işaretlenmiş kartlar. Doğru cevapladıkça kendiliğinden listeden çıkar.")
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
                ForEach(visible) { card in
                    row(card)
                }
                .onDelete { deleteCards(visible, at: $0) }
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
        NavigationLink(value: card) {
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

            // The exit from "Gözden geçir" (CizgiCore's `SecondLook`). Until
            // this shipped, nothing outside `Card.init` ever wrote
            // `lowConfidence`, so a card the owner had checked and found sound
            // stayed flagged forever — on this screen, in Bilgilerim's list, in
            // Egzersiz's quick start and in Tekrar's badge. The only ways off
            // the list were suspending or deleting the card, and both take it
            // out of review, which is the opposite of what checking it means.
            if card.lowConfidence {
                Section {
                    Button {
                        card.resolveSecondLook()
                        try? context.save()
                    } label: {
                        Label("Kontrol ettim, doğru", systemImage: "checkmark.seal")
                    }
                } header: {
                    sectionHeader("Gözden geçir")
                } footer: {
                    Text("Model bu kartta emin olamadı. Doğruluğunu kontrol "
                         + "ettiysen işaretle: kart listeden çıkar, tekrar "
                         + "sırasındaki yerini korur.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }

            // §10.4's surviving idea (2026-08-11): only on cards the model
            // itself doubted — the one moment an independent re-read helps.
            if card.lowConfidence {
                Section {
                    SecondOpinionSection(card: card)
                } header: {
                    sectionHeader("İkinci görüş")
                }
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
                // docs/ADR-008: a durable "keeps tripping me up" signal, fed by
                // both Tekrar and Egzersiz — shown only once the card actually
                // crosses the threshold, not as a running score nobody asked for.
                if FesScore.isFes(score: card.fesScore) {
                    LabeledContent("FES") {
                        Label("\(card.fesNegativeCount) kez yanlış/kararsız", systemImage: "flame.fill")
                            .foregroundStyle(Cizgi.warning)
                    }
                }
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

private extension Card {
    /// The only writer of `lowConfidence` outside `Card.init`, so the swipe on
    /// the list row and the button on the detail screen cannot resolve a card
    /// two different ways.
    ///
    /// Deliberately narrow: `status` is untouched, so the card stays in the
    /// deck and keeps its place in the FSRS queue, and no scheduling field is
    /// written — clearing the model's doubt is not a review.
    func resolveSecondLook() {
        lowConfidence = false
        updatedAt = .now
    }
}
