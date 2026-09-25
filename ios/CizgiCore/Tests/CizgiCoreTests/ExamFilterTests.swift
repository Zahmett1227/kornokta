import XCTest
@testable import CizgiCore

final class ExamFilterTests: XCTestCase {
    private let bank = try! ExamBank(document: ExamBankFixture.standard)

    private func ids(_ filter: ExamFilter, progress: [String: ExamProgress] = [:]) -> [String] {
        bank.questions
            .filter { filter.matches($0, paper: bank.paper(of: $0), progress: progress[$0.id] ?? .untouched) }
            .map(\.id)
    }

    func testDefaultTakesEveryScoreableQuestionAndNothingElse() {
        XCTAssertEqual(Set(ids(ExamFilter())), bank.scoreableIds)
    }

    func testKeylessOnlyWhenAskedAndNeverCancelledOrModified() {
        let withKeyless = Set(ids(ExamFilter(includeKeyless: true)))
        XCTAssertTrue(withKeyless.contains("TUS-2007-2-K-003"))
        XCTAssertFalse(withKeyless.contains("TUS-2019-1-T-052"))
        XCTAssertFalse(withKeyless.contains("TUS-2024-2-K-101"))
    }

    func testSubjectIsOsymsAndTopicUsesTheTopicFilterContract() {
        XCTAssertEqual(ids(ExamFilter(subject: "Histoloji-Embriyoloji")), ["TUS-2019-1-T-002"])
        XCTAssertEqual(ids(ExamFilter(subject: "Farmakoloji", topic: .topic("Otonom Sinir Sistemi"))),
                       ["TUS-2019-1-T-050"])
        XCTAssertEqual(ids(ExamFilter(subject: "Farmakoloji", topic: .none)), ["TUS-2019-1-T-051"])
    }

    func testYearsOldSessionsAndTests() {
        XCTAssertEqual(ids(ExamFilter(minYear: 2013)).count, 4)
        XCTAssertEqual(ids(ExamFilter(maxYear: 2012)), ["TUS-2011-1-T2-010"])
        XCTAssertFalse(ids(ExamFilter(includeOld: false)).contains("TUS-2011-1-T2-010"))
        XCTAssertEqual(ids(ExamFilter(sessions: [2])), [])
        // The second Temel test of 2011/1 is Temel.
        XCTAssertTrue(ids(ExamFilter(testGroups: [.temel])).contains("TUS-2011-1-T2-010"))
        XCTAssertEqual(ids(ExamFilter(testGroups: [.klinik])), [])
    }

    func testFiguresCanBeLeftOut() {
        XCTAssertTrue(ids(ExamFilter()).contains("TUS-2019-1-T-051"))
        XCTAssertFalse(ids(ExamFilter(includeFigures: false)).contains("TUS-2019-1-T-051"))
    }

    func testSourceKindReadsThePaper() {
        XCTAssertEqual(ids(ExamFilter(sourceKinds: [.tusdata])), [])
        XCTAssertEqual(Set(ids(ExamFilter(sourceKinds: [.osym]))), bank.scoreableIds)
    }

    func testProgressDimensions() {
        let progress: [String: ExamProgress] = [
            "TUS-2019-1-T-001": ExamProgress(attemptCount: 2, lastResult: .correct),
            "TUS-2019-1-T-002": ExamProgress(attemptCount: 1, lastResult: .wrong, gapStatus: .open),
            "TUS-2019-1-T-050": ExamProgress(attemptCount: 1, lastResult: .blank, gapStatus: .dismissed),
        ]
        XCTAssertEqual(ids(ExamFilter(progress: .unsolved), progress: progress).count, 2)
        XCTAssertEqual(ids(ExamFilter(progress: .wrong), progress: progress), ["TUS-2019-1-T-002", "TUS-2019-1-T-050"])
        XCTAssertEqual(ids(ExamFilter(progress: .gaps), progress: progress), ["TUS-2019-1-T-002"])
    }

    func testStorageRoundTripsAndGarbageFallsBackToDefault() {
        let filter = ExamFilter(
            subject: "Farmakoloji", topic: .none, minYear: 2013, maxYear: 2020, sessions: [2],
            testGroups: [.klinik], sourceKinds: [.tusdata, .osym], progress: .wrong,
            includeFigures: false, includeOld: false, includeKeyless: true
        )
        XCTAssertEqual(ExamFilter.fromStorage(filter.storageValue), filter)
        XCTAssertEqual(ExamFilter.fromStorage("{bozuk"), ExamFilter())
        XCTAssertEqual(ExamFilter.fromStorage(nil), ExamFilter())
        XCTAssertFalse(ExamFilter().isActive)
        XCTAssertTrue(filter.isActive)
    }

    func testResultRule() {
        XCTAssertEqual(ExamResult.of(selectedOption: nil, answer: 2), .blank)
        XCTAssertEqual(ExamResult.of(selectedOption: nil, answer: nil), .blank)
        XCTAssertEqual(ExamResult.of(selectedOption: 1, answer: nil), .unscored)
        XCTAssertEqual(ExamResult.of(selectedOption: 2, answer: 2), .correct)
        XCTAssertEqual(ExamResult.of(selectedOption: 1, answer: 2), .wrong)
        XCTAssertTrue(ExamResult.blank.isMiss)
        XCTAssertFalse(ExamResult.unscored.isMiss)
    }
}

final class ExamSelectionTests: XCTestCase {
    private func candidates(_ spec: [(String, String)], answered: Set<String> = []) -> [ExamSelectionCandidate] {
        spec.map { id, subject in
            ExamSelectionCandidate(
                id: id,
                subject: subject,
                progress: answered.contains(id) ? ExamProgress(attemptCount: 1, lastResult: .correct) : .untouched
            )
        }
    }

    func testUnansweredComeFirstAndNothingRepeats() {
        var rng = ExamSeededGenerator(seed: 1)
        let pool = candidates((1...10).map { ("q\($0)", "A") }, answered: ["q1", "q2", "q3"])
        let queue = ExamSelection.queue(from: pool, limit: 7, order: .fresh, using: &rng)
        XCTAssertEqual(queue.count, 7)
        XCTAssertEqual(Set(queue).count, 7)
        XCTAssertTrue(Set(queue).isDisjoint(with: ["q1", "q2", "q3"]), "seven unanswered exist, so none answered is picked")
    }

    func testTheSameSeedQueuesTheSameRun() {
        let pool = candidates((1...30).map { ("q\($0)", ["A", "B", "C"][$0 % 3]) })
        var first = ExamSeededGenerator(seed: 42)
        var second = ExamSeededGenerator(seed: 42)
        XCTAssertEqual(ExamSelection.queue(from: pool, limit: 12, order: .fresh, using: &first),
                       ExamSelection.queue(from: pool, limit: 12, order: .fresh, using: &second))
    }

    func testSubjectsAreSpreadNotClumped() {
        var rng = ExamSeededGenerator(seed: 7)
        let pool = candidates((1...6).map { ("a\($0)", "A") } + (1...6).map { ("b\($0)", "B") })
        let queue = ExamSelection.queue(from: pool, limit: nil, order: .fresh, using: &rng)
        let subjects = queue.map { $0.hasPrefix("a") ? "A" : "B" }
        for index in 1..<subjects.count {
            XCTAssertNotEqual(subjects[index], subjects[index - 1], "equal counts alternate: \(subjects)")
        }
    }

    func testASmallSubjectIsSpreadThroughTheRunNotFrontLoaded() {
        var rng = ExamSeededGenerator(seed: 3)
        let pool = candidates((1...10).map { ("p\($0)", "P") } + [("x1", "X"), ("x2", "X")])
        let queue = ExamSelection.queue(from: pool, limit: nil, order: .fresh, using: &rng)
        let positions = queue.enumerated().filter { $0.element.hasPrefix("x") }.map(\.offset)
        XCTAssertEqual(positions.count, 2)
        XCTAssertGreaterThanOrEqual(positions[1] - positions[0], 4, "\(queue)")
    }

    func testOldestMissComesFirstWithinItsSubject() {
        var rng = ExamSeededGenerator(seed: 9)
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let pool = [
            ExamSelectionCandidate(id: "new", subject: "A",
                                   progress: ExamProgress(attemptCount: 1, lastResult: .wrong, lastAnsweredAt: base + 3 * day)),
            ExamSelectionCandidate(id: "old", subject: "A",
                                   progress: ExamProgress(attemptCount: 1, lastResult: .wrong, lastAnsweredAt: base)),
            ExamSelectionCandidate(id: "mid", subject: "A",
                                   progress: ExamProgress(attemptCount: 1, lastResult: .wrong, lastAnsweredAt: base + day)),
        ]
        XCTAssertEqual(ExamSelection.queue(from: pool, limit: nil, order: .oldestFirst, using: &rng),
                       ["old", "mid", "new"])
        XCTAssertEqual(ExamSelection.queue(from: pool, limit: 2, order: .oldestFirst, using: &rng), ["old", "mid"])
    }

    func testNearDuplicatesNeverShareARunEitherWay() {
        var rng = ExamSeededGenerator(seed: 5)
        let pool = [
            ExamSelectionCandidate(id: "q1", subject: "A", similarTo: ["q2"]),
            ExamSelectionCandidate(id: "q2", subject: "A"),
            ExamSelectionCandidate(id: "q3", subject: "B"),
        ]
        for _ in 0..<20 {
            let queue = ExamSelection.queue(from: pool, limit: nil, order: .fresh, using: &rng)
            XCTAssertEqual(queue.count, 2, "\(queue)")
            XCTAssertFalse(queue.contains("q1") && queue.contains("q2"))
        }
    }
}
