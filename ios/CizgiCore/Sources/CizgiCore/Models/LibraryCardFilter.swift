import Foundation

/// Which topic a subject-filtered list should show (schema v2.2).
///
/// `.none` is not "no filter" — it is the "Konusuz" bucket: cards that predate
/// topic assignment, or whose topic the model was unsure about. Without it,
/// every card from before this feature would be invisible under any subject
/// filter, which is most of the deck on the day it ships.
public enum TopicFilter: Hashable, Sendable {
    case all
    case none
    case topic(String)
}

/// Subject/topic filtering for "Bilgilerim" and the exercise mode, kept out of
/// the views so both screens filter identically and the rule is testable.
public enum LibraryCardFilter {
    /// - Parameters:
    ///   - subject: the card's own subject (`card.knowledgeUnit?.subject`).
    ///   - topic: the card's own topic (`card.knowledgeUnit?.topic`).
    ///   - subjectFilter: nil means every subject, including subjectless cards.
    ///   - topicFilter: only meaningful once a subject is chosen; `.all` when not.
    public static func matches(
        subject: String?,
        topic: String?,
        subjectFilter: String?,
        topicFilter: TopicFilter
    ) -> Bool {
        if let subjectFilter, subject != subjectFilter { return false }
        switch topicFilter {
        case .all: return true
        case .none: return topic == nil
        case .topic(let wanted): return topic == wanted
        }
    }
}
