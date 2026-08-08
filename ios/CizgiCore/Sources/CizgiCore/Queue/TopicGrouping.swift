import Foundation

/// Splits a page's generated cards into one group per topic, so `persist` can
/// store one `KnowledgeUnit` per topic (schema v2.2) without any SwiftData
/// schema change — `Card` itself never carries a topic; its unit does.
public enum TopicGrouping {
    /// Groups in deterministic first-seen order; cards keep their relative
    /// order within a group. A card whose topic fails the on-device check
    /// falls into the `nil` group ("Konusuz") rather than being dropped.
    ///
    /// The check re-runs what the server already enforced — the phone is not
    /// entitled to assume the wire behaved. With no schema to check against
    /// (`schema == nil`, i.e. the bundled JSON failed to load) the server's
    /// value is kept as-is: nulling everything for a local resource problem
    /// would silently throw away valid classifications.
    public static func partition(
        _ cards: [GeneratedCard],
        subject: String?,
        schema: SubjectTopicSchema?
    ) -> [(topic: String?, cards: [GeneratedCard])] {
        var order: [String?] = []
        var grouped: [String?: [GeneratedCard]] = [:]

        for card in cards {
            let topic = validatedTopic(card.topic, subject: subject, schema: schema)
            if grouped[topic] == nil {
                order.append(topic)
                grouped[topic] = []
            }
            grouped[topic]?.append(card)
        }

        return order.map { topic in (topic: topic, cards: grouped[topic] ?? []) }
    }

    /// A topic is only meaningful under its own subject, so the pair is checked
    /// together. Public because the backup restore path needs the same rule: a
    /// restored subject may have been remapped, and its stored topic has to be
    /// re-checked against the subject the card actually ends up with.
    public static func validatedTopic(
        _ topic: String?,
        subject: String?,
        schema: SubjectTopicSchema?
    ) -> String? {
        guard let topic else { return nil }
        guard let schema else { return topic }
        guard let subject, schema.isValidTopic(topic, subject: subject) else { return nil }
        return topic
    }
}
