import SwiftUI
import CizgiCore

/// The "Çekimlerim | Kavramlar" switcher shared by Tekrar, Egzersiz and
/// Bilgilerim.
///
/// A switcher rather than a sixth tab: `CizgiRootTabBar` is built around five
/// items with a raised centre, and an even number has no centre to raise. This
/// also matches what `LibraryView` already does with its Kartlar/Bilgi Haritası
/// picker, so it is not a new idea on this screen — only a new axis.
///
/// Shown even when no concept pack has been imported, and that is deliberate:
/// the importer lives inside the Kavramlar side, so hiding the switcher until
/// concept cards exist would leave no way to ever create them. The empty state
/// on the other side is the feature's entry point.
struct CardScopePicker: View {
    @AppStorage(CardScope.storageKey) private var collectionRaw = CardScope.fallback.rawValue

    var body: some View {
        Picker("Deste", selection: $collectionRaw) {
            ForEach(CardCollection.allCases, id: \.rawValue) { collection in
                Text(collection.title).tag(collection.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Cizgi.Space.lg)
        .padding(.vertical, Cizgi.Space.sm)
    }
}
