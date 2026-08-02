import Foundation

/// Thresholds for marker detection (ANA-PLAN §9.3).
///
/// Loaded from `Resources/marker-detection-config.json`, a byte-identical copy
/// of `evals/spikes/marker_detection/config.json` — a Python test fails if the
/// two drift apart. They are data, not code: §0.6 requires thresholds to be
/// changeable without editing source, and these will change when the gold set
/// is used to calibrate them.
public struct MarkerConfig: Codable, Sendable, Equatable {
    public struct ConfidenceWeights: Codable, Sendable, Equatable {
        public let markerOverlap: Double
        public let lineGeometry: Double
        public let localOCRConfidence: Double
        public let documentQuality: Double
        public let neighboringLineSeparation: Double
    }

    public struct DecisionThresholds: Codable, Sendable, Equatable {
        public let autoCandidate: Double
        public let quickConfirm: Double
    }

    public struct Highlight: Codable, Sendable, Equatable {
        public let minSaturation: Double
        public let minValue: Double
        /// Hue ranges per colour, on OpenCV's 0–179 scale. Pink wraps past the
        /// end of the scale, which is why a colour can carry several ranges.
        public let colorHueRangesHSV: [String: [[Double]]]
        public let minOverlapRatio: Double
    }

    public struct Underline: Codable, Sendable, Equatable {
        public let bandHeightRatio: Double
        public let minDarkPixelRatio: Double
        public let minHorizontalExtentRatio: Double
        public let maxComponentThicknessRatio: Double
        public let penOverhangToleranceRatio: Double
        public let overrunMarginRatio: Double
        public let maxOutsideOverrunRatio: Double
    }

    public let confidenceWeights: ConfidenceWeights
    public let decisionThresholds: DecisionThresholds
    public let highlight: Highlight
    public let underline: Underline

    /// Every hue range, flattened. Built once because the mask test runs per
    /// pixel and re-walking the dictionary there would dominate the cost.
    public var hueRanges: [(low: Double, high: Double)] {
        highlight.colorHueRangesHSV.values.flatMap { ranges in
            ranges.compactMap { range in
                guard range.count == 2 else { return nil }
                return (range[0], range[1])
            }
        }
    }

    public enum LoadError: Error, Sendable {
        case missingResource
        case unreadable(String)
    }

    /// Reads the bundled thresholds.
    ///
    /// Throws rather than falling back to built-in numbers: a silent fallback
    /// would mean the phone detecting with values nobody chose, and the
    /// mismatch with the measured report would be invisible.
    public static func bundled(bundle: Bundle = .module) throws -> MarkerConfig {
        guard let url = bundle.url(forResource: "marker-detection-config", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try load(contentsOf: url)
    }

    public static func load(contentsOf url: URL) throws -> MarkerConfig {
        do {
            return try JSONDecoder().decode(MarkerConfig.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
    }
}
