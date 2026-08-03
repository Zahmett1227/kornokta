import XCTest
@testable import CizgiCore

/// Locates a repo file from the test source path (same helper as
/// `MarkerDetectionTests.swift`), so the tests read the same shared files
/// the Python side writes.
private func fsrsRepoFile(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)          // .../ios/CizgiCore/Tests/CizgiCoreTests/x.swift
        .deletingLastPathComponent()          // CizgiCoreTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // CizgiCore
        .deletingLastPathComponent()          // ios
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent(relativePath)
}

private struct FSRSCase: Decodable {
    struct Input: Decodable {
        let priorStability: Double?
        let priorDifficulty: Double?
        let rating: Int
        let elapsedDays: Double
    }
    struct Expected: Decodable {
        let stability: Double
        let difficulty: Double
        let intervalDays: Double
    }
    let name: String
    let input: Input
    let expected: Expected
}

private struct FSRSCaseFile: Decodable {
    let cases: [FSRSCase]
}

private func rating(fromFSRSNumber number: Int) -> ReviewRating {
    switch number {
    case 1: return .again
    case 2: return .hard
    case 3: return .good
    case 4: return .easy
    default: fatalError("unknown FSRS rating \(number) in shared case file")
    }
}

/// The contract with the Python reference (`evals/fsrs/algorithm.py`).
/// A divergence here means the two languages would schedule the same card
/// differently, which ANA-PLAN §18.1 requires this test to catch rather
/// than a user's due dates quietly drifting.
final class FSRSSharedCaseTests: XCTestCase {
    private var scheduler: FSRSScheduler!
    private var cases: [FSRSCase]!
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        let weights = try FSRSWeights.load(contentsOf: fsrsRepoFile("evals/fsrs/weights.json"))
        scheduler = FSRSScheduler(weights: weights)
        let data = try Data(contentsOf: fsrsRepoFile("evals/shared/fsrs-cases.json"))
        cases = try JSONDecoder().decode(FSRSCaseFile.self, from: data).cases
    }

    func testTheCaseListIsNotVacuous() {
        XCTAssertGreaterThanOrEqual(cases.count, 20)
    }

    func testEveryCaseMatchesThePythonReference() {
        for testCase in cases {
            let state: SchedulingState
            if let priorStability = testCase.input.priorStability,
               let priorDifficulty = testCase.input.priorDifficulty {
                state = SchedulingState(
                    stability: priorStability,
                    difficulty: priorDifficulty,
                    reviewCount: 1,
                    lapseCount: 0,
                    lastReviewedAt: baseDate
                )
            } else {
                state = SchedulingState()
            }

            let now = baseDate.addingTimeInterval(testCase.input.elapsedDays * 86_400)
            let result = scheduler.schedule(
                rating: rating(fromFSRSNumber: testCase.input.rating),
                state: state,
                now: now
            )

            XCTAssertEqual(
                result.stability, testCase.expected.stability, accuracy: 1e-6,
                "\(testCase.name): stability"
            )
            XCTAssertEqual(
                result.difficulty, testCase.expected.difficulty, accuracy: 1e-6,
                "\(testCase.name): difficulty"
            )
            XCTAssertEqual(
                result.scheduledDays, testCase.expected.intervalDays, accuracy: 1e-6,
                "\(testCase.name): intervalDays"
            )
        }
    }
}

final class FSRSSchedulerTests: XCTestCase {
    private func weights() throws -> FSRSWeights {
        try FSRSWeights.load(contentsOf: fsrsRepoFile("evals/fsrs/weights.json"))
    }

    func testFirstReviewProducesAPositiveStabilityAndBoundedDifficulty() throws {
        let scheduler = FSRSScheduler(weights: try weights())
        let now = Date()
        for rating in ReviewRating.allCases {
            let result = scheduler.schedule(rating: rating, state: SchedulingState(), now: now)
            XCTAssertGreaterThan(result.stability, 0, "\(rating)")
            XCTAssertGreaterThanOrEqual(result.difficulty, 1, "\(rating)")
            XCTAssertLessThanOrEqual(result.difficulty, 10, "\(rating)")
            XCTAssertGreaterThan(result.dueDate, now, "\(rating)")
        }
    }

    func testEasyOnFirstReviewSchedulesFurtherOutThanAgain() throws {
        let scheduler = FSRSScheduler(weights: try weights())
        let now = Date()
        let again = scheduler.schedule(rating: .again, state: SchedulingState(), now: now)
        let easy = scheduler.schedule(rating: .easy, state: SchedulingState(), now: now)
        XCTAssertLessThan(again.stability, easy.stability)
    }

    func testAgainAfterALongGapIsALapseNotGrowth() throws {
        let scheduler = FSRSScheduler(weights: try weights())
        let lastReviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = lastReviewedAt.addingTimeInterval(10 * 86_400)
        let state = SchedulingState(
            stability: 5.0, difficulty: 5.0, reviewCount: 3, lapseCount: 0, lastReviewedAt: lastReviewedAt
        )
        let result = scheduler.schedule(rating: .again, state: state, now: now)
        XCTAssertLessThan(result.stability, state.stability)
    }

    func testBundledWeightsLoadAndProduceSaneOutput() throws {
        // `try FSRSScheduler()` (no explicit weights) is what `AppEnvironment`
        // actually calls — it must find `Resources/fsrs-weights.json` in the
        // package's own bundle, not just in the repo-root copy the other
        // tests read directly.
        let scheduler = try FSRSScheduler()
        let result = scheduler.schedule(rating: .good, state: SchedulingState(), now: Date())
        XCTAssertGreaterThan(result.stability, 0)
    }
}
