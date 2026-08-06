import XCTest
@testable import CizgiCore

/// The review loop's own logic (ANA-PLAN §5.4, §6.5, §18.3).
///
/// These cover the three faults that made a real deck unusable: a session
/// capped so low that most due cards were unreachable, a forgotten card that
/// never came back, and a grade that could not be taken back.
final class ReviewSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func card(
        id: UUID = UUID(),
        dueOffset: TimeInterval = -60,
        unit: UUID? = nil,
        status: CardStatus = .active,
        reviewCount: Int = 1
    ) -> PlannableCard {
        PlannableCard(
            id: id,
            dueDate: now.addingTimeInterval(dueOffset),
            knowledgeUnitId: unit ?? UUID(),
            status: status,
            reviewCount: reviewCount
        )
    }

    // MARK: Session limits

    /// §18.3's default is "bugün bekleyen tüm kartlar". The old screen applied
    /// the quick-session count to every session, so a backlog was permanently
    /// unreachable — twenty-five cards a day no matter how many were due.
    func testWithoutACapEveryDueCardIsInTheSession() {
        let cards = (0..<120).map { card(dueOffset: Double(-$0), reviewCount: 1) }
        let session = ReviewSessionPlanner.session(cards: cards, now: now, newCardLimit: 20)
        XCTAssertEqual(session.count, 120)
    }

    func testCapTrimsTheSessionWhenOneIsAsked() {
        let cards = (0..<120).map { card(dueOffset: Double(-$0), reviewCount: 1) }
        let session = ReviewSessionPlanner.session(cards: cards, now: now, newCardLimit: 20, cap: 25)
        XCTAssertEqual(session.count, 25)
    }

    func testNotYetDueAndSuspendedCardsStayOut() {
        let due = card(dueOffset: -1)
        let future = card(dueOffset: 3600)
        let suspended = card(dueOffset: -1, status: .suspended)
        let session = ReviewSessionPlanner.session(
            cards: [due, future, suspended], now: now, newCardLimit: 20
        )
        XCTAssertEqual(session, [due.id])
    }

    func testNewCardsAreCappedByTheDailyLimit() {
        let cards = (0..<10).map { card(dueOffset: Double(-$0), reviewCount: 0) }
        let session = ReviewSessionPlanner.session(cards: cards, now: now, newCardLimit: 3)
        XCTAssertEqual(session.count, 3)
    }

    /// The limit is on *learning* new material, not on clearing what is due —
    /// holding back a card that is merely due would hide work the user has
    /// already committed to.
    func testTheDailyLimitNeverHoldsBackARepeatReview() {
        let new = (0..<10).map { card(dueOffset: Double(-$0), reviewCount: 0) }
        let repeats = (0..<10).map { card(dueOffset: Double(-100 - $0), reviewCount: 4) }
        let session = ReviewSessionPlanner.session(cards: new + repeats, now: now, newCardLimit: 2)
        XCTAssertEqual(session.count, 12)
    }

    /// The whole point of the ledger: reopening the screen used to hand out a
    /// fresh allowance, so "günlük 20 yeni kart" was really "20 per sitting".
    func testCardsAlreadyIntroducedTodayConsumeTheAllowance() {
        let cards = (0..<10).map { card(dueOffset: Double(-$0), reviewCount: 0) }
        let session = ReviewSessionPlanner.session(
            cards: cards, now: now, newCardLimit: 5, alreadyIntroducedToday: 4
        )
        XCTAssertEqual(session.count, 1)
    }

    func testAnExhaustedAllowanceAdmitsNoNewCards() {
        let cards = (0..<10).map { card(dueOffset: Double(-$0), reviewCount: 0) }
        let session = ReviewSessionPlanner.session(
            cards: cards, now: now, newCardLimit: 5, alreadyIntroducedToday: 9
        )
        XCTAssertTrue(session.isEmpty)
    }

    /// The ordering rule from §18.3 still has to hold once the limits run.
    func testSessionKeepsThePlannersSpreadAcrossKnowledgeUnits() {
        let unitA = UUID(), unitB = UUID()
        let a1 = card(dueOffset: -300, unit: unitA)
        let a2 = card(dueOffset: -200, unit: unitA)
        let b1 = card(dueOffset: -100, unit: unitB)
        let session = ReviewSessionPlanner.session(
            cards: [a1, a2, b1], now: now, newCardLimit: 20
        )
        XCTAssertEqual(session, [a1.id, b1.id, a2.id])
    }

    // MARK: Walking the session

    func testAdvanceWalksToTheEnd() {
        let ids = [UUID(), UUID(), UUID()]
        var session = ReviewSession(queue: ids)

        XCTAssertEqual(session.current, ids[0])
        session.advance()
        XCTAssertEqual(session.current, ids[1])
        session.advance()
        session.advance()
        XCTAssertNil(session.current)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.completed, 3)
    }

    /// A forgotten card used to be gone for the rest of the sitting: the queue
    /// was a frozen snapshot, so the ten-minute interval the scheduler had just
    /// given it had nothing to act on.
    func testAForgottenCardComesBackInTheSameSession() {
        let ids = [UUID(), UUID()]
        var session = ReviewSession(queue: ids)

        session.advance(relearn: true)
        XCTAssertEqual(session.current, ids[1])
        session.advance()
        XCTAssertEqual(session.current, ids[0], "unutulan kart oturumun sonunda tekrar sorulmalı")
        XCTAssertFalse(session.isFinished)
    }

    func testAForgottenCardGoesToTheEndNotTheNextSlot() {
        let ids = [UUID(), UUID(), UUID()]
        var session = ReviewSession(queue: ids)
        session.advance(relearn: true)
        XCTAssertEqual(session.queue, ids + [ids[0]])
    }

    /// Unbounded requeueing turns "Unuttum" into a loop the user can only leave
    /// by quitting the screen.
    func testACardStopsComingBackAfterTheRepeatLimit() {
        let id = UUID()
        var session = ReviewSession(queue: [id])

        for _ in 0..<ReviewSession.maxRelearningRepeats {
            session.advance(relearn: true)
        }
        XCTAssertEqual(session.current, id)
        session.advance(relearn: true)
        XCTAssertTrue(session.isFinished, "tekrar sınırından sonra kart oturumu uzatmamalı")
    }

    func testAdvancingPastTheEndDoesNothing() {
        var session = ReviewSession(queue: [])
        XCTAssertNil(session.advance())
        XCTAssertTrue(session.isFinished)
    }

    // MARK: Undo

    func testRewindGoesBackToTheGradedCard() {
        let ids = [UUID(), UUID()]
        var session = ReviewSession(queue: ids)
        let step = session.advance()
        XCTAssertEqual(session.current, ids[1])

        session.rewind(step!)
        XCTAssertEqual(session.current, ids[0])
        XCTAssertEqual(session.completed, 0)
    }

    /// Undoing an "Unuttum" has to take the requeue back too, or the card is
    /// asked twice more than it was ever graded.
    func testRewindAlsoRemovesTheRequeuedCopy() {
        let ids = [UUID(), UUID()]
        var session = ReviewSession(queue: ids)
        let step = session.advance(relearn: true)
        XCTAssertEqual(session.queue.count, 3)

        session.rewind(step!)
        XCTAssertEqual(session.queue, ids)
        XCTAssertEqual(session.current, ids[0])
    }

    /// And it has to give the repeat allowance back, or three corrected
    /// mis-taps would silently stop the card from ever returning.
    func testRewindRestoresTheRepeatAllowance() {
        let id = UUID()
        var session = ReviewSession(queue: [id])

        for _ in 0..<ReviewSession.maxRelearningRepeats {
            let step = session.advance(relearn: true)
            session.rewind(step!)
        }
        session.advance(relearn: true)
        XCTAssertEqual(session.current, id, "geri alınan tekrarlar hakkı tüketmemeli")
    }

    func testRewindingSomethingOtherThanTheLastStepIsIgnored() {
        let ids = [UUID(), UUID()]
        var session = ReviewSession(queue: ids)
        session.advance()
        let bogus = ReviewSession.Step(cardId: UUID(), requeuedAt: nil)

        session.rewind(bogus)
        XCTAssertEqual(session.completed, 1)
        XCTAssertEqual(session.current, ids[1])
    }

    func testRewindAtTheStartIsIgnored() {
        var session = ReviewSession(queue: [UUID()])
        session.rewind(ReviewSession.Step(cardId: session.current!, requeuedAt: nil))
        XCTAssertEqual(session.completed, 0)
    }

    // MARK: Pace

    func testPaceFallsBackWhenThereIsNoHistory() {
        XCTAssertEqual(
            ReviewPace.secondsPerCard(recentResponseTimesMs: []),
            ReviewPace.fallbackSecondsPerCard
        )
    }

    func testPaceUsesTheMedianSoOneInterruptionDoesNotMoveIt() {
        // Four seconds each, then one card the user walked away from.
        let times = [4000, 4000, 4000, 900_000]
        XCTAssertEqual(ReviewPace.secondsPerCard(recentResponseTimesMs: times), 4, accuracy: 0.001)
    }

    func testImplausibleTimesAreClampedRatherThanDropped() {
        // All outliers: clamping keeps the estimate at the plausible edge
        // instead of silently reporting the untouched default as "measured".
        let hammering = Array(repeating: 200, count: 10)
        XCTAssertEqual(
            ReviewPace.secondsPerCard(recentResponseTimesMs: hammering),
            ReviewPace.plausibleSecondsPerCard.lowerBound,
            accuracy: 0.001
        )
    }

    /// The old conversion was a hardcoded five cards a minute. A five-minute
    /// session was twenty-five cards whether that took two minutes or twelve.
    func testMinutesBecomeCardsAtTheMeasuredPace() {
        XCTAssertEqual(ReviewPace.cardCount(forMinutes: 5, secondsPerCard: 6), 50)
        XCTAssertEqual(ReviewPace.cardCount(forMinutes: 5, secondsPerCard: 30), 10)
    }

    func testATimeBudgetAlwaysYieldsAtLeastOneCard() {
        XCTAssertEqual(ReviewPace.cardCount(forMinutes: 1, secondsPerCard: 600), 1)
        XCTAssertEqual(ReviewPace.cardCount(forMinutes: 0, secondsPerCard: 12), 1)
    }

    // MARK: Daily ledger

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }

    func testLedgerCountsWithinOneDay() {
        var ledger = DailyNewCardLedger()
        XCTAssertEqual(ledger.count(on: now, calendar: calendar), 0)

        ledger.record(on: now, calendar: calendar)
        ledger.record(on: now.addingTimeInterval(600), calendar: calendar)
        XCTAssertEqual(ledger.count(on: now, calendar: calendar), 2)
    }

    func testLedgerResetsOnANewDay() {
        var ledger = DailyNewCardLedger()
        ledger.record(on: now, calendar: calendar)
        let tomorrow = now.addingTimeInterval(26 * 3600)

        XCTAssertEqual(ledger.count(on: tomorrow, calendar: calendar), 0)
        ledger.record(on: tomorrow, calendar: calendar)
        XCTAssertEqual(ledger.count(on: tomorrow, calendar: calendar), 1)
        XCTAssertEqual(ledger.count(on: now, calendar: calendar), 0)
    }

    func testUndoGivesTheAllowanceBack() {
        var ledger = DailyNewCardLedger()
        ledger.record(on: now, calendar: calendar)
        ledger.record(on: now, calendar: calendar)
        ledger.undoRecord(on: now, calendar: calendar)
        XCTAssertEqual(ledger.count(on: now, calendar: calendar), 1)
    }

    func testUndoNeverGoesBelowZeroOrTouchesAnotherDay() {
        var ledger = DailyNewCardLedger()
        ledger.record(on: now, calendar: calendar)
        ledger.undoRecord(on: now, calendar: calendar)
        ledger.undoRecord(on: now, calendar: calendar)
        XCTAssertEqual(ledger.count(on: now, calendar: calendar), 0)

        ledger.record(on: now, calendar: calendar)
        ledger.undoRecord(on: now.addingTimeInterval(26 * 3600), calendar: calendar)
        XCTAssertEqual(ledger.count(on: now, calendar: calendar), 1)
    }

    func testLedgerSurvivesEncoding() throws {
        var ledger = DailyNewCardLedger()
        ledger.record(on: now, calendar: calendar)
        let restored = try JSONDecoder().decode(
            DailyNewCardLedger.self, from: try JSONEncoder().encode(ledger)
        )
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.count(on: now, calendar: calendar), 1)
    }
}
