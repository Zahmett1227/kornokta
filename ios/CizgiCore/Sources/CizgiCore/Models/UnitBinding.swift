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

    /// The unit on `region` carrying exactly this (subject, topic, claim),
    /// creating one if there is none.
    ///
    /// Never mutates a unit it finds: matching means it is already right, and
    /// anything else would be reaching into cards the caller was not asked
    /// about. A new unit is bound to the same `region`, which is what keeps
    /// "Kaynağı göster" showing the page photo for the card that lands on it.
    ///
    /// **`claim` is part of the match, not just of the new unit.**
    /// `canonicalClaim` is what "Kaynağı göster" prints under *Modelin okuduğu*,
    /// so it is a provenance claim, not a label: two units with the same
    /// ders/konu but different claims are genuinely different provenance, and
    /// merging them would attribute one's reading to the other's cards. This
    /// costs the generated path nothing — every unit `persist` writes for a page
    /// shares that page's single reading, so they still match each other — but it
    /// keeps a hand-written card (which passes `""`, no reading at all) from
    /// silently inheriting the model's text (Codex, PR #43).
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
        let existing = region?.knowledgeUnits.first {
            $0.subject == subject && $0.topic == topic && $0.canonicalClaim == claim
        }
        if let existing {
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
