import SwiftUI

/// Cross-tab navigation state, separate from `AppEnvironment` because this is
/// purely a UI concern (which tab is showing, how deep each tab's stack is),
/// not a domain service.
@MainActor
final class AppNavigator: ObservableObject {
    enum RootTab: Hashable {
        case capture, review, library, settings
    }

    @Published var selectedTab: RootTab = .capture
    // Only Capture and Library push children; Review and Settings are
    // childless tab roots and never need a path to reset.
    @Published var capturePath = NavigationPath()
    @Published var libraryPath = NavigationPath()

    /// Jumps to the Capture tab and pops every tab's stack to its root, so
    /// "home" always lands on the same screen regardless of where it was
    /// called from.
    func goHome() {
        selectedTab = .capture
        capturePath = NavigationPath()
        libraryPath = NavigationPath()
    }
}
