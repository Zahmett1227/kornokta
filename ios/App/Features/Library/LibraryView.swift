import SwiftUI
import SwiftData
import CizgiCore

/// "Bilgilerim" (ANA-PLAN §6.6). No charts in the MVP — the section explicitly
/// says complex graphics are not required.
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

    private var suspended: [Card] { cards.filter { $0.status == .suspended } }
    /// Cards the model or the server's §19 gate flagged (`requiresUserApproval`).
    ///
    /// These are persisted as soon as they are generated — the pipeline no
    /// longer bounces the whole page back to re-selecting a region just
    /// because one card needs a look (§12.2, ADR-004) — so this is the one
    /// place that review actually happens. A card sitting here is not yet in
    /// any review deck (`ReviewScheduler` only ever looks at `.active`).
    private var needsReview: [Card] { cards.filter { $0.status == .needsReview } }
    private var mostForgotten: [Card] {
        cards.filter { $0.lapseCount > 0 }
            .sorted { $0.lapseCount > $1.lapseCount }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack(path: $navigator.libraryPath) {
            List {
                if cards.isEmpty {
                    ContentUnavailableView(
                        "Henüz bilgi yok",
                        systemImage: "books.vertical",
                        description: Text("Bir sayfa çekip pasaj seçtiğinde kartların burada birikir.")
                    )
                } else {
                    Section("Özet") {
                        LabeledContent("Toplam kart", value: "\(cards.count)")
                        LabeledContent("Aktif", value: "\(cards.filter { $0.status == .active }.count)")
                        LabeledContent("Askıya alınan", value: "\(suspended.count)")
                    }

                    if !needsReview.isEmpty {
                        Section {
                            ForEach(needsReview) { card in
                                NavigationLink { CardDetailView(card: card) } label: {
                                    CardRow(card: card)
                                }
                            }
                            .onDelete { deleteCards(needsReview, at: $0) }
                        } header: {
                            Text("Onay bekliyor (\(needsReview.count))")
                        } footer: {
                            Text("Bu kartlar modelin veya sunucunun bir şeyi işaretlemesiyle üretildi; onaylamadan tekrar destesine girmez (§12.2, §19.2).")
                        }
                    }

                    if !mostForgotten.isEmpty {
                        Section("En çok unutulanlar") {
                            ForEach(mostForgotten) { card in
                                NavigationLink { CardDetailView(card: card) } label: {
                                    CardRow(card: card)
                                }
                            }
                            .onDelete { deleteCards(mostForgotten, at: $0) }
                        }
                    }

                    Section("Son eklenenler") {
                        ForEach(filtered) { card in
                            NavigationLink { CardDetailView(card: card) } label: {
                                CardRow(card: card)
                            }
                        }
                        .onDelete { deleteCards(filtered, at: $0) }
                    }
                }
            }
            .navigationTitle("Bilgilerim")
            .searchable(text: $searchText, prompt: "Kartlarda ara")
            .homeButtonToolbar()
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.front)
                .font(.subheadline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(card.type.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if card.status == .suspended {
                    Label("Askıda", systemImage: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                if card.status == .needsReview {
                    Label("Onay bekliyor", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if card.lapseCount > 0 {
                    Text("\(card.lapseCount) kez unutuldu")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CardDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let card: Card

    var body: some View {
        List {
            if card.status == .needsReview {
                Section {
                    if let concern = card.knowledgeUnit?.sourceConcern, !concern.isEmpty {
                        Text(concern)
                    }
                    ForEach(card.riskFlags, id: \.self) { flag in
                        Label(flag.rawValue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Neden onay istiyor")
                } footer: {
                    Text("Kaynağa bakıp doğruysa onayla; onaylamadan bu kart tekrar destesine girmez (§12.2, §19.2).")
                }
            }

            Section("Soru") { Text(card.front) }
            Section("Cevap") { Text(card.back) }

            if let explanation = card.explanation, !explanation.isEmpty {
                Section("Açıklama") { Text(explanation) }
            }

            // Every active card must trace back to its source (§24.4).
            if let quote = card.sourceQuote {
                Section("Kaynak") {
                    Text(quote).font(.footnote).foregroundStyle(.secondary)
                    if let subject = card.knowledgeUnit?.subject {
                        LabeledContent("Ders", value: subject)
                    }
                }
            }

            if card.status != .needsReview && !card.riskFlags.isEmpty {
                Section("İşaretler") {
                    ForEach(card.riskFlags, id: \.self) { flag in
                        Label(flag.rawValue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Tekrar") {
                LabeledContent("Sonraki", value: card.dueDate.formatted(.dateTime.day().month().year()))
                LabeledContent("Tekrar sayısı", value: "\(card.reviewCount)")
                LabeledContent("Unutma", value: "\(card.lapseCount)")
            }

            if card.status == .needsReview {
                Section {
                    Button("Onayla") {
                        card.status = .active
                        card.updatedAt = .now
                        try? context.save()
                    }
                    Button("Sil", role: .destructive) {
                        context.delete(card)
                        try? context.save()
                        dismiss()
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
                Section {
                    Button("Sil", role: .destructive) {
                        context.delete(card)
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Kart")
        .homeButtonToolbar()
    }
}
