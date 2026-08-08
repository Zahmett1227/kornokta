import Foundation

/// The pure half of the one-time subject backfill (schema v2.2 rollout).
///
/// Before the subject picker existed, `KnowledgeUnit.subject` came from a
/// free-text Settings field: it may be nil, empty, a casing variant of a
/// canonical name ("patoloji"), or arbitrary text. The user has confirmed the
/// entire existing deck is Patoloji, so everything unrecognizable resolves to
/// the fallback; a recognized canonical name is only normalized in casing —
/// a deliberately narrow rule so a future re-run can never overwrite a real
/// classification. The SwiftData walk lives in the App target
/// (`SubjectBackfillMigration`); this function is what makes it testable.
public enum SubjectBackfill {
    /// The value to write over `existing`, or nil when it is already correct.
    ///
    /// - nil / blank / unrecognized text → `fallback`
    /// - a Turkish-case-insensitive match of a canonical name → the canonical
    ///   spelling (nil when it is already spelled canonically)
    public static func resolvedSubject(
        existing: String?,
        schema: SubjectTopicSchema,
        fallback: String
    ) -> String? {
        guard let canonical = schema.canonicalSubject(matching: existing) else {
            return fallback
        }
        return canonical == existing ? nil : canonical
    }
}
