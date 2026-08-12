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
    /// The model read the page and found nothing to build a card from.
    ///
    /// Not the same as a broken response, and it stopped being a rare case the
    /// moment photos could come from the library: a picture that is not a book
    /// page at all lands here. It used to be reported as `invalidResponse`,
    /// which reads as "the server is broken" when the honest answer is "there
    /// was nothing marked on this one".
    case noContent

    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .providerUnavailable:
            return true
        case .invalidResponse, .configuration, .budgetExceeded, .noContent:
            return false
        }
    }

    /// What the queue shows the user *when the server said nothing more
    /// specific*.
    ///
    /// The queue used to print `String(describing:)` of this enum, so a real
    /// person read "invalidResponse" in a Turkish interface and could not tell
    /// whether to retry, re-shoot, or check the settings.
    ///
    /// It is now a fallback rather than the whole story. These sentences are
    /// classifications, and a classification cannot distinguish a page that is
    /// merely still generating (free, collected on the next attempt) from one
    /// whose output budget was burned and thrown away (paid, twice). Both read
    /// "Sağlayıcıya ulaşılamadı" and both looked identical on screen — which is
    /// exactly why the cost question could not be answered from the phone.
    /// `PipelineOutcome.failureDetail` carries the server's own words and is
    /// preferred wherever it exists.
    public var message: String {
        switch self {
        case .network:
            return "İnternet bağlantısı kurulamadı. Ağ gelince kendiliğinden yeniden denenecek."
        case .rateLimited:
            return "Sağlayıcı çok fazla istek aldı ya da kotası doldu. Biraz sonra yeniden denenecek."
        case .providerUnavailable:
            return "Sağlayıcıya ulaşılamadı. Yeniden denenecek."
        case .invalidResponse:
            return "Sunucudan beklenmeyen bir yanıt geldi. \"Tekrar dene\" ile yeniden denenebilir."
        case .configuration:
            return "Backend adresi veya cihaz anahtarı eksik. Ayarlar'dan tamamla."
        case .budgetExceeded:
            return "Maliyet üst sınırına ulaşıldı."
        case .noContent:
            return "Bu fotoğrafta işaretlenmiş bir şey bulunamadı. Fosforlu/altı çizili bir sayfa olduğundan emin ol."
        }
    }

    public var resultingState: ProcessingState {
        isTransient ? .temporaryFailure : .permanentFailure
    }
}
