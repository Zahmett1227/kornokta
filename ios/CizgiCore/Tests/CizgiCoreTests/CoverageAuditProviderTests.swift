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
