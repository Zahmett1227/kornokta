import Foundation

// MARK: - Inputs

/// What the statistics need from a card — a flat value, so the grouping below
/// runs in `swift test` without a store (the `KnowledgeMapCard` pattern).
public struct StatsCard: Equatable, Sendable {
    public let id: UUID
    public let subject: String?
    public let topic: String?
    public let status: CardStatus
    public let dueDate: Date

    public init(id: UUID, subject: String?, topic: String?, status: CardStatus, dueDate: Date) {
        self.id = id
        self.subject = subject
        self.topic = topic
        self.status = status
        self.dueDate = dueDate
    }
}

/// One graded review (`ReviewLog`). Kept forever, so any window can be counted.
public struct StatsReview: Equatable, Sendable {
    public let cardId: UUID
    public let at: Date
    public let rating: ReviewRating

    public init(cardId: UUID, at: Date, rating: ReviewRating) {
        self.cardId = cardId
        self.at = at
        self.rating = rating
    }
}

/// One Egzersiz answer (`ExerciseAttempt`). Pruned after 90 days
/// (`ExerciseHistory.retention`), which is why its column is labelled so.
public struct StatsAttempt: Equatable, Sendable {
    public let cardId: UUID
    public let at: Date
    public let result: ExerciseResult

    public init(cardId: UUID, at: Date, result: ExerciseResult) {
        self.cardId = cardId
        self.at = at
        self.result = result
    }
}

/// The period the owner is looking at.
public enum StatsWindow: String, CaseIterable, Hashable, Sendable {
    case all
    case last30Days
    case last7Days

    public var title: String {
        switch self {
        case .all: return "Tümü"
        case .last30Days: return "30 gün"
        case .last7Days: return "7 gün"
        }
    }

    /// The first moment inside the window, or `nil` for all time.
    public func start(now: Date) -> Date? {
        switch self {
        case .all: return nil
        case .last30Days: return now.addingTimeInterval(-30 * 86_400)
        case .last7Days: return now.addingTimeInterval(-7 * 86_400)
        }
    }
}

// MARK: - Outputs

public struct ReviewStats: Equatable, Sendable {
    /// Distinct cards reviewed at least once in the window.
    public let seenCards: Int
    public let reviews: Int
    /// "Unuttum".
    public let forgotten: Int
    /// "Zor".
    public let hard: Int

    public init(seenCards: Int = 0, reviews: Int = 0, forgotten: Int = 0, hard: Int = 0) {
        self.seenCards = seenCards
        self.reviews = reviews
        self.forgotten = forgotten
        self.hard = hard
    }

    /// Share of reviews that were not "Unuttum". `nil` — not 0 — with no
    /// reviews: "no data" and "all wrong" are different things, and a 0% on a
    /// subject nobody has studied yet would read as a verdict.
    public var accuracy: Double? {
        reviews == 0 ? nil : Double(reviews - forgotten) / Double(reviews)
    }
}

public struct ExerciseStats: Equatable, Sendable {
    public let attempts: Int
    /// "Bilemedim".
    public let missed: Int
    /// "Kararsızdım".
    public let unsure: Int

    public init(attempts: Int = 0, missed: Int = 0, unsure: Int = 0) {
        self.attempts = attempts
        self.missed = missed
        self.unsure = unsure
    }

    /// Share answered "Biliyordum". `nil` with no attempts, for the same reason
    /// as `ReviewStats.accuracy`.
    public var accuracy: Double? {
        attempts == 0 ? nil : Double(attempts - missed - unsure) / Double(attempts)
    }
}

/// Everything shown on one row: how many cards, and what was done with them.
public struct StatsLine: Equatable, Sendable {
    public let cardCount: Int
    public let activeCount: Int
    public let suspendedCount: Int
    /// Active cards due now — what Tekrar would offer for this group.
    public let dueCount: Int
    public let review: ReviewStats
    public let exercise: ExerciseStats

    public init(
        cardCount: Int = 0,
        activeCount: Int = 0,
        suspendedCount: Int = 0,
        dueCount: Int = 0,
        review: ReviewStats = ReviewStats(),
        exercise: ExerciseStats = ExerciseStats()
    ) {
        self.cardCount = cardCount
        self.activeCount = activeCount
        self.suspendedCount = suspendedCount
        self.dueCount = dueCount
        self.review = review
        self.exercise = exercise
    }
}

public struct TopicStats: Identifiable, Equatable, Sendable {
    /// Where a card sits inside its subject. The two non-canonical buckets are
    /// Bilgi Haritası's invariant carried over: a name the schema does not know
    /// never becomes a node of its own, but its cards are always counted.
    public enum Bucket: Hashable, Sendable {
        case canonical(String)
        /// No topic at all ("Konusuz").
        case none
        /// A topic name the schema does not list.
        case unrecognized

        public var title: String {
            switch self {
            case .canonical(let name): return name
            case .none: return "Konusuz"
            case .unrecognized: return "Tanınmayan konu"
            }
        }
    }

    public let bucket: Bucket
    public let line: StatsLine

    public var id: Bucket { bucket }

    public var title: String { bucket.title }

    /// The Bilgilerim/Egzersiz filter that reproduces this row — `nil` for the
    /// unrecognised bucket, which no single filter can express.
    public var topicFilter: TopicFilter? {
        switch bucket {
        case .canonical(let name): return .topic(name)
        case .none: return TopicFilter.none
        case .unrecognized: return nil
        }
    }
}

public struct SubjectStats: Identifiable, Equatable, Sendable {
    /// `nil` for cards whose subject is missing or not in the schema.
    public let subject: String?
    public let line: StatsLine
    /// Canonical order, only topics that have cards; then "Konusuz", then
    /// "Tanınmayan konu". Every card of the subject is in exactly one.
    public let topics: [TopicStats]

    public var id: String { subject ?? "\u{1F}unclassified" }
    public var title: String { subject ?? "Ders atanmamış" }
}

public struct StudyStatisticsSummary: Equatable, Sendable {
    public let window: StatsWindow
    public let total: StatsLine
    /// Schema order, only subjects that have cards; then the unclassified group
    /// if it is not empty. The rows' card counts add up to `total.cardCount`.
    public let subjects: [SubjectStats]
}

// MARK: - Builder

/// Per-subject and per-topic study statistics (2026-09-14), and the grouping
/// Bilgilerim's subject → topic browsing is drawn from.
///
/// Two sources with different lifetimes, kept in separate columns on purpose.
/// `ReviewLog` is kept for ever, so the Tekrar numbers honour any window.
/// `ExerciseAttempt` is deleted after 90 days (docs/ADR-008), so the Egzersiz
/// numbers can never reach further back than that — and the builder enforces
/// it here rather than trusting the prune to have run, because the column is
/// labelled "son 90 gün" and must not quietly include an attempt older than its
/// own label. Adding the two into one "kaç kez gördüm" would have made the total
/// shrink silently every day as old attempts aged out.
///
/// Reviews and attempts whose card no longer exists are ignored: they belong to
/// no subject, and counting them in the total but in no row would break the
/// rule that the rows add up.
public enum StudyStatistics {

    /// Whether a card belongs to a subject row — `nil` meaning the
    /// "Ders atanmamış" row. The list a row opens is filtered with this, the
    /// same rule `build` counted with, so the number on the row and the cards
    /// behind it cannot disagree.
    public static func belongs(subject: String?, to row: String?, schema: SubjectTopicSchema) -> Bool {
        let canonical = subject.flatMap { schema.topics(for: $0) } != nil
        guard let row else { return !canonical }
        return canonical && subject == row
    }

    /// Whether a card of `subject` belongs to a topic row. Same guarantee as
    /// `belongs(subject:to:schema:)`.
    public static func belongs(
        topic: String?,
        to bucket: TopicStats.Bucket,
        subject: String,
        schema: SubjectTopicSchema
    ) -> Bool {
        let known = Set(schema.topics(for: subject) ?? [])
        switch bucket {
        case .canonical(let name): return topic == name
        case .none: return topic == nil
        case .unrecognized: return topic.map { !known.contains($0) } ?? false
        }
    }

    public static func build(
        cards: [StatsCard],
        reviews: [StatsReview] = [],
        attempts: [StatsAttempt] = [],
        window: StatsWindow = .all,
        now: Date,
        schema: SubjectTopicSchema
    ) -> StudyStatisticsSummary {
        let reviewStart = window.start(now: now)
        let retentionStart = now.addingTimeInterval(-ExerciseHistory.retention)
        let exerciseStart = max(reviewStart ?? retentionStart, retentionStart)

        var reviewsByCard: [UUID: (count: Int, forgotten: Int, hard: Int)] = [:]
        for review in reviews {
            if let reviewStart, review.at < reviewStart { continue }
            var entry = reviewsByCard[review.cardId] ?? (0, 0, 0)
            entry.count += 1
            if review.rating == .again { entry.forgotten += 1 }
            if review.rating == .hard { entry.hard += 1 }
            reviewsByCard[review.cardId] = entry
        }

        var attemptsByCard: [UUID: (count: Int, missed: Int, unsure: Int)] = [:]
        for attempt in attempts where attempt.at >= exerciseStart {
            var entry = attemptsByCard[attempt.cardId] ?? (0, 0, 0)
            entry.count += 1
            if attempt.result == .missed { entry.missed += 1 }
            if attempt.result == .unsure { entry.unsure += 1 }
            attemptsByCard[attempt.cardId] = entry
        }

        func line(_ group: [StatsCard]) -> StatsLine {
            var active = 0, suspended = 0, due = 0
            var seen = 0, reviewCount = 0, forgotten = 0, hard = 0
            var attemptCount = 0, missed = 0, unsure = 0
            for card in group {
                if card.status == .active {
                    active += 1
                    if card.dueDate <= now { due += 1 }
                }
                if card.status == .suspended { suspended += 1 }
                if let r = reviewsByCard[card.id] {
                    seen += 1
                    reviewCount += r.count
                    forgotten += r.forgotten
                    hard += r.hard
                }
                if let a = attemptsByCard[card.id] {
                    attemptCount += a.count
                    missed += a.missed
                    unsure += a.unsure
                }
            }
            return StatsLine(
                cardCount: group.count,
                activeCount: active,
                suspendedCount: suspended,
                dueCount: due,
                review: ReviewStats(seenCards: seen, reviews: reviewCount, forgotten: forgotten, hard: hard),
                exercise: ExerciseStats(attempts: attemptCount, missed: missed, unsure: unsure)
            )
        }

        let canonicalSubjects = Set(schema.subjects.map(\.name))
        var bySubject: [String: [StatsCard]] = [:]
        var unclassified: [StatsCard] = []
        for card in cards {
            if let subject = card.subject, canonicalSubjects.contains(subject) {
                bySubject[subject, default: []].append(card)
            } else {
                unclassified.append(card)
            }
        }

        func topicRows(_ group: [StatsCard], canonical: [String]) -> [TopicStats] {
            let known = Set(canonical)
            var byTopic: [String: [StatsCard]] = [:]
            var none: [StatsCard] = []
            var unknown: [StatsCard] = []
            for card in group {
                guard let topic = card.topic else { none.append(card); continue }
                if known.contains(topic) {
                    byTopic[topic, default: []].append(card)
                } else {
                    unknown.append(card)
                }
            }
            var rows = canonical.compactMap { topic -> TopicStats? in
                guard let topicCards = byTopic[topic] else { return nil }
                return TopicStats(bucket: .canonical(topic), line: line(topicCards))
            }
            if !none.isEmpty { rows.append(TopicStats(bucket: .none, line: line(none))) }
            if !unknown.isEmpty { rows.append(TopicStats(bucket: .unrecognized, line: line(unknown))) }
            return rows
        }

        var subjects = schema.subjects.compactMap { subject -> SubjectStats? in
            guard let group = bySubject[subject.name] else { return nil }
            return SubjectStats(
                subject: subject.name,
                line: line(group),
                topics: topicRows(group, canonical: subject.topics)
            )
        }
        if !unclassified.isEmpty {
            // No topic breakdown: without a canonical subject there is no topic
            // list to place them against.
            subjects.append(SubjectStats(subject: nil, line: line(unclassified), topics: []))
        }

        return StudyStatisticsSummary(window: window, total: line(cards), subjects: subjects)
    }
}
