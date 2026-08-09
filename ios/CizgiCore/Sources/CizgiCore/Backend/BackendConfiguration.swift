import Foundation

/// Where the backend lives and how long its calls may take.
///
/// This used to sit in `BackendClient.swift` next to the cloud-OCR client;
/// that client left with the deterministic pipeline (ADR-005 trim, 2026-08-09)
/// and the configuration — still used by `BackendCardProvider` and the app's
/// composition root — moved here unchanged.
public struct BackendConfiguration: Sendable, Equatable {
    public var baseURL: URL
    /// Ceiling for one HTTP request.
    public var timeout: TimeInterval
    /// How long `BackendCardProvider` keeps collecting one job's answer.
    public var jobDeadline: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 300, jobDeadline: TimeInterval = 420) {
        self.baseURL = baseURL
        // An upper bound, not a target. Under ADR-006 every card call is either
        // a page upload or a small poll, both of which answer in seconds; this
        // stays generous so the retained synchronous `/api/cards-vision` path
        // (which really can run for minutes) is not cut off by it.
        self.timeout = timeout
        // Seven minutes: comfortably past the backend's own 300 s ceiling, so a
        // job that is going to finish normally does finish inside one call.
        // Passing it is not a lost page — the job keeps running on the server
        // and the next attempt collects it (docs/ADR-006 §4).
        self.jobDeadline = jobDeadline
    }
}
