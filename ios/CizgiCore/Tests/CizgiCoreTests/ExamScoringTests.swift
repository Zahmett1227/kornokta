import XCTest
@testable import CizgiCore

final class ExamScoringTests: XCTestCase {
    private func answer(_ result: ExamResult, _ subject: String? = "Anatomi", ms: Int = 60_000,
                        penalty: ExamPenalty = .quarter) -> ExamScoredAnswer {
        ExamScoredAnswer(questionId: UUID().uuidString, subject: subject, result: result, responseTimeMs: ms, penalty: penalty)
    }

    func testNetIsCorrectMinusAQuarterOfWrong() {
        let score = ExamScoring.score(
            Array(repeating: answer(.correct), count: 10) + Array(repeating: answer(.wrong), count: 6)
                + [answer(.blank), answer(.blank)]
        )
        XCTAssertEqual(score.correct, 10)
        XCTAssertEqual(score.wrong, 6)
        XCTAssertEqual(score.blank, 2)
        XCTAssertEqual(score.net, 8.5, accuracy: 1e-9)
        XCTAssertEqual(score.answered, 18)
        XCTAssertEqual(score.accuracy ?? 0, 10.0 / 18.0, accuracy: 1e-9)
        XCTAssertFalse(score.usesDefaultPenalty)
    }

    func testUnscoredAnswersNeitherCountNorPenalise() {
        let score = ExamScoring.score([answer(.correct), answer(.unscored, penalty: .unknown)])
        XCTAssertEqual(score.unscored, 1)
        XCTAssertEqual(score.answered, 1)
        XCTAssertEqual(score.net, 1)
        XCTAssertFalse(score.usesDefaultPenalty, "an unscored answer from an unknown-rule paper changes nothing")
    }

    func testAnAssumedRuleIsFlagged() {
        XCTAssertTrue(ExamScoring.score([answer(.wrong, penalty: .unknown)]).usesDefaultPenalty)
    }

    func testAverageTimeAndEmptyRun() {
        XCTAssertEqual(ExamScoring.score([answer(.correct, ms: 40_000), answer(.wrong, ms: 80_000)]).averageSeconds, 60)
        let empty = ExamScoring.score([])
        XCTAssertNil(empty.averageSeconds)
        XCTAssertNil(empty.accuracy)
    }

    func testBySubjectFollowsBookletOrder() {
        let breakdown = ExamScoring.bySubject([
            answer(.correct, "Farmakoloji"), answer(.wrong, "Anatomi"), answer(.correct, nil), answer(.correct, "Anatomi"),
        ])
        XCTAssertEqual(breakdown.map(\.subject), ["Anatomi", "Farmakoloji", nil])
        XCTAssertEqual(breakdown[0].score.net, 0.75, accuracy: 1e-9)
    }
}

final class ExamBridgeRankingTests: XCTestCase {
    private func card(_ text: String, subject: String? = "Farmakoloji", topic: String? = nil,
                      id: UUID = UUID()) -> ExamBridgeCard {
        ExamBridgeCard(id: id, subject: subject, topic: topic, front: text, back: "", explanation: nil)
    }

    /// A pool large enough for IDF to mean something.
    private func filler(_ count: Int) -> [ExamBridgeCard] {
        (0..<count).map { card("Genel bilgi kartı numara \($0) tedavi ilaç doz") }
    }

    func testTheCardSharingTheRareTermWins() {
        let target = card("Feokromositoma cerrahisinden önce alfa bloker verilir")
        let other = card("Beta bloker tedavisi astımda dikkatli verilir")
        let query = ExamBridgeQuery(
            stem: "Feokromositomalı hastada ameliyat öncesi hangisi başlanmalıdır?",
            correctOption: "Fenoksibenzamin", subject: "Farmakoloji", topic: nil
        )
        let ranked = ExamBridgeRanking.rank(query, cards: [target, other] + filler(20))
        XCTAssertEqual(ranked.first?.cardId, target.id, "suffixed forms meet at the stem: feokromositomalı ~ feokromositoma")
        XCTAssertFalse(ranked.contains { $0.cardId == other.id }, "a shared common word alone is below the bar")
    }

    func testTheKeysOptionWeighsDouble() {
        // One shared word each, equally rare: only the weight can separate them.
        let byStem = card("Tiroid bezinin embriyolojik gelişimi")
        let byAnswer = card("Propiltiyourasil periferik dönüşümü de engeller")
        let query = ExamBridgeQuery(
            stem: "Tiroid fırtınasında hormon sentezini baskılamak için",
            correctOption: "Propiltiyourasil", subject: "Farmakoloji", topic: nil
        )
        let ranked = ExamBridgeRanking.rank(query, cards: [byStem, byAnswer] + filler(20))
        XCTAssertEqual(ranked.first?.cardId, byAnswer.id)
    }

    func testTurkishCapitalsFoldAndBoilerplateIsIgnored() {
        let target = card("İnsülinoma: Whipple triadı")
        let query = ExamBridgeQuery(stem: "Aşağıdakilerden hangisi INSULINOMA için doğrudur?", correctOption: nil,
                                    subject: "Farmakoloji", topic: nil)
        XCTAssertEqual(ExamBridgeRanking.rank(query, cards: [target] + filler(10)).map(\.cardId), [target.id])
        XCTAssertEqual(ExamBridgeRanking.terms("Aşağıdakilerden hangisidir hastanın"), [])
    }

    func testThePoolIsTheQuestionsSubjectButLinkedCardsAlwaysLead() {
        let elsewhere = card("Feokromositoma", subject: "Patoloji")
        let linked = card("Tamamen alakasız bir kart", subject: "Dahiliye")
        let query = ExamBridgeQuery(stem: "Feokromositoma", correctOption: nil, subject: "Farmakoloji", topic: nil,
                                    linkedCardIds: [linked.id])
        let ranked = ExamBridgeRanking.rank(query, cards: [elsewhere, linked] + filler(5))
        XCTAssertEqual(ranked.map(\.cardId), [linked.id])
        XCTAssertTrue(ranked[0].isLinked)
    }

    func testSameTopicIsPreferredAndTheListIsCapped() {
        let inTopic = card("Atropin muskarinik antagonist", topic: "Otonom Sinir Sistemi")
        let outTopic = card("Atropin muskarinik antagonist", topic: "Kemoterapötikler")
        let query = ExamBridgeQuery(stem: "Atropin zehirlenmesi", correctOption: "Muskarinik blokaj",
                                    subject: "Farmakoloji", topic: "Otonom Sinir Sistemi")
        let ranked = ExamBridgeRanking.rank(query, cards: [outTopic, inTopic] + filler(20))
        XCTAssertEqual(ranked.first?.cardId, inTopic.id)
        XCTAssertTrue(ranked.first?.sharesTopic == true)

        let many = (0..<20).map { _ in card("Atropin muskarinik") }
        XCTAssertEqual(ExamBridgeRanking.rank(query, cards: many + filler(40)).count, ExamBridgeRanking.maxCandidates)
    }

    func testAnEmptyPoolOffersNothing() {
        let query = ExamBridgeQuery(stem: "Atropin", correctOption: nil, subject: "Farmakoloji", topic: nil)
        XCTAssertEqual(ExamBridgeRanking.rank(query, cards: [card("Atropin", subject: "Anatomi")]), [])
    }
}

final class ExamGapLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    func testOpensOnceAndKeepsItsDay() {
        let opened = ExamGapLedger.opening(ExamGap(), at: t0)
        XCTAssertEqual(opened.status, .open)
        XCTAssertEqual(ExamGapLedger.opening(opened, at: t0 + 100).openedAt, t0)
    }

    func testClosesOnlyWhenOpenAndDismissedStaysDismissed() {
        let card = UUID()
        XCTAssertEqual(ExamGapLedger.closing(ExamGap(), byCard: card, at: t0).status, .noGap)
        let closed = ExamGapLedger.closing(ExamGapLedger.opening(ExamGap(), at: t0), byCard: card, at: t0 + 10)
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(closed.closedByCardId, card)
        XCTAssertEqual(closed.openedAt, t0)

        let dismissed = ExamGapLedger.dismissing(ExamGapLedger.opening(ExamGap(), at: t0))
        XCTAssertEqual(dismissed.status, .dismissed)
        XCTAssertEqual(ExamGapLedger.opening(dismissed, at: t0 + 50).status, .dismissed, "Yoksay means never again")
    }

    func testMissingAgainAfterClosingReopens() {
        let closed = ExamGapLedger.closing(ExamGapLedger.opening(ExamGap(), at: t0), byCard: UUID(), at: t0 + 10)
        let reopened = ExamGapLedger.opening(closed, at: t0 + 20)
        XCTAssertEqual(reopened.status, .open)
        XCTAssertEqual(reopened.openedAt, t0 + 20)
        XCTAssertNil(reopened.closedByCardId)
    }

    func testADeletedClosingCardReopensTheGap() {
        let card = UUID()
        let closed = ExamGapLedger.closing(ExamGapLedger.opening(ExamGap(), at: t0), byCard: card, at: t0 + 10)
        XCTAssertEqual(ExamGapLedger.reconciled(closed, existingCardIds: [card]), closed)
        let reopened = ExamGapLedger.reconciled(closed, existingCardIds: [])
        XCTAssertEqual(reopened.status, .open)
        XCTAssertEqual(reopened.openedAt, t0)
    }

    func testLikelyClosersAreNewCardsInTheSameTopicNewestFirst() {
        let gap = ExamGapLedger.opening(ExamGap(), at: t0)
        let before = ExamGapCard(id: UUID(), subject: "Farmakoloji", topic: "Otonom", createdAt: t0 - 1)
        let otherTopic = ExamGapCard(id: UUID(), subject: "Farmakoloji", topic: "Kemoterapi", createdAt: t0 + 5)
        let first = ExamGapCard(id: UUID(), subject: "Farmakoloji", topic: "Otonom", createdAt: t0 + 5)
        let second = ExamGapCard(id: UUID(), subject: "Farmakoloji", topic: "Otonom", createdAt: t0 + 9)
        let cards = [before, otherTopic, first, second]
        XCTAssertEqual(ExamGapLedger.likelyClosers(gap, subject: "Farmakoloji", topic: "Otonom", cards: cards),
                       [second.id, first.id])
        XCTAssertEqual(ExamGapLedger.likelyClosers(gap, subject: "Farmakoloji", topic: nil, cards: cards).count, 3)
        XCTAssertEqual(ExamGapLedger.likelyClosers(ExamGapLedger.dismissing(gap), subject: "Farmakoloji",
                                                   topic: "Otonom", cards: cards), [])
    }
}

final class ExamPaceTests: XCTestCase {
    func testMedianWithItsOwnRange() {
        XCTAssertEqual(ExamPace.secondsPerQuestion(recentResponseTimesMs: []), 75)
        XCTAssertEqual(ExamPace.secondsPerQuestion(recentResponseTimesMs: [90_000, 30_000, 60_000]), 60)
        // A two-minute vignette is a real measurement, not an outlier.
        XCTAssertEqual(ExamPace.secondsPerQuestion(recentResponseTimesMs: [120_000]), 120)
        XCTAssertEqual(ExamPace.secondsPerQuestion(recentResponseTimesMs: [1_000]), 10)
        XCTAssertEqual(ExamPace.questionCount(forMinutes: 20, secondsPerQuestion: 75), 16)
        XCTAssertEqual(ExamPace.questionCount(forMinutes: 1, secondsPerQuestion: 300), 1)
    }

    func testTimeLimitPrefersTheBookletThenTheSittingThenTheDefault() {
        let own = ExamBankFixture.paper("TUS-2013-1-T", questionCount: 120, timeLimitMinutes: 150)
        XCTAssertEqual(ExamTimeLimit.seconds(for: own, sittingQuestionCount: 240), 9_000)
        let shared = ExamBankFixture.paper("TUS-2010-1-T", questionCount: 100, sessionTimeLimitMinutes: 210)
        XCTAssertEqual(ExamTimeLimit.seconds(for: shared, sittingQuestionCount: 200), 6_300)
        let none = ExamBankFixture.paper("TUS-2019-1-K", questionCount: 120)
        XCTAssertEqual(ExamTimeLimit.seconds(for: none, sittingQuestionCount: 240), 9_000)
    }
}

final class ExamPageGeometryTests: XCTestCase {
    func testTopLeftBoxBecomesPDFKitsBottomLeftRect() throws {
        let rect = try XCTUnwrap(ExamPageGeometry.pdfRect(bbox: [40, 100, 295, 200], pageHeight: 842))
        XCTAssertEqual(rect, CGRect(x: 40, y: 642, width: 255, height: 100))
    }

    func testImageRectScalesPadsAndStaysOnThePage() throws {
        let rect = try XCTUnwrap(ExamPageGeometry.imageRect(
            bbox: [2, 100, 295, 200],
            pageSize: CGSize(width: 595, height: 842),
            imageSize: CGSize(width: 1190, height: 1684),
            padding: 6
        ))
        XCTAssertEqual(rect, CGRect(x: 0, y: 188, width: 602, height: 224))
    }

    func testMalformedBoxesAreRefused() {
        XCTAssertNil(ExamPageGeometry.pdfRect(bbox: [1, 2, 3], pageHeight: 842))
        XCTAssertNil(ExamPageGeometry.pdfRect(bbox: [10, 20, 5, 30], pageHeight: 842))
        XCTAssertNil(ExamPageGeometry.pdfRect(bbox: [.nan, 2, 3, 4], pageHeight: 842))
    }
}
