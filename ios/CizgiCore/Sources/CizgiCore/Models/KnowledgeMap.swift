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
}

public struct KnowledgeMapTopicSummary: Identifiable, Equatable, Sendable {
    public var id: String { "\(subject)\u{0}\(topic)" }
    public let subject: String
    public let topic: String
    public let cardCount: Int
    public let activeCount: Int
    public let lapseCount: Int
    public let weakCardCount: Int
}

public struct KnowledgeMapSubjectSummary: Identifiable, Equatable, Sendable {
    public var id: String { subject }
    public let subject: String
    public let cardCount: Int
    public let activeCount: Int
    public let lapseCount: Int
    public let weakCardCount: Int
    public let coveredTopicCount: Int
    public let totalTopicCount: Int
    public let topics: [KnowledgeMapTopicSummary]

    public var coverage: Double {
        guard totalTopicCount > 0 else { return 0 }
        return Double(coveredTopicCount) / Double(totalTopicCount)
    }
}

public enum KnowledgeMapBuilder {
    /// Builds summaries in the canonical schema order. Cards with a legacy or
    /// unknown subject/topic remain available in the card list but never invent
    /// a node in the canonical map.
    public static func build(
        cards: [KnowledgeMapCard],
        schema: SubjectTopicSchema
    ) -> [KnowledgeMapSubjectSummary] {
        schema.subjects.map { subject in
            let subjectCards = cards.filter { $0.subject == subject.name }
            let topics = subject.topics.map { topic in
                let topicCards = subjectCards.filter { $0.topic == topic }
                return KnowledgeMapTopicSummary(
                    subject: subject.name,
                    topic: topic,
                    cardCount: topicCards.count,
                    activeCount: topicCards.filter(\.isActive).count,
                    lapseCount: topicCards.reduce(0) { $0 + $1.lapseCount },
                    weakCardCount: topicCards.filter { $0.lapseCount > 0 || $0.lowConfidence }.count
                )
            }
            return KnowledgeMapSubjectSummary(
                subject: subject.name,
                cardCount: subjectCards.count,
                activeCount: subjectCards.filter(\.isActive).count,
                lapseCount: subjectCards.reduce(0) { $0 + $1.lapseCount },
                weakCardCount: subjectCards.filter { $0.lapseCount > 0 || $0.lowConfidence }.count,
                coveredTopicCount: topics.filter { $0.cardCount > 0 }.count,
                totalTopicCount: topics.count,
                topics: topics
            )
        }
    }
}
