import Foundation

/// FES — a durable "keeps tripping me up" record fed by both Egzersiz and
/// Tekrar (docs/ADR-008).
///
/// Deliberately a stored running score, not one derived from history on every
/// read: `ExerciseAttempt` rows are pruned after 90 days
/// (`ExerciseHistory.retention`), so a derived score would silently reset.
/// Storing it also makes the score behave the way "keeps tripping me up"
/// should — a card missed twice after ten correct answers reads as
/// barely-FES, not as deeply negative, which a running score clamped at
/// `floor` gives for free and a lifetime sum would not.
///
/// Deliberately separate from `ExercisePracticeWeight`/`WeakPointRanking`
/// (docs/ADR-007's neighbour, `ExerciseSelection.swift`): that score decays
/// with time and answers Egzersiz's own "what should I drill next" ordering
/// question. FES answers a different one — "what have I been stuck on,
/// period" — so it never decays and it is fed by Tekrar too, which
/// `ExercisePracticeWeight` deliberately is not.
public enum FesScore {
    /// A score at or above this is FES.
    public static let threshold = 3
    /// Caps how long a bad streak lingers after the user fixes it — about six
    /// correct answers clears any score, however high it climbed.
    public static let ceiling = 12
    public static let floor = 0

    /// A single scored event, independent of which screen produced it.
    public enum Signal: Equatable, Sendable {
        case wrong
        case unsure
        case correct

        var weight: Int {
            switch self {
            case .wrong: return 2
            case .unsure: return 1
            case .correct: return -2
            }
        }

        /// Whether this event should count toward the card's lifetime
        /// negative tally (`Card.fesNegativeCount`), which — unlike the score
        /// itself — never goes back down.
        public var isNegative: Bool {
            switch self {
            case .wrong, .unsure: return true
            case .correct: return false
            }
        }
    }

    public static func signal(for result: ExerciseResult) -> Signal {
        switch result {
        case .missed: return .wrong
        case .unsure: return .unsure
        case .knew: return .correct
        }
    }

    /// "Zor" reads as Egzersiz's "Kararsızdım" — recalled, but not cleanly —
    /// so the two screens speak the same language (CLAUDE.md decision log).
    public static func signal(for rating: ReviewRating) -> Signal {
        switch rating {
        case .again: return .wrong
        case .hard: return .unsure
        case .good, .easy: return .correct
        }
    }

    public static func apply(_ signal: Signal, to score: Int) -> Int {
        min(ceiling, max(floor, score + signal.weight))
    }

    public static func isFes(score: Int) -> Bool {
        score >= threshold
    }

    /// Replays a chronological signal history from zero. Used by the
    /// one-time backfill migration and by tests — the live score is always
    /// `apply`'d incrementally at grading time, never recomputed this way.
    public static func replay(_ signals: [Signal]) -> Int {
        signals.reduce(floor) { apply($1, to: $0) }
    }
}
