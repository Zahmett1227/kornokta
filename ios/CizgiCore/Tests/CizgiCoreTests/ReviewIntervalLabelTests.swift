import XCTest
@testable import CizgiCore

/// The label under each grade button on the review screen.
///
/// Worth testing for one reason: it is a promise. The number the screen prints
/// is the number the card is about to honour, and every boundary here is a
/// place where rounding can print a unit the scheduler did not mean.
final class ReviewIntervalLabelTests: XCTestCase {

    func testMinutesUnderAnHour() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 10.0 / 1440), "10 dk")
        XCTAssertEqual(ReviewIntervalLabel.short(days: 59.0 / 1440), "59 dk")
    }

    /// A card due in seconds must not read "0 dk" — that is a number the user
    /// would take as "never".
    func testSubMinuteRoundsUpRatherThanToZero() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 5.0 / 86_400), "1 dk")
    }

    func testHoursUnderADay() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 0.25), "6 sa")
    }

    /// The one boundary that can print a unit the next branch owns: 0.99 days
    /// rounds to 24 hours, which is a day.
    func testAlmostOneDayStaysInHours() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 0.99), "23 sa")
    }

    func testDays() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 1), "1 gün")
        XCTAssertEqual(ReviewIntervalLabel.short(days: 4.3), "4 gün")
        XCTAssertEqual(ReviewIntervalLabel.short(days: 29), "29 gün")
    }

    func testMonthsAndYears() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 30), "1 ay")
        XCTAssertEqual(ReviewIntervalLabel.short(days: 200), "7 ay")
        XCTAssertEqual(ReviewIntervalLabel.short(days: 365), "1 yıl")
        XCTAssertEqual(ReviewIntervalLabel.short(days: 800), "2 yıl")
    }

    /// A scheduler that returned a non-finite or non-positive interval must not
    /// put "nan gün" on a button.
    func testDegenerateInputs() {
        XCTAssertEqual(ReviewIntervalLabel.short(days: 0), "şimdi")
        XCTAssertEqual(ReviewIntervalLabel.short(days: -1), "şimdi")
        XCTAssertEqual(ReviewIntervalLabel.short(days: .nan), "şimdi")
        XCTAssertEqual(ReviewIntervalLabel.short(days: .infinity), "şimdi")
    }

    /// A large queue is the case that forced this: 3.000 cards at the fallback
    /// pace is 603 minutes, which the start screen printed verbatim.
    func testSessionEstimateClimbsOutOfMinutes() {
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: 4), "4 dk")
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: 59), "59 dk")
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: 60), "1 sa")
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: 90), "1 sa 30 dk")
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: 603), "10 sa")
    }

    /// Zero minutes of work is not a thing the screen should offer to start.
    func testSessionEstimateNeverPrintsZero() {
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: 0), "1 dk")
        XCTAssertEqual(ReviewIntervalLabel.sessionEstimate(minutes: -5), "1 dk")
    }

    /// VoiceOver reads "4 g" as a letter, so the spoken form spells the unit —
    /// but it must agree with the visible one about which unit it is.
    func testSpokenAgreesWithShort() {
        XCTAssertEqual(ReviewIntervalLabel.spoken(days: 10.0 / 1440), "10 dakika sonra")
        XCTAssertEqual(ReviewIntervalLabel.spoken(days: 0.25), "6 saat sonra")
        XCTAssertEqual(ReviewIntervalLabel.spoken(days: 4.3), "4 gün sonra")
        XCTAssertEqual(ReviewIntervalLabel.spoken(days: 200), "7 ay sonra")
        XCTAssertEqual(ReviewIntervalLabel.spoken(days: 800), "2 yıl sonra")
    }
}
