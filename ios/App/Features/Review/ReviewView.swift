import SwiftUI
import SwiftData
import CizgiCore

/// Daily review (ANA-PLAN §5.4, §6.5).
///
/// No network and no model call anywhere in this screen — §11.4 lists review as
/// a place that must never hit an API, and §24.5 requires it to work offline.
struct ReviewView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context

    @Query private var allCards: [Card]

    @State private var queue: [UUID] = []
    @State private var currentIndex = 0
    @State private var isAnswerVisible = false
    @State private var shownAt = Date()

    private var dueCards: [Card] {
        let plan = ReviewSessionPlanner.plan(
            cards: allCards.map {
                (id: $0.id, dueDate: $0.dueDate, knowledgeUnitId: $0.knowledgeUnit?.id, status: $0.status)
            },
            now: .now
        )
        let byId = Dictionary(uniqueKeysWithValues: allCards.map { ($0.id, $0) })
        return plan.compactMap { byId[$0] }
    }

    private var currentCard: Card? {
        guard currentIndex < queue.count else { return nil }
        return allCards.first { $0.id == queue[currentIndex] }
    }

    var body: some View {
        NavigationStack {
            Group {
                if queue.isEmpty {
                    ContentUnavailableView(
                        "Bugünlük bitti",
                        systemImage: "checkmark.circle",
                        description: Text("Şu an tekrar bekleyen kart yok.")
                    )
                } else if let card = currentCard {
                    cardBody(card)
                } else {
                    ContentUnavailableView(
                        "Oturum tamamlandı",
                        systemImage: "checkmark.circle.fill",
                        description: Text("\(queue.count) kart tekrar edildi.")
                    )
                }
            }
            .navigationTitle("Tekrar")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if !queue.isEmpty && currentIndex < queue.count {
                        Text("\(currentIndex + 1) / \(queue.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear(perform: startSessionIfNeeded)
    }

    private func cardBody(_ card: Card) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Text(card.front)
                .font(.title2)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if isAnswerVisible {
                Divider().padding(.horizontal, 48)

                Text(card.back)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let quote = card.sourceQuote {
                    DisclosureGroup("Kaynağı göster") {
                        Text(quote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }
            }

            Spacer()

            if isAnswerVisible {
                gradeButtons(for: card)
            } else {
                Button("Cevabı göster") {
                    isAnswerVisible = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
            }
        }
        .padding(.vertical)
    }

    private func gradeButtons(for card: Card) -> some View {
        HStack(spacing: 8) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button(rating.label) {
                    grade(card, rating)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    private func startSessionIfNeeded() {
        guard queue.isEmpty else { return }
        queue = dueCards.map(\.id)
        currentIndex = 0
        isAnswerVisible = false
        shownAt = .now
    }

    private func grade(_ card: Card, _ rating: ReviewRating) {
        let state = SchedulingState(
            stability: card.stability,
            difficulty: card.difficulty,
            reviewCount: card.reviewCount,
            lapseCount: card.lapseCount,
            lastReviewedAt: card.lastReviewedAt
        )
        let now = Date()
        let result = environment.scheduler.schedule(rating: rating, state: state, now: now)

        let elapsedDays = card.lastReviewedAt.map {
            now.timeIntervalSince($0) / 86_400
        } ?? 0

        let log = ReviewLog(
            reviewedAt: now,
            rating: rating,
            responseTimeMs: Int(now.timeIntervalSince(shownAt) * 1000),
            scheduledDays: result.scheduledDays,
            elapsedDays: elapsedDays,
            stabilityBefore: card.stability,
            stabilityAfter: result.stability,
            difficultyBefore: card.difficulty,
            difficultyAfter: result.difficulty
        )
        log.card = card
        context.insert(log)

        card.dueDate = result.dueDate
        card.stability = result.stability
        card.difficulty = result.difficulty
        card.reviewCount += 1
        if rating == .again { card.lapseCount += 1 }
        card.lastReviewedAt = now
        card.updatedAt = now

        try? context.save()

        currentIndex += 1
        isAnswerVisible = false
        shownAt = .now
    }
}
