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
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter traps
        // on a duplicate id, and a crash in the review screen is a far worse
        // outcome than showing one of two rows.
        let byId = Dictionary(allCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = plan.compactMap { byId[$0] }
        var newCards = 0
        let dailyLimited = ordered.filter { card in
            guard card.reviewCount == 0 else { return true }
            guard newCards < environment.settings.dailyNewCardLimit else { return false }
            newCards += 1
            return true
        }
        // A conservative five cards/minute budget. It is a ceiling, never a
        // promise that encourages rushing; unfinished due cards stay due.
        return Array(dailyLimited.prefix(environment.settings.quickSessionMinutes * 5))
    }

    private var currentCard: Card? {
        guard currentIndex < queue.count else { return nil }
        return allCards.first { $0.id == queue[currentIndex] }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Cizgi.paper.ignoresSafeArea()
                Group {
                    if queue.isEmpty {
                        emptyState(
                            title: "Bugünlük bitti",
                            icon: "checkmark.circle",
                            message: "Şu an tekrar bekleyen kart yok."
                        )
                    } else if let card = currentCard {
                        cardBody(card)
                    } else {
                        emptyState(
                            title: "Oturum tamamlandı",
                            icon: "checkmark.seal.fill",
                            message: "\(queue.count) kart tekrar edildi."
                        )
                    }
                }
            }
            .navigationTitle("Tekrar")
            .homeButtonToolbar()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if !queue.isEmpty && currentIndex < queue.count {
                        Text("\(currentIndex + 1) / \(queue.count)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Cizgi.muted)
                    }
                }
            }
        }
        .tint(Cizgi.accent)
        .onAppear(perform: startSessionIfNeeded)
    }

    private func emptyState(title: String, icon: String, message: String) -> some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(Cizgi.accent)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
        }
        .padding(Cizgi.Space.xl)
    }

    private func cardBody(_ card: Card) -> some View {
        VStack(spacing: Cizgi.Space.lg) {
            progressBar

            ScrollView {
                flashcard(card)
                    .padding(.horizontal, Cizgi.Space.lg)
                    .padding(.top, Cizgi.Space.sm)
            }

            actionArea(card)
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.bottom, Cizgi.Space.md)
        }
        .padding(.top, Cizgi.Space.sm)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = queue.isEmpty ? 0 : Double(currentIndex) / Double(queue.count)
            ZStack(alignment: .leading) {
                Capsule().fill(Cizgi.hairline)
                Capsule().fill(Cizgi.highlighter)
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .padding(.horizontal, Cizgi.Space.lg)
    }

    private func flashcard(_ card: Card) -> some View {
        CardSurface(highlighted: true, padding: Cizgi.Space.xl) {
            VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                CardTypeBadge(type: card.type)

                Text(card.front)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if isAnswerVisible {
                    Rectangle().fill(Cizgi.hairline).frame(height: 1)

                    Text(card.back)
                        .font(.title3)
                        .foregroundStyle(Cizgi.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    if let explanation = card.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(Cizgi.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let quote = card.sourceQuote, !quote.isEmpty {
                        DisclosureGroup("Kaynağı göster") {
                            Text(quote)
                                .font(.footnote)
                                .foregroundStyle(Cizgi.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline)
                        .tint(Cizgi.accent)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isAnswerVisible)
    }

    @ViewBuilder
    private func actionArea(_ card: Card) -> some View {
        if isAnswerVisible {
            gradeButtons(for: card)
        } else {
            Button("Cevabı göster") {
                withAnimation { isAnswerVisible = true }
            }
            .buttonStyle(CizgiPrimaryButtonStyle())
        }
    }

    private func gradeButtons(for card: Card) -> some View {
        HStack(spacing: Cizgi.Space.sm) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button {
                    grade(card, rating)
                } label: {
                    Text(rating.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Cizgi.Space.md)
                        .background(rating.tint)
                        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
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

        withAnimation {
            currentIndex += 1
            isAnswerVisible = false
        }
        shownAt = .now
    }
}
