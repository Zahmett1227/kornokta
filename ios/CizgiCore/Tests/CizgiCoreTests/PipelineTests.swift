import XCTest
@testable import CizgiCore

/// Holds a concrete `CardGenerationError` rather than `any Error`, because
/// `CardGenerating` is Sendable and `Error` is not.
struct FailingGenerator: CardGenerating {
    let error: CardGenerationError
    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        throw error
    }
}

/// A canned vision generator: returns fixed cards without touching the passage,
/// the way `BackendCardProvider` returns cards read off the image. Records what
/// the pipeline asked for so the request-shaping can be checked.
actor RecordingGenerator: CardGenerating {
    private(set) var lastMaxCards: Int?
    private(set) var lastImageData: Data?
    private(set) var lastPassage: String?

    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        lastMaxCards = request.maxCards
        lastImageData = request.imageData
        lastPassage = request.passage
        return PipelineTestFixtures.knowledge()
    }
}

enum PipelineTestFixtures {
    static func knowledge(
        canonicalClaim: String = "İşaretli içerik",
        cards: [GeneratedCard]? = nil,
        modelRuns: [ModelRunMetadata] = []
    ) -> GeneratedKnowledge {
        GeneratedKnowledge(
            canonicalClaim: canonicalClaim,
            tags: ["Farmakoloji"],
            sourceConcern: nil,
            cards: cards ?? [
                GeneratedCard(
                    type: .directRecall,
                    front: "Anafilakside ilk doz nedir?",
                    back: "0,3–0,5 mg IM adrenalin",
                    explanation: nil,
                    sourceQuote: "",
                    riskFlags: []
                )
            ],
            modelRuns: modelRuns
        )
    }
}

/// Fixed-knowledge generator for the success path, with an optional ledger.
struct StubVisionGenerator: CardGenerating {
    var knowledge: GeneratedKnowledge = PipelineTestFixtures.knowledge()
    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        knowledge
    }
}

/// Faz 6 vision flow (docs/FAZ6-PLAN.md §2): marked full page →
/// `/api/cards-vision` → active cards. No local OCR, no marker detection, no
/// confirmation. The pre-Faz-6 OCR-flow pipeline tests were archived per §8.
final class CapturePipelineTests: XCTestCase {
    private var imageURL: URL!

    override func setUpWithError() throws {
        imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        // Undecodable bytes are sent as-is by `UploadImageEncoder`, so this is
        // enough of a "page" for the pipeline to read and forward.
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: imageURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: imageURL)
    }

    private func pipeline(generator: any CardGenerating) -> CapturePipeline {
        CapturePipeline(generator: generator)
    }

    func testMarkedPageBecomesReadyWithActiveCards() async {
        let outcome = await pipeline(generator: StubVisionGenerator()).run(jobId: "job-1", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .ready)
        XCTAssertFalse(outcome.knowledge?.cards.isEmpty ?? true)
        XCTAssertEqual(outcome.generatedGroups.count, 1)
        // No approval step in Faz 6.
        XCTAssertFalse(outcome.knowledge?.cards.first?.requiresUserApproval ?? true)
    }

    func testTheOneGroupSpansTheWholePage() async {
        let outcome = await pipeline(generator: StubVisionGenerator()).run(jobId: "job-2", imageURL: imageURL)
        let box = outcome.annotationGroups.first?.boundingBox
        XCTAssertEqual(box, NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testModelRunReachesTheOutcome() async {
        let modelRun = ModelRunMetadata(
            requestId: "req-1", attempt: 1, provider: "openai", model: "gpt-5.6-sol",
            purpose: "card_generation", promptVersion: "2.0", latencyMs: 120,
            inputTokens: 1012, outputTokens: 571, estimatedCostUSD: 0
        )
        let generator = StubVisionGenerator(knowledge: PipelineTestFixtures.knowledge(modelRuns: [modelRun]))
        let outcome = await pipeline(generator: generator).run(jobId: "job-3", imageURL: imageURL)
        XCTAssertEqual(outcome.modelRuns.first?.requestId, "req-1")
        XCTAssertEqual(outcome.modelRuns.first?.promptVersion, "2.0")
    }

    func testAFailedGenerationStillCarriesWhatItSpent() async {
        // The gap this closes: a page that never produces a card still paid for
        // every attempt it made. Reporting the failure without the ledger was
        // how those attempts stayed invisible to Ayarlar → Kullanım.
        let spent = ModelRunMetadata(
            requestId: "job-5", attempt: 2, provider: "openai", model: "gpt-5.6-sol",
            purpose: "card_generation", promptVersion: "2.5", latencyMs: 240_000,
            inputTokens: 4200, outputTokens: 8192, reasoningTokens: 7000,
            estimatedCostUSD: 0.267, success: false,
            billing: ModelRunBilling.measured, failureReason: "incomplete_max_output_tokens"
        )
        let generator = ThrowingVisionGenerator(
            failure: CardGenerationFailure(
                error: .providerUnavailable("Model üretimi tamamlamadı."),
                accounting: [spent]
            )
        )

        let outcome = await pipeline(generator: generator).run(jobId: "job-5", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertEqual(outcome.modelRuns.count, 1)
        XCTAssertEqual(outcome.modelRuns.first?.failureReason, "incomplete_max_output_tokens")
        XCTAssertEqual(outcome.modelRuns.first?.success, false)
    }

    func testNoContentIsAPaidOutcomeToo() async {
        // "Nothing marked on this page" is a verdict the model reached by
        // reading the whole page — billed like any other call.
        let spent = ModelRunMetadata(
            requestId: "job-6", attempt: 1, provider: "openai", model: "gpt-5.6-sol",
            purpose: "card_generation", promptVersion: "2.5", latencyMs: 30_000,
            inputTokens: 3000, outputTokens: 200, estimatedCostUSD: 0.021
        )
        let generator = ThrowingVisionGenerator(
            failure: CardGenerationFailure(error: .sourceInsufficient, accounting: [spent])
        )

        let outcome = await pipeline(generator: generator).run(jobId: "job-6", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .noContent)
        XCTAssertEqual(outcome.modelRuns.count, 1)
    }

    func testUnreadableImageIsAPermanentFailure() async {
        let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-does-not-exist.jpg")
        let outcome = await pipeline(generator: StubVisionGenerator()).run(jobId: "job-4", imageURL: missing)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .configuration)
    }

    func testSourceInsufficientIsATerminalFailureNotAConfirmation() async {
        // Faz 6 has no confirmation lane: "the model found nothing to make cards
        // from" is a terminal permanent failure, not a bounce to the user.
        let outcome = await pipeline(generator: FailingGenerator(error: .sourceInsufficient))
            .run(jobId: "job-5", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        // Reported as "nothing marked here", not as a broken response: with
        // photos coming from the library this is an ordinary outcome, and the
        // user needs to know which of the two happened.
        XCTAssertEqual(outcome.failure, .noContent)
    }

    func testCoverageSurvivesAPageThatProducedNoCards() async {
        // The page with no cards is the page whose register matters most:
        // every mark on it is uncovered by definition. It reaches the queue on
        // the *failure* path, so the register has to travel there too — the
        // same reason `modelRuns` sits on the outcome rather than inside
        // `knowledge` (docs/PLAN-kapsama-sozlesmesi.md).
        let coverage = PageCoverage(
            reported: true,
            uncovered: [PageMark(kind: .symbol, quote: "★ hiç kartlaşmadı", source: .generator)]
        )
        let generator = ThrowingVisionGenerator(
            failure: CardGenerationFailure(error: .sourceInsufficient, accounting: [], coverage: coverage)
        )

        let outcome = await pipeline(generator: generator).run(jobId: "job-9", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .noContent)
        XCTAssertEqual(outcome.coverage?.uncovered.map(\.quote), ["★ hiç kartlaşmadı"])
    }

    func testGeneratorOutageIsTransient() async {
        let outcome = await pipeline(generator: FailingGenerator(error: .providerUnavailable("ağ yok")))
            .run(jobId: "job-6", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertEqual(outcome.failure, .providerUnavailable)
    }

    func testMalformedResponseIsNotRetriedForever() async {
        let outcome = await pipeline(generator: FailingGenerator(error: .schemaInvalid("bozuk")))
            .run(jobId: "job-7", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .invalidResponse)
    }

    func testBudgetExceededDoesNotRetryForever() async {
        let outcome = await pipeline(generator: FailingGenerator(error: .budgetExceeded))
            .run(jobId: "job-8", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .budgetExceeded)
    }

    func testEveryGeneratorErrorHasARetryClassification() {
        // Guards the mapping itself: a new error case must be classified
        // deliberately, not fall into the catch-all as "transient".
        let cases: [CardGenerationError] = [
            .sourceInsufficient,
            .schemaInvalid("x"),
            .providerUnavailable("x"),
            .budgetExceeded
        ]
        for error in cases {
            let kind = CapturePipeline.failureKind(for: error)
            switch error {
            case .providerUnavailable:
                XCTAssertTrue(kind.isTransient, "\(error) yeniden denenebilir olmalı")
            default:
                XCTAssertFalse(kind.isTransient, "\(error) sonsuza dek denenmemeli")
            }
        }
    }

    func testRerunningTheSameJobGivesTheSameResult() async {
        // Idempotence: replaying a job must not drift (§17).
        let p = pipeline(generator: StubVisionGenerator())
        let first = await p.run(jobId: "job-9", imageURL: imageURL)
        let second = await p.run(jobId: "job-9", imageURL: imageURL)
        XCTAssertEqual(first, second)
    }

    func testMaxCardsSettingReachesTheGenerator() async {
        // The "Pasaj başına kart" setting was displayed in Ayarlar but never
        // reached the request, so changing it did nothing.
        let recorder = RecordingGenerator()
        let p = pipeline(generator: recorder).withMaxCards(2)
        _ = await p.run(jobId: "job-10", imageURL: imageURL)
        let seen = await recorder.lastMaxCards
        XCTAssertEqual(seen, 2)
    }

    func testMaxCardsIsClampedToAtLeastOne() async {
        // A zero ceiling would produce a page that silently generates nothing.
        let recorder = RecordingGenerator()
        let p = pipeline(generator: recorder).withMaxCards(0)
        _ = await p.run(jobId: "job-11", imageURL: imageURL)
        let seen = await recorder.lastMaxCards
        XCTAssertEqual(seen, 1)
    }

    func testTheGeneratorReceivesThePageBytes() async {
        // The vision endpoint reads the marked page itself, so the pipeline must
        // actually forward the page bytes to the generator.
        let recorder = RecordingGenerator()
        _ = await pipeline(generator: recorder).run(jobId: "job-12", imageURL: imageURL)
        let sent = await recorder.lastImageData
        XCTAssertEqual(sent, Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))
    }
}

final class MockCardProviderTests: XCTestCase {

    func testProducesCardsCarryingTheSourceQuote() async throws {
        // "Kaynağı Göster" must work from Faz 1 (§5.5).
        let passage = "Hiperkalemide EKG'de en erken bulgu sivri T dalgasıdır."
        let knowledge = try await MockCardProvider().generate(
            CardGenerationRequest(jobId: "j", passage: passage)
        )
        XCTAssertFalse(knowledge.cards.isEmpty)
        for card in knowledge.cards {
            XCTAssertEqual(card.sourceQuote, passage)
        }
    }

    func testRespectsTheCardLimit() async throws {
        let knowledge = try await MockCardProvider().generate(
            CardGenerationRequest(jobId: "j", passage: "Bir iki üç dört beş altı", maxCards: 1)
        )
        XCTAssertEqual(knowledge.cards.count, 1)
    }

    func testEmptyPassageIsRejectedRatherThanInvented() async {
        do {
            _ = try await MockCardProvider().generate(
                CardGenerationRequest(jobId: "j", passage: "   ")
            )
            XCTFail("boş pasaj kart üretmemeli")
        } catch {
            XCTAssertEqual(error as? CardGenerationError, .sourceInsufficient)
        }
    }

    func testClozeBlanksAWordFromThePassage() {
        let card = MockCardProvider.clozeCard(for: "Hiperkalemide sivri T dalgası görülür")
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.type, .cloze)
        XCTAssertTrue(card?.front.contains("_") ?? false)
    }

    func testShortPassageHasNoCloze() {
        XCTAssertNil(MockCardProvider.clozeCard(for: "Kısa üç söz"))
    }
}

/// Throws a `CardGenerationFailure` — the real provider's error, which carries
/// the ledger. `FailingGenerator` covers the bare-enum case the offline
/// stand-in throws.
struct ThrowingVisionGenerator: CardGenerating {
    let failure: CardGenerationFailure
    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        throw failure
    }
}

/// The diagnosis half of a failed run: what the user actually reads.
extension CapturePipelineTests {

    func testTheServersOwnMessageReachesTheOutcome() async {
        // Before this the string was dropped at `failureKind(for:)` and the
        // screen printed a classification, so a job that was merely still
        // generating and one that had burned its whole output budget looked
        // identical.
        let generator = ThrowingVisionGenerator(
            failure: CardGenerationFailure(
                error: .providerUnavailable("Model üretimi tamamlamadı: max_output_tokens."),
                accounting: []
            )
        )

        let outcome = await pipeline(generator: generator).run(jobId: "job-7", imageURL: imageURL)

        XCTAssertEqual(outcome.failureDetail, "Model üretimi tamamlamadı: max_output_tokens.")
        XCTAssertEqual(
            FailureDiagnosis.text(detail: outcome.failureDetail, kind: outcome.failure),
            "Model üretimi tamamlamadı: max_output_tokens."
        )
    }

    func testAQuotaFailureIsClassifiedAsRateLimitedFromTheLedgersReason() async {
        // The phone never sees OpenAI's status code; the reason the backend
        // records for the cost ledger is what carries it across.
        let spent = ModelRunMetadata(
            requestId: "job-8", attempt: 1, provider: "openai", model: "gpt-5.6-sol",
            purpose: "card_generation", promptVersion: "2.5", latencyMs: 400,
            inputTokens: 0, outputTokens: 0, estimatedCostUSD: 0, success: false,
            billing: ModelRunBilling.none, failureReason: "insufficient_quota"
        )
        let generator = ThrowingVisionGenerator(
            failure: CardGenerationFailure(
                error: .providerUnavailable("OpenAI kredisi/kotası tükendi (insufficient_quota)."),
                accounting: [spent]
            )
        )

        let outcome = await pipeline(generator: generator).run(jobId: "job-8", imageURL: imageURL)

        XCTAssertEqual(outcome.failure, .rateLimited)
        // Still transient, so the page is retried rather than locked out — the
        // first attempt after a top-up succeeds without needing `force`.
        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertEqual(outcome.failureDetail, "OpenAI kredisi/kotası tükendi (insufficient_quota).")
    }

    func testABareErrorWithoutADetailStillFallsBackToTheClassification() async {
        let outcome = await pipeline(generator: FailingGenerator(error: .budgetExceeded))
            .run(jobId: "job-9", imageURL: imageURL)
        XCTAssertNil(outcome.failureDetail)
        XCTAssertEqual(
            FailureDiagnosis.text(detail: outcome.failureDetail, kind: outcome.failure),
            FailureKind.budgetExceeded.message
        )
    }
}
