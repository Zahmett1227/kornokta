import Foundation

/// Whether the confirmation screen's current selection can become cards —
/// pulled out as a pure function of `(groups, selectedGroupIds)`, no SwiftUI
/// and no view state, so it is unit-testable in `CizgiCore` even though the
/// App target itself has no test infrastructure (§9: found via real device
/// use, 2026-08-04 — a group could look selected/blue on screen while the
/// submit button stayed effectively inert, with only a generic
/// handwriting-specific error string explaining why after the fact).
public enum CardCreationEligibility: Equatable, Sendable {
    /// At least one selected group has real, resolvable text (or is the
    /// user's own manual box) — the create-cards action can run.
    case enabled
    /// Nothing is selected yet. Other still-pending groups elsewhere on the
    /// same page must never factor into this on their own — only the
    /// groups the user actually picked do (§9 item 5).
    case noSelectedGroups
    /// At least one group is selected, but none of the selected groups has
    /// resolvable text (empty `selectedText` *and* `contextText`, and not a
    /// user-drawn `.manual` box) — generating a card would mean guessing at
    /// an unresolved passage instead of asking (§0.5).
    case selectedGroupNeedsTextReview
}

public enum CardCreationEligibilityEvaluator {
    /// - Parameters:
    ///   - groups: every group on the page, selected or not — used only to
    ///     look up which of `selectedGroupIds` are actually usable. A
    ///     pending group the user has not selected must never affect this
    ///     result (§9 item 5: other orange candidates waiting for review do
    ///     not block a card built from an already-usable selected group).
    ///   - selectedGroupIds: exactly the ids the user has toggled on.
    public static func evaluate(
        groups: [AnnotationGroup],
        selectedGroupIds: Set<String>
    ) -> CardCreationEligibility {
        let selected = groups.filter { selectedGroupIds.contains($0.id) }
        guard !selected.isEmpty else { return .noSelectedGroups }
        let hasUsableGroup = selected.contains { group in
            group.selectionType == .manual
                || !group.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !group.contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasUsableGroup ? .enabled : .selectedGroupNeedsTextReview
    }
}
