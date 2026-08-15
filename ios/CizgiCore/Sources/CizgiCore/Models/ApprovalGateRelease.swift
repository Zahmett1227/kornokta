import Foundation
import SwiftData

/// Releasing the cards left standing at the approval gate Faz 6 removed
/// (2026-08-15).
///
/// Lives here rather than beside the migration that calls it so it can be run
/// against a real `ModelContainer` in tests. That is not ceremony: the App-side
/// wrapper is guarded by a one-shot UserDefaults flag, so a lookup that
/// silently matched nothing would mark itself done and strand the cards
/// permanently — the one failure mode of this change that cannot be noticed
/// afterwards.
public enum ApprovalGateRelease {

    /// Moves every card still parked at the gate into the active deck and
    /// returns how many moved. Does not save; the caller owns the transaction,
    /// because it is the caller that must not record success on a failed write.
    ///
    /// Filtered in memory rather than with `#Predicate`. `status` is a computed
    /// bridge over the stored `statusRaw`, which the macro cannot see through,
    /// so a predicate would have to hard-code the raw string — the exact silent
    /// mismatch described above. Reading the whole card table is what
    /// `SubjectBackfillMigration` already does for its orphan pass, and this
    /// deck is hundreds of cards.
    ///
    /// `.draft` is deliberately left alone: it is `Card.init`'s default, so a
    /// card sitting in it is a half-written card rather than one somebody
    /// declined to approve. Activating those would be guessing at intent
    /// instead of applying a decision the project already recorded.
    @discardableResult
    public static func release(in context: ModelContext) throws -> Int {
        let stranded = try context.fetch(FetchDescriptor<Card>())
            .filter { $0.status == .needsReview }
        let now = Date()
        for card in stranded {
            card.status = .active
            card.updatedAt = now
        }
        return stranded.count
    }
}
