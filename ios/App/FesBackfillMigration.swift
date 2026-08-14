import Foundation
import SwiftData
import CizgiCore

/// Per-card backfill for FES (docs/ADR-008): replays a card's full
/// review/practice history into `fesScore`/`fesNegativeCount` the first time
/// the card is seen with `fesInitializedAt == nil`.
///
/// Keyed off the card's own field rather than a UserDefaults "done" flag,
/// unlike `SubjectBackfillMigration`/`TopicBackfillMigration`: this is not a
/// one-time event in the deck's history. A brand new card also starts nil —
/// its replay is simply a no-op, since it has no history yet — and a card
/// restored from a pre-v6 backup arrives nil on purpose. Both cases must
/// self-heal on the very next launch rather than being permanently skipped by
/// a global flag that only remembers "every card known at the time this ran
/// once was handled".
@MainActor
enum FesBackfillMigration {
    static func runIfNeeded(container: ModelContainer) {
        let context = ModelContext(container)
        do {
            let cards = try context.fetch(
                FetchDescriptor<Card>(predicate: #Predicate { $0.fesInitializedAt == nil })
            )
            guard !cards.isEmpty else { return }

            // One fetch for every attempt, grouped by card, rather than one
            // query per card: `ExerciseAttempt.cardId` is a bare id (the same
            // "id, not a relationship" shape ADR-006 uses for jobs), so there
            // is no cheaper way to join it to `Card`.
            let attemptsByCard = try context.fetch(FetchDescriptor<ExerciseAttempt>())
                .reduce(into: [UUID: [ExerciseAttempt]]()) { acc, attempt in
                    acc[attempt.cardId, default: []].append(attempt)
                }

            let now = Date()
            for card in cards {
                let reviewSignals = card.reviews.map {
                    (date: $0.reviewedAt, signal: FesScore.signal(for: $0.rating))
                }
                let exerciseSignals = (attemptsByCard[card.id] ?? []).map {
                    (date: $0.answeredAt, signal: FesScore.signal(for: $0.result))
                }
                let signals = (reviewSignals + exerciseSignals)
                    .sorted { $0.date < $1.date }
                    .map(\.signal)

                card.fesScore = FesScore.replay(signals)
                card.fesNegativeCount = signals.filter(\.isNegative).count
                card.fesInitializedAt = now
            }

            try context.save()
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }
}
