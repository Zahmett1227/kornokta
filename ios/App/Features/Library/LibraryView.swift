import SwiftUI
import SwiftData
import CizgiCore

/// "Bilgilerim" (ANA-PLAN §6.6). No charts in the MVP — the section explicitly
/// says complex graphics are not required.
struct LibraryView: View {
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
    private var mostForgotten: [Card] {
        cards.filter { $0.lapseCount > 0 }
            .sorted { $0.lapseCount > $1.lapseCount }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
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

                    if !mostForgotten.isEmpty {
                        Section("En çok unutulanlar") {
                            ForEach(mostForgotten) { card in
                                CardRow(card: card)
                            }
                        }
                    }

                    Section("Son eklenenler") {
                        ForEach(filtered) { card in
                            NavigationLink { CardDetailView(card: card) } label: {
                                CardRow(card: card)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bilgilerim")
            .searchable(text: $searchText, prompt: "Kartlarda ara")
        }
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
    let card: Card

    var body: some View {
        List {
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

            if !card.riskFlags.isEmpty {
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

            Section {
                Button(card.status == .suspended ? "Askıdan çıkar" : "Askıya al") {
                    card.status = card.status == .suspended ? .active : .suspended
                    card.updatedAt = .now
                    try? context.save()
                }
            }
        }
        .navigationTitle("Kart")
    }
}
