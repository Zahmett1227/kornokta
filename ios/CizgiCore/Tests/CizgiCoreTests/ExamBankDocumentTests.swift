import XCTest
@testable import CizgiCore

/// `bank.json` decoding and the bank's own checks (plan §12:
/// `ExamBankDocumentTests`).
final class ExamBankDocumentTests: XCTestCase {
    func testDecodesWhatThePipelineWritesAndIgnoresUnknownKeys() throws {
        // The exact key set package.py writes, plus a key a later pipeline
        // might add — an older phone must still read the file.
        let json = """
        {"schemaVersion":1,"bankVersion":"2026-09-25.2","subjectSchemaVersion":1,
         "builtAt":"2026-09-25T20:14:23+00:00","futureField":{"x":1},
         "papers":[{"id":"TUS-2006-1-K","year":2006,"session":1,"test":"K","date":null,
           "questionCount":100,"timeLimitMinutes":null,"sessionTimeLimitMinutes":null,
           "penalty":"unknown","sourceKind":"osym","keySource":"none",
           "sources":[{"pdf":"\(ExamBankFixture.pdfA)","family":"F1","sourceKind":"osym","keySource":"none"}]}],
         "questions":[{"id":"TUS-2006-1-K-001","paperId":"TUS-2006-1-K","number":1,
           "stem":"Kök","options":["A","B","C","D","E"],"answer":null,"answerSource":null,
           "status":"keyless","osymSubject":"Dahiliye","subject":"Dahiliye","topic":null,
           "figure":"none","provenance":[{"pdf":"\(ExamBankFixture.pdfA)","page":1,"bbox":[59.6,163.3,304.5,293.7]}],
           "altProvenance":[],"textQuality":"native","textSource":"osym","printedAs":null,"similarTo":[]}]}
        """
        let bank = try ExamBank.decode(Data(json.utf8))
        XCTAssertEqual(bank.bankVersion, "2026-09-25.2")
        let paper = try XCTUnwrap(bank.papersById["TUS-2006-1-K"])
        XCTAssertEqual(paper.keySource, .missing)
        XCTAssertEqual(paper.test, .klinik)
        let question = try XCTUnwrap(bank.question("TUS-2006-1-K-001"))
        XCTAssertEqual(question.figure, .absent)
        XCTAssertEqual(question.status, .keyless)
        XCTAssertTrue(question.isReadOnly)
        XCTAssertFalse(question.isScoreable)
        XCTAssertEqual(question.provenance.first?.bbox, [59.6, 163.3, 304.5, 293.7])
    }

    func testAnUnknownEnumValueRefusesTheFile() {
        // Strict on values: a new status is a new schemaVersion, not a guess.
        let doc = ExamBankFixture.standard
        var json = String(data: try! ExamBankFixture.json(doc), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"status\":\"ok\"", with: "\"status\":\"disputed\"")
        XCTAssertThrowsError(try ExamBank.decode(Data(json.utf8)))
    }

    func testRoundTripsThroughJSON() throws {
        let doc = ExamBankFixture.standard
        let decoded = try JSONDecoder().decode(ExamBankDocument.self, from: ExamBankFixture.json(doc))
        XCTAssertEqual(decoded, doc)
    }

    func testCountsAndScoreability() throws {
        let bank = try ExamBank(document: ExamBankFixture.standard)
        XCTAssertEqual(bank.counts.questions, 8)
        XCTAssertEqual(bank.counts.cancelled, 1)
        XCTAssertEqual(bank.counts.keyless, 1)
        XCTAssertEqual(bank.counts.modified, 1)
        XCTAssertEqual(bank.counts.scoreable, 5)
        XCTAssertFalse(bank.scoreableIds.contains("TUS-2024-2-K-101"), "a modified question is not scored")
        XCTAssertFalse(bank.scoreableIds.contains("TUS-2019-1-T-052"), "a cancelled one neither")
        XCTAssertEqual(bank.questionIdsByPaper["TUS-2019-1-T"],
                       ["TUS-2019-1-T-001", "TUS-2019-1-T-002", "TUS-2019-1-T-050", "TUS-2019-1-T-051", "TUS-2019-1-T-052"])
    }

    func testMapsOsymSubjectsToTheAppSubjectFromTheDataItself() throws {
        let bank = try ExamBank(document: ExamBankFixture.standard)
        XCTAssertEqual(bank.appSubject(forOsymSubject: "Histoloji-Embriyoloji"), "Fizyoloji")
        XCTAssertEqual(bank.appSubject(forOsymSubject: "Farmakoloji"), "Farmakoloji")
        XCTAssertEqual(bank.osymSubjects,
                       ["Anatomi", "Histoloji-Embriyoloji", "Biyokimya", "Farmakoloji", "Dahiliye", "Pediatri"])
    }

    func testRefusesTwoQuestionsUnderOneId() {
        let q = ExamBankFixture.question("TUS-2019-1-T-001")
        XCTAssertThrowsError(try ExamBank(document: ExamBankFixture.document(questions: [q, q]))) {
            XCTAssertEqual($0 as? ExamBank.ValidationError, .duplicateQuestion("TUS-2019-1-T-001"))
        }
    }

    func testRefusesAnAnswerPastTheOptions() {
        let q = ExamBankFixture.question("TUS-2019-1-T-001", answer: 5)
        XCTAssertThrowsError(try ExamBank(document: ExamBankFixture.document(questions: [q]))) {
            XCTAssertEqual($0 as? ExamBank.ValidationError, .answerOutOfRange("TUS-2019-1-T-001"))
        }
    }

    func testRefusesAQuestionWithoutItsPaper() {
        let q = ExamBankFixture.question("TUS-2019-1-T-001")
        let doc = ExamBankFixture.document(papers: [], questions: [q])
        XCTAssertThrowsError(try ExamBank(document: doc)) {
            XCTAssertEqual($0 as? ExamBank.ValidationError,
                           .unknownPaper(question: "TUS-2019-1-T-001", paper: "TUS-2019-1-T"))
        }
    }

    func testOldIsUpTo2012() {
        XCTAssertTrue(ExamBankFixture.question("TUS-2012-2-K-001").isOld)
        XCTAssertFalse(ExamBankFixture.question("TUS-2013-1-T-001").isOld)
    }

    func testSittingQuestionCountAddsBothTestsOfTheDay() throws {
        let papers = [
            ExamBankFixture.paper("TUS-2010-1-T", questionCount: 100, sessionTimeLimitMinutes: 210),
            ExamBankFixture.paper("TUS-2010-1-K", questionCount: 100, sessionTimeLimitMinutes: 210),
            ExamBankFixture.paper("TUS-2010-2-T", questionCount: 100),
        ]
        let bank = try ExamBank(document: ExamBankFixture.document(
            papers: papers,
            questions: [ExamBankFixture.question("TUS-2010-1-T-001")]
        ))
        XCTAssertEqual(bank.sittingQuestionCount(for: papers[0]), 200)
    }
}

final class ExamQuestionIDTests: XCTestCase {
    func testParsesTheSchemaPattern() throws {
        let id = try XCTUnwrap(ExamQuestionID("TUS-2019-1-T-045"))
        XCTAssertEqual(id.year, 2019)
        XCTAssertEqual(id.session, 1)
        XCTAssertEqual(id.test, .temel)
        XCTAssertEqual(id.number, 45)
        XCTAssertEqual(id.paperId, "TUS-2019-1-T")
        XCTAssertEqual(id.rawValue, "TUS-2019-1-T-045")
        XCTAssertEqual(id.shortLabel, "2019/1 T45")
        XCTAssertEqual(ExamQuestionID("TUS-2011-1-T2-010")?.test, .temel2)
    }

    func testRejectsAnythingElse() {
        for raw in ["TUS-2019-3-T-045", "TUS-1999-1-T-045", "TUS-2019-1-X-045", "TUS-2019-1-T-45",
                    "TUS-2019-1-T-000", "tus-2019-1-T-045", "TUS-2019-1-T-045-1", "", "TUS-2019-1-T-04a"] {
            XCTAssertNil(ExamQuestionID(raw), raw)
        }
    }
}

/// The owner's real package, when this Mac has it: `EXAM_BANK_PACKAGE` points
/// at `tools/exam_bank/out/CizgiSoruBankasi`. Skipped everywhere else — the
/// bank never enters the repo (docs/ADR-012).
final class ExamBankRealPackageTests: XCTestCase {
    func testTheRealBankDecodesAndValidates() throws {
        guard let path = ProcessInfo.processInfo.environment["EXAM_BANK_PACKAGE"] else {
            throw XCTSkip("EXAM_BANK_PACKAGE yok")
        }
        let package = URL(fileURLWithPath: path, isDirectory: true)
        let started = Date()
        let bank = try ExamBank.decode(Data(contentsOf: package.appendingPathComponent("bank.json")))
        let elapsed = Date().timeIntervalSince(started)
        let manifest = try JSONDecoder().decode(
            ExamBankManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(bank.counts.questions, manifest.counts.questions)
        XCTAssertEqual(bank.bankVersion, manifest.bankVersion)
        print("gerçek banka: \(bank.counts) — çözme \(String(format: "%.2f", elapsed)) sn")

        // The whole import, into a scratch root: every file hashed and copied.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cizgi-real-bank-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ExamBankStore(root: scratch)
        let importStarted = Date()
        let result = try store.install(from: package)
        print("gerçek içe aktarma: \(result.bytes / 1_000_000) MB, "
              + "\(String(format: "%.1f", Date().timeIntervalSince(importStarted))) sn")
        XCTAssertEqual(store.activeVersion, manifest.bankVersion)
        for question in bank.questions {
            for region in question.provenance { XCTAssertNotNil(store.pdfURL(for: region.pdf), region.pdf) }
        }
    }
}
