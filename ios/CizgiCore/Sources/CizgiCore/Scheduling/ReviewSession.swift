import Foundation

/// One sitting at the review screen: which cards, in what order, how far in, and
/// what the last grade did so it can be taken back (ANA-PLAN §5.4, §6.5, §18.3).
///
/// This lives here rather than in the view for the reason the package exists at
/// all: it is the part of the review loop that can go wrong silently, and here
/// `swift test` can hold it still. The view keeps only what SwiftUI needs —
/// which card is on screen and whether the answer is revealed.
///
/// ### Why the queue is not a frozen list
///
/// It used to be: the screen took a snapshot of card ids on appear and walked it
/// to the end. Three things followed, and together they made a real deck
/// unusable — a card you forgot never came back, the session could not be
/// restarted without relaunching the app, and a mis-tap was permanent. This type
/// exists to make all three expressible.
public struct ReviewSession: Equatable, Sendable {

    /// How many times one card may be put back into the same session.
    ///
    /// Not unlimited: a card you cannot recall after three attempts in one
    /// sitting is not going to be learned by a fourth, and an unbounded requeue
    /// turns "Unuttum" into a loop with no way out but leaving the screen. After
    /// this it keeps whatever the scheduler gave it and comes back in a later
    /// session, which is what the scheduler was for.
    public static let maxRelearningRepeats = 3

    /// What one `advance` did, so `rewind` can undo exactly that and nothing else.
    public struct Step: Equatable, Sendable {
        public let cardId: UUID
        /// Where the card was put back, when it was. `nil` means it was not.
        public let requeuedAt: Int?
    }

    public private(set) var queue: [UUID]
    /// How many cards have been graded — also the index of the current one.
    public private(set) var position: Int
    private var relearningRepeats: [UUID: Int]

    public init(queue: [UUID]) {
        self.queue = queue
        self.position = 0
        self.relearningRepeats = [:]
    }

    public var current: UUID? {
        position < queue.count ? queue[position] : nil
    }

    public var isFinished: Bool { position >= queue.count }
    public var isEmpty: Bool { queue.isEmpty }
    /// Total *showings* in this session, which grows when a card is put back.
    public var total: Int { queue.count }
    public var completed: Int { position }

    /// Moves past the current card.
    ///
    /// `relearn` is set for a forgotten card. The card goes to the **end** of the
    /// queue rather than a few places on: the scheduler has just given it a
    /// short interval (ten minutes under both schedulers), and the end of the
    /// queue is the closest this can get to honouring that without pretending to
    /// a precision a card count does not have. In a short session it comes back
    /// sooner than ten minutes — which is still the right thing to do with a
    /// card you just failed.
    @discardableResult
    public mutating func advance(relearn: Bool = false) -> Step? {
        guard let card = current else { return nil }

        var requeuedAt: Int?
        if relearn, relearningRepeats[card, default: 0] < Self.maxRelearningRepeats {
            relearningRepeats[card, default: 0] += 1
            queue.append(card)
            requeuedAt = queue.count - 1
        }
        position += 1
        return Step(cardId: card, requeuedAt: requeuedAt)
    }

    /// Takes back the last `advance`.
    ///
    /// Only the step that actually produced the current position can be undone;
    /// anything else is ignored rather than corrupting the queue. Callers keep
    /// exactly one step (the last), so this guard is a safety net, not a policy.
    public mutating func rewind(_ step: Step) {
        guard position > 0, queue[position - 1] == step.cardId else { return }

        // A requeue always lands at an index at or after the new position, so
        // removing it cannot disturb the card being restored.
        if let requeuedAt = step.requeuedAt, requeuedAt < queue.count, queue[requeuedAt] == step.cardId {
            queue.remove(at: requeuedAt)
            relearningRepeats[step.cardId] = max(0, (relearningRepeats[step.cardId] ?? 1) - 1)
        }
        position -= 1
    }
}

/// A card as the planner needs to see it. A struct rather than the tuple
/// `plan` takes because the limits below need one more field than the ordering
/// does, and a five-tuple at every call site is how the wrong element ends up in
/// the wrong position.
public struct PlannableCard: Equatable, Sendable {
    public let id: UUID
    public let dueDate: Date
    public let knowledgeUnitId: UUID?
    public let status: CardStatus
    /// Zero means never reviewed — a *new* card, which the daily introduction
    /// limit applies to and a repeat review does not.
    public let reviewCount: Int

    public init(id: UUID, dueDate: Date, knowledgeUnitId: UUID?, status: CardStatus, reviewCount: Int) {
        self.id = id
        self.dueDate = dueDate
        self.knowledgeUnitId = knowledgeUnitId
        self.status = status
        self.reviewCount = reviewCount
    }
}

extension ReviewSessionPlanner {

    /// The cards for one session: `plan`'s ordering, then the two limits.
    ///
    /// `cap` is the *whole session's* ceiling and is deliberately optional. It
    /// used to be applied unconditionally from the "quick session" setting, so
    /// five minutes' worth of cards was not a mode but the only mode — a deck
    /// with two hundred cards due could never show more than twenty-five of them
    /// in one sitting, which §18.3's "bugün bekleyen tüm kartlar" default rules
    /// out. Pass `nil` for that default; pass a count for a quick session.
    ///
    /// `alreadyIntroducedToday` is what makes the new-card limit a *daily* one.
    /// Counting only within the session let the allowance reset every time the
    /// screen was reopened, which is not a limit at all.
    public static func session(
        cards: [PlannableCard],
        now: Date,
        newCardLimit: Int,
        alreadyIntroducedToday: Int = 0,
        cap: Int? = nil
    ) -> [UUID] {
        let ordered = plan(
            cards: cards.map {
                (id: $0.id, dueDate: $0.dueDate, knowledgeUnitId: $0.knowledgeUnitId, status: $0.status)
            },
            now: now
        )
        let reviewCounts = Dictionary(
            cards.map { ($0.id, $0.reviewCount) },
            uniquingKeysWith: { first, _ in first }
        )

        var remainingNew = max(0, newCardLimit - alreadyIntroducedToday)
        let limited = ordered.filter { id in
            // An unknown id is treated as a repeat rather than as new: the
            // introduction limit exists to pace *learning*, and wrongly holding
            // back a card that is merely due is the worse mistake.
            guard reviewCounts[id] == 0 else { return true }
            guard remainingNew > 0 else { return false }
            remainingNew -= 1
            return true
        }

        guard let cap, cap > 0 else { return limited }
        return Array(limited.prefix(cap))
    }
}

/// How long this user actually takes per card, measured rather than assumed.
///
/// Every `ReviewLog` has recorded `responseTimeMs` since Faz 1 and nothing ever
/// read it. The "quick session" setting meanwhile converted minutes to cards
/// with a hardcoded five-a-minute guess, so a five-minute session was twenty-five
/// cards whether that took two minutes or twelve. This turns the setting into
/// the time budget it claims to be.
public enum ReviewPace {

    /// Used until there is enough history to say anything. Deliberately
    /// generous: overestimating the time per card makes a quick session shorter
    /// than asked, which is a smaller harm than one that overruns.
    public static let fallbackSecondsPerCard: Double = 12

    /// Below this a "measurement" is someone tapping through without reading;
    /// above it, a card they walked away from mid-answer. Both would distort the
    /// budget, so both are clamped rather than dropped — dropping them would let
    /// a session of pure outliers fall back to the default and look measured.
    public static let plausibleSecondsPerCard: ClosedRange<Double> = 3...60

    /// How many recent reviews to read. Enough to be stable, short enough to
    /// follow a change in how the user works.
    public static let sampleSize = 50

    /// Median rather than mean: one interrupted review should not move the
    /// estimate, and the median of a handful of reviews is already usable.
    public static func secondsPerCard(recentResponseTimesMs: [Int]) -> Double {
        let samples = recentResponseTimesMs
            .prefix(sampleSize)
            .map { min(max(Double($0) / 1000, plausibleSecondsPerCard.lowerBound), plausibleSecondsPerCard.upperBound) }
            .sorted()
        guard !samples.isEmpty else { return fallbackSecondsPerCard }
        let middle = samples.count / 2
        if samples.count.isMultiple(of: 2) {
            return (samples[middle - 1] + samples[middle]) / 2
        }
        return samples[middle]
    }

    /// How many cards fit in `minutes`. At least one, so a budget can never
    /// produce a session with nothing in it.
    public static func cardCount(forMinutes minutes: Int, secondsPerCard: Double) -> Int {
        guard minutes > 0, secondsPerCard > 0 else { return 1 }
        return max(1, Int((Double(minutes) * 60 / secondsPerCard).rounded(.down)))
    }
}

/// How many cards were introduced *today*, kept across launches.
///
/// A "daily new card limit" is a calendar idea, unlike FSRS's own intervals,
/// which are deliberately continuous durations so a flight across time zones
/// cannot shift a due date (§18.1). So this one place does use
/// `Calendar.current`: the user's own day is exactly what they mean by "günlük".
///
/// Persisted state rather than something derived from the store: a card's first
/// review is not reliably recoverable afterwards — a lapse can reset the very
/// fields that would identify it — and a limit that quietly miscounts is worse
/// than one that keeps its own tally.
public struct DailyNewCardLedger: Codable, Equatable, Sendable {
    public private(set) var day: Date
    public private(set) var count: Int

    public init(day: Date = .distantPast, count: Int = 0) {
        self.day = day
        self.count = count
    }

    /// Zero on any day but the recorded one, so a stale tally can never eat
    /// today's allowance.
    public func count(on date: Date, calendar: Calendar = .current) -> Int {
        calendar.isDate(day, inSameDayAs: date) ? count : 0
    }

    public mutating func record(on date: Date, calendar: Calendar = .current) {
        if calendar.isDate(day, inSameDayAs: date) {
            count += 1
        } else {
            day = date
            count = 1
        }
    }

    /// Undoing a grade must give the allowance back, or a few corrected
    /// mis-taps would silently end the day's new cards.
    public mutating func undoRecord(on date: Date, calendar: Calendar = .current) {
        guard calendar.isDate(day, inSameDayAs: date) else { return }
        count = max(0, count - 1)
    }
}
