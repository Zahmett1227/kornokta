import Foundation

/// The small, persistence-independent input Bilgi Haritasi needs from a card.
/// Keeping SwiftData models out of the builder makes coverage and weakness
/// calculations deterministic and unit-testable.
public struct KnowledgeMapCard: Equatable, Sendable {
    public let subject: String?
    public let topic: String?
    public let isActive: Bool
    public let lapseCount: Int
    public let lowConfidence: Bool

    public init(
        subject: String?,
        topic: String?,
        isActive: Bool,
        lapseCount: Int,
        lowConfidence: Bool
    ) {
        self.subject = subject
        self.topic = topic
        self.isActive = isActive
        self.lapseCount = lapseCount
        self.lowConfidence = lowConfidence
    }

    var isWeak: Bool { lapseCount > 0 || lowConfidence }
}

/// A group of cards that is *not* a canonical node — the "Konusuz" bucket, or
/// cards carrying a topic name the schema does not know.
public struct KnowledgeMapBucket: Equatable, Hashable, Sendable {
    public let cardCount: Int
    public let activeCount: Int
    public let weakCardCount: Int
}

public struct KnowledgeMapTopicSummary: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(subject)\u{1F}\(topic)" }
    public let subject: String
    public let topic: String
    public let cardCount: Int
    public let activeCount: Int
    public let lapseCount: Int
    public let weakCardCount: Int
}

public struct KnowledgeMapSubjectSummary: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { subject }
    public let subject: String
    public let cardCount: Int
    public let activeCount: Int
    public let lapseCount: Int
    public let weakCardCount: Int
    public let coveredTopicCount: Int
    public let totalTopicCount: Int
    public let topics: [KnowledgeMapTopicSummary]
    /// Cards in this subject with no topic at all. On the deck as it stands
    /// today this is *every* card — `SubjectBackfillMigration` set the subject
    /// and left topics nil — so a map that only showed canonical topic nodes
    /// would show a user with hundreds of cards an entirely empty screen.
    public let uncategorized: KnowledgeMapBucket?
    /// Cards whose topic is not in this subject's canonical list: possible via
    /// a restored backup written before a schema change. Surfaced so the rows
    /// on screen add up to `cardCount` instead of quietly losing cards.
    public let unrecognizedTopic: KnowledgeMapBucket?

    public var coverage: Double {
        guard totalTopicCount > 0 else { return 0 }
        return Double(coveredTopicCount) / Double(totalTopicCount)
    }
}

public struct KnowledgeMapSummary: Equatable, Sendable {
    public let subjects: [KnowledgeMapSubjectSummary]
    /// Cards with no subject, or a subject the schema does not know. Never a
    /// map node (unknown names must not invent canonical nodes), but still
    /// counted: a "Kart" tile that disagreed with the deck would be worse than
    /// no tile at all.
    public let unclassified: KnowledgeMapBucket?
    public let totalCardCount: Int
    public let coveredTopicCount: Int
    public let totalTopicCount: Int

    public var isEmpty: Bool { totalCardCount == 0 }

    /// Canonical topics holding at least one **active** card.
    ///
    /// `coveredTopicCount` above counts a topic as covered on any card at all,
    /// which is the right answer for this screen: Bilgi Haritası describes the
    /// deck, and a suspended card is still in the deck.
    ///
    /// The Karanlık Harita asks a different question — "what am I not
    /// studying?" — and there a topic whose only cards are suspended is a gap,
    /// not coverage (`DarkMapCoverage` documents why: the 117 duplicates
    /// `DuplicateSuspendMigration` put away must not make a topic look
    /// studied). Both definitions are correct for their own screen; what was
    /// wrong was the entry card computing one and the screen behind it
    /// computing the other, so the number changed on tap (Codex, PR #49).
    ///
    /// Lives here rather than in the caller so the two surfaces share one
    /// definition, and `DarkMapCoverageAgreementTests` locks it against
    /// `DarkMapCoverage.build`.
    public var activeCoveredTopicCount: Int {
        subjects.reduce(0) { $0 + $1.topics.countMatching { $0.activeCount > 0 } }
    }
}

public enum KnowledgeMapBuilder {
    /// Builds the whole map in one pass over the cards.
    ///
    /// The previous version filtered the full card list once per subject and
    /// again once per topic — 11 × N plus 143 × N comparisons — and the view
    /// asked for it three times per render. Grouping first makes it one pass,
    /// and the caller gets every total it needs from a single value so the
    /// numbers on screen cannot disagree with each other.
    public static func build(
        cards: [KnowledgeMapCard],
        schema: SubjectTopicSchema
    ) -> KnowledgeMapSummary {
        var bySubject: [String: [KnowledgeMapCard]] = [:]
        var unclassified: [KnowledgeMapCard] = []
        let canonicalSubjects = Set(schema.subjects.map(\.name))

        for card in cards {
            if let subject = card.subject, canonicalSubjects.contains(subject) {
                bySubject[subject, default: []].append(card)
            } else {
                unclassified.append(card)
            }
        }

        let subjects = schema.subjects.map { subject -> KnowledgeMapSubjectSummary in
            summarize(subject: subject, cards: bySubject[subject.name] ?? [])
        }

        return KnowledgeMapSummary(
            subjects: subjects,
            unclassified: bucket(unclassified),
            totalCardCount: cards.count,
            coveredTopicCount: subjects.reduce(0) { $0 + $1.coveredTopicCount },
            totalTopicCount: subjects.reduce(0) { $0 + $1.totalTopicCount }
        )
    }

    private static func summarize(
        subject: SubjectTopicSchema.Subject,
        cards: [KnowledgeMapCard]
    ) -> KnowledgeMapSubjectSummary {
        let canonicalTopics = Set(subject.topics)
        var byTopic: [String: [KnowledgeMapCard]] = [:]
        var noTopic: [KnowledgeMapCard] = []
        var unknownTopic: [KnowledgeMapCard] = []

        for card in cards {
            guard let topic = card.topic else { noTopic.append(card); continue }
            if canonicalTopics.contains(topic) {
                byTopic[topic, default: []].append(card)
            } else {
                unknownTopic.append(card)
            }
        }

        // Canonical order, always — including topics with no cards, which are
        // the point of a coverage view.
        let topics = subject.topics.map { topic -> KnowledgeMapTopicSummary in
            let topicCards = byTopic[topic] ?? []
            return KnowledgeMapTopicSummary(
                subject: subject.name,
                topic: topic,
                cardCount: topicCards.count,
                activeCount: topicCards.countMatching(\.isActive),
                lapseCount: topicCards.reduce(0) { $0 + $1.lapseCount },
                weakCardCount: topicCards.countMatching(\.isWeak)
            )
        }

        return KnowledgeMapSubjectSummary(
            subject: subject.name,
            cardCount: cards.count,
            activeCount: cards.countMatching(\.isActive),
            lapseCount: cards.reduce(0) { $0 + $1.lapseCount },
            weakCardCount: cards.countMatching(\.isWeak),
            coveredTopicCount: topics.countMatching({ $0.cardCount > 0 }),
            totalTopicCount: topics.count,
            topics: topics,
            uncategorized: bucket(noTopic),
            unrecognizedTopic: bucket(unknownTopic)
        )
    }

    private static func bucket(_ cards: [KnowledgeMapCard]) -> KnowledgeMapBucket? {
        guard !cards.isEmpty else { return nil }
        return KnowledgeMapBucket(
            cardCount: cards.count,
            activeCount: cards.countMatching(\.isActive),
            weakCardCount: cards.countMatching(\.isWeak)
        )
    }
}

private extension Array {
    /// Not named `count(where:)`: the stdlib gained that signature in Swift 6 /
    /// iOS 18, and shadowing it here would make the call site depend on which
    /// toolchain and deployment target happen to be in play.
    func countMatching(_ predicate: (Element) -> Bool) -> Int {
        reduce(0) { predicate($1) ? $0 + 1 : $0 }
    }
}
