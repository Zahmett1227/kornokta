import XCTest
import SwiftData
@testable import CizgiCore

/// Deneme (plan §7.4 e–f, §9.4): the clock, building a mock, scoring it, and
/// handing it in.
final class ExamMockClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    func testTimeRunsOnTheWallClock() {
        let clock = ExamMockClock(startedAt: t0, limitSeconds: 600)
        XCTAssertEqual(clock.remainingSeconds(at: t0 + 100), 500)
        XCTAssertEqual(clock.deadline, t0 + 600)
        XCTAssertFalse(clock.isExpired(at: t0 + 599))
        // The app closed for an hour: the exam did not wait.
        XCTAssertTrue(clock.isExpired(at: t0 + 3_600))
        XCTAssertEqual(clock.remainingSeconds(at: t0 + 3_600), 0)
    }

    func testAPauseStopsTheClockAndIsCounted() {
        let paused = ExamMockClock(startedAt: t0, limitSeconds: 600).pausing(at: t0 + 100)
        XCTAssertTrue(paused.isPaused)
        XCTAssertNil(paused.deadline)
        XCTAssertEqual(paused.remainingSeconds(at: t0 + 1_000), 500, "nothing runs while paused")
        XCTAssertEqual(paused.totalPausedSeconds(at: t0 + 400), 300)

        let resumed = paused.resuming(at: t0 + 400)
        XCTAssertEqual(resumed.pausedSeconds, 300)
        XCTAssertEqual(resumed.remainingSeconds(at: t0 + 500), 400)
        XCTAssertEqual(resumed.deadline, t0 + 900)
        XCTAssertEqual(resumed.pausing(at: t0 + 450).pausing(at: t0 + 480).pausedAt, t0 + 450, "a second pause is a no-op")
    }

    func testUntimedNeverExpires() {
        let clock = ExamMockClock(startedAt: t0, limitSeconds: nil)
        XCTAssertNil(clock.remainingSeconds(at: t0 + 99_999))
        XCTAssertFalse(clock.isExpired(at: t0 + 99_999))
        XCTAssertNil(clock.deadline)
    }
}

final class ExamMockComposerTests: XCTestCase {
    private func bank(_ questions: [ExamQuestion], papers: [ExamPaper]? = nil) throws -> ExamBank {
        try ExamBank(document: ExamBankFixture.document(papers: papers, questions: questions))
    }

    func testAPaperQueueIsTheBookletMinusCancelledSlots() throws {
        let bank = try ExamBank(document: ExamBankFixture.standard)
        let paper = try XCTUnwrap(bank.papersById["TUS-2019-1-T"])
        XCTAssertEqual(ExamMockComposer.paperQueue(bank, paper: paper),
                       ["TUS-2019-1-T-001", "TUS-2019-1-T-002", "TUS-2019-1-T-050", "TUS-2019-1-T-051"])
        let keyless = try XCTUnwrap(bank.papersById["TUS-2007-2-K"])
        let queue = ExamMockComposer.paperQueue(bank, paper: keyless)
        XCTAssertEqual(queue, ["TUS-2007-2-K-003"], "a keyless question sits in its paper")
        XCTAssertEqual(ExamMockComposer.scoreableCount(bank, queue: queue), 0)
    }

    func testTimeLimitShrinksWithAPartialPaper() throws {
        let paper = ExamBankFixture.paper("TUS-2013-1-T", questionCount: 120, timeLimitMinutes: 150)
        let bank = try bank([ExamBankFixture.question("TUS-2013-1-T-001")], papers: [paper])
        XCTAssertEqual(ExamMockComposer.timeLimitSeconds(bank, paper: paper, questionCount: 120), 9_000)
        XCTAssertEqual(ExamMockComposer.timeLimitSeconds(bank, paper: paper, questionCount: 12), 900)
    }

    func testApportionAddsUpExactly() {
        XCTAssertEqual(ExamMockComposer.apportion(10, weights: [1, 1, 1]), [4, 3, 3])
        XCTAssertEqual(ExamMockComposer.apportion(40, weights: [12, 18, 90]).reduce(0, +), 40)
        XCTAssertEqual(ExamMockComposer.apportion(0, weights: [5]), [0])
        XCTAssertEqual(ExamMockComposer.apportion(5, weights: [0, 0]), [0, 0])
    }

    /// Template 2020/1 T: 6 Anatomi, 2 Farmakoloji. A 4-question mixed mock
    /// asks 3 + 1, subjects in booklet order, unanswered first.
    func testMixedMockCopiesTheTemplatesShares() throws {
        var questions: [ExamQuestion] = []
        for n in 1...6 { questions.append(ExamBankFixture.question(String(format: "TUS-2020-1-T-%03d", n), osymSubject: "Anatomi")) }
        for n in 7...8 { questions.append(ExamBankFixture.question(String(format: "TUS-2020-1-T-%03d", n), osymSubject: "Farmakoloji")) }
        for n in 1...5 { questions.append(ExamBankFixture.question(String(format: "TUS-2019-1-T-%03d", n), osymSubject: "Farmakoloji")) }
        questions.append(ExamBankFixture.question("TUS-2019-1-K-001", osymSubject: "Dahiliye"))
        let papers = [
            ExamBankFixture.paper("TUS-2020-1-T", questionCount: 8),
            ExamBankFixture.paper("TUS-2019-1-T", questionCount: 120),
            ExamBankFixture.paper("TUS-2019-1-K", questionCount: 120),
        ]
        let bank = try bank(questions, papers: papers)
        XCTAssertEqual(ExamMockComposer.template(bank, group: .temel)?.id, "TUS-2020-1-T")
        XCTAssertNil(ExamMockComposer.template(bank, group: .klinik), "a paper mostly missing from the bank is no template")

        let answered = Dictionary(uniqueKeysWithValues: (1...5).map {
            (String(format: "TUS-2019-1-T-%03d", $0), ExamProgress(attemptCount: 1, lastResult: .correct))
        })
        var rng = ExamSeededGenerator(seed: 11)
        let queue = ExamMockComposer.mixedQueue(bank, group: .temel, count: 4, progress: answered, using: &rng)
        XCTAssertEqual(queue.count, 4)
        let subjects = queue.compactMap { bank.question($0)?.osymSubject }
        XCTAssertEqual(subjects, ["Anatomi", "Anatomi", "Anatomi", "Farmakoloji"])
        XCTAssertTrue(["TUS-2020-1-T-007", "TUS-2020-1-T-008"].contains(queue[3]), "the unanswered Farmakoloji comes first")
        XCTAssertFalse(queue.contains("TUS-2019-1-K-001"), "Klinik never enters a Temel mock")
    }

    func testMockScoringCountsUnvisitedAsBlankAndKeylessAsUnscored() throws {
        let bank = try ExamBank(document: ExamBankFixture.standard)
        // 001 answered right (key 2), 002 wrong, 050 never visited; the
        // keyless 2007 question marked.
        let scored = bank.mockScoredAnswers(
            queue: ["TUS-2019-1-T-001", "TUS-2019-1-T-002", "TUS-2019-1-T-050", "TUS-2007-2-K-003"],
            answers: [
                "TUS-2019-1-T-001": (2, 40_000),
                "TUS-2019-1-T-002": (0, 60_000),
                "TUS-2007-2-K-003": (1, 30_000),
            ]
        )
        let score = ExamScoring.score(scored)
        XCTAssertEqual(score.correct, 1)
        XCTAssertEqual(score.wrong, 1)
        XCTAssertEqual(score.blank, 1)
        XCTAssertEqual(score.unscored, 1)
        XCTAssertEqual(score.net, 0.75)
        XCTAssertEqual(score.averageSeconds ?? 0, 130.0 / 3, accuracy: 1e-9, "the unvisited zero is not averaged in")
    }
}

final class ExamMockRecorderTests: XCTestCase {
    private var context: ModelContext!
    private var recorder: ExamRecorder!
    private let bank = try! ExamBank(document: ExamBankFixture.standard)
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: Card.self, KnowledgeUnit.self, ReviewLog.self, ExamRun.self, ExamAttempt.self, ExamQuestionState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        recorder = ExamRecorder(context: context)
    }

    private func q(_ id: String) -> ExamQuestion { bank.question(id)! }

    private func mock() -> ExamRun {
        let run = ExamRun(mode: .mock, queuedQuestionIds: ["TUS-2019-1-T-001", "TUS-2019-1-T-002", "TUS-2019-1-T-050"],
                          paperId: "TUS-2019-1-T", timeLimitSeconds: 600, startedAt: t0)
        context.insert(run)
        return run
    }

    func testAnswersCanChangeAndNothingIsHistoryUntilHandedIn() throws {
        let run = mock()
        recorder.setMockAnswer(0, to: q("TUS-2019-1-T-001"), in: run, at: t0 + 10)
        recorder.setMockAnswer(2, to: q("TUS-2019-1-T-001"), in: run, at: t0 + 20)
        recorder.setMockAnswer(1, to: q("TUS-2019-1-T-002"), in: run, at: t0 + 30)
        recorder.setMockAnswer(nil, to: q("TUS-2019-1-T-002"), in: run, at: t0 + 40)
        recorder.addMockTime(12_000, to: q("TUS-2019-1-T-001"), in: run, at: t0 + 20)
        recorder.addMockTime(8_000, to: q("TUS-2019-1-T-001"), in: run, at: t0 + 50)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExamAttempt>()), 2, "one row per question, rewritten")
        let first = try XCTUnwrap(recorder.attempt(for: "TUS-2019-1-T-001", in: run))
        XCTAssertEqual(first.selectedOption, 2)
        XCTAssertEqual(first.isCorrect, true)
        XCTAssertEqual(first.responseTimeMs, 20_000)
        XCTAssertEqual(recorder.attempt(for: "TUS-2019-1-T-002", in: run)?.result, .blank, "cleared")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExamQuestionState>()), 0, "no history mid-mock")
    }

    func testHandingInRecordsWhatWasMetAndLeavesMissesForTheReview() throws {
        let run = mock()
        recorder.setMockAnswer(2, to: q("TUS-2019-1-T-001"), in: run, at: t0 + 10)
        recorder.setMockAnswer(0, to: q("TUS-2019-1-T-002"), in: run, at: t0 + 20)
        recorder.toggleFlag("TUS-2019-1-T-002", in: run)
        run.clock = run.clock.pausing(at: t0 + 30)

        XCTAssertEqual(recorder.submitMock(run, bank: bank, at: t0 + 90, byTimeLimit: false), 2)
        try context.save()
        XCTAssertEqual(run.finishedAt, t0 + 90)
        XCTAssertEqual(run.pausedSeconds, 60, "a pause still open when handed in is counted")
        XCTAssertNil(run.pausedAt)
        XCTAssertEqual(run.flaggedQuestionIds, ["TUS-2019-1-T-002"])

        XCTAssertEqual(recorder.attempt(for: "TUS-2019-1-T-001", in: run)?.bridgeOutcome, .notAsked)
        XCTAssertNil(recorder.attempt(for: "TUS-2019-1-T-002", in: run)?.bridgeOutcome, "the review asks the bridge")
        XCTAssertEqual(recorder.existingState(for: "TUS-2019-1-T-002")?.lastResult, .wrong)
        XCTAssertNil(recorder.existingState(for: "TUS-2019-1-T-050"), "never reached: no history")

        XCTAssertEqual(recorder.submitMock(run, bank: bank, at: t0 + 120, byTimeLimit: true), 0, "idempotent")
        XCTAssertFalse(run.endedByTimeLimit)
    }

    func testFlagsToggle() {
        let run = mock()
        recorder.toggleFlag("TUS-2019-1-T-050", in: run)
        recorder.toggleFlag("TUS-2019-1-T-001", in: run)
        recorder.toggleFlag("TUS-2019-1-T-050", in: run)
        XCTAssertEqual(run.flaggedQuestionIds, ["TUS-2019-1-T-001"])
    }
}

final class ExamBankResultTests: XCTestCase {
    func testResultsReadTheBanksKeyNotTheStoredFlag() throws {
        let bank = try ExamBank(document: ExamBankFixture.standard)
        XCTAssertEqual(bank.result(questionId: "TUS-2019-1-T-001", selectedOption: 2), .correct)
        XCTAssertEqual(bank.result(questionId: "TUS-2019-1-T-001", selectedOption: 0), .wrong)
        XCTAssertEqual(bank.result(questionId: "TUS-2019-1-T-001", selectedOption: nil), .blank)
        XCTAssertEqual(bank.result(questionId: "TUS-2007-2-K-003", selectedOption: 1), .unscored, "keyless")
        XCTAssertEqual(bank.result(questionId: "TUS-2099-1-T-001", selectedOption: 1), .unscored, "not in this bank")
    }
}
