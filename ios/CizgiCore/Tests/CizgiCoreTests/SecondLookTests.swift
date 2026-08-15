import XCTest
@testable import CizgiCore

/// Leaving "Gözden geçir" (2026-08-15).
///
/// The defect these close is an absence, not a wrong branch: `lowConfidence`
/// had no writer outside `Card.init`, so a card the owner had checked and found
/// correct stayed flagged for the life of the deck. The rule below is the one
/// both Bilgilerim and Egzersiz now read, so the two lists cannot drift apart
/// again, and clearing the flag is the single exit all of them honour.
final class SecondLookTests: XCTestCase {

    func testAFlaggedCardInTheDeckIsPending() {
        XCTAssertTrue(SecondLook.isPending(lowConfidence: true, status: .active))
    }

    func testAnUnflaggedCardIsNotPending() {
        XCTAssertFalse(SecondLook.isPending(lowConfidence: false, status: .active))
    }

    /// The exit the owner actually asked for: checking a card and finding it
    /// sound clears the flag, and the card stays `.active` — still in review,
    /// just no longer in the list.
    func testClearingTheFlagIsTheWayOutWithoutLeavingTheDeck() {
        let status = CardStatus.active
        XCTAssertTrue(SecondLook.isPending(lowConfidence: true, status: status))
        XCTAssertFalse(SecondLook.isPending(lowConfidence: false, status: status))
    }

    /// Suspending was the *old* way off the list, and it still works — but it
    /// works by taking the card out of the deck, which is why it could never be
    /// the answer to "I checked it and it is correct".
    func testASuspendedCardIsNotListedEvenWhileFlagged() {
        XCTAssertFalse(SecondLook.isPending(lowConfidence: true, status: .suspended))
    }

    /// A pre-Faz 6 `needsReview` card is still in the deck's history, so a flag
    /// on one must not be silently swallowed by the status check — only
    /// `.suspended` takes a card off this list.
    func testOnlySuspensionHidesAFlaggedCard() {
        for status in [CardStatus.active, .draft, .needsReview] {
            XCTAssertTrue(
                SecondLook.isPending(lowConfidence: true, status: status),
                "\(status) durumundaki işaretli kart listeden düşmemeli"
            )
        }
    }
}
