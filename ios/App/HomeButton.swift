import SwiftUI

/// Top-left "go home" control shown on every screen (tab roots included), so
/// there is always one consistent way back to Capture regardless of how deep
/// a NavigationStack push or a tab switch has taken the user.
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
