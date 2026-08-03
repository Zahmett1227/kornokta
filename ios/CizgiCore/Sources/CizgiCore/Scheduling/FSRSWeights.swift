import Foundation

/// FSRS-6 weights and target retention (ANA-PLAN §18.1).
///
/// Loaded from `Resources/fsrs-weights.json`, a byte-identical copy of
/// `evals/fsrs/weights.json` — a Python test fails if the two drift apart,
/// the same arrangement `MarkerConfig` already uses for its own thresholds.
/// These are the open-spaced-repetition project's published defaults, not a
/// number this codebase invented (§0.6) — see the JSON file's own comment
/// for provenance.
public struct FSRSWeights: Codable, Sendable, Equatable {
    public let version: String
    public let weights: [Double]
    public let desiredRetention: Double

    public enum LoadError: Error, Sendable {
        case missingResource
        case unreadable(String)
        case wrongWeightCount(Int)
    }

    /// Reads the bundled weights.
    ///
    /// Throws rather than falling back to built-in numbers, for the same
    /// reason `MarkerConfig.bundled()` does: a silent fallback would mean
    /// scheduling with values nobody chose.
    public static func bundled() throws -> FSRSWeights {
        try bundled(bundle: .module)
    }

    static func bundled(bundle: Bundle) throws -> FSRSWeights {
        guard let url = bundle.url(forResource: "fsrs-weights", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try load(contentsOf: url)
    }

    public static func load(contentsOf url: URL) throws -> FSRSWeights {
        let decoded: FSRSWeights
        do {
            decoded = try JSONDecoder().decode(FSRSWeights.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        guard decoded.weights.count == 21 else {
            throw LoadError.wrongWeightCount(decoded.weights.count)
        }
        return decoded
    }
}
