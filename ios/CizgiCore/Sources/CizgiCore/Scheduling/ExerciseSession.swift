import Foundation

/// A self-contained practice result. These values are intentionally not review
/// ratings: recording one must never alter FSRS scheduling state.
public enum ExerciseResult: String, Codable, CaseIterable, Sendable {
    case knew
    case unsure
    case missed
}

public enum ExerciseMode: String, Codable, CaseIterable, Sendable {
    case free
    case quick
    case weak
}

public struct ExerciseSummary: Equatable, Sendable {
    public let knew: Int
    public let unsure: Int
    public let missed: Int

    public var answered: Int { knew + unsure + missed }

    public init(knew: Int, unsure: Int, missed: Int) {
        self.knew = knew
        self.unsure = unsure
        self.missed = missed
    }
}

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
    public private(set) var results: [UUID: ExerciseResult]

    public init(cardIds: [UUID], using generator: inout some RandomNumberGenerator) {
        self.queue = cardIds.shuffled(using: &generator)
        self.position = 0
        self.results = [:]
    }

    /// Rebuilds a durable run after app relaunch. Invalid cursor positions are
    /// clamped so a partially written snapshot finishes safely instead of
    /// indexing outside the queue.
    public init(
        queue: [UUID],
        position: Int,
        results: [UUID: ExerciseResult] = [:]
    ) {
        self.queue = queue
        self.position = min(max(position, 0), queue.count)
        self.results = results.filter { queue.contains($0.key) }
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

    public var summary: ExerciseSummary {
        ExerciseSummary(
            knew: results.values.filter { $0 == .knew }.count,
            unsure: results.values.filter { $0 == .unsure }.count,
            missed: results.values.filter { $0 == .missed }.count
        )
    }

    public mutating func advance() {
        guard position < queue.count else { return }
        position += 1
    }

    /// Records the practice-only result for the current card and advances.
    /// Keeping this operation in the session makes it impossible for the UI to
    /// attribute an answer to the card after the cursor has already moved.
    public mutating func record(_ result: ExerciseResult) {
        guard let current else { return }
        results[current] = result
        advance()
    }

    /// Reshuffles and starts over. A second pass in the original order would
    /// be recall of the sequence as much as of the cards.
    public mutating func restart(using generator: inout some RandomNumberGenerator) {
        queue = queue.shuffled(using: &generator)
        position = 0
        results = [:]
    }

    /// Drops cards that no longer exist (deleted mid-session), keeping the
    /// cursor on the card the user is looking at.
    public mutating func remove(_ id: UUID) {
        guard let index = queue.firstIndex(of: id) else { return }
        queue.remove(at: index)
        results.removeValue(forKey: id)
        if index < position { position -= 1 }
    }
}
