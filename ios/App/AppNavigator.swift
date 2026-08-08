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
    /// A focused card session temporarily removes the custom root bar. This is
    /// the *only* reason it is ever hidden: depth inside a tab is handled by
    /// where the bar is attached (see `rootTabBarInset`), not by a flag, so
    /// nothing here has to stay in sync with a `NavigationPath`.
    ///
    /// Anything that sets this to `true` owes the user a visible way out of
    /// the screen that hid it — with no tab bar and no back button, a root tab
    /// has no other exit.
    @Published var isTabBarHidden = false
    /// A cross-feature request (for example from Bilgi Haritasi) that the
    /// Egzersiz root consumes into its subject/topic filters.
    @Published var exerciseTarget: ExerciseTarget?

    // Capture, Exercise and Library own child navigation. Keeping independent
    // paths means switching tabs never destroys another tab's place.
    //
    // Caveat worth knowing before relying on these: every push in the app is a
    // view-based `NavigationLink { destination }`, which does not append to a
    // bound `NavigationPath`. Resetting them below is therefore best-effort,
    // and nothing that has to be *correct* may be derived from `isEmpty`.
    @Published var capturePath = NavigationPath()
    @Published var exercisePath = NavigationPath()
    @Published var libraryPath = NavigationPath()

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
