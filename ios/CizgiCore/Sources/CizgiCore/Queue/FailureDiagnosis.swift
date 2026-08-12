import Foundation

/// Turning what the server said into what the user reads and what the queue does.
///
/// Split out of `CapturePipeline` for one reason: this is the logic that was
/// silently wrong for months, and it is the only part of the failure path that
/// depends on nothing but `FailureKind` and two strings — so it can be tested
/// for real on any machine, rather than only in a simulator on a Mac.
///
/// The bug it exists to prevent: `CapturePipeline` classified every failure
/// into a `FailureKind` and threw the server's message away. Five very
/// different events — a job still generating happily (free, collected on the
/// next poll), a generation aborted at the timeout (billed, result lost), a
/// response truncated at `max_output_tokens` (billed in full, nothing usable),
/// an exhausted API quota (needs a top-up, will never fix itself) and a dropped
/// connection (free) — all arrived on screen as the same six words:
/// "Sağlayıcıya ulaşılamadı. Yeniden denenecek." Nothing the user could see
/// distinguished the free cases from the expensive ones.
public enum FailureDiagnosis {

    /// The server's own sentence, or nil when there is nothing worth showing.
    ///
    /// Trimmed and emptiness-checked rather than passed through: an empty
    /// string would replace a useful classification message with a blank row,
    /// which is worse than the generic sentence it displaced.
    public static func detail(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sharpens a classification using the machine-readable reason the backend
    /// records for the cost ledger.
    ///
    /// The phone never sees the *provider's* HTTP status — it only ever talks
    /// to our own backend — so a rate limit and an exhausted quota used to be
    /// indistinguishable from a dropped connection, and `FailureKind
    /// .rateLimited` sat in the enum with nothing in the app able to produce
    /// it. The reason string is the missing signal, reused rather than
    /// re-derived by sniffing Turkish prose out of an error message.
    ///
    /// Deliberately only ever narrows *within* the transient family. Which
    /// failures are worth retrying is the server's decision (§17), and an
    /// unrecognised reason must leave that decision alone rather than guess —
    /// turning a retryable failure permanent on an unknown string would lock a
    /// page out of generation for good, since the job id is the page id.
    public static func refine(_ kind: FailureKind, using reason: String?) -> FailureKind {
        guard kind == .providerUnavailable, let reason else { return kind }
        switch reason {
        case "http_429", "insufficient_quota":
            return .rateLimited
        default:
            return kind
        }
    }

    /// What a queue row shows under a failed page.
    ///
    /// The server's sentence wins whenever there is one. The two are not
    /// competing descriptions of the same event: the classification's message
    /// says what happens next ("yeniden denenecek"), which the row already
    /// conveys with a state label and an icon, while the server's says what
    /// actually happened — and that is the half that was missing.
    public static func text(detail: String?, kind: FailureKind?) -> String? {
        detail ?? kind?.message
    }
}
