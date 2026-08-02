import XCTest
import CoreGraphics
@testable import CizgiCore

/// Deterministic stand-in for Vision so the pipeline is testable anywhere.
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

/// Records what the pipeline actually asked for. An actor because
/// `CardGenerating` is Sendable and this one has mutable state.
actor RecordingGenerator: CardGenerating {
    private(set) var lastMaxCards: Int?
    private(set) var lastPassage: String?

    func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        lastMaxCards = request.maxCards
        lastPassage = request.passage
        return try await MockCardProvider().generate(request)
    }
}

private func line(_ id: String, _ text: String, y: Double) -> RecognizedLine {
    RecognizedLine(
        id: id,
        text: text,
        confidence: 0.95,
        box: CGRect(x: 0.1, y: y, width: 0.8, height: 0.04)
    )
}

final class CapturePipelineTests: XCTestCase {
    let imageURL = URL(fileURLWithPath: "/tmp/page.jpg")

    let page = [
        line("line_00", "Anafilakside ilk seçenek tedavi", y: 0.10),
        line("line_01", "0,3–0,5 mg IM adrenalindir.", y: 0.16),
        line("line_02", "İkinci basamak sıvı replasmanıdır.", y: 0.22)
    ]

    func testSelectedLinesBecomeCards() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00", "line_01"])
        )
        let outcome = await pipeline.run(jobId: "job-1", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .ready)
        XCTAssertEqual(outcome.selectedLineIds, ["line_00", "line_01"])
        XCTAssertEqual(
            outcome.passage,
            "Anafilakside ilk seçenek tedavi 0,3–0,5 mg IM adrenalindir."
        )
        XCTAssertFalse(outcome.knowledge?.cards.isEmpty ?? true)
    }

    func testPassageFollowsPageOrderNotTapOrder() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            // Tapped bottom line first.
            selector: FixedSelection(lineIds: ["line_01", "line_00"])
        )
        let outcome = await pipeline.run(jobId: "job-2", imageURL: imageURL)
        XCTAssertEqual(
            outcome.passage,
            "Anafilakside ilk seçenek tedavi 0,3–0,5 mg IM adrenalindir."
        )
    }

    func testNoSelectionAsksTheUserInsteadOfGuessing() async {
        // §19.3: no marker and no manual selection must not become a card.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: ManualSelectionOnly()
        )
        let outcome = await pipeline.run(jobId: "job-3", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .confirmationRequired)
        XCTAssertNil(outcome.knowledge)
    }

    func testUnreadableImageIsAPermanentFailure() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: [], error: .cannotReadImage(imageURL))
        )
        let outcome = await pipeline.run(jobId: "job-4", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .configuration)
    }

    func testPageWithNoTextIsRejected() async {
        let pipeline = CapturePipeline(recognizer: StubRecognizer(lines: []))
        let outcome = await pipeline.run(jobId: "job-5", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
    }

    func testGeneratorOutageIsTransientAndKeepsTheOCRResult() async {
        // §21.2: a provider failure must not lose the capture or the local OCR.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: FailingGenerator(error: .providerUnavailable("bağlantı yok"))
        )
        let outcome = await pipeline.run(jobId: "job-6", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertEqual(outcome.failure, .providerUnavailable)
        XCTAssertNotNil(outcome.recognized)
        XCTAssertEqual(outcome.passage, "Anafilakside ilk seçenek tedavi")
    }

    func testMalformedResponseIsNotRetriedForever() async {
        // §17: a schema violation will violate the schema again on replay, so
        // it must not go round the retry loop. This case used to be reported as
        // transient, which contradicted `FailureKind.invalidResponse`.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: FailingGenerator(error: .schemaInvalid("bozuk"))
        )
        let outcome = await pipeline.run(jobId: "job-6b", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .invalidResponse)
        // The capture and the local OCR survive either way (§21.2).
        XCTAssertNotNil(outcome.recognized)
        XCTAssertEqual(outcome.passage, "Anafilakside ilk seçenek tedavi")
    }

    func testThinPassageAsksTheUserRatherThanRetrying() async {
        // §12.1/§19.3: too little source is not a machine failure — replaying
        // it cannot help, so the user is asked to widen the selection.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: FailingGenerator(error: .sourceInsufficient)
        )
        let outcome = await pipeline.run(jobId: "job-6c", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .confirmationRequired)
        XCTAssertNil(outcome.knowledge)
        XCTAssertEqual(outcome.selectedLineIds, ["line_00"])
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

    func testBudgetExceededDoesNotRetryForever() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: FailingGenerator(error: .budgetExceeded)
        )
        let outcome = await pipeline.run(jobId: "job-7", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .budgetExceeded)
    }

    func testRerunningTheSameJobGivesTheSameResult() async {
        // Idempotence: replaying a job must not drift (§17).
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_01"])
        )
        let first = await pipeline.run(jobId: "job-8", imageURL: imageURL)
        let second = await pipeline.run(jobId: "job-8", imageURL: imageURL)
        XCTAssertEqual(first, second)
    }

    func testMaxCardsSettingReachesTheGenerator() async {
        // The "Pasaj başına kart" setting was displayed in Ayarlar but never
        // reached the request, so changing it did nothing.
        let recorder = RecordingGenerator()
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00", "line_01"]),
            generator: recorder
        ).withMaxCards(2)

        _ = await pipeline.run(jobId: "job-10", imageURL: imageURL)
        let seen = await recorder.lastMaxCards
        XCTAssertEqual(seen, 2)
    }

    func testMaxCardsIsClampedToAtLeastOne() async {
        // A zero ceiling would produce a page that silently generates nothing.
        let recorder = RecordingGenerator()
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: recorder
        ).withMaxCards(0)

        _ = await pipeline.run(jobId: "job-11", imageURL: imageURL)
        let seen = await recorder.lastMaxCards
        XCTAssertEqual(seen, 1)
    }

    func testWithMaxCardsKeepsTheSelector() async {
        // `withSelector` and `withMaxCards` are both copy-with-change; one must
        // not drop what the other set.
        let pipeline = CapturePipeline(recognizer: StubRecognizer(lines: page))
            .withSelector(FixedSelection(lineIds: ["line_00"]))
            .withMaxCards(3)
        let outcome = await pipeline.run(jobId: "job-12", imageURL: imageURL)
        XCTAssertEqual(outcome.selectedLineIds, ["line_00"])
        XCTAssertEqual(outcome.finalState, .ready)
    }

    func testUnknownLineIdsAreIgnored() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_99"])
        )
        let outcome = await pipeline.run(jobId: "job-9", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .confirmationRequired)
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
