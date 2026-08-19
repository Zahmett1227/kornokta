import XCTest
@testable import CizgiCore

/// `CoverageAuditProvider.parse` — the one decision in the audit client worth
/// testing directly (this package has no HTTP stub, same constraint that keeps
/// `SecondOpinionProvider.parse` internal).
final class CoverageAuditProviderTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesMarksUncoveredAndUsage() throws {
        let audit = try CoverageAuditProvider.parse(data("""
        {"requestId":"page-1",
         "marks":[{"kind":"handwriting","quote":"hoca notu","coveredByCardIndex":0},
                  {"kind":"symbol","quote":"★ CD30","coveredByCardIndex":null}],
         "uncovered":[{"kind":"symbol","quote":"★ CD30","coveredByCardIndex":null}],
         "discarded":1,
         "usage":{"provider":"gemini","model":"gemini-3.5-flash","inputTokens":1500,
                  "cachedInputTokens":0,"outputTokens":300,"reasoningTokens":120,
                  "estimatedCostUSD":0.0027},
         "promptVersion":"1.0"}
        """))

        // The full register is the denominator: "2 marks seen, 1 uncovered"
        // says something that "1 uncovered" on its own does not.
        XCTAssertEqual(audit.markCount, 2)
        XCTAssertEqual(audit.uncovered.map(\.quote), ["★ CD30"])
        XCTAssertEqual(audit.uncovered.first?.source, .auditor)
        XCTAssertEqual(audit.discarded, 1)
        XCTAssertEqual(audit.usage?.reasoningTokens, 120)
        XCTAssertEqual(audit.promptVersion, "1.0")
    }

    func testUnknownTierDropsOneRowRatherThanTheAnswer() throws {
        let audit = try CoverageAuditProvider.parse(data("""
        {"requestId":"page-1","marks":[],
         "uncovered":[{"kind":"doodle","quote":"bilinmeyen","coveredByCardIndex":null},
                      {"kind":"underline","quote":"altı çizili","coveredByCardIndex":null}],
         "usage":null,"promptVersion":"1.0"}
        """))
        XCTAssertEqual(audit.uncovered.map(\.quote), ["altı çizili"])
    }

    func testMissingOptionalBlocksDecodeToDefaults() throws {
        // `discarded` and `usage` are optional so an older deployment cannot
        // fail the whole response; a missing ledger simply leaves nothing to
        // account, exactly as the second opinion behaves.
        let audit = try CoverageAuditProvider.parse(data("""
        {"requestId":"page-1","marks":[],"uncovered":[]}
        """))
        XCTAssertEqual(audit.discarded, 0)
        XCTAssertNil(audit.usage)
        XCTAssertNil(audit.promptVersion)
    }

    // MARK: Billing (Codex, PR #47)

    func testBillingComesFromTheServerRatherThanFromRetryability() {
        // The two disagree in both directions and only the server can tell them
        // apart: an exhausted quota is retryable and *free* (Gemini rejected the
        // request), a safety stop is permanent and *billed* (it generated
        // first). Deriving billing from `retryable` recorded both backwards.
        let freeButRetryable = CoverageAuditError.server("kota tükendi", retryable: true, billing: "none")
        XCTAssertEqual(freeButRetryable.billing, ModelRunBilling.none)
        XCTAssertTrue(freeButRetryable.retryable)

        let billedButPermanent = CoverageAuditError.server(
            "üretim temiz bitmedi", retryable: false, billing: "unmeasured"
        )
        XCTAssertEqual(billedButPermanent.billing, ModelRunBilling.unmeasured)
        XCTAssertFalse(billedButPermanent.retryable)
    }

    func testAServerAnswerWithNoVerdictIsFree() {
        // The server states the verdict on every failure it produces, so an
        // absent one means the answer never came from an audit: a refusal from
        // the composition root (missing GEMINI_API_KEY) or a deployment with no
        // `/api/coverage` at all. Reading that as "possibly billed" put
        // configuration errors in the cost screen as spend (Codex, PR #47).
        XCTAssertEqual(
            CoverageAuditError.server("Eksik ortam değişkeni: GEMINI_API_KEY.", retryable: false, billing: nil).billing,
            ModelRunBilling.none
        )
        // Nothing was ever sent, so nothing can have been billed.
        XCTAssertEqual(CoverageAuditError.notConfigured.billing, ModelRunBilling.none)
    }

    func testFailuresAfterTheRequestLeftStayPossiblyBilled() {
        // These happen after the bytes were sent: the model may have generated
        // and been billed without us ever learning the amount, and there
        // overstating is the safe direction.
        XCTAssertEqual(CoverageAuditError.transport("ağ koptu").billing, ModelRunBilling.unmeasured)
        XCTAssertEqual(CoverageAuditError.invalidResponse("bozuk gövde").billing, ModelRunBilling.unmeasured)
        XCTAssertEqual(
            CoverageAuditError.server("üretim temiz bitmedi", retryable: false, billing: "unmeasured").billing,
            ModelRunBilling.unmeasured
        )
    }

    func testGarbageIsReportedAsAnInvalidResponse() {
        // Not retryable and not silent: the caller shows the message rather
        // than pretending the page has no uncovered marks.
        XCTAssertThrowsError(try CoverageAuditProvider.parse(data("{bozuk"))) { error in
            guard case CoverageAuditError.invalidResponse = error else {
                return XCTFail("Beklenen invalidResponse, alınan: \(error)")
            }
        }
    }
}
