import XCTest
@testable import CizgiCore

/// Changing a card's kind in the editor (2026-08-15).
///
/// The invariant every case here defends: options UI visible ⟺ the card is
/// `.multipleChoice` ⟺ the option list is non-empty. Both Codex bugs in this
/// area (PR #29) were the answer being left pointing at the wrong option, so the
/// cases that matter most are the ones where `back` moves.
final class CardTypeChangeTests: XCTestCase {

    private let options: [CardOption] = [
        CardOption(text: "Adrenalin", isCorrect: true, why: nil),
        CardOption(text: "Noradrenalin", isCorrect: false, why: "Anafilakside ilk seçenek değil."),
        CardOption(text: "Dopamin", isCorrect: false, why: nil),
        CardOption(text: "Dobutamin", isCorrect: false, why: nil),
        CardOption(text: "Efedrin", isCorrect: false, why: nil),
    ]

    func testPlainToPlainMovesNothingButTheType() {
        let effect = CardTypeChange.effect(
            picking: .mechanism,
            currentType: .directRecall,
            derivedBack: "Cevap",
            currentOptions: [],
            stash: nil
        )
        XCTAssertEqual(effect, .setTypeOnly(.mechanism))
    }

    /// With nothing stashed, the answer becomes the correct option and the four
    /// distractors start empty — which keeps "Kaydet" disabled (`emptyOption`)
    /// until they are filled, rather than letting a half-built card through.
    func testBecomingFiveOptionSeedsTheAnswerAsTheCorrectOption() throws {
        let effect = CardTypeChange.effect(
            picking: .multipleChoice,
            currentType: .directRecall,
            derivedBack: "Adrenalin",
            currentOptions: [],
            stash: nil
        )
        guard case .enterMultipleChoice(let seeded) = effect else { return XCTFail("beklenen geçiş olmadı") }
        XCTAssertEqual(seeded.count, MultipleChoice.optionCount)
        XCTAssertEqual(seeded.filter(\.isCorrect).count, 1)
        XCTAssertEqual(seeded.first(where: \.isCorrect)?.text, "Adrenalin")
        XCTAssertTrue(seeded.filter { !$0.isCorrect }.allSatisfy { $0.text.isEmpty })
        XCTAssertEqual(MultipleChoice.validate(seeded), .emptyOption)
    }

    /// Leaving carries the answer out of the options *before* they are dropped —
    /// the ordering PR #29 got wrong twice.
    func testLeavingFiveOptionCarriesTheTickedAnswerOut() {
        let effect = CardTypeChange.effect(
            picking: .cloze,
            currentType: .multipleChoice,
            derivedBack: "Adrenalin",
            currentOptions: options,
            stash: nil
        )
        XCTAssertEqual(effect, .leaveMultipleChoice(type: .cloze, back: "Adrenalin", stash: options))
    }

    /// Switching away and back must not make the user retype four distractors —
    /// but the restored answer is the *current* one, not the one that was correct
    /// when the options were put away. Rewriting the answer while the card was
    /// plain and then coming back would otherwise silently reinstate the old
    /// answer: the same invariant break as PR #29, arriving by another route.
    func testARestoredStashTakesItsAnswerFromTheCurrentBack() throws {
        let effect = CardTypeChange.effect(
            picking: .multipleChoice,
            currentType: .directRecall,
            derivedBack: "0,5 mg IM adrenalin",
            currentOptions: [],
            stash: options
        )
        guard case .enterMultipleChoice(let restored) = effect else { return XCTFail("beklenen geçiş olmadı") }
        XCTAssertEqual(restored.first(where: \.isCorrect)?.text, "0,5 mg IM adrenalin")
        XCTAssertEqual(restored.filter { !$0.isCorrect }.map(\.text), ["Noradrenalin", "Dopamin", "Dobutamin", "Efedrin"])
        // The distractors keep their reasons; only the answer was replaced.
        XCTAssertEqual(restored[1].why, "Anafilakside ilk seçenek değil.")
        XCTAssertEqual(MultipleChoice.validate(restored), .valid)
    }

    /// "Şıkları kaldır" and the picker are the same operation, so the button
    /// routes through `effect(picking: .directRecall, ...)`. That target is
    /// `resolvedType`'s own degradation target — the two cannot diverge.
    func testTheRemoveOptionsButtonMatchesResolvedTypesDegradation() {
        let effect = CardTypeChange.effect(
            picking: .directRecall,
            currentType: .multipleChoice,
            derivedBack: "Adrenalin",
            currentOptions: options,
            stash: nil
        )
        XCTAssertEqual(effect, .leaveMultipleChoice(type: .directRecall, back: "Adrenalin", stash: options))
        XCTAssertEqual(MultipleChoice.resolvedType(current: .multipleChoice, options: nil), .directRecall)
    }

    /// Re-picking the type already selected is a no-op the editor still has to
    /// handle: on a five-option card it must not wipe the options the user is
    /// halfway through editing.
    func testRepickingTheSameTypeKeepsTheOptionsIntact() {
        XCTAssertEqual(
            CardTypeChange.effect(
                picking: .multipleChoice,
                currentType: .multipleChoice,
                derivedBack: "Adrenalin",
                currentOptions: options,
                stash: nil
            ),
            .enterMultipleChoice(options: options)
        )
        XCTAssertEqual(
            CardTypeChange.effect(
                picking: .cloze,
                currentType: .cloze,
                derivedBack: "Cevap",
                currentOptions: [],
                stash: nil
            ),
            .setTypeOnly(.cloze)
        )
    }
}
