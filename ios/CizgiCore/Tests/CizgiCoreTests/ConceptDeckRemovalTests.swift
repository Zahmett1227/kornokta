import XCTest
import SwiftData
@testable import CizgiCore

/// Removing the concept deck from a store that has one (2026-09-14).
///
/// Against a real in-memory container, for `ApprovalGateReleaseTests`' reason:
/// the caller writes a one-shot flag, so a removal that quietly matched nothing
/// would record success and leave 3.017 cards in the deck for good. These prove
/// the tag lookup finds them — and, just as much, that it finds nothing else.
final class ConceptDeckRemovalTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            ReviewLog.self, ExerciseRun.self, ExerciseAttempt.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func unit(tags: [String], cards: Int, logsPerCard: Int = 0, in context: ModelContext) -> [Card] {
        let unit = KnowledgeUnit(canonicalClaim: "", subject: "Farmakoloji", tags: tags)
        context.insert(unit)
        return (0..<cards).map { _ in
            let card = Card(type: .directRecall, front: "Soru", back: "Cevap", status: .active)
            context.insert(card)
            card.knowledgeUnit = unit
            for _ in 0..<logsPerCard {
                let log = ReviewLog(
                    rating: .good, responseTimeMs: 1000, scheduledDays: 1, elapsedDays: 0,
                    stabilityBefore: 0, stabilityAfter: 1, difficultyBefore: 0, difficultyAfter: 5
                )
                context.insert(log)
                log.card = card
            }
            return card
        }
    }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    /// The case the owner's store is in: tagged units, their cards, their
    /// review history — all of it gone, and the counts say so.
    func testATaggedUnitGoesWithItsCardsAndTheirHistory() throws {
        let context = try makeContext()
        unit(tags: ["glibenklamid", ConceptDeckLegacy.tag], cards: 3, logsPerCard: 2, in: context)
        try context.save()

        let outcome = try ConceptDeckRemoval.remove(in: context)
        try context.save()

        XCTAssertEqual(outcome.unitsDeleted, 1)
        XCTAssertEqual(outcome.cardsDeleted, 3)
        XCTAssertEqual(outcome.reviewLogsDeleted, 6)
        XCTAssertEqual(try count(KnowledgeUnit.self, in: context), 0)
        XCTAssertEqual(try count(Card.self, in: context), 0)
        XCTAssertEqual(try count(ReviewLog.self, in: context), 0)
    }

    /// Just as important as the deletion: a photographed card, and its review
    /// history, must not be touched by a sweep aimed at a different deck.
    func testAnUntaggedUnitIsLeftExactlyAsItWas() throws {
        let context = try makeContext()
        let kept = unit(tags: ["solunum"], cards: 2, logsPerCard: 3, in: context)
        unit(tags: [ConceptDeckLegacy.tag], cards: 4, in: context)
        try context.save()

        let outcome = try ConceptDeckRemoval.remove(in: context)
        try context.save()

        XCTAssertEqual(outcome.cardsDeleted, 4)
        let remaining = try context.fetch(FetchDescriptor<Card>())
        XCTAssertEqual(Set(remaining.map(\.id)), Set(kept.map(\.id)))
        XCTAssertEqual(try count(ReviewLog.self, in: context), 6)
    }

    /// A tag that merely *contains* the marker is somebody's topic, not the
    /// importer's stamp.
    func testTheTagMustMatchExactly() throws {
        let context = try makeContext()
        unit(tags: ["kavram-paketi-notlari", "kavram"], cards: 1, in: context)
        try context.save()

        XCTAssertTrue(try ConceptDeckRemoval.remove(in: context).isEmpty)
        XCTAssertEqual(try count(Card.self, in: context), 1)
    }

    /// `CardStatus` has no `queued` case any more, so `card.status` reads such
    /// a card as `.draft`. The stray pass must look at the stored string.
    func testAStrayQueuedCardIsFoundThroughItsRawStatus() throws {
        let context = try makeContext()
        let stray = Card(type: .directRecall, front: "Soru", back: "Cevap", status: .active)
        stray.statusRaw = ConceptDeckLegacy.queuedStatusRaw
        context.insert(stray)
        let capture = Card(type: .directRecall, front: "Çekim", back: "Cevap", status: .active)
        context.insert(capture)
        try context.save()

        XCTAssertEqual(stray.status, .draft, "önkoşul: enum'da artık queued yok")

        let outcome = try ConceptDeckRemoval.remove(in: context)
        try context.save()

        XCTAssertEqual(outcome.cardsDeleted, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).map(\.id), [capture.id])
    }

    /// A card that is both tagged and queued is one card, deleted once.
    func testATaggedQueuedCardIsCountedOnce() throws {
        let context = try makeContext()
        let cards = unit(tags: [ConceptDeckLegacy.tag], cards: 2, in: context)
        cards[0].statusRaw = ConceptDeckLegacy.queuedStatusRaw
        try context.save()

        XCTAssertEqual(try ConceptDeckRemoval.remove(in: context).cardsDeleted, 2)
    }

    /// Egzersiz runs point at cards by bare id, so the cascade never reaches
    /// them. A run made of concept cards goes whole; a capture run stays.
    func testConceptExerciseRunsGoAndCaptureRunsStay() throws {
        let context = try makeContext()
        let concept = unit(tags: [ConceptDeckLegacy.tag], cards: 2, in: context)
        let capture = unit(tags: ["solunum"], cards: 2, in: context)

        let conceptRun = ExerciseRun(mode: .quick, queuedCardIds: concept.map(\.id))
        context.insert(conceptRun)
        for card in concept {
            let attempt = ExerciseAttempt(cardId: card.id, result: .knew, responseTimeMs: 900)
            context.insert(attempt)
            attempt.run = conceptRun
        }
        let captureRun = ExerciseRun(mode: .quick, queuedCardIds: capture.map(\.id))
        context.insert(captureRun)
        let kept = ExerciseAttempt(cardId: capture[0].id, result: .missed, responseTimeMs: 900)
        context.insert(kept)
        kept.run = captureRun
        try context.save()

        let outcome = try ConceptDeckRemoval.remove(in: context)
        try context.save()

        XCTAssertEqual(outcome.exerciseRunsDeleted, 1)
        XCTAssertEqual(outcome.attemptsDeleted, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseRun>()).map(\.id), [captureRun.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseAttempt>()).map(\.id), [kept.id])
    }

    /// A run should never mix decks, but if one does, only the orphaned
    /// attempts go — not the capture work recorded in the same run.
    func testAMixedRunKeepsItsCaptureAttempts() throws {
        let context = try makeContext()
        let concept = unit(tags: [ConceptDeckLegacy.tag], cards: 1, in: context)
        let capture = unit(tags: ["solunum"], cards: 1, in: context)

        let run = ExerciseRun(mode: .quick, queuedCardIds: [concept[0].id, capture[0].id])
        context.insert(run)
        let orphan = ExerciseAttempt(cardId: concept[0].id, result: .knew, responseTimeMs: 900)
        let kept = ExerciseAttempt(cardId: capture[0].id, result: .knew, responseTimeMs: 900)
        [orphan, kept].forEach { context.insert($0); $0.run = run }
        try context.save()

        let outcome = try ConceptDeckRemoval.remove(in: context)
        try context.save()

        XCTAssertEqual(outcome.exerciseRunsDeleted, 0)
        XCTAssertEqual(outcome.attemptsDeleted, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExerciseAttempt>()).map(\.id), [kept.id])
    }

    /// The migration writes its flag after a successful run; a second run —
    /// after a restore, or on a device where the flag was cleared — must find
    /// nothing and report nothing.
    func testASecondRunDeletesNothing() throws {
        let context = try makeContext()
        unit(tags: [ConceptDeckLegacy.tag], cards: 3, logsPerCard: 1, in: context)
        try context.save()

        XCTAssertFalse(try ConceptDeckRemoval.remove(in: context).isEmpty)
        try context.save()
        XCTAssertTrue(try ConceptDeckRemoval.remove(in: context).isEmpty)
    }

    /// An empty store — a fresh install — is not an error.
    func testAnEmptyStoreIsFine() throws {
        XCTAssertTrue(try ConceptDeckRemoval.remove(in: try makeContext()).isEmpty)
    }

    func testBackupRecordRecognition() {
        XCTAssertTrue(ConceptDeckLegacy.isConcept(tags: ["x", ConceptDeckLegacy.tag], status: "active"))
        XCTAssertTrue(ConceptDeckLegacy.isConcept(tags: [], status: "queued"))
        XCTAssertFalse(ConceptDeckLegacy.isConcept(tags: ["solunum"], status: "active"))
        XCTAssertFalse(ConceptDeckLegacy.isConcept(tags: [], status: "suspended"))
    }
}
