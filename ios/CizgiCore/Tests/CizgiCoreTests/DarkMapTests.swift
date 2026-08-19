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
        XCTAssertTrue(DarkMapError.server("503", retryable: true, usage: []).retryable)
        XCTAssertFalse(DarkMapError.server("403", retryable: false, usage: []).retryable)
        XCTAssertFalse(DarkMapError.invalidResponse("bozuk").retryable)
    }

    /// The backend already names the real suspect ("Gemini kotası/kredisi
    /// tükenmiş…"); rewording it here would undo exactly that.
    func testServerMessageTravelsVerbatim() {
        let message = "Gemini kotası/kredisi tükenmiş görünüyor (429 RESOURCE_EXHAUSTED)."
        XCTAssertEqual(
            DarkMapError.server(message, retryable: true, usage: []).errorDescription,
            message
        )
    }

    /// Only `.server` can carry a ledger; the rest never reached a model.
    func testOnlyServerFailuresCarryALedger() {
        let run = ModelRunMetadata(
            requestId: "r",
            provider: "openai",
            model: "m",
            purpose: "dark_map",
            promptVersion: "1.0",
            latencyMs: 10,
            inputTokens: 1,
            outputTokens: 2,
            estimatedCostUSD: 0.1,
            success: false
        )
        XCTAssertEqual(DarkMapError.server("x", retryable: true, usage: [run]).usage, [run])
        XCTAssertTrue(DarkMapError.transport("kopuk").usage.isEmpty)
        XCTAssertTrue(DarkMapError.notConfigured.usage.isEmpty)
    }
}

/// Locks the one number the two map surfaces share (Codex, PR #49).
///
/// Bilgi Haritası's entry card promises "N konuda tek kartın yok"; tapping it
/// opens a screen that computes the same figure from `DarkMapCoverage`. Those
/// were two independent definitions of "covered", and they disagreed exactly
/// where it hurts — a topic whose every card is suspended. This is the project's
/// standard remedy for "aynı davranış iki yerde": one definition, locked by a
/// test rather than kept in sync by hand.
final class DarkMapCoverageAgreementTests: XCTestCase {

    private func pair(
        subject: String,
        topic: String?,
        isActive: Bool
    ) -> (KnowledgeMapCard, DarkMapCoverage.Card) {
        (
            KnowledgeMapCard(
                subject: subject,
                topic: topic,
                isActive: isActive,
                lapseCount: 0,
                lowConfidence: false
            ),
            DarkMapCoverage.Card(
                subject: subject,
                topic: topic,
                front: "soru",
                isActive: isActive,
                lowConfidence: false
            )
        )
    }

    private func assertAgreement(
        _ pairs: [(KnowledgeMapCard, DarkMapCoverage.Card)],
        line: UInt = #line
    ) {
        let map = KnowledgeMapBuilder.build(cards: pairs.map(\.0), schema: schema)
        let payload = DarkMapCoverage.build(cards: pairs.map(\.1), schema: schema)
        XCTAssertEqual(
            map.activeCoveredTopicCount,
            payload.coveredTopicCount,
            "giriş kartı ile Karanlık Harita aynı desteyi farklı sayıyor",
            line: line
        )
    }

    func testAgreesOnAnOrdinaryDeck() {
        assertAgreement([
            pair(subject: "Patoloji", topic: "Inflamasyon", isActive: true),
            pair(subject: "Patoloji", topic: "Neoplazi", isActive: true),
            pair(subject: "Genel Cerrahi", topic: "Deri Hastalıkları", isActive: true),
        ])
    }

    /// The case that used to diverge: every card in the topic is suspended, so
    /// Bilgi Haritası counted it as covered while the Dark Map called it empty.
    func testAgreesWhenATopicHoldsOnlySuspendedCards() {
        let pairs = [
            pair(subject: "Patoloji", topic: "Inflamasyon", isActive: false),
            pair(subject: "Patoloji", topic: "Neoplazi", isActive: true),
        ]
        assertAgreement(pairs)

        // And it is the *active-only* answer both now give — the suspended-only
        // topic is a gap, which is the whole point of the feature.
        let map = KnowledgeMapBuilder.build(cards: pairs.map(\.0), schema: schema)
        XCTAssertEqual(map.coveredTopicCount, 2, "Bilgi Haritası desteyi anlatır: ikisi de kapsanmış")
        XCTAssertEqual(map.activeCoveredTopicCount, 1, "Karanlık Harita çalışılanı anlatır: biri boş")
    }

    func testAgreesWhenEveryCardIsSuspended() {
        assertAgreement([
            pair(subject: "Patoloji", topic: "Inflamasyon", isActive: false),
            pair(subject: "Genel Cerrahi", topic: "Deri Hastalıkları", isActive: false),
        ])
    }

    /// Uncategorised and unrecognised cards are excluded by both, for their own
    /// reasons; the totals must still line up.
    func testAgreesWithUnclassifiedCardsPresent() {
        assertAgreement([
            pair(subject: "Patoloji", topic: nil, isActive: true),
            pair(subject: "Patoloji", topic: "Otonom", isActive: true),
            pair(subject: "Patoloji", topic: "Inflamasyon", isActive: true),
        ])
    }

    func testAgreesOnAnEmptyDeck() {
        assertAgreement([])
    }
}

/// The three ways a payload can have no rows (Codex, PR #49).
///
/// A closed enum with a test rather than a chain of `if`s in the view, because
/// the view got this wrong twice: first by asserting a cause it could not know,
/// then by calling an all-suspended deck empty. Only one of the three is
/// something the user can act on, so collapsing them loses the only part that
/// matters.
final class DarkMapEmptinessTests: XCTestCase {

    func testNilWhenThereAreRows() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon")],
            schema: schema
        )
        XCTAssertNil(DarkMapCoverage.emptiness(of: payload))
    }

    func testUnclassifiedOnly() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: nil), card(subject: nil, topic: nil)],
            schema: schema
        )
        XCTAssertEqual(DarkMapCoverage.emptiness(of: payload), .unclassifiedOnly)
    }

    /// The case that used to read "Deste boş görünüyor" — with cards in it.
    func testInactiveOnly() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon", isActive: false),
                card(subject: "Patoloji", topic: "Neoplazi", isActive: false),
            ],
            schema: schema
        )
        XCTAssertEqual(DarkMapCoverage.emptiness(of: payload), .inactiveOnly)
    }

    func testNoCards() {
        XCTAssertEqual(DarkMapCoverage.emptiness(of: DarkMapCoverage.build(cards: [], schema: schema)), .noCards)
    }

    /// Both present: the actionable cause is the one worth naming.
    func testUnclassifiedWinsOverInactive() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: nil),
                card(subject: "Patoloji", topic: "Inflamasyon", isActive: false),
            ],
            schema: schema
        )
        XCTAssertEqual(DarkMapCoverage.emptiness(of: payload), .unclassifiedOnly)
    }
}

/// The sampler takes the *longest* fronts, so an unbounded one is the case it
/// most reliably finds (Codex, PR #49).
final class DarkMapSampleLengthTests: XCTestCase {

    func testTruncatesAnOverLongFrontAndMarksTheCut() {
        let long = String(repeating: "a", count: DarkMapCoverage.maxSampleFrontLength + 500)
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon", front: long)],
            schema: schema
        )
        let front = payload.rows[0].sampleFronts[0]
        XCTAssertEqual(front.count, DarkMapCoverage.maxSampleFrontLength + 1)
        XCTAssertTrue(front.hasSuffix("…"))
    }

    func testLeavesAFrontAtTheLimitUntouched() {
        let exact = String(repeating: "b", count: DarkMapCoverage.maxSampleFrontLength)
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon", front: exact)],
            schema: schema
        )
        XCTAssertEqual(payload.rows[0].sampleFronts[0], exact)
    }

    /// Truncation must not disturb the "longest first" ordering the sampler
    /// exists for — the cut happens after the choice, not before it.
    func testStillPrefersTheLongestFrontsBeforeTruncating() {
        let huge = String(repeating: "x", count: 5_000)
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon", front: "kısa"),
                card(subject: "Patoloji", topic: "Inflamasyon", front: huge),
            ],
            schema: schema,
            maxSampleFronts: 1
        )
        XCTAssertEqual(payload.rows[0].sampleFronts.count, 1)
        XCTAssertTrue(payload.rows[0].sampleFronts[0].hasPrefix("xxx"))
    }
}

/// The phone's half of the prompt-table integrity fix (Codex, PR #49).
///
/// The server flattens and escapes again and that is the guarantee; this stops
/// the phone putting a multiline question on the wire at all, and makes the
/// length ceiling mean something — 240 newlines is short and still ruinous.
final class DarkMapSampleFlatteningTests: XCTestCase {

    func testCollapsesNewlinesAndRunsOfWhitespace() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon", front: "ilk satır\n\tikinci  satır")],
            schema: schema
        )
        XCTAssertEqual(payload.rows[0].sampleFronts[0], "ilk satır ikinci satır")
    }

    func testDropsAWhitespaceOnlyFront() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Inflamasyon", front: "\n\t  \n"),
                card(subject: "Patoloji", topic: "Inflamasyon", front: "gerçek soru"),
            ],
            schema: schema
        )
        XCTAssertEqual(payload.rows[0].sampleFronts, ["gerçek soru"])
        XCTAssertEqual(payload.rows[0].cardCount, 2)
    }

    /// The ceiling is measured after flattening, not before.
    func testMeasuresTheCeilingAfterFlattening() {
        let front = String(repeating: "a", count: 200)
            + String(repeating: "\n", count: 200)
            + String(repeating: "b", count: 200)
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon", front: front)],
            schema: schema
        )
        let sample = payload.rows[0].sampleFronts[0]
        XCTAssertFalse(sample.contains("\n"))
        XCTAssertLessThanOrEqual(sample.count, DarkMapCoverage.maxSampleFrontLength + 1)
    }
}

/// Two staleness axes pulling opposite ways (Codex, PR #49, rounds 7 and 9).
///
/// The deck moves fast (`@Query` updates the instant a card is suspended); the
/// schema moves slowly (a deployed backend can know a topic a released app does
/// not). Handing the whole answer to either side fixes one and breaks the other,
/// which is exactly what happened once. Each owns what it is authoritative about.
final class DarkMapUntouchedReconciliationTests: XCTestCase {

    private func keys(_ rows: [(subject: String, topic: String)]) -> [String] {
        rows.map { "\($0.subject)|\($0.topic)" }
    }

    func testUsesTheCurrentDeckWithNoServerList() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon")],
            schema: schema
        )
        let rows = DarkMapCoverage.untouched(schema: schema, payload: payload)
        XCTAssertFalse(keys(rows).contains("Patoloji|Inflamasyon"))
        XCTAssertTrue(keys(rows).contains("Patoloji|Neoplazi"))
        XCTAssertEqual(rows.count, 3)
    }

    /// The round-9 regression: a card suspended after the run must move the
    /// topic back into the list, without needing a paid rerun.
    func testTracksTheDeckEvenWhenAServerListIsPresent() {
        let stale = [(subject: "Patoloji", topic: "Neoplazi")]
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Inflamasyon", isActive: false)],
            schema: schema
        )
        let rows = DarkMapCoverage.untouched(schema: schema, payload: payload, serverUntouched: stale)
        // Inflamasyon is suspended now, so it is uncovered again — even though
        // the server's older answer did not list it.
        XCTAssertTrue(keys(rows).contains("Patoloji|Inflamasyon"))
    }

    /// The round-7 finding: a topic only the server knows must still surface.
    func testAddsTopicsTheBundledSchemaDoesNotKnow() {
        let payload = DarkMapCoverage.build(cards: [], schema: schema)
        let rows = DarkMapCoverage.untouched(
            schema: schema,
            payload: payload,
            serverUntouched: [(subject: "Farmakoloji", topic: "Yeni Konu")]
        )
        XCTAssertTrue(keys(rows).contains("Farmakoloji|Yeni Konu"))
        XCTAssertEqual(rows.count, 5)
    }

    /// A server row this build *does* know was already decided from the deck —
    /// it must not appear twice.
    func testDoesNotDuplicateAKnownServerRow() {
        let payload = DarkMapCoverage.build(cards: [], schema: schema)
        let rows = DarkMapCoverage.untouched(
            schema: schema,
            payload: payload,
            serverUntouched: [(subject: "Patoloji", topic: "Neoplazi")]
        )
        XCTAssertEqual(keys(rows).filter { $0 == "Patoloji|Neoplazi" }.count, 1)
    }

    /// And a known server row for a topic the deck now covers must not
    /// resurrect it.
    func testAKnownServerRowCannotResurrectACoveredTopic() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Neoplazi")],
            schema: schema
        )
        let rows = DarkMapCoverage.untouched(
            schema: schema,
            payload: payload,
            serverUntouched: [(subject: "Patoloji", topic: "Neoplazi")]
        )
        XCTAssertFalse(keys(rows).contains("Patoloji|Neoplazi"))
    }
}

/// The third instance of one staleness axis (Codex, PR #49, rounds 7/9/10).
///
/// A ranking is bought once and read for as long as the screen lives, while
/// `@Query` keeps the deck current underneath it. Patching the sites that
/// happened to be looked at fixed it twice and missed the zone rows both times;
/// this locks the single choke point instead.
final class DarkMapZoneReconciliationTests: XCTestCase {

    private func zone(subject: String, topic: String, cardCount: Int, weak: Int = 0) -> DarkZone {
        DarkZone(
            subject: subject,
            topic: topic,
            cardCount: cardCount,
            weakCardCount: weak,
            consensusRaw: "confirmed",
            raters: ["openai", "gemini"],
            darkness: 4,
            tusYieldRaw: "high",
            missingConcepts: ["x"],
            reasons: [DarkZone.Reason(family: "openai", reason: "r")]
        )
    }

    /// The reported case: the last active card is suspended, so the row must
    /// stop claiming coverage — and stop offering "Bu konuyu çalış", which the
    /// view gates on `cardCount > 0`.
    func testDropsToZeroWhenTheLastActiveCardIsSuspended() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Neoplazi", isActive: false)],
            schema: schema
        )
        let out = DarkMapCoverage.reconcile(
            zones: [zone(subject: "Patoloji", topic: "Neoplazi", cardCount: 3, weak: 1)],
            with: payload
        )
        XCTAssertEqual(out[0].cardCount, 0)
        XCTAssertEqual(out[0].weakCardCount, 0)
    }

    func testPicksUpACardAddedSinceTheRun() {
        let payload = DarkMapCoverage.build(
            cards: [
                card(subject: "Patoloji", topic: "Neoplazi"),
                card(subject: "Patoloji", topic: "Neoplazi", lowConfidence: true),
            ],
            schema: schema
        )
        let out = DarkMapCoverage.reconcile(
            zones: [zone(subject: "Patoloji", topic: "Neoplazi", cardCount: 0)],
            with: payload
        )
        XCTAssertEqual(out[0].cardCount, 2)
        XCTAssertEqual(out[0].weakCardCount, 1)
    }

    /// The judgement is what was paid for; only the counts are deck facts.
    func testLeavesTheRankingUntouched() {
        let payload = DarkMapCoverage.build(cards: [], schema: schema)
        let original = zone(subject: "Patoloji", topic: "Neoplazi", cardCount: 5)
        let out = DarkMapCoverage.reconcile(zones: [original], with: payload)
        XCTAssertEqual(out[0].darkness, original.darkness)
        XCTAssertEqual(out[0].consensus, original.consensus)
        XCTAssertEqual(out[0].tusYield, original.tusYield)
        XCTAssertEqual(out[0].raters, original.raters)
        XCTAssertEqual(out[0].missingConcepts, original.missingConcepts)
        XCTAssertEqual(out[0].reasons, original.reasons)
    }

    /// Order and membership are the user's paid result; a topic that became
    /// covered stays on the list, it just says so honestly.
    func testKeepsEveryZoneAndItsOrder() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Neoplazi")],
            schema: schema
        )
        let out = DarkMapCoverage.reconcile(
            zones: [
                zone(subject: "Patoloji", topic: "Neoplazi", cardCount: 0),
                zone(subject: "Patoloji", topic: "Inflamasyon", cardCount: 0),
            ],
            with: payload
        )
        XCTAssertEqual(out.map(\.topic), ["Neoplazi", "Inflamasyon"])
        XCTAssertEqual(out[0].cardCount, 1)
        XCTAssertEqual(out[1].cardCount, 0)
    }

    /// The pair is the identity here too.
    func testDoesNotBorrowACountFromTheSameTopicNameUnderAnotherSubject() {
        let payload = DarkMapCoverage.build(
            cards: [card(subject: "Patoloji", topic: "Deri Hastalıkları")],
            schema: schema
        )
        let out = DarkMapCoverage.reconcile(
            zones: [zone(subject: "Genel Cerrahi", topic: "Deri Hastalıkları", cardCount: 9)],
            with: payload
        )
        XCTAssertEqual(out[0].cardCount, 0)
    }
}
