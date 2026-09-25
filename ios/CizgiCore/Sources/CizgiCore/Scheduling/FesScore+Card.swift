import Foundation

/// The one way a live answer writes FES onto a card (docs/ADR-008).
///
/// Tekrar (`ReviewView.grade`) and Egzersiz (`ExerciseView.applyFesScore`)
/// each carried their own copy of these lines, and a third writer — the
/// Çıkmış bridge, where the owner names the card a missed exam question
/// needed (docs/PLAN-cikmis-soru-bankasi.md §7.5) — was about to add another.
/// Three hand-kept copies of a rule is how this project's pairs have drifted
/// before, so the rule lives here once.
///
/// Kept out of `FesScore.swift` on purpose: that file is Foundation-only and
/// compiles in the Linux slice package, which cannot see the SwiftData `Card`.
extension FesScore {
    /// Where the card stood against the FES threshold before and after one
    /// recorded answer. Egzersiz's summary counts cards that crossed it.
    public struct Transition: Equatable, Sendable {
        public let wasFes: Bool
        public let isFes: Bool

        public init(wasFes: Bool, isFes: Bool) {
            self.wasFes = wasFes
            self.isFes = isFes
        }

        public var entered: Bool { !wasFes && isFes }
        public var left: Bool { wasFes && !isFes }
    }

    /// Applies one answer to the card's FES record. Does not save — every
    /// caller already saves the context it graded in.
    @discardableResult
    public static func record(_ signal: Signal, on card: Card, at now: Date) -> Transition {
        let wasFes = isFes(score: card.fesScore)
        card.fesScore = apply(signal, to: card.fesScore)
        if signal.isNegative { card.fesNegativeCount += 1 }
        // A live update is itself authoritative — it need not wait for
        // `FesBackfillMigration` to say so. Without this, a card answered
        // between one launch and the next carries a real, nonzero score next
        // to a `nil` marker; exporting it in that window and restoring
        // elsewhere replays an empty history (`ExerciseAttempt` never travels
        // in a backup) and silently zeroes the score right back out (Codex
        // review, PR #41).
        card.fesInitializedAt = now
        return Transition(wasFes: wasFes, isFes: isFes(score: card.fesScore))
    }
}
