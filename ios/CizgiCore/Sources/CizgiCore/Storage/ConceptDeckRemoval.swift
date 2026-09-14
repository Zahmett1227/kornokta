import Foundation
import SwiftData

/// The one trace of the removed concept deck (docs/ADR-010, kaldırıldı
/// 2026-09-14).
///
/// The deck is gone — its importer, its screens, its column on `Card` and its
/// `queued` status. What cannot go is the ability to recognise its old records,
/// because they are still out there: in the owner's store until the removal
/// migration runs, and in every v7 backup file taken while the deck existed.
/// Both carry these markers and nothing else that says "concept".
///
/// The tag is the reliable one. The importer wrote it on every `KnowledgeUnit`
/// it made, precisely so that a concept card could be told apart from its tags
/// alone — "including inside a backup, which carries tags but not the pack",
/// as its own comment put it. On the simulator store the removal was proven
/// against, it covered 831 units and all 3.017 concept cards, with zero
/// untagged concept cards left over.
///
/// The status is a belt to that brace. Cards imported before the queue existed
/// are `active`, so matching on `queued` alone would have found none of them;
/// cards imported after it are `queued` *and* tagged. It stays because a stray
/// `queued` card with no unit would otherwise read as `.draft` through
/// `Card.status`'s fallback — a finished card silently reclassified as a
/// half-written one.
public enum ConceptDeckLegacy {
    public static let tag = "kavram-paketi"
    public static let queuedStatusRaw = "queued"

    /// Whether a backup record came from the removed deck.
    public static func isConcept(tags: [String], status: String) -> Bool {
        tags.contains(tag) || status == queuedStatusRaw
    }
}

/// Deletes everything the concept deck left in the store.
///
/// "Kavramlara dair hiçbir şey bırakma" — so this goes further than the cards.
/// A `KnowledgeUnit` cascades to its cards and a card cascades to its
/// `ReviewLog`s, but `ExerciseAttempt` holds a bare `cardId`, not a
/// relationship: deleting a card leaves its attempts behind, pointing at
/// nothing, and they would go on feeding Egzersiz's practice weights and any
/// statistics that count attempts. So runs and attempts are removed by id.
///
/// Deleted explicitly rather than trusted to the cascade rules. The cascade is
/// declared and would normally do this, but a migration that reports "done"
/// and writes a one-shot flag is exactly where "normally" is not good enough:
/// explicit deletes are what the counts below are made of, and what the tests
/// can hold still.
public enum ConceptDeckRemoval {

    public struct Outcome: Equatable, Sendable {
        public let unitsDeleted: Int
        public let cardsDeleted: Int
        public let reviewLogsDeleted: Int
        public let exerciseRunsDeleted: Int
        public let attemptsDeleted: Int

        public init(
            unitsDeleted: Int = 0,
            cardsDeleted: Int = 0,
            reviewLogsDeleted: Int = 0,
            exerciseRunsDeleted: Int = 0,
            attemptsDeleted: Int = 0
        ) {
            self.unitsDeleted = unitsDeleted
            self.cardsDeleted = cardsDeleted
            self.reviewLogsDeleted = reviewLogsDeleted
            self.exerciseRunsDeleted = exerciseRunsDeleted
            self.attemptsDeleted = attemptsDeleted
        }

        public var isEmpty: Bool { self == Outcome() }
    }

    /// Removes the deck and reports what went. Does not save — the caller owns
    /// the transaction, because it is the caller that must not record success
    /// on a failed write (`ApprovalGateRelease`'s rule).
    ///
    /// Idempotent: a second run finds nothing and returns an empty outcome.
    ///
    /// Filtered in memory rather than with `#Predicate`: `tags` is a stored
    /// array the macro cannot search, and the unit table is a few hundred rows
    /// on the capture deck the owner keeps.
    @discardableResult
    public static func remove(in context: ModelContext) throws -> Outcome {
        var unitsDeleted = 0
        var cardsDeleted = 0
        var logsDeleted = 0
        var deletedCardIds = Set<UUID>()

        func deleteCard(_ card: Card) {
            for log in card.reviews {
                context.delete(log)
                logsDeleted += 1
            }
            deletedCardIds.insert(card.id)
            context.delete(card)
            cardsDeleted += 1
        }

        let units = try context.fetch(FetchDescriptor<KnowledgeUnit>())
            .filter { $0.tags.contains(ConceptDeckLegacy.tag) }
        for unit in units {
            for card in unit.cards {
                deleteCard(card)
            }
            context.delete(unit)
            unitsDeleted += 1
        }

        // The stray-status pass. Compared against the raw string on purpose:
        // `CardStatus` no longer has the case, so `card.status` would answer
        // `.draft` and match nothing.
        let strays = try context.fetch(FetchDescriptor<Card>())
            .filter { $0.statusRaw == ConceptDeckLegacy.queuedStatusRaw && !deletedCardIds.contains($0.id) }
        for card in strays {
            deleteCard(card)
        }

        guard !deletedCardIds.isEmpty else {
            return Outcome()
        }

        // A run was built from one deck: the scope switch closed any open run
        // before the other deck could be studied. So a run whose queue is made
        // entirely of deleted cards *is* a concept run, and goes whole — its
        // attempts with it. A run that mixes (none should) keeps its capture
        // attempts and loses only the orphans.
        var runsDeleted = 0
        var attemptsDeleted = 0
        let runs = try context.fetch(FetchDescriptor<ExerciseRun>())
        for run in runs {
            let queue = run.queue
            if !queue.isEmpty, queue.allSatisfy({ deletedCardIds.contains($0) }) {
                attemptsDeleted += run.attempts.count
                for attempt in run.attempts {
                    context.delete(attempt)
                }
                context.delete(run)
                runsDeleted += 1
            } else {
                for attempt in run.attempts where deletedCardIds.contains(attempt.cardId) {
                    context.delete(attempt)
                    attemptsDeleted += 1
                }
            }
        }

        return Outcome(
            unitsDeleted: unitsDeleted,
            cardsDeleted: cardsDeleted,
            reviewLogsDeleted: logsDeleted,
            exerciseRunsDeleted: runsDeleted,
            attemptsDeleted: attemptsDeleted
        )
    }
}
