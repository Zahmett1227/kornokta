import Foundation

/// A free-practice run over a set of cards, independent of FSRS.
///
/// Deliberately *not* a `ReviewSession`: nothing here grades, requeues, writes
/// a `ReviewLog` or touches a card's scheduling state. It is a shuffled walk
/// with a position — question, answer, next — for going over a subject before
/// an exam without disturbing the spaced-repetition history that took months
/// to build.
///
/// The shuffle takes an injected generator so the order is testable; production
/// passes `SystemRandomNumberGenerator`.
public struct ExerciseSession: Equatable, Sendable {
    public private(set) var queue: [UUID]
    public private(set) var position: Int

    public init(cardIds: [UUID], using generator: inout some RandomNumberGenerator) {
        self.queue = cardIds.shuffled(using: &generator)
        self.position = 0
    }

    /// `nil` once the walk is over — the view shows its finish screen rather
    /// than silently wrapping around, which would make "how much is left"
    /// meaningless.
    public var current: UUID? {
        position < queue.count ? queue[position] : nil
    }

    public var isFinished: Bool { position >= queue.count }
    public var total: Int { queue.count }
    /// How many cards are behind the cursor — the "3 / 12" numerator.
    public var completed: Int { min(position, queue.count) }

    public mutating func advance() {
        guard position < queue.count else { return }
        position += 1
    }

    /// Reshuffles and starts over. A second pass in the original order would
    /// be recall of the sequence as much as of the cards.
    public mutating func restart(using generator: inout some RandomNumberGenerator) {
        queue = queue.shuffled(using: &generator)
        position = 0
    }

    /// Drops cards that no longer exist (deleted mid-session), keeping the
    /// cursor on the card the user is looking at.
    public mutating func remove(_ id: UUID) {
        guard let index = queue.firstIndex(of: id) else { return }
        queue.remove(at: index)
        if index < position { position -= 1 }
    }
}
