import XCTest
@testable import CizgiCore

/// Writing a card by hand on the page it belongs to (2026-08-15).
///
/// The gap these close is the one no automatic signal sees: a fact the model
/// never turned into a card carries no `lowConfidence`, so the only check on a
/// hand-written card is the rules here.
final class ManualCardCreationTests: XCTestCase {

    /// A real pair from the bundled template, so the topic rules are tested
    /// against the schema the app actually ships rather than a fixture.
    private func schema() throws -> SubjectTopicSchema {
        try XCTUnwrap(SubjectTopicSchema.shared)
    }

    private func firstSubjectAndTopic(_ schema: SubjectTopicSchema) throws -> (String, String) {
        let subject = try XCTUnwrap(schema.subjects.first)
        return (subject.name, try XCTUnwrap(subject.topics.first))
    }

    // MARK: Text

    func testAPlainCardIsTrimmedAndClassified() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "  Anaflakside ilk doz?  ",
            back: "\n0,5 mg IM adrenalin\n",
            explanation: "  Uyluk ön-dış yüzü.  ",
            type: .directRecall,
            subject: subject,
            topic: topic
        )

        let card = try XCTUnwrap(draft.validate(schema: schema).card)
        XCTAssertEqual(card.front, "Anaflakside ilk doz?")
        XCTAssertEqual(card.back, "0,5 mg IM adrenalin")
        XCTAssertEqual(card.explanation, "Uyluk ön-dış yüzü.")
        XCTAssertEqual(card.type, .directRecall)
        XCTAssertNil(card.options)
        XCTAssertEqual(card.subject, subject)
        XCTAssertEqual(card.topic, topic)
    }

    func testAnEmptiedExplanationBecomesNil() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Soru", back: "Cevap", explanation: "   ",
            subject: subject, topic: topic
        )
        XCTAssertNil(try XCTUnwrap(draft.validate(schema: schema).card).explanation)
    }

    func testACardWithoutAQuestionOrAnAnswerCannotBeSaved() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        var draft = ManualCardDraft(front: "  ", back: "Cevap", subject: subject, topic: topic)
        XCTAssertEqual(draft.validate(schema: schema), .emptyFront)

        draft = ManualCardDraft(front: "Soru", back: "\n", subject: subject, topic: topic)
        XCTAssertEqual(draft.validate(schema: schema), .emptyBack)
    }

    // MARK: Ders/konu

    /// The owner's decision: unlike the editor, this form has no "Konusuz".
    /// A card added to plug a gap on a marked page always knows which topic the
    /// gap was in.
    func testSubjectAndTopicAreBothRequired() throws {
        let schema = try schema()
        let (subject, _) = try firstSubjectAndTopic(schema)

        XCTAssertEqual(
            ManualCardDraft(front: "Soru", back: "Cevap", subject: nil, topic: nil).validate(schema: schema),
            .missingSubject
        )
        XCTAssertEqual(
            ManualCardDraft(front: "Soru", back: "Cevap", subject: subject, topic: nil).validate(schema: schema),
            .missingTopic
        )
        XCTAssertEqual(
            ManualCardDraft(front: "Soru", back: "Cevap", subject: subject, topic: "   ").validate(schema: schema),
            .missingTopic
        )
    }

    /// Topic names are unique only *within* a subject, so a valid topic under one
    /// ders has to be rejected under another — the whole reason every check in
    /// this project runs on the (ders, konu) pair.
    func testATopicFromAnotherSubjectIsRejected() throws {
        let schema = try schema()
        let first = try XCTUnwrap(schema.subjects.first)
        let other = try XCTUnwrap(
            schema.subjects.first(where: { subject in
                subject.name != first.name && !subject.topics.contains(where: first.topics.contains)
            })
        )
        let draft = ManualCardDraft(
            front: "Soru", back: "Cevap",
            subject: other.name,
            topic: try XCTUnwrap(first.topics.first)
        )
        XCTAssertEqual(draft.validate(schema: schema), .invalidTopic)
    }

    /// A subject typed in a different case still resolves — the same tr-locale
    /// rule the rest of the app uses, so a legacy `Source.subject` written before
    /// the template existed does not block the form.
    func testTheSubjectIsCanonicalised() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Soru", back: "Cevap",
            subject: subject.lowercased(with: Locale(identifier: "tr")),
            topic: topic
        )
        XCTAssertEqual(try XCTUnwrap(draft.validate(schema: schema).card).subject, subject)
    }

    /// A nil schema is not an error: every screen hides the ders/konu UI when the
    /// template cannot be read, so the card must save unclassified rather than be
    /// blocked on a picker that is not on screen.
    func testWithoutTheTemplateTheCardSavesUnclassified() throws {
        let card = try XCTUnwrap(
            ManualCardDraft(front: "Soru", back: "Cevap").validate(schema: nil).card
        )
        XCTAssertNil(card.subject)
        XCTAssertNil(card.topic)
    }

    // MARK: Five options

    func testTheAnswerIsTheCorrectOption() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Hangisi?", back: "Adrenalin",
            type: .multipleChoice,
            distractors: [
                .init(text: "Noradrenalin", why: "Vazopresör, anafilakside ilk seçenek değil."),
                .init(text: "Dopamin"),
                .init(text: "Dobutamin"),
                .init(text: "Efedrin"),
            ],
            subject: subject, topic: topic
        )

        let card = try XCTUnwrap(draft.validate(schema: schema).card)
        let options = try XCTUnwrap(card.options)
        XCTAssertEqual(options.count, MultipleChoice.optionCount)
        XCTAssertEqual(options.filter(\.isCorrect).count, 1)
        XCTAssertEqual(options.first(where: \.isCorrect)?.text, card.back)
        XCTAssertEqual(card.type, .multipleChoice)
    }

    /// The owner's decision: an empty "neden yanlış" is not a defect. It must
    /// neither block the save nor be stored as `""` — `nil` is what an absent
    /// reason looks like everywhere else.
    func testAnEmptyReasonIsAllowedAndStoredAsNil() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Hangisi?", back: "Adrenalin",
            type: .multipleChoice,
            distractors: [
                .init(text: "Noradrenalin"),
                .init(text: "Dopamin"),
                .init(text: "Dobutamin"),
                .init(text: "Efedrin"),
            ],
            subject: subject, topic: topic
        )

        let options = try XCTUnwrap(draft.validate(schema: schema).card?.options)
        XCTAssertTrue(options.allSatisfy { $0.why == nil })
    }

    func testAnEmptyDistractorBlocksTheSave() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Hangisi?", back: "Adrenalin",
            type: .multipleChoice,
            distractors: [
                .init(text: "Noradrenalin"),
                .init(text: "  "),
                .init(text: "Dobutamin"),
                .init(text: "Efedrin"),
            ],
            subject: subject, topic: topic
        )
        XCTAssertEqual(draft.validate(schema: schema), .options(.emptyOption))
    }

    /// A distractor that repeats the answer gives the question away. Caught by
    /// `comparisonKey`, so the Turkish İ/ı pair counts as the same word — the
    /// exact case `lowercased()` alone gets wrong (ADR-001).
    func testADistractorRepeatingTheAnswerIsCaughtAcrossTurkishCase() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Hangisi?", back: "İnsülin",
            type: .multipleChoice,
            distractors: [
                .init(text: "insülin"),
                .init(text: "Glukagon"),
                .init(text: "Kortizol"),
                .init(text: "Somatostatin"),
            ],
            subject: subject, topic: topic
        )
        XCTAssertEqual(draft.validate(schema: schema), .options(.duplicateOptions))
    }

    /// Distractors typed while the type was "Beş şık" and then left behind must
    /// not follow a plain card into the deck.
    func testDistractorsAreIgnoredOnAPlainCard() throws {
        let schema = try schema()
        let (subject, topic) = try firstSubjectAndTopic(schema)
        let draft = ManualCardDraft(
            front: "Soru", back: "Cevap",
            type: .cloze,
            distractors: [.init(text: "A"), .init(text: "B"), .init(text: "C"), .init(text: "D")],
            subject: subject, topic: topic
        )
        let card = try XCTUnwrap(draft.validate(schema: schema).card)
        XCTAssertNil(card.options)
        XCTAssertEqual(card.type, .cloze)
    }
}
