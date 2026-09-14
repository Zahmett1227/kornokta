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
    /// on one must not be silently swallowed by the status check — only a status
    /// that takes the card out of the deck takes it off this list.
    func testOnlyBeingOutOfTheDeckHidesAFlaggedCard() {
        for status in [CardStatus.active, .draft, .needsReview] {
            XCTAssertTrue(
                SecondLook.isPending(lowConfidence: true, status: status),
                "\(status) durumundaki işaretli kart listeden düşmemeli"
            )
        }
    }

    /// The single answer to "is this card out of play?" that SecondLook,
    /// Egzersiz's pool and its setup sheet all read. Moved here from the
    /// removed concept-queue tests (2026-09-14) because the property outlived
    /// the deck: suspension is now the only way out, and the other three
    /// statuses must go on answering `false` exactly as they did at the call
    /// sites this property replaced.
    func testOnlySuspensionWithholdsACard() {
        XCTAssertTrue(CardStatus.suspended.isWithheld)
        for status in [CardStatus.active, .draft, .needsReview] {
            XCTAssertFalse(status.isWithheld, "\(status) desteden düşmemeli")
        }
    }
}
