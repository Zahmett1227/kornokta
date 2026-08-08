import SwiftUI

/// Cross-tab navigation state, separate from `AppEnvironment` because this is
/// purely a UI concern (which tab is showing, how deep each tab's stack is),
/// not a domain service.
@MainActor
final class AppNavigator: ObservableObject {
    struct ExerciseTarget: Equatable {
        let id = UUID()
        let subject: String?
        let topic: String?
    }

    enum RootTab: Hashable {
        case capture, review, exercise, library, settings
    }

    /// Egzersiz is the product's daily working surface, so launches and the
    /// global home action both land here. Capture remains one tap away.
    @Published var selectedTab: RootTab = .exercise
    /// Focused card sessions temporarily remove the custom root bar.
    @Published var isTabBarHidden = false
    /// A cross-feature request (for example from Bilgi Haritasi) that the
    /// Egzersiz root consumes into its subject/topic filters.
    @Published var exerciseTarget: ExerciseTarget?

    // Capture, Exercise and Library own child navigation. Keeping independent
    // paths means switching tabs never destroys another tab's place.
    @Published var capturePath = NavigationPath()
    @Published var exercisePath = NavigationPath()
    @Published var libraryPath = NavigationPath()

    var showsRootTabBar: Bool {
        guard !isTabBarHidden else { return false }
        switch selectedTab {
        case .capture: return capturePath.isEmpty
        case .exercise: return exercisePath.isEmpty
        case .library: return libraryPath.isEmpty
        case .review, .settings: return true
        }
    }

    /// Jumps to the Exercise tab and pops every tab's stack to its root, so
    /// "home" always lands on the same screen regardless of where it was
    /// called from.
    func goHome() {
        selectedTab = .exercise
        isTabBarHidden = false
        capturePath = NavigationPath()
        exercisePath = NavigationPath()
        libraryPath = NavigationPath()
    }


    func openExercise(subject: String?, topic: String? = nil) {
        exerciseTarget = ExerciseTarget(subject: subject, topic: topic)
        exercisePath = NavigationPath()
        selectedTab = .exercise
    }
}
