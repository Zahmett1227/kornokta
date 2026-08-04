import XCTest
@testable import CizgiCore

/// §9/§11 items 24–28: the confirmation screen's "Seçili gruplardan kart
/// oluştur" button must reflect exactly this pure decision — never a
/// separately (and possibly divergently) computed disabled state.
final class CardCreationEligibilityTests: XCTestCase {
    private func group(
        _ id: String,
        selectionType: AnnotationType = .highlight,
        selectedText: String = "",
        contextText: String = ""
    ) -> AnnotationGroup {
        AnnotationGroup(
            id: id,
            evidenceIds: [],
            selectedLineIds: [],
            contextLineIds: [],
            boundingBox: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.02),
            confidence: 0.9,
            needsConfirmation: true,
            selectionType: selectionType,
            selectedText: selectedText,
            contextText: contextText
        )
    }

    func testNoSelectionIsIneligible() {
        let groups = [group("a", selectedText: "hipoksi")]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: []),
            .noSelectedGroups
        )
    }

    func testASelectedGroupWithResolvedTextIsEnabled() {
        let groups = [group("a", selectedText: "hipoksi")]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: ["a"]),
            .enabled
        )
    }

    /// §9 item 5: other pending groups elsewhere on the page must never
    /// globally block a card built from an already-usable selected group.
    func testOtherPendingGroupsDoNotBlockAnAlreadyUsableSelection() {
        let groups = [
            group("a", selectedText: "hipoksi"),
            group("b", selectedText: ""), // still pending, never selected
            group("c", selectedText: ""), // still pending, never selected
        ]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: ["a"]),
            .enabled
        )
    }

    /// The exact real-device symptom (§9): a group can be toggled on/"look
    /// selected" while its grounded text never resolved to anything.
    func testASelectedGroupWithNoResolvedTextNeedsReview() {
        let groups = [group("a", selectedText: "", contextText: "")]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: ["a"]),
            .selectedGroupNeedsTextReview
        )
    }

    /// A manual (user-drawn) box is always usable even with no grounded OCR
    /// text at all — that's the point of drawing it by hand.
    func testASelectedManualGroupWithNoTextIsStillEnabled() {
        let groups = [group("a", selectionType: .manual, selectedText: "", contextText: "")]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: ["a"]),
            .enabled
        )
    }

    /// §11 item 30: a group the user rejected (never selected) must not be
    /// treated as if it were part of the submission, even if it is the only
    /// group with resolvable text on the page.
    func testARejectedGroupIsNotConsideredEvenIfItHasResolvableText() {
        let groups = [
            group("a", selectedText: ""),          // selected, unresolved
            group("b", selectedText: "hipoksi"),   // resolvable, but not selected
        ]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: ["a"]),
            .selectedGroupNeedsTextReview
        )
    }

    /// §11 item 28: removing the only selection must flip eligibility back.
    func testRemovingTheOnlySelectionGoesBackToNoSelectedGroups() {
        let groups = [group("a", selectedText: "hipoksi")]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: []),
            .noSelectedGroups
        )
    }

    /// At least one usable group among several selected ones is enough.
    func testAtLeastOneUsableSelectedGroupIsEnoughAmongSeveral() {
        let groups = [
            group("a", selectedText: ""),
            group("b", selectedText: "hipoksi"),
        ]
        XCTAssertEqual(
            CardCreationEligibilityEvaluator.evaluate(groups: groups, selectedGroupIds: ["a", "b"]),
            .enabled
        )
    }
}
