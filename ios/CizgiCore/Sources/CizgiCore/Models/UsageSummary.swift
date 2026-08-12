import Foundation

/// The three things that can be known about a call's billing.
///
/// Plain strings rather than an enum because this is persisted: a value the
/// server adds later must not make an existing store undecodable, which is the
/// same rule `CardType` and the gate's `decision` already follow. It lives here
/// rather than beside `ModelRun` so the whole accounting vocabulary stays
/// Foundation-only and can be tested without SwiftData.
public enum ModelRunBilling {
    /// The provider reported usage; the token counts are real.
    public static let measured = "measured"
    /// The request reached the model but no usage ever came back — our timeout
    /// aborted it, or the worker was killed mid-generation. Billed; unmeasurable.
    public static let unmeasured = "unmeasured"
    /// Rejected before any generation happened. Genuinely free.
    public static let none = "none"
}

/// Aggregation of the provider-call ledger for Ayarlar → Kullanım (§16.8, §20.3).
///
/// Deliberately Foundation-only and free of SwiftData: the arithmetic here is
/// the part that can be wrong in a way nobody notices — a total that quietly
/// reads low is indistinguishable from a cheap month — so it has to be testable
/// on its own, without a simulator. `SettingsView` projects its `ModelRun`
/// rows into `UsageEntry` and asks this for the answer.
///
/// The one rule everything below follows: **money is only ever added up from
/// calls whose cost was actually measured.** A call that was billed but never
/// reported its usage is counted, named and shown as a count — never averaged
/// into a figure, because a plausible invented number is worse than an honest
/// "we don't know" (§0.6).
public struct UsageEntry: Sendable, Equatable {
    public let purpose: String
    public let model: String
    public let success: Bool
    /// One of `ModelRunBilling`'s three values.
    public let billing: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let estimatedCostUSD: Double

    public init(
        purpose: String,
        model: String,
        success: Bool,
        billing: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int,
        estimatedCostUSD: Double
    ) {
        self.purpose = purpose
        self.model = model
        self.success = success
        self.billing = billing
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct UsageSummary: Sendable, Equatable {
    public var callCount: Int = 0
    public var successCount: Int = 0
    /// Failed, and we know what it cost. The number that used to be missing
    /// entirely: this is money spent on pages that produced nothing.
    public var billedFailureCount: Int = 0
    /// Failed after reaching the model, with no usage ever reported — our own
    /// timeout, or a worker killed mid-generation. Billed; amount unknowable.
    public var unmeasuredCount: Int = 0
    /// Rejected before generating (rate limit, bad key, exhausted quota).
    /// Genuinely free, and counted separately so it cannot be mistaken for a
    /// suspiciously cheap real call.
    public var freeFailureCount: Int = 0

    /// Everything measured, successes and failures alike.
    public var totalCostUSD: Double = 0
    /// The measured share that bought nothing.
    public var wastedCostUSD: Double = 0

    public var inputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    public var outputTokens: Int = 0
    public var reasoningTokens: Int = 0

    public init() {}

    /// Average over *measured* calls only — the unmeasured ones would drag it
    /// toward zero and make every page look cheaper than it was.
    public var averageCostPerMeasuredCallUSD: Double {
        let measured = successCount + billedFailureCount
        return measured > 0 ? totalCostUSD / Double(measured) : 0
    }

    /// Share of measured spend that produced no cards, 0...1.
    public var wastedShare: Double {
        totalCostUSD > 0 ? wastedCostUSD / totalCostUSD : 0
    }

    /// Share of input tokens served from the provider's cache, 0...1. Low here
    /// means the prompt prefix is not being reused — worth knowing before
    /// paying full price for the same instructions on every page.
    public var cacheHitShare: Double {
        inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : 0
    }

    /// Share of output tokens spent on hidden thinking rather than cards.
    /// Output is the most expensive thing here, so this is where "am I paying
    /// for reasoning I don't need?" gets answered.
    public var reasoningShare: Double {
        outputTokens > 0 ? Double(reasoningTokens) / Double(outputTokens) : 0
    }

    /// True when at least one call is known to have been billed without
    /// reporting how much — the point at which this screen stops being able to
    /// promise it matches the provider's invoice, and has to say so.
    public var hasUnmeasuredSpend: Bool { unmeasuredCount > 0 }

    public static func of(_ entries: [UsageEntry]) -> UsageSummary {
        var summary = UsageSummary()
        for entry in entries {
            summary.callCount += 1

            switch entry.billing {
            case ModelRunBilling.unmeasured:
                summary.unmeasuredCount += 1
                // No tokens and no money: there is nothing to add. Adding its
                // zero cost to the total would be arithmetically harmless and
                // narratively false — it is counted, above, precisely so the
                // screen can say the total is a floor rather than a figure.
                continue
            case ModelRunBilling.none:
                summary.freeFailureCount += 1
                continue
            default:
                break
            }

            if entry.success {
                summary.successCount += 1
            } else {
                summary.billedFailureCount += 1
                summary.wastedCostUSD += entry.estimatedCostUSD
            }
            summary.totalCostUSD += entry.estimatedCostUSD
            summary.inputTokens += entry.inputTokens
            summary.cachedInputTokens += entry.cachedInputTokens
            summary.outputTokens += entry.outputTokens
            summary.reasoningTokens += entry.reasoningTokens
        }
        return summary
    }

    /// One summary per model, most expensive first.
    ///
    /// Exists for the model comparison (Sol / Terra / Luna): running one week
    /// on each and reading the two rows side by side is the only measurement
    /// that answers "does the cheaper tier cost me quality on *my* pages?" with
    /// real money attached. Unnamed models — a failed call has no model id to
    /// report — are grouped under an empty key rather than dropped, so the row
    /// counts still sum to the total.
    public static func byModel(_ entries: [UsageEntry]) -> [(model: String, summary: UsageSummary)] {
        var grouped: [String: [UsageEntry]] = [:]
        for entry in entries { grouped[entry.model, default: []].append(entry) }
        return grouped
            .map { (model: $0.key, summary: UsageSummary.of($0.value)) }
            .sorted { left, right in
                if left.summary.totalCostUSD != right.summary.totalCostUSD {
                    return left.summary.totalCostUSD > right.summary.totalCostUSD
                }
                return left.model < right.model
            }
    }
}
