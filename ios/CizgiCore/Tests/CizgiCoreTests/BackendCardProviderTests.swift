import XCTest
@testable import CizgiCore

/// `BackendCardProvider.map` is the one piece of the real card generator
/// worth unit testing directly (no HTTP mocking in this package — see
/// `BackendPipelineTests.swift`'s header comment on `BackendClient` for why).
/// It is also the highest-risk logic in it: the server's gate (`runCardGate`)
/// never removes a rejected card from `output.cards`, it only scores it in a
/// separate `gate.verdicts` array — so this mapping is what actually keeps a
/// rejected card off the phone (§0.5, §5.3).
///
/// Faz 6 (docs/FAZ6-PLAN.md): the v2 gate only ever returns `auto_accept` or
/// `reject`. Kept cards are always active — there is no approval step.
final class BackendCardProviderTests: XCTestCase {
    private func card(
        id: String = "card_1",
        explanation: String = "",
        tags: [String] = ["Farmakoloji"],
        lowConfidence: Bool = false
    ) -> RemoteCard {
        RemoteCard(
            id: id,
            type: .directRecall,
            front: "Ön yüz",
            back: "Arka yüz",
            explanation: explanation,
            difficulty: 2,
            tags: tags,
            lowConfidence: lowConfidence
        )
    }

    private func usage() -> RemoteUsage {
        RemoteUsage(provider: "openai", model: "gpt-5.6-sol", inputTokens: 1012, outputTokens: 571, estimatedCostUSD: 0)
    }

    private func success(
        readText: String = "işaretli ham metin",
        cards: [RemoteCard],
        verdicts: [RemoteCardVerdict],
        warnings: [String] = []
    ) -> RemoteCardsSuccess {
        RemoteCardsSuccess(
            output: RemoteCardsOutput(requestId: "req-1", readText: readText, cards: cards, usage: usage()),
            gate: RemoteCardGateReport(verdicts: verdicts, warnings: warnings),
            cardPromptVersion: "2.0"
        )
    }

    func testAutoAcceptedCardIsKeptAndActive() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.cards.count, 1)
        // Faz 6: cards go straight to the active deck, no approval.
        XCTAssertFalse(knowledge.cards[0].requiresUserApproval)
    }

    func testRejectedCardNeverReachesTheDeck() throws {
        // `runCardGate` never mutates `output.cards`, so a rejected card is
        // still physically present here — this mapping is the one thing
        // standing between it and the user's deck (§0.5, §5.3).
        let decoded = success(
            cards: [card(id: "card_1"), card(id: "card_2")],
            verdicts: [
                RemoteCardVerdict(cardId: "card_1", decision: "auto_accept"),
                RemoteCardVerdict(cardId: "card_2", decision: "reject"),
            ]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.cards.count, 1)
    }

    func testAnUnscoredCardIdDefaultsToKeptAndActive() throws {
        // The v2 gate scores every card, so an unscored id only happens on a
        // malformed response. Faz 6 has no confirmation lane, so the honest
        // fallback is an active card the user can delete in Bilgilerim.
        let decoded = success(
            cards: [card(id: "card_1")],
            verdicts: []
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.cards.count, 1)
        XCTAssertFalse(knowledge.cards[0].requiresUserApproval)
    }

    func testEveryCardRejectedIsTreatedAsSourceInsufficient() {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "reject")]
        )
        XCTAssertThrowsError(try BackendCardProvider.map(decoded, elapsedMs: 100)) { error in
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testNoCardsAtAllIsTreatedAsSourceInsufficient() {
        let decoded = success(cards: [], verdicts: [])
        XCTAssertThrowsError(try BackendCardProvider.map(decoded, elapsedMs: 100)) { error in
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testEmptyExplanationBecomesNilNotAnEmptyString() throws {
        let decoded = success(
            cards: [card(explanation: "")],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)
        XCTAssertNil(knowledge.cards[0].explanation)
    }

    func testConcernComesFromTheGateWarnings() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")],
            warnings: ["2 kart pasaj limitini aştığı için reddedildi."]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertNotNil(knowledge.sourceConcern)
        XCTAssertTrue(knowledge.sourceConcern?.contains("pasaj limitini") ?? false)
    }

    func testNoWarningsMeansNoConcern() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)
        XCTAssertNil(knowledge.sourceConcern)
    }

    func testModelRunCarriesTheRealUsageAndThePromptVersionFromTheResponse() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 1234)

        XCTAssertEqual(knowledge.modelRun?.requestId, "req-1")
        XCTAssertEqual(knowledge.modelRun?.provider, "openai")
        XCTAssertEqual(knowledge.modelRun?.model, "gpt-5.6-sol")
        XCTAssertEqual(knowledge.modelRun?.purpose, "card_generation")
        XCTAssertEqual(knowledge.modelRun?.promptVersion, "2.0")
        XCTAssertEqual(knowledge.modelRun?.latencyMs, 1234)
        XCTAssertEqual(knowledge.modelRun?.inputTokens, 1012)
        XCTAssertEqual(knowledge.modelRun?.outputTokens, 571)
    }

    func testCanonicalClaimIsTheReadTextAndTagsAreTheUnionOfCardTags() throws {
        let decoded = success(
            readText: "Anafilaksi tedavisi",
            cards: [
                card(id: "card_1", tags: ["Acil", "Farmakoloji"]),
                card(id: "card_2", tags: ["Farmakoloji", "Dahiliye"]),
            ],
            verdicts: [
                RemoteCardVerdict(cardId: "card_1", decision: "auto_accept"),
                RemoteCardVerdict(cardId: "card_2", decision: "auto_accept"),
            ]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.canonicalClaim, "Anafilaksi tedavisi")
        XCTAssertEqual(knowledge.tags, ["Acil", "Farmakoloji", "Dahiliye"])
    }

    func testCanonicalClaimFallsBackToFirstFrontWhenReadTextIsEmpty() throws {
        let decoded = success(
            readText: "   ",
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)
        XCTAssertEqual(knowledge.canonicalClaim, "Ön yüz")
    }
}
