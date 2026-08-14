import Foundation
import SwiftData

/// Finding the `KnowledgeUnit` a card belongs on (2026-08-15).
///
/// Ders/konu live on the unit, not the card, and one unit is shared by every
/// card on the page that got the same topic (`TopicGrouping`). That sharing is
/// what makes the rule here non-obvious: writing a new subject onto an existing
/// unit silently reclassifies its siblings, so a card that needs a different
/// pair has to *move* to another unit rather than take its unit with it.
///
/// The editor learned this first (`CardEditorView.applyClassification`). Adding a
/// card by hand needs exactly the same decision, and "the same behaviour in two
/// places" is the drift this project has structural rules against — so the
/// find-or-create lives here, once.
public enum KnowledgeUnitBinding {

    /// The unit on `region` carrying exactly this (subject, topic), creating one
    /// if there is none.
    ///
    /// Never mutates a unit it finds: matching means the pair is already right,
    /// and anything else would be reaching into cards the caller was not asked
    /// about. A new unit is bound to the same `region`, which is what keeps
    /// "Kaynağı göster" showing the page photo for the card that lands on it.
    ///
    /// A `nil` region is allowed and yields an unbound unit — a card can carry a
    /// ders/konu with no page behind it (this is what a restored backup's cards
    /// look like).
    @discardableResult
    public static func findOrCreate(
        on region: TextRegion?,
        subject: String?,
        topic: String?,
        claim: String,
        tags: [String] = [],
        sourceConcern: String? = nil,
        context: ModelContext
    ) -> KnowledgeUnit {
        if let existing = region?.knowledgeUnits.first(where: { $0.subject == subject && $0.topic == topic }) {
            return existing
        }
        let unit = KnowledgeUnit(
            canonicalClaim: claim,
            subject: subject,
            topic: topic,
            tags: tags,
            sourceConcern: sourceConcern
        )
        unit.region = region
        context.insert(unit)
        return unit
    }
}
