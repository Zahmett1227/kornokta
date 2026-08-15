import Foundation

/// Text search for "Bilgilerim" (2026-08-15).
///
/// Replaces `localizedCaseInsensitiveContains`, which on a Turkish device folds
/// by tr rules and therefore misses the pair this deck is full of: `"İnflamasyon
/// nedir?"` does not contain `"Inflamasyon"`, because a capital `I` lowercases
/// to `ı`, not `i`. The search field capitalises its first letter, so which
/// results came back depended on which capital I the keyboard happened to emit
/// — the same class of bug ADR-001 records for option matching.
public enum CardSearch {

    /// Hand-rolled rather than `folding(options:locale:)`, for the reason
    /// `MultipleChoice.comparisonKey` gives: a locale-driven fold is exactly
    /// what is being worked around here, so it cannot also be the fix.
    ///
    /// Deliberately *not* `comparisonKey` itself, despite the overlap. That key
    /// is byte-locked to the backend's `optionKey` (CLAUDE.md) and drops every
    /// non-alphanumeric character, which is right for comparing two options and
    /// wrong for search: it would silently make `"5-FU"` and `"5 FU"` the same
    /// query as `"5FU"` and quietly change what a typed space means.
    private static let turkishFolding: [Character: Character] = [
        "İ": "i", "I": "i", "ı": "i", "i": "i",
        "Ç": "c", "ç": "c",
        "Ğ": "g", "ğ": "g",
        "Ş": "s", "ş": "s",
        "Ö": "o", "ö": "o",
        "Ü": "u", "ü": "u",
    ]

    /// Combining Diacritical Marks. Stripped after decomposition so the eponyms
    /// this deck actually contains — Sézary, Ménétrier — are reachable from a
    /// plain keyboard. Turkish letters never reach this step; they are mapped
    /// whole above, so `ğ` cannot decay into `g` by a different route and give
    /// two spellings of the same fold.
    private static let combiningMarks: ClosedRange<UInt32> = 0x0300...0x036F

    static func fold(_ text: String) -> String {
        var mapped = ""
        mapped.reserveCapacity(text.count)
        for character in text {
            if let folded = turkishFolding[character] {
                mapped.append(folded)
            } else {
                mapped.append(contentsOf: String(character).lowercased())
            }
        }
        let decomposed = mapped.decomposedStringWithCanonicalMapping
        return String(String.UnicodeScalarView(
            decomposed.unicodeScalars.filter { !combiningMarks.contains($0.value) }
        ))
    }

    /// Every piece of a card the search reads.
    ///
    /// Question and answer alone were not enough: a card whose only mention of
    /// a term sits in its explanation or in one of its five options was
    /// unreachable, which on this deck is a real card, not a hypothetical.
    ///
    /// An empty or whitespace-only query matches everything, so the caller can
    /// pass `searchText` straight through without branching on it — the branch
    /// is what got skipped on four of the five sections before this existed.
    public static func matches(
        query: String,
        front: String,
        back: String,
        explanation: String?,
        tags: [String] = [],
        subject: String? = nil,
        topic: String? = nil,
        optionTexts: @autoclosure () -> [String] = []
    ) -> Bool {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }

        var haystacks: [String] = [front, back]
        if let explanation { haystacks.append(explanation) }
        haystacks.append(contentsOf: tags)
        if let subject { haystacks.append(subject) }
        if let topic { haystacks.append(topic) }
        if haystacks.contains(where: { !$0.isEmpty && fold($0).contains(needle) }) { return true }

        // Last, and behind an autoclosure, because it is the only expensive
        // field: `Card.options` decodes JSON out of `optionsRaw` on every read.
        // Evaluated eagerly it would parse the whole deck on every keystroke —
        // including keystrokes that already matched on the question, and
        // including no query at all, where the guard above returns first.
        return optionTexts().contains { !$0.isEmpty && fold($0).contains(needle) }
    }
}
