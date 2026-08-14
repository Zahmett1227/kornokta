import Foundation

/// How many cards an Egzersiz session should draw: a flat count, a time box
/// translated through the user's own measured pace (`ReviewPace`, shared with
/// Tekrar's quick session), or the whole filtered pool.
public enum ExerciseBudget: Equatable, Hashable, Sendable {
    case cards(Int)
    case minutes(Int)
    case all

    public static let cardPresets = [5, 10, 20, 30, 50]
    public static let minutePresets = [5, 10, 20]

    /// Translates to `ExerciseSelection.pick`'s `limit:` contract — `nil`
    /// means every eligible card, exactly like `ReviewSessionPlanner`'s
    /// `cap`. Pool-size clamping is `pick`'s own job; this never needs the
    /// pool to answer "how many cards does this budget ask for".
    public func limit(secondsPerCard: Double) -> Int? {
        switch self {
        case .cards(let count): return count
        case .all: return nil
        case .minutes(let minutes): return ReviewPace.cardCount(forMinutes: minutes, secondsPerCard: secondsPerCard)
        }
    }
}
