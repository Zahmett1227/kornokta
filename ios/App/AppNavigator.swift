import SwiftUI
import CizgiCore

/// Cross-tab navigation state, separate from `AppEnvironment` because this is
/// purely a UI concern (which tab is showing, how deep each tab's stack is),
/// not a domain service.
@MainActor
final class AppNavigator: ObservableObject {
    struct ExerciseTarget: Equatable {
        struct Filter: Equatable {
            let subject: String
            /// A full `TopicFilter`, not a name: Bilgi Haritası can ask for the
            /// "Konusuz" bucket, which no topic name can express.
            let topic: TopicFilter
        }

        let id = UUID()
        /// `nil` means "just take me to Egzersiz" — the link on the review
        /// screen is a jump, not an opinion about what to practise. Only a
        /// caller that is genuinely asking for a narrower run (Bilgi Haritası)
        /// sends a filter, and only that caller gets to overwrite the choice
        /// the user made in the Egzersiz filter menu.
        let filter: Filter?
    }

    enum RootTab: Hashable {
        case capture, review, exercise, library, settings
    }

    /// Value-based routes for the Capture tab's stack. An enum rather than
    /// pushing a model object because the queue screen has no model of its
    /// own; `PageDetailView` pushes the `CapturedPage` itself.
    enum CaptureRoute: Hashable {
        case queue
    }

    /// Value-based routes for the Settings tab's stack, same reasoning as
    /// `CaptureRoute`: the per-call cost breakdown has no model object of its
    /// own to push.
    enum SettingsRoute: Hashable {
        case usageDetail
        case examBank
    }

    /// The past exam bank's screens (docs/PLAN-cikmis-soru-bankasi.md §7.4).
    ///
    /// Registered on both the Egzersiz and the Bilgilerim stacks: Egzersiz is
    /// where questions are answered, Bilgilerim lists "Kitaba dönünce". A run
    /// is pushed by its id — the `ExamRun` row is the durable state, so a
    /// relaunch resumes the same run from the same value.
    enum ExamRoute: Hashable {
        case home
        case session(UUID)
        /// Deneme (Faz A3): a timed paper, answered without the key.
        case mock(UUID)
        case mockPapers
        /// A finished run's result, from the home screen's history.
        case result(UUID)
        /// A finished run's misses, one by one, with the bridge.
        case review(UUID)
        case gaps
        case question(String)
        /// Import screen, reachable from Egzersiz when no bank is there yet.
        case bankSettings
    }

    /// Value-based routes for the Library tab's stack (2026-09-14).
    ///
    /// Browsing the deck by subject and topic, and the per-subject statistics.
    /// `nil` subject is the "Ders atanmamış" row — cards whose subject is missing
    /// or not in the schema — so every row a list shows can be opened.
    /// `Card` and `KnowledgeMapSubjectSummary` are still pushed as themselves.
    enum LibraryRoute: Hashable {
        case subject(String?)
        case topic(subject: String, bucket: TopicStats.Bucket)
        case subjectStats(String?)
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
    // Every push in the app is value-based (`NavigationLink(value:)` +
    // `navigationDestination`), so these paths genuinely track depth and
    // resetting them below really pops to the root. Keep it that way: a
    // view-based `NavigationLink { destination }` would not append to the
    // bound path, silently breaking `goHome()` for its screen.
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

    /// Switches to Egzersiz and leaves the filters exactly as the user left them.
    func openExercise() {
        show(ExerciseTarget(filter: nil))
    }

    /// Switches to Egzersiz and narrows it, e.g. "Bu dersten Egzersiz".
    func openExercise(subject: String, topic: TopicFilter = .all) {
        show(ExerciseTarget(filter: .init(subject: subject, topic: topic)))
    }

    /// Switches to Egzersiz and opens Çıkmış screens on a fresh stack — how
    /// "Kitaba dönünce" in Bilgilerim starts a run: runs live in Egzersiz, so
    /// "Bitir" always lands on the Çıkmış home a run belongs to.
    func openExam(_ routes: [ExamRoute]) {
        var path = NavigationPath()
        for route in routes { path.append(route) }
        exercisePath = path
        selectedTab = .exercise
    }

    private func show(_ target: ExerciseTarget) {
        exerciseTarget = target
        exercisePath = NavigationPath()
        selectedTab = .exercise
    }
}
