import XCTest
@testable import CizgiCore

/// Per-subject study statistics and Bilgilerim's subject → topic grouping
/// (2026-09-14).
final class StudyStatisticsTests: XCTestCase {
    private let schema = SubjectTopicSchema(
        version: 1,
        subjects: [
            .init(name: "Patoloji", topics: ["Inflamasyon", "Neoplazi"]),
            .init(name: "Farmakoloji", topics: ["Otonom"]),
            .init(name: "Anatomi", topics: ["Kemik"]),
        ]
    )
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func card(
        _ subject: String?, _ topic: String?,
        status: CardStatus = .active, dueIn days: Double = 1, id: UUID = UUID()
    ) -> StatsCard {
        StatsCard(id: id, subject: subject, topic: topic, status: status,
                  dueDate: now.addingTimeInterval(days * 86_400))
    }

    private func review(_ card: StatsCard, _ rating: ReviewRating, daysAgo: Double = 1) -> StatsReview {
        StatsReview(cardId: card.id, at: now.addingTimeInterval(-daysAgo * 86_400), rating: rating)
    }

    private func attempt(_ card: StatsCard, _ result: ExerciseResult, daysAgo: Double = 1) -> StatsAttempt {
        StatsAttempt(cardId: card.id, at: now.addingTimeInterval(-daysAgo * 86_400), result: result)
    }

    // MARK: Grouping

    /// The invariant Bilgi Haritası set and this screen keeps: every card lands
    /// in exactly one row, so the rows on screen add up to the deck.
    func testEveryCardIsCountedExactlyOnce() {
        let cards = [
            card("Patoloji", "Neoplazi"), card("Patoloji", "Inflamasyon"),
            card("Patoloji", nil), card("Patoloji", "Eski konu adı"),
            card("Farmakoloji", "Otonom"),
            card(nil, nil), card("Tanınmayan ders", "Otonom"),
        ]
        let summary = StudyStatistics.build(cards: cards, now: now, schema: schema)

        XCTAssertEqual(summary.total.cardCount, 7)
        XCTAssertEqual(summary.subjects.reduce(0) { $0 + $1.line.cardCount }, 7)
        for subject in summary.subjects where subject.subject != nil {
            XCTAssertEqual(subject.topics.reduce(0) { $0 + $1.line.cardCount }, subject.line.cardCount,
                           "\(subject.title) konuları dersin toplamına eşit olmalı")
        }
    }

    func testSubjectsFollowSchemaOrderAndSkipEmptyOnes() {
        let summary = StudyStatistics.build(
            cards: [card("Farmakoloji", "Otonom"), card("Patoloji", "Neoplazi"), card(nil, nil)],
            now: now, schema: schema
        )
        XCTAssertEqual(summary.subjects.map(\.title), ["Patoloji", "Farmakoloji", "Ders atanmamış"],
                       "şema sırası, kartsız Anatomi yok, sınıflandırılmamış en sonda")
    }

    func testTopicsAreCanonicalThenNoneThenUnrecognized() {
        let summary = StudyStatistics.build(
            cards: [card("Patoloji", "Eski"), card("Patoloji", nil),
                    card("Patoloji", "Neoplazi"), card("Patoloji", "Inflamasyon")],
            now: now, schema: schema
        )
        let topics = summary.subjects[0].topics
        XCTAssertEqual(topics.map(\.title), ["Inflamasyon", "Neoplazi", "Konusuz", "Tanınmayan konu"])
        XCTAssertEqual(topics.map(\.topicFilter), [.topic("Inflamasyon"), .topic("Neoplazi"), TopicFilter.none, nil])
    }

    func testStatusCountsAndDueCount() {
        let summary = StudyStatistics.build(
            cards: [
                card("Patoloji", "Neoplazi", status: .active, dueIn: -1),   // due
                card("Patoloji", "Neoplazi", status: .active, dueIn: 3),    // not yet
                card("Patoloji", "Neoplazi", status: .suspended, dueIn: -5), // suspended: never due
            ],
            now: now, schema: schema
        )
        let line = summary.subjects[0].line
        XCTAssertEqual(line.cardCount, 3)
        XCTAssertEqual(line.activeCount, 2)
        XCTAssertEqual(line.suspendedCount, 1)
        XCTAssertEqual(line.dueCount, 1)
    }

    /// The list behind a row must hold exactly the cards the row counted.
    func testMembershipAgreesWithTheCounts() {
        let cards = [
            card("Patoloji", "Neoplazi"), card("Patoloji", nil), card("Patoloji", "Eski"),
            card("Farmakoloji", "Otonom"), card(nil, nil), card("Bilinmeyen", "Otonom"),
        ]
        let summary = StudyStatistics.build(cards: cards, now: now, schema: schema)
        for subject in summary.subjects {
            let members = cards.filter {
                StudyStatistics.belongs(subject: $0.subject, to: subject.subject, schema: schema)
            }
            XCTAssertEqual(members.count, subject.line.cardCount, subject.title)
            guard let name = subject.subject else { continue }
            for topic in subject.topics {
                let inTopic = members.filter {
                    StudyStatistics.belongs(topic: $0.topic, to: topic.bucket, subject: name, schema: schema)
                }
                XCTAssertEqual(inTopic.count, topic.line.cardCount, "\(name) · \(topic.title)")
            }
        }
    }

    // MARK: Review column

    func testReviewCountsSeenCardsAndForgetting() {
        let a = card("Patoloji", "Neoplazi")
        let b = card("Patoloji", "Neoplazi")
        let summary = StudyStatistics.build(
            cards: [a, b, card("Patoloji", "Neoplazi")],
            reviews: [review(a, .again), review(a, .good), review(a, .hard), review(b, .easy)],
            now: now, schema: schema
        )
        let stats = summary.subjects[0].line.review
        XCTAssertEqual(stats.seenCards, 2, "hiç tekrar edilmemiş kart görülmüş sayılmaz")
        XCTAssertEqual(stats.reviews, 4)
        XCTAssertEqual(stats.forgotten, 1)
        XCTAssertEqual(stats.hard, 1)
        XCTAssertEqual(try XCTUnwrap(stats.accuracy), 0.75, accuracy: 1e-9)
    }

    /// "No data" and "all wrong" must not look the same on screen.
    func testAccuracyIsNilWithoutDataAndZeroWhenAllWrong() {
        let a = card("Patoloji", "Neoplazi")
        let empty = StudyStatistics.build(cards: [a], now: now, schema: schema)
        XCTAssertNil(empty.total.review.accuracy)
        XCTAssertNil(empty.total.exercise.accuracy)

        let wrong = StudyStatistics.build(
            cards: [a], reviews: [review(a, .again)], attempts: [attempt(a, .missed)],
            now: now, schema: schema
        )
        XCTAssertEqual(wrong.total.review.accuracy, 0)
        XCTAssertEqual(wrong.total.exercise.accuracy, 0)
    }

    /// The window boundary is inclusive: a review exactly seven days ago is in
    /// "7 gün", one a second earlier is not.
    func testWindowBoundaryIsInclusive() {
        let a = card("Patoloji", "Neoplazi")
        let edge = StatsReview(cardId: a.id, at: now.addingTimeInterval(-7 * 86_400), rating: .good)
        let before = StatsReview(cardId: a.id, at: now.addingTimeInterval(-7 * 86_400 - 1), rating: .good)
        let summary = StudyStatistics.build(cards: [a], reviews: [edge, before], window: .last7Days,
                                            now: now, schema: schema)
        XCTAssertEqual(summary.total.review.reviews, 1)
    }

    func testReviewLogsHonourEveryWindow() {
        let a = card("Patoloji", "Neoplazi")
        let reviews = [review(a, .good, daysAgo: 2), review(a, .good, daysAgo: 20), review(a, .good, daysAgo: 400)]
        func count(_ window: StatsWindow) -> Int {
            StudyStatistics.build(cards: [a], reviews: reviews, window: window, now: now, schema: schema)
                .total.review.reviews
        }
        XCTAssertEqual(count(.last7Days), 1)
        XCTAssertEqual(count(.last30Days), 2)
        XCTAssertEqual(count(.all), 3, "ReviewLog hiç silinmez, 'Tümü' gerçekten tümü")
    }

    // MARK: Exercise column

    func testExerciseCountsMissedAndUnsure() {
        let a = card("Farmakoloji", "Otonom")
        let summary = StudyStatistics.build(
            cards: [a],
            attempts: [attempt(a, .knew), attempt(a, .missed), attempt(a, .unsure), attempt(a, .knew)],
            now: now, schema: schema
        )
        let stats = summary.total.exercise
        XCTAssertEqual(stats.attempts, 4)
        XCTAssertEqual(stats.missed, 1)
        XCTAssertEqual(stats.unsure, 1)
        XCTAssertEqual(try XCTUnwrap(stats.accuracy), 0.5, accuracy: 1e-9)
    }

    /// The column is labelled "son 90 gün". Even under "Tümü", and even if the
    /// prune has not run, an attempt older than that is not counted.
    func testExerciseNeverReachesPastNinetyDays() {
        let a = card("Farmakoloji", "Otonom")
        let attempts = [attempt(a, .knew, daysAgo: 10), attempt(a, .knew, daysAgo: 95)]
        let all = StudyStatistics.build(cards: [a], attempts: attempts, window: .all, now: now, schema: schema)
        XCTAssertEqual(all.total.exercise.attempts, 1)

        let week = StudyStatistics.build(cards: [a], attempts: attempts, window: .last7Days, now: now, schema: schema)
        XCTAssertEqual(week.total.exercise.attempts, 0)
    }

    /// History of a deleted card belongs to no row; counting it in the total
    /// alone would make the rows stop adding up.
    func testHistoryOfADeletedCardIsIgnored() {
        let kept = card("Patoloji", "Neoplazi")
        let gone = card("Patoloji", "Neoplazi")
        let summary = StudyStatistics.build(
            cards: [kept],
            reviews: [review(kept, .good), review(gone, .again)],
            attempts: [attempt(gone, .missed)],
            now: now, schema: schema
        )
        XCTAssertEqual(summary.total.review.reviews, 1)
        XCTAssertEqual(summary.total.exercise.attempts, 0)
        XCTAssertEqual(summary.subjects[0].line.review.reviews, summary.total.review.reviews)
    }

    /// Suspended cards were really studied: their history counts, they just
    /// are not active.
    func testASuspendedCardsHistoryStillCounts() {
        let a = card("Patoloji", "Neoplazi", status: .suspended)
        let summary = StudyStatistics.build(cards: [a], reviews: [review(a, .again)], now: now, schema: schema)
        XCTAssertEqual(summary.total.review.reviews, 1)
        XCTAssertEqual(summary.total.activeCount, 0)
    }
}
