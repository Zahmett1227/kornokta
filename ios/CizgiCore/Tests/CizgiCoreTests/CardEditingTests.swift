import XCTest
@testable import CizgiCore

/// Editing a card and resolving where it came from (ANA-PLAN §5.5, §6.5).
///
/// Faz 6 dropped the approval step on the promise that a wrong card could be
/// corrected afterwards; these cover the rules that promise rests on, plus the
/// ones that stop "Kaynağı göster" from showing something that only looks like
/// a source.
final class CardEditingTests: XCTestCase {

    // MARK: Editing

    func testAnEditIsTrimmed() {
        let validation = CardEditor.validate(
            front: "  Anaflakside ilk doz?  ",
            back: "\n0,5 mg IM adrenalin\n",
            explanation: "  Kas içi, uyluk ön-dış yüzü.  "
        )
        XCTAssertEqual(
            validation.edit,
            CardEdit(
                front: "Anaflakside ilk doz?",
                back: "0,5 mg IM adrenalin",
                explanation: "Kas içi, uyluk ön-dış yüzü."
            )
        )
    }

    /// An emptied explanation has to become `nil`, not `""` — the generator
    /// stores an absent one as `nil`, and an empty string would render a blank
    /// "Açıklama" section instead of no section.
    func testAnEmptiedExplanationBecomesNil() {
        let validation = CardEditor.validate(front: "Soru", back: "Cevap", explanation: "   ")
        XCTAssertNil(validation.edit?.explanation)
    }

    func testACardWithoutAQuestionOrAnAnswerCannotBeSaved() {
        XCTAssertEqual(CardEditor.validate(front: "   ", back: "Cevap", explanation: ""), .emptyFront)
        XCTAssertEqual(CardEditor.validate(front: "Soru", back: "\n", explanation: ""), .emptyBack)
    }

    /// One wording for each reason, so the disabled button and the message under
    /// the field cannot drift apart.
    func testEveryRejectionCarriesAMessageAndEveryAcceptanceDoesNot() {
        XCTAssertNotNil(CardEditValidation.emptyFront.message)
        XCTAssertNotNil(CardEditValidation.emptyBack.message)
        XCTAssertNil(CardEditor.validate(front: "Soru", back: "Cevap", explanation: "").message)
    }

    func testAnUntouchedEditReportsNoChange() {
        let edit = CardEdit(front: "Soru", back: "Cevap", explanation: "Açıklama")
        XCTAssertFalse(CardEditor.changes(edit, from: "Soru", "Cevap", "Açıklama"))
        XCTAssertTrue(CardEditor.changes(edit, from: "Soru", "Başka cevap", "Açıklama"))
        XCTAssertTrue(CardEditor.changes(edit, from: "Soru", "Cevap", nil))
    }

    // MARK: Source material

    private let captured = Date(timeIntervalSince1970: 1_770_000_000)

    private func material(
        cardFront: String = "Anaflakside ilk doz?",
        quote: String? = nil,
        readText: String? = nil,
        subject: String? = nil,
        pageImagePath: String? = "pages/abc.jpg",
        pageImageExists: Bool = true
    ) -> CardSourceMaterial {
        CardSourceResolver.material(
            cardFront: cardFront,
            quote: quote,
            readText: readText,
            subject: subject,
            pageImagePath: pageImagePath,
            pageImageExists: pageImageExists,
            capturedAt: captured
        )
    }

    func testThePageImageIsSourceMaterialOnItsOwn() {
        // The whole point of the fix: a Faz 6 card has no quote, so the photo is
        // the only provenance there is — and the old gate hid it.
        let resolved = material()
        XCTAssertEqual(resolved.pageImagePath, "pages/abc.jpg")
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertFalse(resolved.pageImageDiscarded)
    }

    /// "Orijinal sayfayı sakla" off is a real setting; a card whose page was
    /// deleted must say so rather than look like it never had one.
    func testADiscardedPageIsReportedRatherThanHidden() {
        let resolved = material(pageImageExists: false)
        XCTAssertNil(resolved.pageImagePath)
        XCTAssertTrue(resolved.pageImageDiscarded)
        XCTAssertFalse(resolved.isEmpty)
    }

    func testACardWithNoPageAtAllHasNothingToShow() {
        let resolved = material(pageImagePath: nil, pageImageExists: false)
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertFalse(resolved.pageImageDiscarded)
    }

    func testTheModelsReadTextIsKept() {
        let resolved = material(readText: "  Anaflakside ilk basamak 0,5 mg IM adrenalindir.  ")
        XCTAssertEqual(resolved.readText, "Anaflakside ilk basamak 0,5 mg IM adrenalindir.")
    }

    /// `BackendCardProvider.map` falls back to this string when the model
    /// returned no read text. Presenting it as "what the page said" would be a
    /// fabrication with a provenance label on it.
    func testTheGeneratorsPlaceholderIsNotShownAsASource() {
        let resolved = material(readText: CardSourceResolver.readTextPlaceholder)
        XCTAssertNil(resolved.readText)
    }

    /// The generator's other fallback is the first card's own front. Echoing the
    /// question back as its own source is worse than showing none.
    func testReadTextThatMerelyRepeatsTheQuestionIsDropped() {
        let resolved = material(cardFront: "Anaflakside ilk doz?", readText: "anaflakside ilk doz?")
        XCTAssertNil(resolved.readText)
    }

    /// Why a hand-written card's unit carries an **empty** claim rather than the
    /// question (Codex, PR #43).
    ///
    /// The equality rule above hides a claim only while it still matches the
    /// front. Edit the question afterwards and the stale one walks back out
    /// under "Modelin okuduğu" — text the model never read. An empty claim is
    /// dropped whatever the question later becomes.
    func testAnEmptyClaimStaysHiddenAfterTheQuestionIsEdited() {
        let seededWithTheQuestion = material(cardFront: "Yeni soru?", readText: "Eski soru?")
        XCTAssertEqual(seededWithTheQuestion.readText, "Eski soru?", "kusurun kendisi: eski soru sızıyor")

        let seededEmpty = material(cardFront: "Yeni soru?", readText: "")
        XCTAssertNil(seededEmpty.readText)
    }

    func testBlankFieldsNeverBecomeEmptySections() {
        let resolved = material(quote: "   ", readText: "\n", subject: "  ")
        XCTAssertNil(resolved.quote)
        XCTAssertNil(resolved.readText)
        XCTAssertNil(resolved.subject)
    }

    func testALegacyQuoteStillSurvives() {
        let resolved = material(quote: "0,5 mg IM adrenalin", pageImagePath: nil, pageImageExists: false)
        XCTAssertEqual(resolved.quote, "0,5 mg IM adrenalin")
        XCTAssertFalse(resolved.isEmpty)
    }

    func testSubjectAloneIsEnoughToShowSomething() {
        let resolved = material(subject: "Farmakoloji", pageImagePath: nil, pageImageExists: false)
        XCTAssertEqual(resolved.subject, "Farmakoloji")
        XCTAssertFalse(resolved.isEmpty)
    }
}
