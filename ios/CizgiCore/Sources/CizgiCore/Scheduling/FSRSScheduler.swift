import Foundation

/// FSRS-6, the real spaced-repetition algorithm (ANA-PLAN §18.1), replacing
/// `PlaceholderScheduler` behind the same `ReviewScheduling` seam — nothing
/// downstream (`ReviewView`, `ReviewSessionPlanner`, the SwiftData `Card`
/// fields) changes shape.
///
/// This is a line-for-line port of `evals/fsrs/algorithm.py`, which carries
/// the full derivation and provenance notes; `FSRSSchedulerTests.swift`
/// checks both sides against the same generated case file
/// (`evals/shared/fsrs-cases.json`) so a divergence between the two
/// languages fails a test rather than surfacing as a wrong due date months
/// later (§18.1: "birim testleri referans implementasyonla
/// karşılaştırılmalıdır").
///
/// Three choices the algorithm spec leaves to the implementer, made the same
/// way here as in the Python reference:
/// - Elapsed time between reviews is a continuous duration
///   (`now.timeIntervalSince(lastReviewedAt) / 1 day`), never a calendar-date
///   difference — a calendar-day boundary shifts when the device's time zone
///   changes, which is exactly the "time zone change causes a lost or
///   doubled review" failure §18.1 forbids.
/// - "Same-day" (the short-term stability formula) is `elapsedDays < 1.0`,
///   not a calendar-day equality check, for the same reason.
/// - Stability is floored at a small positive epsilon; the algorithm spec
///   does not state one, and this module's own defensive addition avoids
///   `pow(S, -w9)` and `S / factor` blowing up at S=0.
public struct FSRSScheduler: ReviewScheduling {
    private let weights: FSRSWeights

    public init(weights: FSRSWeights) {
        self.weights = weights
    }

    /// Loads the bundled weights. Throws rather than falling back to built-in
    /// numbers, the same discipline `MarkerConfig`-backed components use.
    public init() throws {
        self.init(weights: try FSRSWeights.bundled())
    }

    static let minDifficulty = 1.0
    static let maxDifficulty = 10.0
    static let minStability = 0.01
    static let maxIntervalDays = 36_500.0

    public func schedule(rating: ReviewRating, state: SchedulingState, now: Date) -> SchedulingResult {
        let w = weights.weights
        let g = Self.numericRating(rating)

        let stability: Double
        let difficulty: Double

        if state.reviewCount == 0 || state.lastReviewedAt == nil {
            difficulty = Self.initDifficulty(g, w)
            stability = Self.initStability(g, w)
        } else {
            let elapsedDays = now.timeIntervalSince(state.lastReviewedAt!) / 86_400
            difficulty = Self.nextDifficulty(state.difficulty, g, w)
            if elapsedDays < 1.0 {
                stability = Self.nextStabilityShortTerm(state.stability, g, w)
            } else {
                let r = Self.retrievability(elapsedDays, state.stability, w)
                if g == 1 {
                    stability = Self.nextStabilityFailure(state.difficulty, state.stability, r, w)
                } else {
                    stability = Self.nextStabilitySuccess(state.difficulty, state.stability, r, g, w)
                }
            }
        }

        let intervalDays = Self.nextInterval(stability, w, weights.desiredRetention)
        let due = now.addingTimeInterval(intervalDays * 86_400)

        return SchedulingResult(
            dueDate: due,
            stability: stability,
            difficulty: difficulty,
            scheduledDays: intervalDays
        )
    }

    /// FSRS's own convention: Again=1, Hard=2, Good=3, Easy=4 — the same
    /// order ANA-PLAN §18.2 lists the four ratings in.
    static func numericRating(_ rating: ReviewRating) -> Int {
        switch rating {
        case .again: return 1
        case .hard: return 2
        case .good: return 3
        case .easy: return 4
        }
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        max(low, min(high, value))
    }

    static func initDifficulty(_ g: Int, _ w: [Double]) -> Double {
        let d0 = w[4] - exp(w[5] * Double(g - 1)) + 1
        return clamp(d0, minDifficulty, maxDifficulty)
    }

    static func initStability(_ g: Int, _ w: [Double]) -> Double {
        max(w[g - 1], minStability)
    }

    static func nextDifficulty(_ difficulty: Double, _ g: Int, _ w: [Double]) -> Double {
        let deltaD = -w[6] * Double(g - 3)
        let linearDamped = difficulty + deltaD * (10 - difficulty) / 9
        let d0Easy = w[4] - exp(w[5] * 3) + 1
        let reverted = w[7] * d0Easy + (1 - w[7]) * linearDamped
        return clamp(reverted, minDifficulty, maxDifficulty)
    }

    static func retrievability(_ elapsedDays: Double, _ stability: Double, _ w: [Double]) -> Double {
        let decay = -w[20]
        let factor = pow(0.9, 1 / decay) - 1
        return pow(1 + factor * elapsedDays / stability, decay)
    }

    static func nextInterval(_ stability: Double, _ w: [Double], _ desiredRetention: Double) -> Double {
        let decay = -w[20]
        let factor = pow(0.9, 1 / decay) - 1
        let days = (stability / factor) * (pow(desiredRetention, 1 / decay) - 1)
        return clamp(days, 0, maxIntervalDays)
    }

    static func nextStabilitySuccess(
        _ difficulty: Double, _ stability: Double, _ r: Double, _ g: Int, _ w: [Double]
    ) -> Double {
        // Hard=2 and Easy=4 only; Good=3 gets neither (implicit factor 1).
        let hardPenalty = g == 2 ? w[15] : 1.0
        let easyBonus = g == 4 ? w[16] : 1.0
        let increase = 1
            + exp(w[8])
            * (11 - difficulty)
            * pow(stability, -w[9])
            * (exp((1 - r) * w[10]) - 1)
            * hardPenalty
            * easyBonus
        return max(stability * increase, minStability)
    }

    static func nextStabilityFailure(
        _ difficulty: Double, _ stability: Double, _ r: Double, _ w: [Double]
    ) -> Double {
        let value = w[11]
            * pow(difficulty, -w[12])
            * (pow(stability + 1, w[13]) - 1)
            * exp((1 - r) * w[14])
        return max(value, minStability)
    }

    static func nextStabilityShortTerm(_ stability: Double, _ g: Int, _ w: [Double]) -> Double {
        let increase = exp(w[17] * (Double(g - 3) + w[18])) * pow(stability, -w[19])
        return max(stability * increase, minStability)
    }
}
