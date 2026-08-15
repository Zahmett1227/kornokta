import SwiftUI
import SwiftData
import CizgiCore

@main
struct CizgiApp: App {
    private let container: ModelContainer
    @StateObject private var environment: AppEnvironment

    init() {
        // Built before the property wrapper so the throwing calls are not
        // inside StateObject's autoclosure, which cannot throw.
        let container: ModelContainer
        let environment: AppEnvironment
        do {
            let schema = Schema(CizgiSchema.allModels)
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema)]
            )
            environment = try AppEnvironment(container: container)
        } catch {
            // A store that will not open is not something the user can act on,
            // and carrying on would silently drop captures.
            fatalError("Yerel veri deposu açılamadı: \(error)")
        }

        self.container = container
        _environment = StateObject(wrappedValue: environment)

        // After the container exists, before any view reads it: the library
        // filters assume every unit's subject is either canonical or nil.
        SubjectBackfillMigration.runIfNeeded(container: container)
        // Depends on the subject backfill above having already run — it only
        // touches units already carrying "Patoloji".
        TopicBackfillMigration.runIfNeeded(container: container)
        // Independent of the two above: keys off each card's own
        // `fesInitializedAt`, not a shared flag, so it runs every launch and
        // only ever touches cards that still need it (docs/ADR-008). Also
        // called again after a backup restore, on that flow's own context —
        // see `FesBackfillMigration`'s doc comment for why that second call
        // is load-bearing, not defensive.
        FesBackfillMigration.runIfNeeded(context: ModelContext(container))
        // Independent of all three: releases the cards still waiting at the
        // approval gate Faz 6 removed, so they finally reach the scheduler.
        ApprovalGateMigration.runIfNeeded(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        .modelContainer(container)
    }
}
