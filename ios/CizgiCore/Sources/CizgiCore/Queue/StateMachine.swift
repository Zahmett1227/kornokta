import Foundation

/// Legal moves through the capture pipeline (ANA-PLAN §17).
///
/// Kept as pure logic with no SwiftData or I/O so it can be exhaustively
/// tested. Every step must be idempotent and re-entrant: re-processing the same
/// job must not produce a second set of cards (§17), which is why the queue
/// checks `canTransition` instead of blindly advancing.
public enum PipelineStateMachine {

    /// The happy path, in order.
    public static let happyPath: [ProcessingState] = [
        .captured,
        .localPreprocessing,
        .localOCR,
        .markerDetection,
        .cloudOCR,
        .transcriptionReconciliation,
        .cardGeneration,
        .qualityValidation,
        .ready
    ]

    public static func canTransition(from current: ProcessingState, to next: ProcessingState) -> Bool {
        if current == next { return true }  // idempotent re-entry

        // A cancelled or finished job never moves again. Failure is not
        // terminal in the same way: the user can retry it.
        if current == .ready || current == .cancelled { return false }

        switch next {
        case .cancelled:
            // The user may drop a job at any point before it finishes (§17).
            return true
        case .temporaryFailure, .permanentFailure:
            return !current.isTerminal
        case .confirmationRequired:
            // Confirmation is only ever requested from the two steps that can
            // discover ambiguity (§17, §19.2).
            return current == .transcriptionReconciliation || current == .qualityValidation
        default:
            break
        }

        switch current {
        case .confirmationRequired:
            // Once the user answers, the job resumes at card generation.
            return next == .cardGeneration
        case .temporaryFailure:
            // A retry re-enters the pipeline at its first step; the individual
            // steps are idempotent so replaying is safe.
            return happyPath.contains(next) && next != .ready
        case .permanentFailure:
            return next == .captured
        default:
            guard
                let currentIndex = happyPath.firstIndex(of: current),
                let nextIndex = happyPath.firstIndex(of: next)
            else { return false }
            return nextIndex == currentIndex + 1
        }
    }

    /// The next automatic step, or nil when the queue should stop and wait for
    /// the user or for a retry.
    public static func nextAutomaticState(after current: ProcessingState) -> ProcessingState? {
        guard !current.isTerminal, !current.needsUser, current != .temporaryFailure else {
            return nil
        }
        guard
            let index = happyPath.firstIndex(of: current),
            index + 1 < happyPath.count
        else { return nil }
        return happyPath[index + 1]
    }
}

/// Retry policy for transient failures (§17): exponential backoff with jitter,
/// and a hard cap so a permanently broken job stops burning battery.
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 300) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func shouldRetry(attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// Delay before attempt `attempt` (0-based). `jitter` is injected so tests
    /// stay deterministic.
    public func delay(forAttempt attempt: Int, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponential = baseDelay * pow(2, Double(attempt))
        let capped = min(exponential, maxDelay)
        // Full jitter: spread retries so several queued pages do not all wake
        // at the same instant.
        return capped * (0.5 + 0.5 * jitter)
    }
}

/// Why a step failed. Schema and configuration errors must not be retried
/// forever (§17).
public enum FailureKind: Sendable, Equatable {
    case network
    case rateLimited
    case providerUnavailable
    case invalidResponse
    case configuration
    case budgetExceeded

    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .providerUnavailable:
            return true
        case .invalidResponse, .configuration, .budgetExceeded:
            return false
        }
    }

    public var resultingState: ProcessingState {
        isTransient ? .temporaryFailure : .permanentFailure
    }
}
