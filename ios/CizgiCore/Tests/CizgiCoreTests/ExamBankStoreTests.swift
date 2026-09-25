import XCTest
import CryptoKit
import SwiftData
@testable import CizgiCore

/// The import (plan §7.1): verify every file against the manifest, swap the
/// bank in only when all of it checks out, and keep the old one otherwise.
final class ExamBankStoreTests: XCTestCase {
    private var scratch: URL!
    private var store: ExamBankStore!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cizgi-exam-bank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ExamBankStore(root: scratch.appendingPathComponent("ExamBank", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes a package the way `tools/exam_bank/package.py` does.
    @discardableResult
    private func makePackage(
        named name: String = "CizgiSoruBankasi",
        version: String = "2026-09-25.1",
        schemaVersion: Int = 1,
        tamper: ((URL) throws -> Void)? = nil,
        editManifest: ((inout [[String: Any]]) -> Void)? = nil
    ) throws -> URL {
        let package = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("pdf"), withIntermediateDirectories: true)

        let pdfBytes = Data("%PDF-1.4 sahte kitapçık".utf8)
        let pdfName = SHA256.hash(data: pdfBytes).map { String(format: "%02x", $0) }.joined()
        let pdfPath = "pdf/\(pdfName).pdf"
        try pdfBytes.write(to: package.appendingPathComponent(pdfPath))

        let questions = [
            ExamBankFixture.question("TUS-2019-1-T-001", pdf: pdfPath),
            ExamBankFixture.question("TUS-2019-1-T-002", pdf: pdfPath),
        ]
        let bankData = try ExamBankFixture.json(ExamBankFixture.document(questions: questions, version: version))
        try bankData.write(to: package.appendingPathComponent("bank.json"))

        var files: [[String: Any]] = []
        for (path, data) in [("bank.json", bankData), (pdfPath, pdfBytes)] {
            files.append(["path": path, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                          "bytes": data.count])
        }
        editManifest?(&files)
        let manifest: [String: Any] = [
            "bankVersion": version, "schemaVersion": schemaVersion, "builtAt": "2026-09-25T20:00:00+00:00",
            "files": files, "counts": ["papers": 1, "questions": questions.count],
            "gates": ["V1": ["pass": true]], "humanCheck": NSNull(),
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try tamper?(package)
        return package
    }

    func testInstallsAVerifiedPackageAndLoadsIt() throws {
        let package = try makePackage()
        var progress: [Double] = []
        let result = try store.install(from: package) { progress.append($0) }
        XCTAssertEqual(result.bank.counts.questions, 2)
        XCTAssertNil(result.replacedVersion)
        XCTAssertEqual(progress.last, 1)

        XCTAssertEqual(store.activeVersion, "2026-09-25.1")
        XCTAssertEqual(try store.loadActive()?.counts.questions, 2)
        XCTAssertEqual(store.activeManifest()?.counts.questions, 2)
        let question = try XCTUnwrap(store.loadActive()?.questions.first)
        XCTAssertNotNil(store.pdfURL(for: question.provenance[0].pdf))
        XCTAssertNil(store.pdfURL(for: "../manifest.json"))
        XCTAssertGreaterThan(store.diskUsage(), 0)

        let excluded = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "the booklets never go to iCloud (plan D10)")
    }

    func testACorruptFileStopsTheImportAndKeepsTheOldBank() throws {
        try store.install(from: makePackage(version: "2026-09-25.1"))
        let bad = try makePackage(version: "2026-09-26.1") { package in
            let pdf = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("pdf").path)[0]
            try Data("bozuldu".utf8).write(to: package.appendingPathComponent("pdf/\(pdf)"))
        }
        XCTAssertThrowsError(try store.install(from: bad)) { error in
            guard case .corruptFile(let path)? = error as? ExamBankInstallError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(path.hasPrefix("pdf/"))
        }
        XCTAssertEqual(store.activeVersion, "2026-09-25.1")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
        XCTAssertEqual(leftovers, ["2026-09-25.1", "active.json"], "no staging folder left behind")
    }

    func testANewVersionReplacesTheOldOneOnDisk() throws {
        try store.install(from: makePackage(version: "2026-09-25.1"))
        let result = try store.install(from: makePackage(version: "2026-09-25.2"))
        XCTAssertEqual(result.replacedVersion, "2026-09-25.1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted(),
                       ["2026-09-25.2", "active.json"])
    }

    func testReimportingTheSameVersionWorks() throws {
        try store.install(from: makePackage())
        XCTAssertNoThrow(try store.install(from: makePackage()))
        XCTAssertEqual(store.activeVersion, "2026-09-25.1")
    }

    func testRefusesWhatItCannotRead() throws {
        XCTAssertThrowsError(try store.install(from: makePackage(schemaVersion: 2))) {
            XCTAssertEqual($0 as? ExamBankInstallError, .unsupportedSchema(2))
        }
        let empty = scratch.appendingPathComponent("Bos", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.install(from: empty)) {
            XCTAssertEqual($0 as? ExamBankInstallError, .notAPackage)
        }
        let escaping = try makePackage(editManifest: { $0.append(["path": "../evil", "sha256": "0", "bytes": 1]) })
        XCTAssertThrowsError(try store.install(from: escaping)) {
            XCTAssertEqual($0 as? ExamBankInstallError, .unsafePath("../evil"))
        }
        XCTAssertNil(store.activeVersion)
    }

    func testAQuestionPointingAtAnUnshippedPDFIsRefused() throws {
        let package = try makePackage(editManifest: { files in files.removeAll { ($0["path"] as? String) != "bank.json" } })
        XCTAssertThrowsError(try store.install(from: package)) { error in
            guard case .missingPDF? = error as? ExamBankInstallError else { return XCTFail("\(error)") }
        }
    }

    func testRemoveDeletesEverything() throws {
        try store.install(from: makePackage())
        try store.remove()
        XCTAssertNil(store.activeVersion)
        XCTAssertNil(try store.loadActive())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testPathRules() {
        XCTAssertTrue(ExamBankStore.isSafePackagePath("bank.json"))
        XCTAssertTrue(ExamBankStore.isSafePackagePath(ExamBankFixture.pdfA))
        XCTAssertFalse(ExamBankStore.isSafePackagePath("pdf/../bank.json"))
        XCTAssertFalse(ExamBankStore.isSafePackagePath("pdf/ABC.pdf"))
        XCTAssertTrue(ExamBankStore.isSafeVersion("2026-09-25.12"))
        XCTAssertFalse(ExamBankStore.isSafeVersion("../2026-09-25.1"))
        XCTAssertFalse(ExamBankStore.isSafeVersion("2026-09-25"))
    }
}

/// The three SwiftData models (plan §7.3), in memory.
final class ExamModelsTests: XCTestCase {
    private var context: ModelContext!

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: ExamRun.self, ExamAttempt.self, ExamQuestionState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    func testTheSchemaCarriesTheThreeModels() {
        let names = CizgiSchema.allModels.map { String(describing: $0) }
        XCTAssertTrue(names.contains("ExamRun"))
        XCTAssertTrue(names.contains("ExamAttempt"))
        XCTAssertTrue(names.contains("ExamQuestionState"))
    }

    func testStateCountsAnswersAndKeepsTheNewestResult() {
        let state = ExamQuestionState(questionId: "TUS-2019-1-T-045")
        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        state.record(.wrong, at: t0 + 10)
        state.record(.correct, at: t0)   // an older answer arriving late
        state.record(.blank, at: t0 + 20)
        XCTAssertEqual(state.attemptCount, 3)
        XCTAssertEqual(state.wrongCount, 2)
        XCTAssertEqual(state.lastResult, .blank)
        XCTAssertEqual(state.lastAnsweredAt, t0 + 20)
        XCTAssertTrue(state.progress.isWrong)
    }

    func testGapAndLinksRoundTripThroughTheirStrings() {
        let state = ExamQuestionState(questionId: "TUS-2019-1-T-045")
        let card = UUID()
        state.link(card)
        state.link(card)
        XCTAssertEqual(state.linkedCards, [card])
        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        state.gap = ExamGapLedger.closing(ExamGapLedger.opening(state.gap, at: t0), byCard: card, at: t0 + 1)
        XCTAssertEqual(state.gapStatusRaw, "closed")
        XCTAssertEqual(state.gap.closedByCardId, card)
        state.unlink(card)
        XCTAssertEqual(state.linkedCards, [])
    }

    func testDeletingARunTakesItsAttempts() throws {
        let run = ExamRun(mode: .practice, queuedQuestionIds: ["TUS-2019-1-T-001"], filter: ExamFilter(subject: "Anatomi"))
        context.insert(run)
        let attempt = ExamAttempt(questionId: "TUS-2019-1-T-001", selectedOption: 1, isCorrect: false, responseTimeMs: 5_000)
        attempt.run = run
        context.insert(attempt)
        try context.save()
        XCTAssertEqual(run.filter.subject, "Anatomi")
        XCTAssertEqual(attempt.result, .wrong)
        XCTAssertEqual(run.currentQuestionId, "TUS-2019-1-T-001")

        context.delete(run)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExamAttempt>()), 0)
    }

    func testAttemptResultReadsBlankAndUnscored() {
        XCTAssertEqual(ExamAttempt(questionId: "x", selectedOption: nil, isCorrect: nil, responseTimeMs: 0).result, .blank)
        XCTAssertEqual(ExamAttempt(questionId: "x", selectedOption: 2, isCorrect: nil, responseTimeMs: 0).result, .unscored)
        XCTAssertEqual(ExamAttempt(questionId: "x", selectedOption: 2, isCorrect: true, responseTimeMs: 0).result, .correct)
    }
}
