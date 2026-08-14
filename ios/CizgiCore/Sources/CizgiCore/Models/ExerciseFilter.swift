import Foundation

/// How recently a card must have been captured to match (`Card.createdAt`).
public enum CardRecency: Equatable, Hashable, Sendable, CaseIterable {
    case all
    case last7Days
    case last30Days

    var days: Int? {
        switch self {
        case .all: return nil
        case .last7Days: return 7
        case .last30Days: return 30
        }
    }

    /// Durable form for `ExerciseRun.filterJSON`. A spelled-out string rather
    /// than a raw `Int`/case index — an added case later must not silently
    /// shift what an already-stored run means.
    var storageValue: String {
        switch self {
        case .all: return "all"
        case .last7Days: return "last_7_days"
        case .last30Days: return "last_30_days"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "all": self = .all
        case "last_7_days": self = .last7Days
        case "last_30_days": self = .last30Days
        default: return nil
        }
    }
}

/// A card-state dimension Egzersiz can filter on. Multiple selected states
/// are OR'd — "yeni ya da vadesi gelmiş kartlar" is a single, sensible ask;
/// AND would almost always mean zero cards.
public enum CardStateFilter: Equatable, Hashable, Sendable, CaseIterable {
    /// Never reviewed in Tekrar (`reviewCount == 0`).
    case unstudied
    /// Past its FSRS due date.
    case due
    /// `lowConfidence` — the same set Bilgilerim's "Gözden geçir" lists.
    case needsReview

    fileprivate func matches(_ candidate: ExerciseCandidate, now: Date) -> Bool {
        switch self {
        case .unstudied: return candidate.reviewCount == 0
        case .due: return candidate.dueDate <= now
        case .needsReview: return candidate.lowConfidence
        }
    }

    /// Durable form for `ExerciseRun.filterJSON`, same reasoning as
    /// `CardRecency.storageValue`.
    var storageValue: String {
        switch self {
        case .unstudied: return "unstudied"
        case .due: return "due"
        case .needsReview: return "needs_review"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "unstudied": self = .unstudied
        case "due": self = .due
        case "needs_review": self = .needsReview
        default: return nil
        }
    }
}

/// One active dimension of an `ExerciseFilter`, for building removable
/// summary chips. Carries data, not a label — Turkish text and icons belong
/// to the App layer (`CizgiTheme`), the same split `TopicFilter` already
/// follows; Core never formats anything for display.
public enum FilterDimension: Equatable, Hashable, Sendable {
    case subject(String)
    case topic(TopicFilter)
    case cardType(CardType)
    case state(CardStateFilter)
    case recency(CardRecency)
    case fesOnly
}

/// Egzersiz'in altı boyutlu kurulum filtresi (docs/ADR-008 çevresinde
/// tanıtıldı). Ders/konu mevcut `LibraryCardFilter`/`TopicFilter`'ı sarar —
/// Bilgilerim'le aynı mantık iki kez yazılmaz.
public struct ExerciseFilter: Equatable, Sendable {
    public var subject: String?
    public var topic: TopicFilter
    /// Boş küme = tümü. Kullanıcının hiçbir tipi işaretlememesi ile hepsini
    /// işaretlemesi aynı sonucu verir — "hiçbir kart" tuzağı oluşmaz.
    public var cardTypes: Set<CardType>
    /// Boş küme = tümü; birden fazla seçim OR'lanır.
    public var states: Set<CardStateFilter>
    public var recency: CardRecency
    public var fesOnly: Bool

    public init(
        subject: String? = nil,
        topic: TopicFilter = .all,
        cardTypes: Set<CardType> = [],
        states: Set<CardStateFilter> = [],
        recency: CardRecency = .all,
        fesOnly: Bool = false
    ) {
        self.subject = subject
        self.topic = topic
        self.cardTypes = cardTypes
        self.states = states
        self.recency = recency
        self.fesOnly = fesOnly
    }

    public var isActive: Bool {
        subject != nil || topic != .all || !cardTypes.isEmpty || !states.isEmpty
            || recency != .all || fesOnly
    }

    /// Ordered, stable dimensions for chip rendering — order matches the
    /// setup sheet's section order.
    public var activeDimensions: [FilterDimension] {
        var result: [FilterDimension] = []
        if let subject { result.append(.subject(subject)) }
        if topic != .all { result.append(.topic(topic)) }
        result.append(contentsOf: CardType.allCases.filter(cardTypes.contains).map(FilterDimension.cardType))
        result.append(contentsOf: CardStateFilter.allCases.filter(states.contains).map(FilterDimension.state))
        if recency != .all { result.append(.recency(recency)) }
        if fesOnly { result.append(.fesOnly) }
        return result
    }

    /// Removes exactly the dimension one chip's "x" represents. Multi-valued
    /// dimensions (`cardType`, `state`) drop only that one member.
    public func removing(_ dimension: FilterDimension) -> ExerciseFilter {
        var copy = self
        switch dimension {
        case .subject:
            // Mirrors `SubjectTopicFilterMenu.subjectBinding`: a topic chosen
            // under one subject means nothing once the subject is cleared.
            copy.subject = nil
            copy.topic = .all
        case .topic:
            copy.topic = .all
        case .cardType(let type):
            copy.cardTypes.remove(type)
        case .state(let state):
            copy.states.remove(state)
        case .recency:
            copy.recency = .all
        case .fesOnly:
            copy.fesOnly = false
        }
        return copy
    }
}

/// A card's filterable facts, independent of SwiftData — keeps
/// `ExerciseFilter.matches` pure and testable without a `ModelContext`.
public struct ExerciseCandidate: Equatable, Sendable {
    public let id: UUID
    public let subject: String?
    public let topic: String?
    public let type: CardType
    public let reviewCount: Int
    public let dueDate: Date
    public let lowConfidence: Bool
    public let createdAt: Date
    public let fesScore: Int

    public init(
        id: UUID,
        subject: String?,
        topic: String?,
        type: CardType,
        reviewCount: Int,
        dueDate: Date,
        lowConfidence: Bool,
        createdAt: Date,
        fesScore: Int
    ) {
        self.id = id
        self.subject = subject
        self.topic = topic
        self.type = type
        self.reviewCount = reviewCount
        self.dueDate = dueDate
        self.lowConfidence = lowConfidence
        self.createdAt = createdAt
        self.fesScore = fesScore
    }
}

extension ExerciseFilter {
    public func matches(_ candidate: ExerciseCandidate, now: Date = .now) -> Bool {
        guard LibraryCardFilter.matches(
            subject: candidate.subject,
            topic: candidate.topic,
            subjectFilter: subject,
            topicFilter: topic
        ) else { return false }

        if !cardTypes.isEmpty, !cardTypes.contains(candidate.type) { return false }

        if !states.isEmpty, !states.contains(where: { $0.matches(candidate, now: now) }) {
            return false
        }

        if let days = recency.days {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            guard candidate.createdAt >= cutoff else { return false }
        }

        if fesOnly, !FesScore.isFes(score: candidate.fesScore) { return false }

        return true
    }
}

extension ExerciseFilter {
    /// A small, explicit JSON shape for `ExerciseRun.filterJSON` — not
    /// `Codable` synthesis on `ExerciseFilter` itself. A hand-picked shape
    /// stays stable as the type's own internals change, the same reason
    /// `TopicFilter.storageValue` exists instead of encoding the enum
    /// directly.
    private struct Storage: Codable {
        var subject: String?
        var topic: String?
        var cardTypes: [String]
        var states: [String]
        var recency: String
        var fesOnly: Bool
    }

    public var storageValue: String? {
        let storage = Storage(
            subject: subject,
            topic: topic.storageValue,
            cardTypes: CardType.allCases.filter(cardTypes.contains).map(\.rawValue),
            states: CardStateFilter.allCases.filter(states.contains).map(\.storageValue),
            recency: recency.storageValue,
            fesOnly: fesOnly
        )
        guard let data = try? JSONEncoder().encode(storage) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Unreadable or missing storage falls back to a blank filter rather than
    /// throwing — the same "never block a restore over one bad field" rule
    /// `TopicFilter.fromStorage` and every `BackupExporter.CardRecord` field
    /// added since version 1 already follow.
    public static func fromStorage(_ raw: String?) -> ExerciseFilter {
        guard let raw, let data = raw.data(using: .utf8),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else { return ExerciseFilter() }
        return ExerciseFilter(
            subject: storage.subject,
            topic: TopicFilter.fromStorage(storage.topic),
            cardTypes: Set(storage.cardTypes.compactMap(CardType.init(rawValue:))),
            states: Set(storage.states.compactMap(CardStateFilter.init(storageValue:))),
            recency: CardRecency(storageValue: storage.recency) ?? .all,
            fesOnly: storage.fesOnly
        )
    }
}
