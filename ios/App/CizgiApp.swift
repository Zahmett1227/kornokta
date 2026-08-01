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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        .modelContainer(container)
    }
}
