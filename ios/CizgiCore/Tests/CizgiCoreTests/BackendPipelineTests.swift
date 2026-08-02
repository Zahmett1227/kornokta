import XCTest
import CoreGraphics
@testable import CizgiCore

/// Backend stub. Records what it was asked and replays a canned reply, so the
/// cloud path is exercised with no network and no device token.
actor StubBackend: BackendCalling {
    private let result: Result<RemoteRecognition, BackendError>
    private(set) var requests: [(jobId: String, mimeType: String, localLines: [LocalLine])] = []

    init(_ result: Result<RemoteRecognition, BackendError>) {
        self.result = result
    }

    func recognize(
        jobId: String,
        imageData: Data,
        mimeType: String,
        localLines: [LocalLine]
    ) async throws -> RemoteRecognition {
        requests.append((jobId, mimeType, localLines))
        return try result.get()
    }
}

private func remoteLine(_ id: String, _ text: String, y: Double) -> RemoteLine {
    RemoteLine(lineId: id, text: text, confidence: 0.97, x: 0.1, y: y, width: 0.8, height: 0.04)
}

private func remote(
    _ lines: [RemoteLine],
    decision: RemoteDecision? = .autoAccept
) -> RemoteRecognition {
    RemoteRecognition(
        jobId: "job",
        page: RemotePage(imageWidth: 1600, imageHeight: 1200, elapsedMs: 400, lines: lines),
        reconciliation: decision.map {
            RemoteReconciliation(
                decision: $0,
                reason: "test",
                text: lines.map(\.text).joined(separator: "\n"),
                lines: [],
                criticalLineIds: []
            )
        }
    )
}

private func localLine(_ id: String, _ text: String, y: Double) -> RecognizedLine {
    RecognizedLine(
        id: id,
        text: text,
        confidence: 0.9,
        box: CGRect(x: 0.1, y: y, width: 0.8, height: 0.04)
    )
}

final class BackendPipelineTests: XCTestCase {
    /// A real file, because the pipeline reads the image off disk to send it.
    private var imageURL: URL!

    override func setUpWithError() throws {
        imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: imageURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: imageURL)
    }

    /// Apple Vision's Turkish, as measured: no ı ş ğ İ at all.
    private let localPage = [
        localLine("line_00", "Anafilakside ilk secenek tedavi", y: 0.10),
        localLine("line_01", "0,3-0,5 mg IM adrenalindir.", y: 0.16),
    ]

    private let cloudPage = [
        remoteLine("g0", "Anafilakside ilk seçenek tedavi", y: 0.10),
        remoteLine("g1", "0,3–0,5 mg IM adrenalindir.", y: 0.16),
    ]

    func testPassageComesFromTheCloudNotTheLocalReading() async {
        // The whole point of the backend: Apple Vision cannot write Turkish,
        // so a passage built from it would carry 'secenek' into every card.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_00", "line_01"]),
            backend: StubBackend(.success(remote(cloudPage)))
        )
        let outcome = await pipeline.run(jobId: "job-1", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .ready)
        XCTAssertEqual(outcome.passage, "Anafilakside ilk seçenek tedavi 0,3–0,5 mg IM adrenalindir.")
        XCTAssertFalse(outcome.passage?.contains("secenek") ?? true)
    }

    func testOnlyTheSelectedRegionIsTakenFromTheCloudReading() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.success(remote(cloudPage)))
        )
        let outcome = await pipeline.run(jobId: "job-2", imageURL: imageURL)
        XCTAssertEqual(outcome.passage, "0,3–0,5 mg IM adrenalindir.")
    }

    func testCloudLinesArePairedByPositionNotById() async {
        // The engines number their own lines, so the ids never correspond.
        // Pairing by id would take the wrong line's text.
        let shuffled = [
            remoteLine("zzz", "0,3–0,5 mg IM adrenalindir.", y: 0.16),
            remoteLine("aaa", "Anafilakside ilk seçenek tedavi", y: 0.10),
        ]
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.success(remote(shuffled)))
        )
        let outcome = await pipeline.run(jobId: "job-3", imageURL: imageURL)
        XCTAssertEqual(outcome.passage, "0,3–0,5 mg IM adrenalindir.")
    }

    func testLocalReadingIsSentSoTheBackendCanCompare() async {
        let backend = StubBackend(.success(remote(cloudPage)))
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_00"]),
            backend: backend
        )
        _ = await pipeline.run(jobId: "job-4", imageURL: imageURL)

        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].localLines.count, 2)
        // Geometry travels with it, because the backend pairs on position.
        XCTAssertEqual(requests[0].localLines[0].y, 0.10, accuracy: 0.0001)
        XCTAssertEqual(requests[0].mimeType, "image/jpeg")
    }

    func testCriticalDisagreementAsksTheUserBeforeGeneratingAnything() async {
        // §19.2: a critical-token disagreement is never recorded silently, and
        // the check happens before generation so a disputed passage never
        // costs a model call.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            generator: FailingGenerator(error: .providerUnavailable("çağrılmamalıydı")),
            backend: StubBackend(.success(remote(cloudPage, decision: .quickConfirm)))
        )
        let outcome = await pipeline.run(jobId: "job-5", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .confirmationRequired)
        XCTAssertNil(outcome.knowledge)
        XCTAssertNotNil(outcome.passage)
    }

    func testRejectedPageNeverBecomesACard() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.success(remote(cloudPage, decision: .reject)))
        )
        let outcome = await pipeline.run(jobId: "job-6", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertNil(outcome.knowledge)
    }

    func testNetworkFailureIsRetryableAndKeepsTheCapture() async {
        // §21.2: a provider failure must not lose the capture or the local OCR.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.failure(.transient("bağlantı yok")))
        )
        let outcome = await pipeline.run(jobId: "job-7", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertEqual(outcome.failure, .providerUnavailable)
        XCTAssertNotNil(outcome.recognized)
        XCTAssertEqual(outcome.selectedLineIds, ["line_01"])
    }

    func testUnauthorizedIsNotRetriedForever() async {
        // A wrong device token is fixed by the user, not by waiting.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.failure(.unauthorized))
        )
        let outcome = await pipeline.run(jobId: "job-8", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .configuration)
    }

    func testMissingConfigurationIsPermanent() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.failure(.notConfigured("anahtar yok")))
        )
        let outcome = await pipeline.run(jobId: "job-9", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.failure, .configuration)
    }

    func testCloudReadingThatMissesTheMarkedRegionAsksInsteadOfFallingBack() async {
        // Falling back to the local text would quietly ship the reading we
        // know is wrong for Turkish, so the user is asked instead.
        let elsewhere = [remoteLine("g0", "sayfanın altındaki başka satır", y: 0.90)]
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"]),
            backend: StubBackend(.success(remote(elsewhere)))
        )
        let outcome = await pipeline.run(jobId: "job-10", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .confirmationRequired)
        XCTAssertNil(outcome.knowledge)
    }

    func testWithoutABackendTheLocalReadingIsStillUsed() async {
        // No backend configured is not an error: capture and the offline flow
        // have to keep working (§24.1).
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: localPage),
            selector: FixedSelection(lineIds: ["line_01"])
        )
        let outcome = await pipeline.run(jobId: "job-11", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .ready)
        XCTAssertEqual(outcome.passage, "0,3-0,5 mg IM adrenalindir.")
    }

    func testWithBackendKeepsTheSelectorAndTheCardLimit() async {
        // The copy-with-change helpers must not drop each other's setting.
        let backend = StubBackend(.success(remote(cloudPage)))
        let pipeline = CapturePipeline(recognizer: StubRecognizer(lines: localPage))
            .withSelector(FixedSelection(lineIds: ["line_00"]))
            .withMaxCards(2)
            .withBackend(backend)
        let outcome = await pipeline.run(jobId: "job-12", imageURL: imageURL)

        XCTAssertEqual(outcome.selectedLineIds, ["line_00"])
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1, "backend withSelector/withMaxCards sonrası düşmüş olabilir")
    }

    func testWithBackendSurvivesWithSelector() async {
        let backend = StubBackend(.success(remote(cloudPage)))
        let pipeline = CapturePipeline(recognizer: StubRecognizer(lines: localPage))
            .withBackend(backend)
            .withSelector(FixedSelection(lineIds: ["line_00"]))
        _ = await pipeline.run(jobId: "job-13", imageURL: imageURL)
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1, "withSelector backend'i düşürdü")
    }
}

final class LineOverlapTests: XCTestCase {
    func testBoxesOnTheSameLineOverlap() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertTrue(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.105, width: 0.8, height: 0.04))
    }

    func testBoxesOnDifferentLinesDoNot() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertFalse(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.50, width: 0.8, height: 0.04))
    }

    func testTouchingEdgesAreNotAnOverlap() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertFalse(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.14, width: 0.8, height: 0.04))
    }

    func testZeroSizedBoxNeverOverlaps() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertFalse(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.10, width: 0, height: 0))
    }
}

final class MimeTypeTests: XCTestCase {
    func testMapsTheExtensionsTheBackendAccepts() {
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.jpg")), "image/jpeg")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.PNG")), "image/png")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.tiff")), "image/tiff")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.pdf")), "application/pdf")
    }

    func testUnknownExtensionsDefaultToJpeg() {
        // The store writes .jpg, so this is the safe default; an unknown type
        // would otherwise be rejected by the backend with a 415.
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b")), "image/jpeg")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.heic")), "image/jpeg")
    }
}

final class ReconciliationPassthroughTests: XCTestCase {
    private var imageURL: URL!

    override func setUpWithError() throws {
        imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: imageURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: imageURL)
    }

    private let local = [
        RecognizedLine(id: "line_00", text: "0,3-0,5 mg IM adrenalindir.",
                       confidence: 0.9, box: CGRect(x: 0.1, y: 0.16, width: 0.8, height: 0.04))
    ]

    private func reply(decision: RemoteDecision, reason: String, flags: [String]) -> RemoteRecognition {
        RemoteRecognition(
            jobId: "job",
            page: RemotePage(
                imageWidth: 1600, imageHeight: 1200, elapsedMs: 300,
                lines: [RemoteLine(lineId: "g0", text: "0,3–0,5 mg IV adrenalindir.",
                                   confidence: 0.97, x: 0.1, y: 0.16, width: 0.8, height: 0.04)]
            ),
            reconciliation: RemoteReconciliation(
                decision: decision,
                reason: reason,
                text: "0,3–0,5 mg IV adrenalindir.",
                lines: [RemoteLineReconciliation(
                    lineId: "g0",
                    primaryText: "0,3–0,5 mg IV adrenalindir.",
                    secondaryText: "0,3-0,5 mg IM adrenalindir.",
                    agrees: false,
                    criticalTokenFlags: flags
                )],
                criticalLineIds: ["g0"]
            )
        )
    }

    func testTheReasonReachesTheCaller() async {
        // §19.2: a confirmation with no reason attached is one the user cannot
        // answer well. "check this page" invites a reflexive tap.
        let flag = "replace: kaynak [IM (route)] -> okuma [IV (route)]"
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: local),
            selector: FixedSelection(lineIds: ["line_00"]),
            backend: StubBackend(.success(reply(
                decision: .quickConfirm,
                reason: "1 satırda kritik değer uyuşmazlığı",
                flags: [flag]
            )))
        )
        let outcome = await pipeline.run(jobId: "job-r1", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .confirmationRequired)
        XCTAssertEqual(outcome.reconciliation?.reason, "1 satırda kritik değer uyuşmazlığı")
        // The flag names BOTH readings, which is what makes it answerable.
        let flags = outcome.reconciliation?.lines.flatMap(\.criticalTokenFlags) ?? []
        XCTAssertEqual(flags, [flag])
        XCTAssertTrue(flag.contains("IM"))
        XCTAssertTrue(flag.contains("IV"))
    }

    func testTheReasonSurvivesARejection() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: local),
            selector: FixedSelection(lineIds: ["line_00"]),
            backend: StubBackend(.success(reply(decision: .reject, reason: "Okunabilir satır yok.", flags: [])))
        )
        let outcome = await pipeline.run(jobId: "job-r2", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .permanentFailure)
        XCTAssertEqual(outcome.reconciliation?.reason, "Okunabilir satır yok.")
    }

    func testAnAcceptedPageStillCarriesItsReconciliation() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: local),
            selector: FixedSelection(lineIds: ["line_00"]),
            backend: StubBackend(.success(reply(decision: .autoAccept, reason: "İki motor da aynı metni okudu.", flags: [])))
        )
        let outcome = await pipeline.run(jobId: "job-r3", imageURL: imageURL)
        XCTAssertEqual(outcome.finalState, .ready)
        XCTAssertNotNil(outcome.reconciliation)
    }

    func testTheReasonSurvivesAGenerationFailure() async {
        // The reason belongs to the page, not to the happy path. A capture that
        // stops for some *other* reason still has to be able to say what the
        // two readings disagreed about — otherwise the confirmation screen asks
        // a question the user cannot answer (§19.2). Every exit after the cloud
        // step has to carry it, which is easy to drop one return at a time.
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: local),
            selector: FixedSelection(lineIds: ["line_00"]),
            generator: FailingGenerator(error: .providerUnavailable("ağ yok")),
            backend: StubBackend(.success(reply(
                decision: .autoAccept,
                reason: "İki motor da aynı metni okudu.",
                flags: []
            )))
        )
        let outcome = await pipeline.run(jobId: "job-r5", imageURL: imageURL)

        XCTAssertEqual(outcome.finalState, .temporaryFailure)
        XCTAssertEqual(outcome.reconciliation?.reason, "İki motor da aynı metni okudu.")
    }

    func testWithoutABackendThereIsNoReconciliationToShow() async {
        let pipeline = CapturePipeline(
            recognizer: StubRecognizer(lines: local),
            selector: FixedSelection(lineIds: ["line_00"])
        )
        let outcome = await pipeline.run(jobId: "job-r4", imageURL: imageURL)
        XCTAssertNil(outcome.reconciliation)
    }
}
