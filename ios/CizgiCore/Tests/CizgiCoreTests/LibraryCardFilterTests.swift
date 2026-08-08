import XCTest
@testable import CizgiCore

final class LibraryCardFilterTests: XCTestCase {
    private func matches(
        subject: String?,
        topic: String?,
        filterSubject: String?,
        filterTopic: TopicFilter
    ) -> Bool {
        LibraryCardFilter.matches(
            subject: subject,
            topic: topic,
            subjectFilter: filterSubject,
            topicFilter: filterTopic
        )
    }

    func testNoFilterKeepsEveryCardIncludingUnclassifiedOnes() {
        XCTAssertTrue(matches(subject: "Patoloji", topic: "İnflamasyon", filterSubject: nil, filterTopic: .all))
        XCTAssertTrue(matches(subject: nil, topic: nil, filterSubject: nil, filterTopic: .all))
    }

    func testSubjectFilterExcludesOtherSubjectsAndSubjectlessCards() {
        XCTAssertTrue(matches(subject: "Patoloji", topic: nil, filterSubject: "Patoloji", filterTopic: .all))
        XCTAssertFalse(matches(subject: "Anatomi", topic: nil, filterSubject: "Patoloji", filterTopic: .all))
        XCTAssertFalse(matches(subject: nil, topic: nil, filterSubject: "Patoloji", filterTopic: .all))
    }

    func testTopicFilterNarrowsWithinTheSubject() {
        XCTAssertTrue(matches(subject: "Patoloji", topic: "İnflamasyon",
                              filterSubject: "Patoloji", filterTopic: .topic("İnflamasyon")))
        XCTAssertFalse(matches(subject: "Patoloji", topic: "Neoplazi",
                               filterSubject: "Patoloji", filterTopic: .topic("İnflamasyon")))
    }

    func testKonusuzBucketFindsCardsFromBeforeTopicAssignment() {
        // The whole pre-v2.2 deck lands here; without this bucket it would be
        // invisible under any subject filter.
        XCTAssertTrue(matches(subject: "Patoloji", topic: nil, filterSubject: "Patoloji", filterTopic: .none))
        XCTAssertFalse(matches(subject: "Patoloji", topic: "İnflamasyon",
                               filterSubject: "Patoloji", filterTopic: .none))
    }

    /// A stored filter has to come back as the same filter. `topicName` folds
    /// `.none` and `.all` onto the same `nil`, so an exercise resumed after a
    /// relaunch would have silently widened from "Konusuz" to every topic.
    func testStoredFilterSurvivesARoundTripIncludingTheKonusuzBucket() {
        for filter: TopicFilter in [.all, .none, .topic("İnflamasyon")] {
            XCTAssertEqual(TopicFilter.fromStorage(filter.storageValue), filter)
        }

        XCTAssertNil(TopicFilter.all.storageValue)
        XCTAssertNotNil(TopicFilter.none.storageValue)
        XCTAssertNotEqual(TopicFilter.none.storageValue, TopicFilter.all.storageValue)
    }

    /// The sentinel must not be reachable by any real topic name, and no
    /// canonical topic may collide with it.
    func testKonusuzSentinelCannotCollideWithACanonicalTopic() throws {
        let schema = try SubjectTopicSchema.bundled()
        let allTopics = schema.subjects.flatMap(\.topics)

        XCTAssertFalse(allTopics.contains(TopicFilter.noneStorageToken))
        XCTAssertFalse(allTopics.isEmpty, "şema boşsa bu kontrol bir şey kanıtlamaz")
    }
}
