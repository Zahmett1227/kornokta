import SwiftUI

/// Top-left "go home" control for **pushed** screens: one consistent way back
/// out of a detail screen, next to the system's own back button, without
/// walking up a stack one level at a time.
///
/// Home is Egzersiz, not Capture — the app's daily working surface moved and
/// `goHome()` moved with it. Tab roots deliberately do not carry this: they
/// show the root bar instead, and Egzersiz would be offering to take the user
/// where they already are.
private struct HomeButton: View {
    @EnvironmentObject private var navigator: AppNavigator

    var body: some View {
        Button {
            navigator.goHome()
        } label: {
            Image(systemName: "house.fill")
        }
        .accessibilityLabel("Ana sayfaya dön")
    }
}

extension View {
    func homeButtonToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HomeButton()
            }
        }
    }
}
