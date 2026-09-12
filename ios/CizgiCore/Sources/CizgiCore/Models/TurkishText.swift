import Foundation

/// Turkish-correct case conversion for text that is shown to the user
/// (docs/ADR-001).
///
/// `"i".uppercased()` is `"I"`, which is right in English and wrong here: in
/// Turkish the dotted i uppercases to `İ` and the dotless ı to `I`, and they
/// are different letters. A topic called "Endokrin Sistem Farmakolojisi" set in
/// caps came out as "ENDOKRIN SISTEM" — a spelling no Turkish reader writes.
///
/// It is a function rather than a rule people remember because the failure is
/// quiet: the text still renders, still fits, still looks like a heading. The
/// same reasoning put `comparisonKey` and `SubjectTopicSchema`'s lookup behind
/// an explicit locale.
public enum TurkishText {
    /// The locale every display-case conversion in the app goes through.
    public static let locale = Locale(identifier: "tr")

    public static func uppercased(_ text: String) -> String {
        text.uppercased(with: locale)
    }
}
