import SwiftUI
import SwiftData
import CizgiCore

// MARK: - Row actions

/// The swipe actions every card list in Bilgilerim shares (2026-09-14).
///
/// Suspending used to live only on the card detail screen, four taps deep, while
/// the lists offered a one-swipe *delete* — the irreversible action was the easy
/// one. Now a full swipe suspends (reversible, the same verb Tekrar and Egzersiz
/// use) and deleting takes a deliberate tap on the second button.
///
/// One modifier so the three sections, the topic list and the search results
/// cannot drift into offering different actions for the same card.
struct CardRowActions: ViewModifier {
    @Environment(\.modelContext) private var context
    let card: Card

    func body(content: Content) -> some View {
        content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                card.status = card.status == .suspended ? .active : .suspended
                card.updatedAt = .now
                try? context.save()
            } label: {
                if card.status == .suspended {
                    Label("Askıdan çıkar", systemImage: "play.circle")
                } else {
                    Label("Askıya al", systemImage: "pause.circle")
                }
            }
            .tint(card.status == .suspended ? Cizgi.success : Cizgi.warning)

            // Unconfirmed, as `LibraryView.deleteCards` always was: one card the
            // owner is looking at. The confirmation lives where one swipe would
            // take many cards (the queue list's page delete).
            Button(role: .destructive) {
                context.delete(card)
                try? context.save()
            } label: {
                Label("Sil", systemImage: "trash")
            }
        }
    }
}

extension View {
    func cardRowActions(_ card: Card) -> some View {
        modifier(CardRowActions(card: card))
    }
}

/// A card row as every Bilgilerim list shows it: tappable into the detail,
/// swipeable to suspend or delete.
struct LibraryCardRow: View {
    let card: Card

    var body: some View {
        NavigationLink(value: card) {
            CardRow(card: card)
        }
        .listRowBackground(Cizgi.surface)
        .cardRowActions(card)
    }
}

// MARK: - Subject row

/// One subject in "Dersler": its colour, its name, and what is waiting in it.
struct SubjectBrowseRow: View {
    let stats: SubjectStats

    private var subject: CizgiSubject? { CizgiSubject.matching(stats.subject) }

    var body: some View {
        HStack(spacing: Cizgi.Space.md) {
            Circle()
                .fill(subject?.color ?? Cizgi.hairline)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stats.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                BrowseCounts(line: stats.line)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "12 kart · 3 vadesi geldi · 1 askıda" — the parts that are not zero.
struct BrowseCounts: View {
    let line: StatsLine

    var body: some View {
        HStack(spacing: Cizgi.Space.sm) {
            Text("\(line.cardCount) kart")
            if line.dueCount > 0 {
                Text("\(line.dueCount) vadesi geldi")
                    .foregroundStyle(Cizgi.warning)
            }
            if line.suspendedCount > 0 {
                Text("\(line.suspendedCount) askıda")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(Cizgi.muted)
    }
}

// MARK: - Subject → topics

/// One subject's topics, from the same grouping the "Dersler" row counted with.
/// For the "Ders atanmamış" row there is no topic list to place cards against,
/// so its cards are listed directly.
struct SubjectCardsView: View {
    @Query(sort: \Card.createdAt, order: .reverse) private var allCards: [Card]
    let subject: String?

    private var schema: SubjectTopicSchema? { SubjectTopicSchema.shared }

    private var members: [Card] {
        guard let schema else { return [] }
        return allCards.filter {
            StudyStatistics.belongs(subject: $0.knowledgeUnit?.subject, to: subject, schema: schema)
        }
    }

    var body: some View {
        let members = self.members
        List {
            if let schema, let subject {
                let summary = StudyStatistics.build(cards: members.map(StatsCard.init), now: .now, schema: schema)
                if let stats = summary.subjects.first {
                    Section {
                        ForEach(stats.topics) { topic in
                            NavigationLink(value: AppNavigator.LibraryRoute.topic(subject: subject, bucket: topic.bucket)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(topic.bucket == .unrecognized ? Cizgi.muted : Cizgi.ink)
                                    BrowseCounts(line: topic.line)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .listRowBackground(Cizgi.surface)
                        }
                    } header: {
                        LibrarySectionHeader(text: "Konular")
                    } footer: {
                        Text("\(stats.line.cardCount) kart, \(stats.topics.count) grupta.")
                            .font(.footnote)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
            } else {
                Section {
                    ForEach(members) { LibraryCardRow(card: $0) }
                } footer: {
                    Text("Dersi olmayan ya da ders listesinde bulunmayan kartlar. "
                         + "Kart detayındaki \"Düzenle\"den bir derse taşıyabilirsin.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle(subject ?? "Ders atanmamış")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if members.isEmpty {
                ContentUnavailableView("Kart kalmadı", systemImage: "rectangle.stack")
            }
        }
    }
}

// MARK: - Topic → cards

struct TopicCardsView: View {
    @Query(sort: \Card.createdAt, order: .reverse) private var allCards: [Card]
    let subject: String
    let bucket: TopicStats.Bucket

    private var cards: [Card] {
        guard let schema = SubjectTopicSchema.shared else { return [] }
        return allCards.filter {
            StudyStatistics.belongs(subject: $0.knowledgeUnit?.subject, to: subject, schema: schema)
                && StudyStatistics.belongs(topic: $0.knowledgeUnit?.topic, to: bucket, subject: subject, schema: schema)
        }
    }


    var body: some View {
        let cards = self.cards
        List {
            Section {
                ForEach(cards) { LibraryCardRow(card: $0) }
            } footer: {
                if bucket == .unrecognized {
                    Text("Konusu bu dersin konu listesinde olmayan kartlar.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle(bucket.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if cards.isEmpty {
                ContentUnavailableView("Kart kalmadı", systemImage: "rectangle.stack")
            }
        }
    }
}

struct LibrarySectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Cizgi.ink)
            .textCase(nil)
    }
}

extension StatsCard {
    /// The flat value the statistics and the grouping read from a card.
    init(_ card: Card) {
        self.init(
            id: card.id,
            subject: card.knowledgeUnit?.subject,
            topic: card.knowledgeUnit?.topic,
            status: card.status,
            dueDate: card.dueDate
        )
    }
}
