import XCTest
@testable import CizgiCore

/// `BackendCardProvider.map` is the one piece of the real card generator
/// worth unit testing directly (no HTTP mocking in this package — see
/// `BackendPipelineTests.swift`'s header comment on `BackendClient` for why).
/// It is also the highest-risk new logic in it: the server's §19 gate
/// (`runCardGate`) never removes a rejected card from `output.cards`, it only
/// scores it in a separate `gate.verdicts` array — so this mapping is what
/// actually keeps a rejected card off the phone (§0.5, §19.3).
final class BackendCardProviderTests: XCTestCase {
    private func card(
        id: String = "card_1",
        explanation: String = "",
        riskFlags: [RiskFlag] = [],
        requiresUserApproval: Bool = false
    ) -> RemoteCard {
        RemoteCard(
            id: id,
            type: .directRecall,
            front: "Ön yüz",
            back: "Arka yüz",
            explanation: explanation,
            sourceQuote: "kaynak alıntı",
            riskFlags: riskFlags,
            requiresUserApproval: requiresUserApproval
        )
    }

    private func unit(
        canonicalClaim: String = "iddia",
        tags: [String] = ["Farmakoloji"],
        sourceConcern: String? = nil,
        requiresUserApproval: Bool = false
    ) -> RemoteKnowledgeUnit {
        RemoteKnowledgeUnit(
            canonicalClaim: canonicalClaim,
            tags: tags,
            sourceConcern: sourceConcern,
            requiresUserApproval: requiresUserApproval
        )
    }

    private func usage() -> RemoteUsage {
        RemoteUsage(provider: "openai", model: "gpt-5.6-sol", inputTokens: 1012, outputTokens: 571, estimatedCostUSD: 0)
    }

    private func success(
        knowledgeUnits: [RemoteKnowledgeUnit],
        cards: [RemoteCard],
        verdicts: [RemoteCardVerdict],
        warnings: [String] = []
    ) -> RemoteCardsSuccess {
        RemoteCardsSuccess(
            output: RemoteCardsOutput(requestId: "req-1", knowledgeUnits: knowledgeUnits, cards: cards, usage: usage()),
            gate: RemoteCardGateReport(verdicts: verdicts, warnings: warnings),
            cardPromptVersion: "cardGeneration.v1"
        )
    }

    func testAutoAcceptedCardIsKeptAsIs() throws {
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.cards.count, 1)
        XCTAssertFalse(knowledge.cards[0].requiresUserApproval)
    }

    func testRejectedCardNeverReachesTheDeck() throws {
        // The server's own comment: `runCardGate` never mutates `output.cards`,
        // so a rejected card is still physically present here — this is the
        // one thing standing between it and the user's deck (§0.5, §19.3).
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card(id: "card_1"), card(id: "card_2")],
            verdicts: [
                RemoteCardVerdict(cardId: "card_1", decision: "auto_accept"),
                RemoteCardVerdict(cardId: "card_2", decision: "reject"),
            ]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.cards.count, 1)
    }

    func testQuickConfirmForcesApprovalEvenIfTheModelSaidFalse() throws {
        // ADR-001's floor-not-ceiling rule: the gate can only escalate.
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card(requiresUserApproval: false)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "quick_confirm")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertTrue(knowledge.cards[0].requiresUserApproval)
    }

    func testModelApprovalRequirementSurvivesAnAutoAcceptVerdict() throws {
        // The gate never relaxes a model-reported `true` back down (ADR-001).
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card(requiresUserApproval: true)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertTrue(knowledge.cards[0].requiresUserApproval)
    }

    func testACardIdTheGateNeverScoredIsNeverTrustedSilently() throws {
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card(id: "card_1")],
            verdicts: []
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.cards.count, 1)
        XCTAssertTrue(knowledge.cards[0].requiresUserApproval)
    }

    func testNoKnowledgeUnitsIsTreatedAsSourceInsufficient() {
        let decoded = success(knowledgeUnits: [], cards: [card()], verdicts: [])
        XCTAssertThrowsError(try BackendCardProvider.map(decoded, elapsedMs: 100)) { error in
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testEveryCardRejectedIsTreatedAsSourceInsufficient() {
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "reject")]
        )
        XCTAssertThrowsError(try BackendCardProvider.map(decoded, elapsedMs: 100)) { error in
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testEmptyExplanationBecomesNilNotAnEmptyString() throws {
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card(explanation: "")],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)
        XCTAssertNil(knowledge.cards[0].explanation)
    }

    func testConcernCombinesTheKnowledgeUnitAndTheGateWarnings() throws {
        let decoded = success(
            knowledgeUnits: [unit(sourceConcern: "Kaynak belirsiz.", requiresUserApproval: true)],
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")],
            warnings: ["Sayfa geneli duplicate kart riski yüksek."]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertNotNil(knowledge.sourceConcern)
        XCTAssertTrue(knowledge.sourceConcern?.contains("Kaynak belirsiz.") ?? false)
        XCTAssertTrue(knowledge.sourceConcern?.contains("onay istiyor") ?? false)
        XCTAssertTrue(knowledge.sourceConcern?.contains("duplicate kart riski") ?? false)
    }

    func testNoConcernAtAllStaysNil() throws {
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)
        XCTAssertNil(knowledge.sourceConcern)
    }

    func testModelRunCarriesTheRealUsageAndThePromptVersionFromTheResponse() throws {
        let decoded = success(
            knowledgeUnits: [unit()],
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 1234)

        XCTAssertEqual(knowledge.modelRun?.requestId, "req-1")
        XCTAssertEqual(knowledge.modelRun?.provider, "openai")
        XCTAssertEqual(knowledge.modelRun?.model, "gpt-5.6-sol")
        XCTAssertEqual(knowledge.modelRun?.purpose, "card_generation")
        XCTAssertEqual(knowledge.modelRun?.promptVersion, "cardGeneration.v1")
        XCTAssertEqual(knowledge.modelRun?.latencyMs, 1234)
        XCTAssertEqual(knowledge.modelRun?.inputTokens, 1012)
        XCTAssertEqual(knowledge.modelRun?.outputTokens, 571)
    }

    func testCanonicalClaimAndTagsComeFromTheFirstKnowledgeUnit() throws {
        let decoded = success(
            knowledgeUnits: [unit(canonicalClaim: "Anafilaksi tedavisi", tags: ["Acil", "Farmakoloji"])],
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100)

        XCTAssertEqual(knowledge.canonicalClaim, "Anafilaksi tedavisi")
        XCTAssertEqual(knowledge.tags, ["Acil", "Farmakoloji"])
    }
}
