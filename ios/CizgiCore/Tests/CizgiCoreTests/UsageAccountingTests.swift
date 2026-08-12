import XCTest
@testable import CizgiCore

private func entry(
    purpose: String = "card_generation",
    model: String = "gpt-5.6-sol",
    success: Bool,
    billing: String,
    input: Int = 0,
    cached: Int = 0,
    output: Int = 0,
    reasoning: Int = 0,
    cost: Double = 0
) -> UsageEntry {
    UsageEntry(
        purpose: purpose, model: model, success: success, billing: billing,
        inputTokens: input, cachedInputTokens: cached,
        outputTokens: output, reasoningTokens: reasoning, estimatedCostUSD: cost
    )
}

final class UsageSummaryTests: XCTestCase {

    func testWastedSpendIsSeparatedFromTheTotal() {
        // The number the old screen could not show at all: money spent on calls
        // that produced no cards.
        let summary = UsageSummary.of([
            entry(success: true, billing: ModelRunBilling.measured, cost: 0.06),
            entry(success: false, billing: ModelRunBilling.measured, cost: 0.24),
            entry(success: true, billing: ModelRunBilling.measured, cost: 0.10),
        ])
        XCTAssertEqual(summary.callCount, 3)
        XCTAssertEqual(summary.successCount, 2)
        XCTAssertEqual(summary.billedFailureCount, 1)
        XCTAssertEqual(summary.totalCostUSD, 0.40, accuracy: 1e-9)
        XCTAssertEqual(summary.wastedCostUSD, 0.24, accuracy: 1e-9)
        XCTAssertEqual(summary.wastedShare, 0.6, accuracy: 1e-9)
    }

    func testUnmeasuredCallsAreCountedButNeverPriced() {
        // A call aborted at the timeout was billed and never said how much.
        // Averaging it in would invent a number; dropping it would hide the
        // failure mode. It is counted, and the screen says the total is a floor.
        let summary = UsageSummary.of([
            entry(success: true, billing: ModelRunBilling.measured, cost: 0.10),
            entry(success: false, billing: ModelRunBilling.unmeasured),
            entry(success: false, billing: ModelRunBilling.unmeasured),
        ])
        XCTAssertEqual(summary.callCount, 3)
        XCTAssertEqual(summary.unmeasuredCount, 2)
        XCTAssertTrue(summary.hasUnmeasuredSpend)
        XCTAssertEqual(summary.totalCostUSD, 0.10, accuracy: 1e-9)
        XCTAssertEqual(summary.billedFailureCount, 0)
        // Averaged over the one measured call, not over all three.
        XCTAssertEqual(summary.averageCostPerMeasuredCallUSD, 0.10, accuracy: 1e-9)
    }

    func testRejectedCallsAreFreeAndDoNotDragTheAverageDown() {
        let summary = UsageSummary.of([
            entry(success: true, billing: ModelRunBilling.measured, cost: 0.10),
            entry(success: false, billing: ModelRunBilling.none),
            entry(success: false, billing: ModelRunBilling.none),
        ])
        XCTAssertEqual(summary.freeFailureCount, 2)
        XCTAssertFalse(summary.hasUnmeasuredSpend)
        XCTAssertEqual(summary.averageCostPerMeasuredCallUSD, 0.10, accuracy: 1e-9)
    }

    func testCacheAndReasoningSharesAreSubsetsNotAdditions() {
        let summary = UsageSummary.of([
            entry(success: true, billing: ModelRunBilling.measured,
                  input: 4000, cached: 3000, output: 2000, reasoning: 1200, cost: 0.07)
        ])
        XCTAssertEqual(summary.inputTokens, 4000)
        XCTAssertEqual(summary.cacheHitShare, 0.75, accuracy: 1e-9)
        XCTAssertEqual(summary.outputTokens, 2000)
        XCTAssertEqual(summary.reasoningShare, 0.6, accuracy: 1e-9)
    }

    func testSharesAreZeroRatherThanNaNWhenThereAreNoTokens() {
        // Every one of these divides by a count that can legitimately be zero.
        let summary = UsageSummary.of([entry(success: false, billing: ModelRunBilling.unmeasured)])
        XCTAssertEqual(summary.cacheHitShare, 0)
        XCTAssertEqual(summary.reasoningShare, 0)
        XCTAssertEqual(summary.wastedShare, 0)
        XCTAssertEqual(summary.averageCostPerMeasuredCallUSD, 0)
    }

    func testEmptyLedgerIsAllZeros() {
        XCTAssertEqual(UsageSummary.of([]), UsageSummary())
    }

    func testPerModelBreakdownSumsBackToTheWholeAndSortsByCost() {
        // The measurement a model change needs: two rows, real money on each.
        let entries = [
            entry(model: "gpt-5.6-sol", success: true, billing: ModelRunBilling.measured, cost: 0.30),
            entry(model: "gpt-5.6-terra", success: true, billing: ModelRunBilling.measured, cost: 0.12),
            entry(model: "gpt-5.6-terra", success: false, billing: ModelRunBilling.measured, cost: 0.05),
            entry(model: "", success: false, billing: ModelRunBilling.unmeasured),
        ]
        let rows = UsageSummary.byModel(entries)

        XCTAssertEqual(rows.map(\.model), ["gpt-5.6-sol", "gpt-5.6-terra", ""])
        XCTAssertEqual(rows[0].summary.totalCostUSD, 0.30, accuracy: 1e-9)
        XCTAssertEqual(rows[1].summary.totalCostUSD, 0.17, accuracy: 1e-9)
        XCTAssertEqual(rows[1].summary.wastedCostUSD, 0.05, accuracy: 1e-9)
        // The unnamed row exists rather than being dropped, so the counts still
        // add up to the whole ledger.
        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.callCount }, entries.count)
    }
}

final class FailureDiagnosisTests: XCTestCase {

    func testServerMessageWinsOverTheGenericClassification() {
        // The whole point: these two used to print the same six words.
        XCTAssertEqual(
            FailureDiagnosis.text(
                detail: "Model üretimi tamamlamadı: max_output_tokens.",
                kind: .providerUnavailable
            ),
            "Model üretimi tamamlamadı: max_output_tokens."
        )
        XCTAssertEqual(
            FailureDiagnosis.text(detail: nil, kind: .providerUnavailable),
            FailureKind.providerUnavailable.message
        )
    }

    func testBlankServerMessageFallsBackRatherThanShowingAnEmptyRow() {
        XCTAssertNil(FailureDiagnosis.detail("   \n "))
        XCTAssertNil(FailureDiagnosis.detail(nil))
        XCTAssertEqual(FailureDiagnosis.detail("  boşluklu  "), "boşluklu")
    }

    func testQuotaAndRateLimitBecomeRateLimitedRatherThanUnreachable() {
        // `.rateLimited` existed in the enum with nothing able to produce it,
        // because the phone never sees the provider's HTTP status.
        XCTAssertEqual(FailureDiagnosis.refine(.providerUnavailable, using: "http_429"), .rateLimited)
        XCTAssertEqual(
            FailureDiagnosis.refine(.providerUnavailable, using: "insufficient_quota"),
            .rateLimited
        )
    }

    func testAnUnknownReasonChangesNothing() {
        // An unrecognised reason must not turn a retryable failure permanent:
        // the job id is the page id, so that would lock the page out for good.
        XCTAssertEqual(
            FailureDiagnosis.refine(.providerUnavailable, using: "brand_new_server_reason"),
            .providerUnavailable
        )
        XCTAssertTrue(FailureDiagnosis.refine(.providerUnavailable, using: "timeout").isTransient)
    }

    func testRefineNeverTouchesAKindItDoesNotOwn() {
        XCTAssertEqual(FailureDiagnosis.refine(.invalidResponse, using: "http_429"), .invalidResponse)
        XCTAssertEqual(FailureDiagnosis.refine(.noContent, using: "http_429"), .noContent)
        XCTAssertEqual(FailureDiagnosis.refine(.configuration, using: "insufficient_quota"), .configuration)
    }

    func testRateLimitedStaysTransientSoThePageIsRetried() {
        XCTAssertTrue(FailureKind.rateLimited.isTransient)
        XCTAssertEqual(FailureKind.rateLimited.resultingState, .temporaryFailure)
    }
}
