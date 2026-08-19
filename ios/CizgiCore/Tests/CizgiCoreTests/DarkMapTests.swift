import XCTest

@testable import CizgiCore

/// Two subjects, four topics — enough to exercise schema ordering and the
/// "same topic name under two subjects" case without pulling in all 143.
private let schema = SubjectTopicSchema(
    version: 1,
    subjects: [
        .init(name: "Patoloji", topics: ["Inflamasyon", "Neoplazi", "Deri Hastalıkları"]),
        .init(name: "Genel Cerrahi", topics: ["Deri Hastalıkları"]),
    ]
)

private func card(
    subject: String?,
    topic: String?,
    front: String = "soru",
    isActive: Bool = true,
    lowConfidence: Bool = false
) -> DarkMapCoverage.Card {
    DarkMapCoverage.Card(
        subject: subject,
        topic: topic,
        front: front,
        isActive: isActive,
        lowConfidence: lowConfidence
    )
}

final class DarkMapCoverageTests: XCTestCase {

    func testGroupsCanonicalPairs() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon"),
                card(subject: "Patoloji", topic: "Inflamasyon"),
                card(subject: "Patoloji", topic: "Neoplazi", lowConfidence: true),
            ],
            schema: schema
        )
        XCTAssertEqual(payload.rows.count, 2)
        XCTAssertEqual(payload.rows[0].topic, "Inflamasyon")
        XCTAssertEqual(payload.rows[0].cardCount, 2)
        XCTAssertEqual(payload.rows[1].weakCardCount, 1)
        XCTAssertEqual(payload.classifiedCards, 3)
    }

    /// The pair is the identity. A grouping that keyed on the bare topic name
    /// would merge these two and report one subject as covered when it is not —
    /// the same trap the backend test guards on its side.
    func testSameTopicNameUnderTwoSubjectsStaysApart() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Deri Hastalıkları"),
                card(subject: "Genel Cerrahi", topic: "Deri Hastalıkları"),
            ],
            schema: schema
        )
        XCTAssertEqual(payload.rows.count, 2)
        XCTAssertEqual(
            payload.rows.map(\.subject).sorted(),
            ["Genel Cerrahi", "Patoloji"]
        )
        XCTAssertTrue(payload.rows.allSatisfy { $0.cardCount == 1 })
    }

    /// Absence is the server's job. Sending the zeros would make this phone's
    /// (possibly stale) schema copy authoritative about which topics exist.
    func testDoesNotSendZeroCardTopics() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon")],
            schema: schema
        )
        XCTAssertEqual(payload.rows.count, 1)
        XCTAssertEqual(payload.coveredTopicCount, 1)
    }

    /// A suspended duplicate is not coverage: it is a card the owner will never
    /// see again, and counting it makes a topic look studied because it once
    /// held a redundant card.
    func testExcludesInactiveCardsAndCountsThem() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon"),
                card(subject: "Patoloji", topic: "Inflamasyon", isActive: false),
                card(subject: "Patoloji", topic: "Neoplazi", isActive: false),
            ],
            schema: schema
        )
        XCTAssertEqual(payload.rows.count, 1)
        XCTAssertEqual(payload.rows[0].cardCount, 1)
        XCTAssertEqual(payload.inactiveCards, 2)
    }

    /// On a deck where most cards still carry no topic, a payload built only
    /// from rows would describe a corner of the deck while looking like it
    /// described all of it.
    func testCountsUnclassifiedRatherThanHidingIt() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: nil),
                card(subject: nil, topic: nil),
                card(subject: "Kardiyoloji", topic: "Aritmiler"),
                card(subject: "Patoloji", topic: "Otonom"),
                card(subject: "Patoloji", topic: "Inflamasyon"),
            ],
            schema: schema
        )
        XCTAssertEqual(payload.unclassifiedCards, 4)
        XCTAssertEqual(payload.rows.count, 1)
    }

    /// Byte-identical payloads across runs are what let the provider's prompt
    /// cache hit, and a cached input token bills at roughly a tenth of the rate.
    func testRowsFollowSchemaOrderNotInsertionOrder() {
        let forward = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Neoplazi"),
                card(subject: "Patoloji", topic: "Inflamasyon"),
            ],
            schema: schema
        )
        let reversed = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon"),
                card(subject: "Patoloji", topic: "Neoplazi"),
            ],
            schema: schema
        )
        XCTAssertEqual(forward.rows.map(\.topic), ["Inflamasyon", "Neoplazi"])
        XCTAssertEqual(forward.rows.map(\.topic), reversed.rows.map(\.topic))
    }

    /// The shortest cards are the bare definitions — exactly the ones that make
    /// a shallow topic look covered. Prompt rule 4 asks the model to spot
    /// "twelve cards that all restate one definition", and handing it the
    /// twelve shortest would hide the signal it is being asked to read.
    func testSamplesLongestFrontsFirst() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon", front: "kısa"),
                card(subject: "Patoloji", topic: "Inflamasyon", front: "orta uzunlukta bir soru"),
                card(subject: "Patoloji", topic: "Inflamasyon", front: "en uzun ve en ayrıntılı olan soru"),
            ],
            schema: schema,
            maxSampleFronts: 2
        )
        XCTAssertEqual(
            payload.rows[0].sampleFronts,
            ["en uzun ve en ayrıntılı olan soru", "orta uzunlukta bir soru"]
        )
    }

    func testSamplingCanBeDisabledAndBlankFrontsSkipped() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon")],
            schema: schema,
            maxSampleFronts: 0
        )
        XCTAssertTrue(payload.rows[0].sampleFronts.isEmpty)

        let blank = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon", front: "   "),
                card(subject: "Patoloji", topic: "Inflamasyon", front: "gerçek soru"),
            ],
            schema: schema
        )
        XCTAssertEqual(blank.rows[0].sampleFronts, ["gerçek soru"])
        XCTAssertEqual(blank.rows[0].cardCount, 2)
    }
}

final class DarkMapProviderParseTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let full = """
        {
          "requestId": "req-1",
          "promptVersion": "1.0",
          "zones": [
            {
              "subject": "Patoloji",
              "topic": "Neoplazi",
              "topicKey": "Patoloji|Neoplazi",
              "cardCount": 3,
              "weakCardCount": 1,
              "consensus": "confirmed",
              "raters": ["openai", "gemini"],
              "darkness": 4.5,
              "tusYield": "high",
              "missingConcepts": ["onkogen aktivasyonu", "tümör supresör kaybı"],
              "reasons": [
                { "family": "openai", "reason": "o gerekçe" },
                { "family": "gemini", "reason": "g gerekçe" }
              ]
            }
          ],
          "untouched": [{ "subject": "Genel Cerrahi", "topic": "Deri Hastalıkları" }],
          "totals": {
            "canonicalTopics": 143,
            "coveredTopics": 2,
            "untouchedTopics": 141,
            "totalCards": 9
          },
          "raters": [
            { "family": "openai", "model": "gpt-5.6-luna", "ok": true, "zoneCount": 1, "droppedUnknown": 0 },
            { "family": "gemini", "model": "gemini-3.5-flash", "ok": true, "zoneCount": 1, "droppedUnknown": 0 }
          ],
          "singleRater": false,
          "droppedUnknownFromClient": 0,
          "usage": [
            {
              "attempt": 1,
              "provider": "openai",
              "model": "gpt-5.6-luna",
              "purpose": "dark_map",
              "promptVersion": "1.0",
              "outcome": "success",
              "billing": "measured",
              "usage": {
                "inputTokens": 2000,
                "cachedInputTokens": 1200,
                "outputTokens": 400,
                "reasoningTokens": 250
              },
              "estimatedCostUSD": 0.0009,
              "latencyMs": 8200
            }
          ]
        }
        """

    func testParsesAFullResponse() throws {
        let result = try DarkMapProvider.parse(data(full))
        XCTAssertEqual(result.zones.count, 1)
        XCTAssertFalse(result.singleRater)
        XCTAssertEqual(result.totals.untouchedTopics, 141)
        XCTAssertEqual(result.untouched, [UntouchedTopic(subject: "Genel Cerrahi", topic: "Deri Hastalıkları")])

        let zone = try XCTUnwrap(result.zones.first)
        XCTAssertEqual(zone.consensus, .confirmed)
        XCTAssertEqual(zone.tusYield, .high)
        XCTAssertEqual(zone.darkness, 4.5, accuracy: 0.001)
        XCTAssertEqual(zone.cardCount, 3)
        XCTAssertEqual(zone.raters, ["openai", "gemini"])
        XCTAssertEqual(zone.reasons.map(\.family), ["openai", "gemini"])
        XCTAssertEqual(result.confirmedZones.count, 1)
    }

    /// Both calls are billed whatever the verdict, so both have to reach
    /// Ayarlar → Kullanım.
    func testCarriesTheLedgerThroughWithTheRequestId() throws {
        let result = try DarkMapProvider.parse(data(full))
        let run = try XCTUnwrap(result.usage.first)
        XCTAssertEqual(run.requestId, "req-1")
        XCTAssertEqual(run.purpose, "dark_map")
        XCTAssertEqual(run.provider, "openai")
        XCTAssertTrue(run.success)
        XCTAssertEqual(run.billing, ModelRunBilling.measured)
        XCTAssertEqual(run.cachedInputTokens, 1200)
        XCTAssertEqual(run.reasoningTokens, 250)
    }

    /// The cautious default. An unlabelled map is treated as unconfirmed rather
    /// than silently presented as agreement.
    func testMissingSingleRaterDefaultsToTrue() throws {
        let json = """
            {
              "requestId": "r",
              "zones": [],
              "untouched": [],
              "totals": { "canonicalTopics": 143, "coveredTopics": 0, "untouchedTopics": 143, "totalCards": 0 }
            }
            """
        let result = try DarkMapProvider.parse(data(json))
        XCTAssertTrue(result.singleRater)
        XCTAssertTrue(result.zones.isEmpty)
        XCTAssertTrue(result.usage.isEmpty)
        XCTAssertTrue(result.raters.isEmpty)
    }

    /// A newer server adding a consensus level must not take the map down; the
    /// zone still shows, just without a badge.
    func testUnknownEnumValuesDegradeToNilButKeepTheRawString() throws {
        let json = """
            {
              "requestId": "r",
              "zones": [{
                "subject": "Patoloji", "topic": "Neoplazi", "cardCount": 0,
                "consensus": "unanimous", "darkness": 5, "tusYield": "critical"
              }],
              "untouched": [],
              "totals": { "canonicalTopics": 1, "coveredTopics": 0, "untouchedTopics": 1, "totalCards": 0 }
            }
            """
        let zone = try XCTUnwrap(try DarkMapProvider.parse(data(json)).zones.first)
        XCTAssertNil(zone.consensus)
        XCTAssertEqual(zone.consensusRaw, "unanimous")
        XCTAssertNil(zone.tusYield)
        XCTAssertEqual(zone.weakCardCount, 0)
        XCTAssertTrue(zone.missingConcepts.isEmpty)
    }

    func testReportsAFailedRater() throws {
        let json = """
            {
              "requestId": "r",
              "zones": [],
              "untouched": [],
              "totals": { "canonicalTopics": 1, "coveredTopics": 0, "untouchedTopics": 1, "totalCards": 0 },
              "raters": [
                { "family": "openai", "model": "m", "ok": true, "zoneCount": 2, "droppedUnknown": 0 },
                { "family": "gemini", "model": "g", "ok": false, "error": "Gemini 503", "zoneCount": 0, "droppedUnknown": 0 }
              ],
              "singleRater": true
            }
            """
        let result = try DarkMapProvider.parse(data(json))
        XCTAssertTrue(result.singleRater)
        XCTAssertEqual(result.raters.count, 2)
        XCTAssertEqual(result.raters[1].error, "Gemini 503")
        XCTAssertFalse(result.raters[1].ok)
    }

    func testRejectsAResponseMissingTheFieldsWithNoSensibleDefault() {
        // No `totals`: a map without them is not degraded, it is wrong.
        let json = """
            { "requestId": "r", "zones": [], "untouched": [] }
            """
        XCTAssertThrowsError(try DarkMapProvider.parse(data(json))) { error in
            guard case DarkMapError.invalidResponse = error else {
                return XCTFail("beklenen invalidResponse, alınan \(error)")
            }
        }
    }
}

final class DarkMapErrorTests: XCTestCase {

    /// Drives whether "Tekrar dene" is worth offering.
    func testRetryability() {
        XCTAssertFalse(DarkMapError.notConfigured.retryable)
        XCTAssertFalse(DarkMapError.schemaUnavailable.retryable)
        XCTAssertTrue(DarkMapError.transport("kopuk").retryable)
        XCTAssertTrue(DarkMapError.server("503", retryable: true).retryable)
        XCTAssertFalse(DarkMapError.server("403", retryable: false).retryable)
        XCTAssertFalse(DarkMapError.invalidResponse("bozuk").retryable)
    }

    /// The backend already names the real suspect ("Gemini kotası/kredisi
    /// tükenmiş…"); rewording it here would undo exactly that.
    func testServerMessageTravelsVerbatim() {
        let message = "Gemini kotası/kredisi tükenmiş görünüyor (429 RESOURCE_EXHAUSTED)."
        XCTAssertEqual(DarkMapError.server(message, retryable: true).errorDescription, message)
    }
}
