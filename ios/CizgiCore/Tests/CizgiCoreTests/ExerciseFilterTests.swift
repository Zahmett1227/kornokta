import XCTest
@testable import CizgiCore

final class ExerciseFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        id: UUID = UUID(),
        subject: String? = "Patoloji",
        topic: String? = "İnflamasyon",
        type: CardType = .directRecall,
        reviewCount: Int = 3,
        dueDate: Date? = nil,
        lowConfidence: Bool = false,
        createdAt: Date? = nil,
        fesScore: Int = 0
    ) -> ExerciseCandidate {
        ExerciseCandidate(
            id: id,
            subject: subject,
            topic: topic,
            type: type,
            reviewCount: reviewCount,
            dueDate: dueDate ?? now.addingTimeInterval(10 * 86_400),
            lowConfidence: lowConfidence,
            createdAt: createdAt ?? now.addingTimeInterval(-100 * 86_400),
            fesScore: fesScore
        )
    }

    // MARK: isActive / boş filtre = tümü

    func testFreshFilterIsInactiveAndMatchesEverything() {
        let filter = ExerciseFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(candidate(), now: now))
        XCTAssertTrue(filter.matches(candidate(subject: nil, topic: nil), now: now))
    }

    // MARK: Ders / Konu (LibraryCardFilter'a devrediliyor)

    func testSubjectFilterExcludesOtherSubjects() {
        let filter = ExerciseFilter(subject: "Patoloji")
        XCTAssertTrue(filter.matches(candidate(subject: "Patoloji"), now: now))
        XCTAssertFalse(filter.matches(candidate(subject: "Farmakoloji"), now: now))
    }

    func testTopicNoneBucketMatchesOnlyTopiclessCards() {
        let filter = ExerciseFilter(subject: "Patoloji", topic: .none)
        XCTAssertTrue(filter.matches(candidate(subject: "Patoloji", topic: nil), now: now))
        XCTAssertFalse(filter.matches(candidate(subject: "Patoloji", topic: "İnflamasyon"), now: now))
    }

    // MARK: Kart tipi — boş küme = tümü, dolu küme kesişim

    func testEmptyCardTypeSetMatchesEveryType() {
        let filter = ExerciseFilter(cardTypes: [])
        XCTAssertTrue(filter.matches(candidate(type: .multipleChoice), now: now))
        XCTAssertTrue(filter.matches(candidate(type: .cloze), now: now))
    }

    func testNonEmptyCardTypeSetExcludesOthers() {
        let filter = ExerciseFilter(cardTypes: [.multipleChoice])
        XCTAssertTrue(filter.matches(candidate(type: .multipleChoice), now: now))
        XCTAssertFalse(filter.matches(candidate(type: .directRecall), now: now))
    }

    func testMultipleSelectedCardTypesAreOred() {
        let filter = ExerciseFilter(cardTypes: [.multipleChoice, .cloze])
        XCTAssertTrue(filter.matches(candidate(type: .multipleChoice), now: now))
        XCTAssertTrue(filter.matches(candidate(type: .cloze), now: now))
        XCTAssertFalse(filter.matches(candidate(type: .mechanism), now: now))
    }

    // MARK: Kart durumu — unstudied / due / needsReview, OR'lu

    func testUnstudiedMatchesOnlyNeverReviewedCards() {
        let filter = ExerciseFilter(states: [.unstudied])
        XCTAssertTrue(filter.matches(candidate(reviewCount: 0), now: now))
        XCTAssertFalse(filter.matches(candidate(reviewCount: 1), now: now))
    }

    func testDueMatchesCardsAtOrPastTheirDueDate() {
        let filter = ExerciseFilter(states: [.due])
        XCTAssertTrue(filter.matches(candidate(dueDate: now), now: now))
        XCTAssertTrue(filter.matches(candidate(dueDate: now.addingTimeInterval(-1)), now: now))
        XCTAssertFalse(filter.matches(candidate(dueDate: now.addingTimeInterval(1)), now: now))
    }

    func testNeedsReviewMatchesLowConfidenceCards() {
        let filter = ExerciseFilter(states: [.needsReview])
        XCTAssertTrue(filter.matches(candidate(lowConfidence: true), now: now))
        XCTAssertFalse(filter.matches(candidate(lowConfidence: false), now: now))
    }

    func testMultipleSelectedStatesAreOred() {
        // "Yeni ya da vadesi gelmiş" tek bir mantıklı istek; AND neredeyse
        // her zaman sıfır kart verirdi.
        let filter = ExerciseFilter(states: [.unstudied, .due])
        let unstudied = candidate(reviewCount: 0, dueDate: now.addingTimeInterval(10 * 86_400))
        let due = candidate(reviewCount: 5, dueDate: now.addingTimeInterval(-1))
        let neither = candidate(reviewCount: 5, dueDate: now.addingTimeInterval(10 * 86_400))
        XCTAssertTrue(filter.matches(unstudied, now: now))
        XCTAssertTrue(filter.matches(due, now: now))
        XCTAssertFalse(filter.matches(neither, now: now))
    }

    // MARK: Eklenme tarihi

    func testRecencyLast7DaysExcludesOlderCards() {
        let filter = ExerciseFilter(recency: .last7Days)
        XCTAssertTrue(filter.matches(candidate(createdAt: now.addingTimeInterval(-1 * 86_400)), now: now))
        XCTAssertFalse(filter.matches(candidate(createdAt: now.addingTimeInterval(-8 * 86_400)), now: now))
    }

    func testRecencyBoundaryIsInclusive() {
        let filter = ExerciseFilter(recency: .last7Days)
        let exactlyAtCutoff = now.addingTimeInterval(-7 * 86_400)
        XCTAssertTrue(filter.matches(candidate(createdAt: exactlyAtCutoff), now: now))
    }

    // MARK: FES

    func testFesOnlyExcludesCardsBelowThreshold() {
        let filter = ExerciseFilter(fesOnly: true)
        XCTAssertTrue(filter.matches(candidate(fesScore: FesScore.threshold), now: now))
        XCTAssertFalse(filter.matches(candidate(fesScore: FesScore.threshold - 1), now: now))
    }

    // MARK: Kesişim (tüm boyutlar birlikte)

    func testAllSixDimensionsIntersect() {
        let filter = ExerciseFilter(
            subject: "Patoloji",
            topic: .topic("İnflamasyon"),
            cardTypes: [.multipleChoice],
            states: [.due],
            recency: .last30Days,
            fesOnly: true
        )
        let matching = candidate(
            subject: "Patoloji", topic: "İnflamasyon", type: .multipleChoice,
            dueDate: now.addingTimeInterval(-1), createdAt: now.addingTimeInterval(-1 * 86_400),
            fesScore: 5
        )
        XCTAssertTrue(filter.matches(matching, now: now))

        // Tek boyut bile uymazsa kesişim boşalır.
        let wrongType = candidate(
            subject: "Patoloji", topic: "İnflamasyon", type: .directRecall,
            dueDate: now.addingTimeInterval(-1), createdAt: now.addingTimeInterval(-1 * 86_400),
            fesScore: 5
        )
        XCTAssertFalse(filter.matches(wrongType, now: now))
    }

    // MARK: activeDimensions / removing — chip'lerin tek tek silinmesi

    func testInactiveFilterHasNoDimensions() {
        XCTAssertTrue(ExerciseFilter().activeDimensions.isEmpty)
    }

    func testRemovingSubjectAlsoClearsTopic() {
        // SubjectTopicFilterMenu'nün ders değişince konuyu sıfırlaması ile
        // aynı kural: dersi olmayan bir konu seçimi anlamsız kalır.
        let filter = ExerciseFilter(subject: "Patoloji", topic: .topic("İnflamasyon"))
        let cleared = filter.removing(.subject("Patoloji"))
        XCTAssertNil(cleared.subject)
        XCTAssertEqual(cleared.topic, .all)
    }

    func testRemovingOneCardTypeLeavesTheOthers() {
        let filter = ExerciseFilter(cardTypes: [.multipleChoice, .cloze])
        let after = filter.removing(.cardType(.multipleChoice))
        XCTAssertEqual(after.cardTypes, [.cloze])
    }

    func testRemovingOneStateLeavesTheOthers() {
        let filter = ExerciseFilter(states: [.due, .unstudied])
        let after = filter.removing(.state(.due))
        XCTAssertEqual(after.states, [.unstudied])
    }

    func testRemovingEveryActiveDimensionReturnsToInactive() {
        var filter = ExerciseFilter(
            subject: "Patoloji",
            cardTypes: [.multipleChoice],
            states: [.due],
            recency: .last7Days,
            fesOnly: true
        )
        for dimension in filter.activeDimensions {
            filter = filter.removing(dimension)
        }
        XCTAssertFalse(filter.isActive)
    }

    func testActiveDimensionsProducesOneEntryPerSelectedCardTypeAndState() {
        let filter = ExerciseFilter(cardTypes: [.multipleChoice, .cloze], states: [.due, .unstudied])
        let dimensions = filter.activeDimensions
        XCTAssertEqual(dimensions.count, 4)
    }

    // MARK: storageValue / fromStorage — ExerciseRun.filterJSON'un gidiş-dönüşü

    func testDefaultFilterRoundTripsThroughStorage() {
        let filter = ExerciseFilter()
        let restored = ExerciseFilter.fromStorage(filter.storageValue)
        XCTAssertEqual(restored, filter)
    }

    func testAllSixDimensionsRoundTripThroughStorage() {
        let filter = ExerciseFilter(
            subject: "Patoloji",
            topic: .topic("İnflamasyon"),
            cardTypes: [.multipleChoice, .cloze],
            states: [.due, .needsReview],
            recency: .last7Days,
            fesOnly: true
        )
        let restored = ExerciseFilter.fromStorage(filter.storageValue)
        XCTAssertEqual(restored, filter)
    }

    func testNoneTopicBucketRoundTripsDistinctlyFromAll() {
        // `.none` ("Konusuz") and `.all` must not collapse into the same
        // stored value — the same bug `TopicFilter.storageValue` itself
        // guards against.
        let filter = ExerciseFilter(subject: "Patoloji", topic: .none)
        let restored = ExerciseFilter.fromStorage(filter.storageValue)
        XCTAssertEqual(restored.topic, .none)
    }

    func testNilStorageFallsBackToDefaultFilter() {
        XCTAssertEqual(ExerciseFilter.fromStorage(nil), ExerciseFilter())
    }

    func testGarbageStorageFallsBackToDefaultFilterRatherThanCrashing() {
        XCTAssertEqual(ExerciseFilter.fromStorage("not json at all"), ExerciseFilter())
    }

    func testCardStateFilterStorageValueRoundTrips() {
        for state in CardStateFilter.allCases {
            XCTAssertEqual(CardStateFilter(storageValue: state.storageValue), state)
        }
    }

    func testCardRecencyStorageValueRoundTrips() {
        for recency in CardRecency.allCases {
            XCTAssertEqual(CardRecency(storageValue: recency.storageValue), recency)
        }
    }
}
