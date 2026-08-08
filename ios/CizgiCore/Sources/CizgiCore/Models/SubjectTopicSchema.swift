import Foundation

/// Canonical ders → konu template (subject picker, library filters, and the
/// on-device check of model-assigned topics).
///
/// Loaded from `Resources/subject_topics.json`, a byte-identical copy of
/// `backend/schemas/subject_topics.json` — a vitest in the backend suite
/// fails if the two drift apart, the same arrangement `FSRSWeights` already
/// uses. The names originate in the tusoskop project's
/// `subjectTopicSchema.js` and are hand-synced (see the JSON's `_comment`).
///
/// Topic names are unique only within a subject ("İmmünoloji" exists under
/// both Patoloji and Mikrobiyoloji), so validity is always a
/// (subject, topic) pair.
public struct SubjectTopicSchema: Codable, Sendable, Equatable {
    public struct Subject: Codable, Sendable, Equatable {
        public let name: String
        public let topics: [String]
    }

    public let version: Int
    public let subjects: [Subject]

    public enum LoadError: Error, Sendable {
        case missingResource
        case unreadable(String)
        case empty
    }

    /// Reads the bundled template.
    ///
    /// Throws rather than falling back to a built-in list, for the same
    /// reason `FSRSWeights.bundled()` does: a silent fallback would mean
    /// classifying cards against names nobody chose. Callers hide the
    /// subject/topic UI when this fails instead of crashing.
    public static func bundled() throws -> SubjectTopicSchema {
        try bundled(bundle: .module)
    }

    static func bundled(bundle: Bundle) throws -> SubjectTopicSchema {
        guard let url = bundle.url(forResource: "subject_topics", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try load(contentsOf: url)
    }

    public static func load(contentsOf url: URL) throws -> SubjectTopicSchema {
        let decoded: SubjectTopicSchema
        do {
            decoded = try JSONDecoder().decode(SubjectTopicSchema.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        guard !decoded.subjects.isEmpty else { throw LoadError.empty }
        return decoded
    }

    public var subjectNames: [String] {
        subjects.map(\.name)
    }

    public func topics(for subject: String) -> [String]? {
        subjects.first(where: { $0.name == subject })?.topics
    }

    public func isValidTopic(_ topic: String, subject: String) -> Bool {
        topics(for: subject)?.contains(topic) ?? false
    }

    /// Maps free-form input (the legacy Settings text field, or a hand-typed
    /// value from a backup) onto a canonical subject name.
    ///
    /// Comparison is trimmed and case-insensitive under the Turkish locale so
    /// "patoloji" and "PATOLOJİ" (dotted İ) both resolve to "Patoloji".
    /// Returns nil when nothing matches — callers treat that as "no subject",
    /// never as a new subject name.
    public func canonicalSubject(matching raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let locale = Locale(identifier: "tr")
        let needle = trimmed.lowercased(with: locale)
        return subjects.first(where: { $0.name.lowercased(with: locale) == needle })?.name
    }
}
