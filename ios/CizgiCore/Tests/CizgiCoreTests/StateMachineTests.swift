import XCTest
@testable import CizgiCore

final class StateMachineTests: XCTestCase {

    func testHappyPathAdvancesOneStepAtATime() {
        for (index, state) in PipelineStateMachine.happyPath.enumerated()
        where index + 1 < PipelineStateMachine.happyPath.count {
            let next = PipelineStateMachine.happyPath[index + 1]
            XCTAssertTrue(
                PipelineStateMachine.canTransition(from: state, to: next),
                "\(state) -> \(next) yasal olmalı"
            )
        }
    }

    func testCannotSkipSteps() {
        XCTAssertFalse(PipelineStateMachine.canTransition(from: .captured, to: .cardGeneration))
        XCTAssertFalse(PipelineStateMachine.canTransition(from: .localOCR, to: .ready))
    }

    func testReentryIsIdempotent() {
        // Replaying a step must be legal: §17 requires every step to be
        // idempotent so a resumed job does not produce duplicate cards.
        for state in ProcessingState.allCases {
            XCTAssertTrue(PipelineStateMachine.canTransition(from: state, to: state))
        }
    }

    func testFinishedJobNeverMovesAgain() {
        for target in ProcessingState.allCases where target != .ready {
            XCTAssertFalse(
                PipelineStateMachine.canTransition(from: .ready, to: target),
                "ready -> \(target) olmamalı"
            )
        }
    }

    func testCancelledJobNeverMovesAgain() {
        for target in ProcessingState.allCases where target != .cancelled {
            XCTAssertFalse(PipelineStateMachine.canTransition(from: .cancelled, to: target))
        }
    }

    func testUserCanCancelAnUnfinishedJob() {
        XCTAssertTrue(PipelineStateMachine.canTransition(from: .cloudOCR, to: .cancelled))
        XCTAssertTrue(PipelineStateMachine.canTransition(from: .confirmationRequired, to: .cancelled))
    }

    func testConfirmationOnlyComesFromStepsThatCanDiscoverAmbiguity() {
        XCTAssertTrue(
            PipelineStateMachine.canTransition(from: .transcriptionReconciliation, to: .confirmationRequired)
        )
        XCTAssertTrue(
            PipelineStateMachine.canTransition(from: .qualityValidation, to: .confirmationRequired)
        )
        XCTAssertFalse(PipelineStateMachine.canTransition(from: .localOCR, to: .confirmationRequired))
    }

    func testConfirmationResumesAtCardGeneration() {
        XCTAssertTrue(PipelineStateMachine.canTransition(from: .confirmationRequired, to: .cardGeneration))
        XCTAssertFalse(PipelineStateMachine.canTransition(from: .confirmationRequired, to: .ready))
    }

    func testTemporaryFailureCanReenterButNotJumpToReady() {
        XCTAssertTrue(PipelineStateMachine.canTransition(from: .temporaryFailure, to: .localOCR))
        XCTAssertFalse(PipelineStateMachine.canTransition(from: .temporaryFailure, to: .ready))
    }

    func testAutomaticAdvanceStopsWhereTheUserIsNeeded() {
        XCTAssertNil(PipelineStateMachine.nextAutomaticState(after: .confirmationRequired))
        XCTAssertNil(PipelineStateMachine.nextAutomaticState(after: .temporaryFailure))
        XCTAssertNil(PipelineStateMachine.nextAutomaticState(after: .ready))
        XCTAssertEqual(PipelineStateMachine.nextAutomaticState(after: .captured), .localPreprocessing)
    }
}

final class RetryPolicyTests: XCTestCase {

    func testBackoffGrowsAndIsCapped() {
        let policy = RetryPolicy(maxAttempts: 6, baseDelay: 2, maxDelay: 60)
        let noJitter = 1.0
        let delays = (0..<6).map { policy.delay(forAttempt: $0, jitter: noJitter) }
        for (a, b) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
        XCTAssertLessThanOrEqual(delays.last!, 60)
    }

    func testJitterSpreadsRetries() {
        let policy = RetryPolicy(baseDelay: 10, maxDelay: 1000)
        let low = policy.delay(forAttempt: 2, jitter: 0)
        let high = policy.delay(forAttempt: 2, jitter: 1)
        XCTAssertLessThan(low, high)
        XCTAssertGreaterThan(low, 0)
    }

    func testStopsAfterMaxAttempts() {
        let policy = RetryPolicy(maxAttempts: 3)
        XCTAssertTrue(policy.shouldRetry(attempt: 2))
        XCTAssertFalse(policy.shouldRetry(attempt: 3))
    }

    func testSchemaAndConfigErrorsAreNotRetried() {
        // §17: 4xx/schema failures must not loop forever.
        XCTAssertFalse(FailureKind.invalidResponse.isTransient)
        XCTAssertFalse(FailureKind.configuration.isTransient)
        XCTAssertFalse(FailureKind.budgetExceeded.isTransient)
        XCTAssertEqual(FailureKind.configuration.resultingState, .permanentFailure)
    }

    func testNetworkErrorsAreRetried() {
        XCTAssertTrue(FailureKind.network.isTransient)
        XCTAssertEqual(FailureKind.network.resultingState, .temporaryFailure)
    }
}
