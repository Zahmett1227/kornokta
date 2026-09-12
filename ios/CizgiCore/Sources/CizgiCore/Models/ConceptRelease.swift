import Foundation
import SwiftData

/// Letting a batch of queued concept cards into the deck, on the day the owner
/// asks for it.
///
/// A concept pack is one file of thousands of finished cards. Importing them as
/// `.active` with `dueDate` now would make every one of them due on the first
/// day: the review screen would open on a backlog of 3.000, FSRS would have no
/// way to drain it, and the predictable outcome is that the deck gets abandoned
/// rather than learned. So the importer parks them in `.queued` and this type is
/// the only way out of it.
///
/// No daily quota, no schedule, no automatic drip. That was a deliberate choice
/// (2026-09-10): a quota decides for you on a day it cannot know about — a night
/// shift, a free Sunday — and then either nags or wastes the day. A button that
/// releases cards when pressed puts the decision where the information is.
/// Nothing here runs unless the owner taps.
///
/// Lives in CizgiCore, split in two: `plan` is pure and takes the selection
/// decision, `release` applies it to a context. The split is what makes the
/// interesting half testable without a container, and it is the same shape as
/// `ApprovalGateRelease` (which keeps its write out of the decision for the
/// same reason).
public enum ConceptRelease {

    /// What the selector needs to know about one queued card. Deliberately not
    /// `Card`: the decision is about ordering and grouping, and a struct the
    /// tests can build by hand keeps it that way.
    public struct Candidate: Equatable, Sendable {
        /// The card.
        public let id: UUID
        /// The concept it belongs to (`Card.knowledgeUnit?.id`), or nil for a
        /// queued card with no concept — which a pack never produces, but the
        /// relationship is optional and this must not crash on one.
        public let conceptId: UUID?
        /// The pack's own ordering key: the concept slug (`bk-117`, `km-062`),
        /// carried as the first entry of `KnowledgeUnit.tags`. Sorting by it
        /// releases concepts in source-book order instead of insertion order,
        /// which is arbitrary once a pack has been re-imported.
        public let order: String

        public init(id: UUID, conceptId: UUID?, order: String) {
            self.id = id
            self.conceptId = conceptId
            self.order = order
        }
    }

    /// Which cards a "+N" press should release.
    ///
    /// Releases **whole concepts**, so `target` is a floor rather than an exact
    /// count: asking for 20 when the next concepts hold 6, 7 and 9 cards
    /// releases 22. Splitting a concept is the thing worth avoiding — meeting
    /// two of a concept's six cards teaches the fragment without the frame, and
    /// the remaining four would arrive days later as if they were new material.
    ///
    /// Concepts come out in `order`, and the cards within a concept keep the
    /// order they arrived in. Ties on `order` (two concepts sharing a slug,
    /// which a well-formed pack does not contain) fall back to the concept id so
    /// the result is deterministic — a selector that returned a different batch
    /// each time it ran would make the count shown on screen a guess.
    public static func plan(_ candidates: [Candidate], target: Int) -> [UUID] {
        guard target > 0, !candidates.isEmpty else { return [] }

        // Grouped by concept, each group keeping its incoming card order.
        var groups: [GroupKey: [UUID]] = [:]
        var keys: [GroupKey] = []
        for candidate in candidates {
            let key = GroupKey(order: candidate.order, conceptId: candidate.conceptId)
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(candidate.id)
        }

        var released: [UUID] = []
        for key in keys.sorted() {
            guard let cards = groups[key] else { continue }
            released.append(contentsOf: cards)
            if released.count >= target { break }
        }
        return released
    }

    /// Moves the planned cards into the active deck and returns how many moved.
    ///
    /// Does not save — the caller owns the transaction, for `ApprovalGateRelease`'s
    /// reason: only the caller can tell the user what landed, and telling him
    /// 20 cards arrived when the write failed is worse than the failure.
    ///
    /// `dueDate` is set to now at release rather than at import. An imported
    /// card's due date is meaningless while it is queued, and if it were left at
    /// the import date then a pack imported in September and released in January
    /// would arrive four months overdue — FSRS reads that lateness as evidence
    /// about the owner's memory, which it is not.
    ///
    /// Only `.queued` cards are touched. Passing an id that is already active
    /// does nothing instead of resetting its schedule: the batch button can be
    /// pressed twice before the view refreshes, and the second press must not
    /// pull cards back to the front of the queue.
    @discardableResult
    public static func release(ids: [UUID], in context: ModelContext, now: Date = .now) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let wanted = Set(ids)
        let cards = try context.fetch(FetchDescriptor<Card>())
            .filter { wanted.contains($0.id) && $0.status == .queued }
        for card in cards {
            card.status = .active
            card.dueDate = now
            card.updatedAt = now
        }
        return cards.count
    }

    /// The queued cards of a collection, as candidates, ready for `plan`.
    ///
    /// Takes an already-fetched array rather than fetching: the screen that
    /// calls this has the cards in hand from its own `@Query`, and a second
    /// fetch here could disagree with what the owner is looking at.
    public static func candidates(in cards: [Card]) -> [Candidate] {
        cards.filter { $0.status == .queued }.map { card in
            Candidate(
                id: card.id,
                conceptId: card.knowledgeUnit?.id,
                // First tag is the pack slug (`ConceptPackImporter` writes it
                // first, for exactly this kind of use). Falling back to the
                // concept's name keeps the ordering stable and human-meaningful
                // for a card whose tags were edited away.
                order: card.knowledgeUnit?.tags.first
                    ?? card.knowledgeUnit?.canonicalClaim
                    ?? ""
            )
        }
    }

    /// Sort key for a concept group: pack order first, concept id to break ties.
    private struct GroupKey: Hashable, Comparable {
        let order: String
        let conceptId: UUID?

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return (lhs.conceptId?.uuidString ?? "") < (rhs.conceptId?.uuidString ?? "")
        }
    }
}
