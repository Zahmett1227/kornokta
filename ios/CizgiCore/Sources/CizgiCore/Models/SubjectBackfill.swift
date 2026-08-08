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

    /// The same normalization for a card arriving from a backup, with one
    /// deliberate difference: **an absent subject stays absent.**
    ///
    /// The migration maps nil → fallback because at that point the subject
    /// field predated the picker, so "empty" meant "never asked". Once the
    /// picker exists, "Seçilmedi" is a choice the user can make on purpose, and
    /// a restore that overwrote it with Patoloji would be inventing data.
    ///
    /// This exists because the migration flag is set on the first launch of a
    /// fresh install — while the store is still empty — so a backup restored
    /// afterwards is never seen by it, and its pre-picker subjects would
    /// otherwise sit outside every picker and filter (Codex, PR #32).
    public static func restoredSubject(
        existing: String?,
        schema: SubjectTopicSchema,
        fallback: String
    ) -> String? {
        let trimmed = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return schema.canonicalSubject(matching: trimmed) ?? fallback
    }
}
