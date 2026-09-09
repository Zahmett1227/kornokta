import Foundation

/// The one place a deck is narrowed to a single `CardCollection`.
///
/// This exists to be *findable*, not to save characters. The risk the
/// collection split introduces is entirely one-sided: forget the filter at one
/// call site and 3.017 imported cards pour into Tekrar, Egzersiz or the
/// reminder counts, which is precisely the "çalışan sistemi bozma" failure the
/// split was supposed to avoid. Nothing detects that automatically — the cards
/// are valid, active and due — so the defence is that every narrowing has the
/// same name and `grep CardScope` enumerates them.
///
/// Deliberately in-memory rather than a `@Query` predicate. The screens here
/// already filter in memory (`LibraryView` says why: SQLite will not fold
/// Turkish case), a `@Query` predicate cannot read a `@AppStorage` value
/// without restructuring each screen around an injected initialiser, and at
/// this deck's size the difference is not measurable. If it ever is, the fix
/// is to push *this* filter into the query — the call sites keep the same
/// shape, which is the other reason it has a name.
public enum CardScope {
    /// The key both the App target's scope switcher and every screen read.
    /// Held here so the six readers cannot drift onto different keys.
    public static let storageKey = "cizgi.cardCollection"

    /// The collection a fresh install starts in: the one the app's own capture
    /// flow fills, so a user who never imports a pack sees no change at all.
    public static let fallback: CardCollection = .capture

    public static func cards(_ all: [Card], in collection: CardCollection) -> [Card] {
        all.filter { $0.collection == collection }
    }

    /// Resolves the stored raw value, tolerating an absent or unknown string —
    /// the same failure posture as `Card.collection` itself.
    public static func collection(fromStored raw: String) -> CardCollection {
        CardCollection(rawValue: raw) ?? fallback
    }
}
