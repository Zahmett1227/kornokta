import Foundation
import SwiftData
import CizgiCore

/// One-time removal of the concept deck from the store (2026-09-14).
///
/// The owner tried the imported concept pack (docs/ADR-010) and decided against
/// it: "kavramlar kısmını tamamen kaldıracağız". The code is gone; this clears
/// what the code left behind on the device — 3.017 cards on the owner's phone,
/// their units, their review history, and the Egzersiz runs made from them.
///
/// Deletes rather than suspends, unlike `DuplicateSuspendMigration`: those were
/// the owner's own cards with history worth keeping, these are an experiment
/// the owner asked to have leave no trace. The decision itself lives in
/// `ConceptDeckRemoval` so it runs against a real container in `swift test`.
///
/// Why this matters more than a cleanup usually does. The same launch that runs
/// this also drops `Card.collectionRaw` from the schema, so nothing on screen
/// can tell a concept card from a photographed one any more — without this,
/// all 3.017 would silently join Çekimlerim: valid, active, due, and wrong. The
/// importer's tag is the only way left to find them, which is exactly why
/// `ConceptDeckLegacy` survives the removal.
///
/// `ApprovalGateMigration`'s shape: a UserDefaults flag written only after a
/// successful save, a rollback and a retry on the next launch otherwise. Also
/// re-run by `SettingsView.restore`, which clears this flag if it fails.
@MainActor
enum ConceptDeckRemovalMigration {
    static let flagKey = "cizgi.migration.conceptDeckRemoval.v1"

    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        do {
            try ConceptDeckRemoval.remove(in: context)
            try context.save()
            defaults.set(true, forKey: flagKey)
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }
}
