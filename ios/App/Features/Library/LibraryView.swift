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
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]
    @State private var searchText = ""

    private var filtered: [Card] {
        guard !searchText.isEmpty else { return cards }
        return cards.filter {
            $0.front.localizedCaseInsensitiveContains(searchText)
                || $0.back.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var activeCount: Int { cards.filter { $0.status == .active }.count }
    private var suspendedCount: Int { cards.filter { $0.status == .suspended }.count }
    private var mostForgotten: [Card] {
        cards.filter { $0.lapseCount > 0 }
            .sorted { $0.lapseCount > $1.lapseCount }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack(path: $navigator.libraryPath) {
            Group {
                if cards.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Cizgi.paper.ignoresSafeArea())
            .navigationTitle("Bilgilerim")
            .searchable(text: $searchText, prompt: "Kartlarda ara")
            .homeButtonToolbar()
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
                HStack(spacing: Cizgi.Space.sm) {
                    StatTile(value: "\(cards.count)", label: "Toplam")
                    StatTile(value: "\(activeCount)", label: "Aktif")
                    StatTile(value: "\(suspendedCount)", label: "Askıda")
                }
                .listRowInsets(EdgeInsets(top: Cizgi.Space.sm, leading: Cizgi.Space.lg,
                                          bottom: Cizgi.Space.sm, trailing: Cizgi.Space.lg))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let card: Card

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

            // Faz 6 cards have no per-card source quote; only show it when one
            // exists (legacy cards) rather than an empty "Kaynak" section.
            if let quote = card.sourceQuote, !quote.isEmpty {
                Section {
                    Text(quote).font(.footnote).foregroundStyle(Cizgi.muted)
                    if let subject = card.knowledgeUnit?.subject {
                        LabeledContent("Ders", value: subject)
                    }
                } header: { sectionHeader("Kaynak") }
            } else if let subject = card.knowledgeUnit?.subject {
                Section { LabeledContent("Ders", value: subject) }
            }

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
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Cizgi.ink)
            .textCase(nil)
    }
}
