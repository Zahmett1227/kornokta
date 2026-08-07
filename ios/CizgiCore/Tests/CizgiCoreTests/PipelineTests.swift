import XCTest
import CoreGraphics
@testable import CizgiCore

/// Deterministic stand-in for Vision. The Faz 6 vision pipeline no longer runs
/// local OCR, but `CapturePipeline.init` still takes a recognizer (retained
/// seam), so tests need one to construct the pipeline.
struct StubRecognizer: TextRecognizing {
    var lines: [RecognizedLine]
    var error: TextRecognitionError?

    func recognize(imageAt url: URL) async throws -> RecognizedPage {
        if let error { throw error }
        return RecognizedPage(lines: lines, elapsed: 0.05)
    }
}

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
        modelRun: ModelRunMetadata? = nil
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
            modelRun: modelRun
        )
    }
}

/// Fixed-knowledge generator for the success path, with an optional modelRun.
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
        CapturePipeline(recognizer: StubRecognizer(lines: []), generator: generator)
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
            requestId: "req-1", provider: "openai", model: "gpt-5.6-sol", purpose: "card_generation",
            promptVersion: "2.0", latencyMs: 120, inputTokens: 1012, outputTokens: 571, estimatedCostUSD: 0
        )
        let generator = StubVisionGenerator(knowledge: PipelineTestFixtures.knowledge(modelRun: modelRun))
        let outcome = await pipeline(generator: generator).run(jobId: "job-3", imageURL: imageURL)
        XCTAssertEqual(outcome.modelRun?.requestId, "req-1")
        XCTAssertEqual(outcome.modelRun?.promptVersion, "2.0")
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
