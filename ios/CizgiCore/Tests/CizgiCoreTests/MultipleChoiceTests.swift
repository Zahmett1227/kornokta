import XCTest
@testable import CizgiCore

/// Five-option cards (ANA-PLAN §13.3, docs/FAZ7-PLAN-coktan-secmeli.md).
final class MultipleChoiceValidationTests: XCTestCase {
    private func options(
        count: Int = 5,
        correctAt: Int? = 0,
        texts: [String]? = nil
    ) -> [CardOption] {
        let labels = texts ?? (0..<count).map { "Şık \($0)" }
        return labels.enumerated().map { index, text in
            CardOption(text: text, isCorrect: index == correctAt, why: index == correctAt ? nil : "yanlış")
        }
    }

    func testFiveOptionsWithOneCorrectIsValid() {
        XCTAssertEqual(MultipleChoice.validate(options()), .valid)
        XCTAssertEqual(MultipleChoice.correctIndex(options(correctAt: 3)), 3)
    }

    /// §13.3's first rule, and the one a model breaks most easily.
    func testOptionCountMustBeExactlyFive() {
        XCTAssertEqual(MultipleChoice.validate(options(count: 4)), .wrongOptionCount(4))
        XCTAssertEqual(MultipleChoice.validate(options(count: 6)), .wrongOptionCount(6))
        XCTAssertEqual(MultipleChoice.validate([]), .wrongOptionCount(0))
    }

    func testExactlyOneOptionMustBeCorrect() {
        XCTAssertEqual(MultipleChoice.validate(options(correctAt: nil)), .noCorrectOption)

        var two = options()
        two[2] = CardOption(text: two[2].text, isCorrect: true, why: nil)
        XCTAssertEqual(MultipleChoice.validate(two), .severalCorrectOptions(2))
    }

    func testBlankOptionIsRejected() {
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["Doğru", "   ", "C", "D", "E"])),
            .emptyOption
        )
    }

    /// Two identical distractors make the question unanswerable as written —
    /// and it is the shape "two correct answers" takes most often.
    func testDuplicateOptionsAreRejected() {
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["Hipokalemi", "Hipokalemi", "C", "D", "E"])),
            .duplicateOptions
        )
    }

    /// Case and accents do not make two options different — and Turkish is
    /// exactly where the naive comparison fails (ADR-001: `İ`/`ı`).
    func testDuplicatesAreCaughtAcrossTurkishCaseAndAccents() {
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["İskemi", "iskemi", "C", "D", "E"])),
            .duplicateOptions
        )
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["Şok", "sok", "C", "D", "E"])),
            .duplicateOptions
        )
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["Sağ ventrikül", "sag  ventrikul", "C", "D", "E"])),
            .duplicateOptions
        )
    }

    /// The device and the server must call the same pairs duplicates. This one
    /// diverged: punctuation was a separator here and not there, so a card the
    /// server accepted arrived and silently lost its options (Codex, PR #29).
    func testPunctuationStillTellsOptionsApart() {
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["HER2+", "HER2", "C", "D", "E"])),
            .valid
        )
        XCTAssertEqual(
            MultipleChoice.validate(options(texts: ["A-B", "A B", "C", "D", "E"])),
            .valid
        )
    }

    func testGenuinelyDifferentOptionsAreNotCalledDuplicates() {
        XCTAssertEqual(
            MultipleChoice.validate(
                options(texts: ["Hipokalemi", "Hiperkalemi", "Hiponatremi", "Hipokalsemi", "Hipomagnezemi"])
            ),
            .valid
        )
    }

    func testEveryFailureExplainsWhatToFix() {
        let cases: [MultipleChoiceValidation] = [
            .wrongOptionCount(3), .noCorrectOption, .severalCorrectOptions(2),
            .emptyOption, .duplicateOptions,
        ]
        for validation in cases {
            XCTAssertNotNil(validation.message, "\(validation) mesajsız")
        }
        XCTAssertNil(MultipleChoiceValidation.valid.message)
    }
}

final class MultipleChoiceTypeTests: XCTestCase {
    private let sound = (0..<5).map { CardOption(text: "Şık \($0)", isCorrect: $0 == 0, why: nil) }

    func testSoundOptionsMakeItAMultipleChoiceCard() {
        XCTAssertEqual(MultipleChoice.resolvedType(current: .directRecall, options: sound), .multipleChoice)
    }

    /// Removing the options in the editor must leave a usable plain card, not a
    /// five-option card with nothing to choose from.
    func testRemovingOptionsFallsBackToAPlainCard() {
        XCTAssertEqual(MultipleChoice.resolvedType(current: .multipleChoice, options: nil), .directRecall)
        XCTAssertEqual(
            MultipleChoice.resolvedType(current: .multipleChoice, options: Array(sound.prefix(2))),
            .directRecall
        )
    }

    func testOtherTypesAreLeftAlone() {
        XCTAssertEqual(MultipleChoice.resolvedType(current: .cloze, options: nil), .cloze)
        XCTAssertEqual(MultipleChoice.resolvedType(current: .mechanism, options: []), .mechanism)
    }
}

final class MultipleChoiceStorageTests: XCTestCase {
    private let sound = [
        CardOption(text: "Hipokalemi", isCorrect: true, why: nil),
        CardOption(text: "Hiperkalemi", isCorrect: false, why: "Sivri T dalgası yapar."),
        CardOption(text: "Hiponatremi", isCorrect: false, why: "Sodyum tablosu farklı."),
        CardOption(text: "Hipokalsemi", isCorrect: false, why: "Tetani ön planda."),
        CardOption(text: "Hipomagnezemi", isCorrect: false, why: "Eşlik eder, tablo bu değil."),
    ]

    func testRoundTrips() {
        let raw = MultipleChoice.encode(sound)
        XCTAssertNotNil(raw)
        XCTAssertEqual(MultipleChoice.decode(raw), sound)
    }

    /// A card whose stored options are broken must read as a plain card, not
    /// render half a question.
    func testUnusableStorageDecodesToNil() {
        XCTAssertNil(MultipleChoice.decode(nil))
        XCTAssertNil(MultipleChoice.decode(""))
        XCTAssertNil(MultipleChoice.decode("{]"))
        XCTAssertNil(MultipleChoice.decode(MultipleChoice.encode(Array(sound.prefix(3)))))
    }
}

final class MultipleChoiceOrderTests: XCTestCase {
    private let card = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!

    func testOrderIsAPermutation() {
        let order = MultipleChoice.presentationOrder(cardId: card, reviewCount: 0, count: 5)
        XCTAssertEqual(order.sorted(), [0, 1, 2, 3, 4])
    }

    /// Stable within one sitting: SwiftUI redraws constantly and the options
    /// must not move under the user's thumb.
    func testSameSittingGivesTheSameOrder() {
        let first = MultipleChoice.presentationOrder(cardId: card, reviewCount: 4, count: 5)
        let again = MultipleChoice.presentationOrder(cardId: card, reviewCount: 4, count: 5)
        XCTAssertEqual(first, again)
    }

    /// …but not frozen for ever, or the position gets memorised instead of the
    /// fact. Across a handful of reviews at least one order must differ.
    func testOrderChangesBetweenReviews() {
        let orders = (0..<6).map { MultipleChoice.presentationOrder(cardId: card, reviewCount: $0, count: 5) }
        XCTAssertGreaterThan(Set(orders.map { $0.description }).count, 1)
    }

    /// Two cards reviewed the same number of times must not share a layout,
    /// or a whole session would put the answer in the same slot.
    func testDifferentCardsGetDifferentOrders() {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let orders = Set(
            [card, other].map { MultipleChoice.presentationOrder(cardId: $0, reviewCount: 1, count: 5).description }
        )
        XCTAssertEqual(orders.count, 2)
    }

    func testDegenerateCountsAreSafe() {
        XCTAssertEqual(MultipleChoice.presentationOrder(cardId: card, reviewCount: 0, count: 0), [])
        XCTAssertEqual(MultipleChoice.presentationOrder(cardId: card, reviewCount: 0, count: 1), [0])
        XCTAssertEqual(MultipleChoice.presentationOrder(cardId: card, reviewCount: -3, count: 5).sorted(), [0, 1, 2, 3, 4])
    }
}
