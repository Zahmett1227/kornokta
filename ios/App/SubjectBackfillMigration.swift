import Foundation
import SwiftData
import CizgiCore

/// One-time backfill for the subject/topic rollout (schema v2.2): every card
/// existing before it gets a canonical subject — "Patoloji", per the user's
/// own statement that the whole current deck is Patoloji. Topics stay nil
/// ("Konusuz"); the model only assigns them to new captures.
///
/// Runs at launch, guarded by a UserDefaults flag that is written only after a
/// successful save — a failed run rolls back and simply tries again next
/// launch, which is safe because the resolution rule itself is idempotent
/// (`SubjectBackfill.resolvedSubject` returns nil for anything already
/// canonical, and the unit-creation pass only touches cards with no unit).
@MainActor
enum SubjectBackfillMigration {
    static let flagKey = "cizgi.migration.subjectBackfill.v1"
    private static let fallbackSubject = "Patoloji"

    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        // No schema means no canonical names to normalize against; writing
        // nothing is better than writing against a broken resource. Not
        // flagged done, so a later launch with the resource fixed retries.
        guard let schema = try? SubjectTopicSchema.bundled(),
              schema.subjectNames.contains(fallbackSubject) else { return }

        let context = ModelContext(container)
        do {
            let units = try context.fetch(FetchDescriptor<KnowledgeUnit>())
            for unit in units {
                if let resolved = SubjectBackfill.resolvedSubject(
                    existing: unit.subject,
                    schema: schema,
                    fallback: fallbackSubject
                ) {
                    unit.subject = resolved
                    unit.updatedAt = .now
                }
            }

            // A card without a unit predates the pipeline ever writing one;
            // it needs a unit to carry a subject at all. Insert-only.
            let orphans = try context.fetch(FetchDescriptor<Card>())
                .filter { $0.knowledgeUnit == nil }
            for card in orphans {
                let unit = KnowledgeUnit(canonicalClaim: card.front, subject: fallbackSubject)
                context.insert(unit)
                card.knowledgeUnit = unit
            }

            try context.save()
            defaults.set(true, forKey: flagKey)
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }
}
