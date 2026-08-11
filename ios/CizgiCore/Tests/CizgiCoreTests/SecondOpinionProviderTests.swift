import XCTest
@testable import CizgiCore

/// `SecondOpinionProvider.parse` is the piece worth testing directly — this
/// package has no HTTP stub (see `BackendCardProviderTests`'s header), and the
/// parse is where the wire contract's lenient-verdict rule actually lives.
final class SecondOpinionProviderTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesAFullResponse() throws {
        let opinion = try SecondOpinionProvider.parse(data(
            """
            {"requestId":"r1","verdict":"contradicts","reading":"hipokalemi",
             "note":"Önek ters okunmuş.","promptVersion":"2.0"}
            """
        ))
        XCTAssertEqual(opinion.verdict, .contradicts)
        XCTAssertEqual(opinion.verdictRaw, "contradicts")
        XCTAssertEqual(opinion.reading, "hipokalemi")
        XCTAssertEqual(opinion.note, "Önek ters okunmuş.")
    }

    func testMissingNoteAndPromptVersionDecodeToNil() throws {
        // promptVersion arrived with the endpoint, but the decoder must not
        // depend on it — the same forward-compatibility stance as the rest of
        // the wire types.
        let opinion = try SecondOpinionProvider.parse(data(
            #"{"requestId":"r1","verdict":"supports","reading":"aynı metin"}"#
        ))
        XCTAssertEqual(opinion.verdict, .supports)
        XCTAssertNil(opinion.note)
    }

    func testBlankNoteCollapsesToNil() throws {
        let opinion = try SecondOpinionProvider.parse(data(
            #"{"requestId":"r1","verdict":"unclear","reading":"okunamıyor","note":"  "}"#
        ))
        XCTAssertEqual(opinion.verdict, .unclear)
        XCTAssertNil(opinion.note)
    }

    func testUnknownVerdictKeepsTheRawStringInsteadOfFailing() throws {
        // A server-side addition must not fail the whole response on an older
        // client — same rule as `RemoteJobView.status`.
        let opinion = try SecondOpinionProvider.parse(data(
            #"{"requestId":"r1","verdict":"partially_supports","reading":"..."}"#
        ))
        XCTAssertNil(opinion.verdict)
        XCTAssertEqual(opinion.verdictRaw, "partially_supports")
    }

    func testMalformedBodyThrowsInvalidResponse() {
        XCTAssertThrowsError(try SecondOpinionProvider.parse(data(#"{"verdict":"supports"}"#))) { error in
            guard case SecondOpinionError.invalidResponse = error else {
                return XCTFail("invalidResponse bekleniyordu, gelen: \(error)")
            }
        }
    }

    func testRetryableFlagFollowsTheCase() {
        XCTAssertFalse(SecondOpinionError.notConfigured.retryable)
        XCTAssertTrue(SecondOpinionError.transport("ağ yok").retryable)
        // The server's own retryable flag is the rule (§17): the quota message
        // arrives as retryable so a top-up needs only another tap.
        XCTAssertTrue(SecondOpinionError.server("kota tükendi", retryable: true).retryable)
        XCTAssertFalse(SecondOpinionError.server("anahtar geçersiz", retryable: false).retryable)
        XCTAssertFalse(SecondOpinionError.invalidResponse("bozuk").retryable)
    }
}
