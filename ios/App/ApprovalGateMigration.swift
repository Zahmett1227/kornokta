import Foundation
import SwiftData
import CizgiCore

/// One-time release of the cards left standing at the Faz 6 approval gate
/// (2026-08-15).
///
/// Faz 6 removed the approval step — cards enter the active deck and a
/// suspicious one is *flagged* rather than held back (docs/FAZ6-PLAN.md,
/// docs/FAZ7-PLAN-coktan-secmeli.md §9). What the pivot never did was let go of
/// the cards already waiting: `.needsReview` is not `.active`, and
/// `ReviewScheduler` schedules `.active` only, so on the owner's deck 25 cards
/// captured on 2026-08-04 had sat outside every review since. They were not
/// hidden — they list normally, since `CardRow` badges only `.suspended` — and
/// they were not counted either: "Toplam 631 / Aktif 606 / Askıda 0" left 25
/// cards unexplained on screen, which is how this surfaced at all.
///
/// Nothing new can arrive here: `BackendCardProvider` hard-codes
/// `requiresUserApproval: false` and is the only live `CardGenerating`, so the
/// mapping in `ProcessingQueue` that reads it is dead. This is the backlog, not
/// a policy — hence a one-shot UserDefaults flag, in the shape
/// `SubjectBackfillMigration` established, rather than a per-card marker.
///
/// The rule itself lives in `ApprovalGateRelease` so it can be exercised
/// against a real `ModelContainer`. That flag is why: a lookup that quietly
/// matched nothing would still save cleanly, still record success, and strand
/// the cards for good.
@MainActor
enum ApprovalGateMigration {
    static let flagKey = "cizgi.migration.approvalGate.v1"

    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        do {
            try ApprovalGateRelease.release(in: context)
            try context.save()
            defaults.set(true, forKey: flagKey)
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }
}
