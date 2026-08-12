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
        type: CardType = .directRecall,
        explanation: String = "",
        tags: [String] = ["Farmakoloji"],
        lowConfidence: Bool = false,
        options: [RemoteCardOption]? = nil,
        correctOption: Int? = nil,
        topic: String? = nil
    ) -> RemoteCard {
        RemoteCard(
            id: id,
            type: type,
            front: "Ön yüz",
            back: "Arka yüz",
            explanation: explanation,
            difficulty: 2,
            tags: tags,
            lowConfidence: lowConfidence,
            options: options,
            correctOption: correctOption,
            topic: topic
        )
    }

    /// Five sound options, correct one first.
    private func remoteOptions(correctAt: Int = 0, texts: [String]? = nil) -> [RemoteCardOption] {
        let labels = texts ?? ["Hipokalemi", "Hiperkalemi", "Hiponatremi", "Hipokalsemi", "Hipomagnezemi"]
        return labels.enumerated().map { index, text in
            RemoteCardOption(text: text, correct: index == correctAt, why: index == correctAt ? "" : "yanlış çünkü …")
        }
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

    // MARK: Per-card topic (schema v2.2)

    func testTopicSurvivesTheMapping() throws {
        let decoded = success(
            cards: [card(topic: "İnflamasyon")],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])
        XCTAssertEqual(knowledge.cards.first?.topic, "İnflamasyon")
    }

    func testTopicDecodesFromV22AndDefaultsToNilOnOlderResponses() throws {
        // A v2.2 card names its topic; a pre-topic (v2.0/v2.1) card has no
        // `topic` key at all. Both must decode — the second one is exactly
        // what an already-stored job result looks like after this update.
        let v22 = """
        {"id":"c1","type":"direct_recall","front":"f","back":"b","explanation":"",
         "difficulty":2,"tags":[],"lowConfidence":false,"options":null,
         "correctOption":null,"topic":"İnflamasyon"}
        """
        let legacy = """
        {"id":"c2","type":"direct_recall","front":"f","back":"b","explanation":"",
         "difficulty":2,"tags":[],"lowConfidence":false}
        """
        let decoder = JSONDecoder()
        let withTopic = try decoder.decode(RemoteCard.self, from: Data(v22.utf8))
        let without = try decoder.decode(RemoteCard.self, from: Data(legacy.utf8))
        XCTAssertEqual(withTopic.topic, "İnflamasyon")
        XCTAssertNil(without.topic)
    }

    // MARK: Five-option cards (§13.3)

    func testSoundOptionsSurviveTheMapping() throws {
        let decoded = success(
            cards: [card(type: .multipleChoice, options: remoteOptions(correctAt: 2), correctOption: 2)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

        XCTAssertEqual(knowledge.cards[0].options?.count, 5)
        XCTAssertEqual(knowledge.cards[0].options?[2].isCorrect, true)
        XCTAssertEqual(knowledge.cards[0].options?[1].why, "yanlış çünkü …")
    }

    /// The server states the answer twice (`correct` and `correctOption`) so
    /// that a disagreement is visible. If the two disagree here, neither can be
    /// trusted and the card falls back to a plain one rather than asking a
    /// question with the wrong key.
    func testDisagreeingAnswerKeyDropsTheOptions() throws {
        let decoded = success(
            cards: [card(type: .multipleChoice, options: remoteOptions(correctAt: 0), correctOption: 3)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

        XCTAssertNil(knowledge.cards[0].options)
        // The card itself is kept: its front and back are fine.
        XCTAssertEqual(knowledge.cards.count, 1)
    }

    func testMalformedOptionsAreIgnoredRatherThanShownHalfBuilt() throws {
        let short = Array(remoteOptions().prefix(3))
        let decoded = success(
            cards: [card(type: .multipleChoice, options: short, correctOption: 0)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        XCTAssertNil(try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: []).cards[0].options)
    }

    /// A v2.0 response, or any plain card: no options, no special case.
    func testPlainCardHasNoOptions() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        XCTAssertNil(try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: []).cards[0].options)
    }

    /// Options on a card that did not claim to be five-option are not promoted:
    /// the type is what the server committed to.
    func testOptionsOnAPlainTypeAreIgnored() throws {
        let decoded = success(
            cards: [card(options: remoteOptions(), correctOption: 0)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        XCTAssertNil(try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: []).cards[0].options)
    }

    /// Decoded since Faz 6 and dropped on the floor ever since. It is what
    /// Bilgilerim's "Gözden geçir" list and the review badge read, i.e. the
    /// whole of §13.3 rule 6 as Faz 6 answers it.
    func testLowConfidenceReachesTheCard() throws {
        let decoded = success(
            cards: [card(lowConfidence: true)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        XCTAssertTrue(try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: []).cards[0].lowConfidence)

        let confident = success(
            cards: [card(lowConfidence: false)],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        XCTAssertFalse(try BackendCardProvider.map(confident, elapsedMs: 100).cards[0].lowConfidence)
    }

    func testAutoAcceptedCardIsKeptAndActive() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

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
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

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
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

        XCTAssertEqual(knowledge.cards.count, 1)
        XCTAssertFalse(knowledge.cards[0].requiresUserApproval)
    }

    /// The same "an older client must not choke on a newer server" rule
    /// `status` and `decision` already follow. A strict enum here failed the
    /// *whole* response, and a decode failure is reported as `schemaInvalid` —
    /// permanent — so one new card type would have cost every card on the page,
    /// for good.
    func testAnUnknownCardTypeDropsThatCardRatherThanTheWholePage() throws {
        let json = """
        {
          "output": {
            "requestId": "job-1",
            "readText": "Sayfa metni",
            "cards": [
              {"id": "card_1", "type": "direct_recall", "front": "Ön", "back": "Arka",
               "explanation": "", "difficulty": 2, "tags": [], "lowConfidence": false},
              {"id": "card_2", "type": "yeni_tip_2027", "front": "Ön", "back": "Arka",
               "explanation": "", "difficulty": 2, "tags": [], "lowConfidence": false}
            ],
            "usage": {"provider": "openai", "model": "m", "inputTokens": 1,
                      "outputTokens": 1, "estimatedCostUSD": 0}
          },
          "gate": {"verdicts": [], "warnings": []},
          "cardPromptVersion": "v2.3"
        }
        """
        let decoded = try JSONDecoder().decode(RemoteCardsSuccess.self, from: Data(json.utf8))
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 10)

        XCTAssertEqual(knowledge.cards.count, 1)
        XCTAssertEqual(knowledge.cards[0].type, .directRecall)
    }

    func testEveryCardRejectedIsTreatedAsSourceInsufficient() {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "reject")]
        )
        XCTAssertThrowsError(try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])) { error in
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testNoCardsAtAllIsTreatedAsSourceInsufficient() {
        let decoded = success(cards: [], verdicts: [])
        XCTAssertThrowsError(try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])) { error in
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testEmptyExplanationBecomesNilNotAnEmptyString() throws {
        let decoded = success(
            cards: [card(explanation: "")],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])
        XCTAssertNil(knowledge.cards[0].explanation)
    }

    func testConcernComesFromTheGateWarnings() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")],
            warnings: ["2 kart pasaj limitini aştığı için reddedildi."]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

        XCTAssertNotNil(knowledge.sourceConcern)
        XCTAssertTrue(knowledge.sourceConcern?.contains("pasaj limitini") ?? false)
    }

    func testNoWarningsMeansNoConcern() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])
        XCTAssertNil(knowledge.sourceConcern)
    }

    func testModelRunCarriesTheRealUsageAndThePromptVersionFromTheResponse() throws {
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        // No server ledger in this response — the fallback reconstructs one
        // line from the card payload's own usage block, so a deployment that
        // predates per-call accounting still records its call.
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 1234, accounting: [])

        XCTAssertEqual(knowledge.modelRuns.count, 1)
        let run = knowledge.modelRuns.first
        XCTAssertEqual(run?.requestId, "req-1")
        XCTAssertEqual(run?.provider, "openai")
        XCTAssertEqual(run?.model, "gpt-5.6-sol")
        XCTAssertEqual(run?.purpose, "card_generation")
        XCTAssertEqual(run?.promptVersion, "2.0")
        XCTAssertEqual(run?.latencyMs, 1234)
        XCTAssertEqual(run?.inputTokens, 1012)
        XCTAssertEqual(run?.outputTokens, 571)
        XCTAssertEqual(run?.success, true)
    }

    func testServerLedgerWinsOverTheSingleLineFallback() throws {
        // When the server reports its own ledger it is authoritative: it saw
        // every attempt, including the ones that failed before this phone was
        // even awake, and it knows the prices. Recomputing anything here would
        // be a second answer to a settled question.
        let decoded = success(
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let ledger = [
            ModelRunMetadata(
                requestId: "job-9", attempt: 1, provider: "openai", model: "gpt-5.6-sol",
                purpose: "card_generation", promptVersion: "2.5", latencyMs: 290_000,
                inputTokens: 0, outputTokens: 0, estimatedCostUSD: 0, success: false,
                billing: ModelRunBilling.unmeasured, failureReason: "timeout"
            ),
            ModelRunMetadata(
                requestId: "job-9", attempt: 2, provider: "openai", model: "gpt-5.6-sol",
                purpose: "card_generation", promptVersion: "2.5", latencyMs: 62_000,
                inputTokens: 4000, cachedInputTokens: 3000, outputTokens: 2000,
                reasoningTokens: 1200, estimatedCostUSD: 0.0665
            ),
        ]

        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 1234, accounting: ledger)

        XCTAssertEqual(knowledge.modelRuns.count, 2)
        XCTAssertEqual(knowledge.modelRuns.first?.billing, ModelRunBilling.unmeasured)
        XCTAssertEqual(knowledge.modelRuns.last?.cachedInputTokens, 3000)
        XCTAssertEqual(knowledge.modelRuns.last?.reasoningTokens, 1200)
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
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])

        XCTAssertEqual(knowledge.canonicalClaim, "Anafilaksi tedavisi")
        XCTAssertEqual(knowledge.tags, ["Acil", "Farmakoloji", "Dahiliye"])
    }

    func testCanonicalClaimFallsBackToFirstFrontWhenReadTextIsEmpty() throws {
        let decoded = success(
            readText: "   ",
            cards: [card()],
            verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")]
        )
        let knowledge = try BackendCardProvider.map(decoded, elapsedMs: 100, accounting: [])
        XCTAssertEqual(knowledge.canonicalClaim, "Ön yüz")
    }

    // MARK: Job state (docs/ADR-006)

    private func view(
        status: String,
        result: RemoteCardsSuccess? = nil,
        error: String? = nil,
        retryable: Bool? = nil
    ) -> RemoteJobView {
        RemoteJobView(jobId: "job-1", status: status, result: result, error: error, retryable: retryable)
    }

    private func readySuccess() -> RemoteCardsSuccess {
        success(cards: [card()], verdicts: [RemoteCardVerdict(cardId: "card_1", decision: "auto_accept")])
    }

    /// An id the server has never heard of is simply absent from the poll's
    /// array. That absence is what tells the provider to upload the page — it
    /// is the normal first step of every capture, not an error.
    func testAbsentJobIsSubmitted() {
        XCTAssertEqual(BackendCardProvider.action(for: nil), .submit)
    }

    func testQueuedAndProcessingJobsAreWaitedFor() {
        XCTAssertEqual(BackendCardProvider.action(for: view(status: "queued")), .wait)
        XCTAssertEqual(BackendCardProvider.action(for: view(status: "processing")), .wait)
    }

    func testReadyJobUsesItsResult() {
        XCTAssertEqual(
            BackendCardProvider.action(for: view(status: "ready", result: readySuccess())),
            .useResult
        )
    }

    /// Waiting forever for a row that says it is finished but carries nothing
    /// would look exactly like a hung page. Better to say so.
    func testReadyJobWithoutAResultFailsRatherThanWaiting() {
        XCTAssertEqual(
            BackendCardProvider.action(for: view(status: "ready")),
            .failPermanently("Biten işte sonuç yok.")
        )
    }

    /// The server already decides what is worth retrying (§17); repeating that
    /// judgement here is how the two would drift.
    ///
    /// A transient failure must stay *distinguishable* from a permanent one
    /// rather than collapsing into one "failed": `generate()` re-uploads the
    /// page for the first and gives up on the second. Reporting a retryable
    /// failure as an answer instead would deadlock the page — every later
    /// attempt would poll, find the same old failure, and fail again without
    /// ever sending the photo.
    func testFailedJobFollowsTheServersRetryableVerdict() {
        XCTAssertEqual(
            BackendCardProvider.action(for: view(status: "failed", error: "OpenAI 503", retryable: true)),
            .failTransiently("OpenAI 503")
        )
        XCTAssertEqual(
            BackendCardProvider.action(for: view(status: "failed", error: "şema hatası", retryable: false)),
            .failPermanently("şema hatası")
        )
    }

    /// A missing `retryable` is read as "do not retry". The server always sends
    /// one, so this only bites on a malformed row — and quietly re-uploading a
    /// page forever is the worse of the two ways to be wrong.
    func testFailedJobWithoutAVerdictIsNotRetried() {
        guard case .failPermanently = BackendCardProvider.action(for: view(status: "failed")) else {
            return XCTFail("Kararsız bir hata tekrar denenmemeli")
        }
    }

    /// An older build must not turn a status the server added later into a
    /// permanently failed page — transient means the queue tries again, and by
    /// then the app may well have been updated.
    func testUnknownStatusIsTreatedAsTransient() {
        guard case .failTransiently = BackendCardProvider.action(for: view(status: "paused")) else {
            return XCTFail("Bilinmeyen durum geçici hata olmalı")
        }
    }

    /// Short while a page is likely to finish, longer afterwards, so a slow one
    /// does not cost dozens of pointless round trips.
    func testPollIntervalBacksOff() {
        XCTAssertEqual(BackendCardProvider.pollInterval(afterWaiting: 0), 3)
        XCTAssertEqual(BackendCardProvider.pollInterval(afterWaiting: 29), 3)
        XCTAssertEqual(BackendCardProvider.pollInterval(afterWaiting: 30), 5)
        XCTAssertEqual(BackendCardProvider.pollInterval(afterWaiting: 119), 5)
        XCTAssertEqual(BackendCardProvider.pollInterval(afterWaiting: 120), 10)
    }
}
