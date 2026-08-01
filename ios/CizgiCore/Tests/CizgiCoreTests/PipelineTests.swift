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
            generator: FailingGenerator(error: CardGenerationError.schemaInvalid("bozuk"))
        )
        let outcome = await pipeline.run(jobId: "job-6", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertNotNil(outcome.recognized)
        XCTAssertEqual(outcome.passage, "Anafilakside ilk seçenek tedavi")
    }

    func testBudgetExceededDoesNotRetryForever() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: page),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: FailingGenerator(error: CardGenerationError.budgetExceeded)
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
