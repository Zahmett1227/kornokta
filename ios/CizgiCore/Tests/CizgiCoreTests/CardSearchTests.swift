import XCTest
@testable import CizgiCore

/// Searching the deck (2026-08-15).
///
/// The reported symptom was "search does nothing", and it had two independent
/// causes. The view-level one — four of the five sections never applying the
/// query at all — lives in `LibraryView`. The one here is the folding: on a
/// Turkish device `localizedCaseInsensitiveContains` maps a capital `I` to `ı`,
/// so which cards came back depended on which capital I the keyboard produced.
final class CardSearchTests: XCTestCase {

    private func matches(_ query: String, _ front: String) -> Bool {
        CardSearch.matches(query: query, front: front, back: "", explanation: nil)
    }

    // MARK: The İ/I pair

    /// The exact miss that started this: typed with the ASCII capital, which is
    /// what an English keyboard and iOS autocapitalisation both produce.
    func testACapitalIFindsTheDottedCapital() {
        XCTAssertTrue(matches("Inflamasyon", "İnflamasyon nedir?"))
        XCTAssertTrue(matches("inflamasyon", "İnflamasyon nedir?"))
        XCTAssertTrue(matches("İnflamasyon", "İnflamasyon nedir?"))
    }

    /// And the other direction: text written with the dotless capital has to be
    /// reachable from a query typed with the dotted one.
    func testTheDotlessCapitalIsReachableToo() {
        XCTAssertTrue(matches("iskemi", "Iskemi bulguları"))
        XCTAssertTrue(matches("İskemi", "Iskemi bulguları"))
        XCTAssertTrue(matches("ıskemi", "Iskemi bulguları"))
    }

    /// All four I's fold together, in text as well as in the query — the one
    /// rule that makes the two tests above symmetric rather than coincidental.
    func testEveryTurkishIFoldsToTheSameLetter() {
        XCTAssertEqual(
            Set(["İ", "I", "ı", "i"].map(CardSearch.fold)),
            ["i"]
        )
    }

    func testTheRestOfTheTurkishAlphabetFoldsToo() {
        XCTAssertTrue(matches("gogus", "Göğüs duvarı"))
        XCTAssertTrue(matches("sismis", "Şişmiş hücre"))
        XCTAssertTrue(matches("cekirdek", "Çekirdek zarı"))
    }

    /// Eponyms this deck actually contains, typed without the accent.
    func testAccentedEponymsAreReachableFromAPlainKeyboard() {
        XCTAssertTrue(matches("sezary", "Sézary sendromu"))
        XCTAssertTrue(matches("menetrier", "Ménétrier hastalığı"))
    }

    // MARK: Punctuation is not folded away

    /// Where this deliberately parts company with `MultipleChoice.comparisonKey`,
    /// which drops every non-alphanumeric character. For search, a typed space
    /// has to keep meaning a space — otherwise the query silently widens and
    /// the user cannot narrow it back down.
    func testSpacingAndPunctuationStillCount() {
        XCTAssertTrue(matches("5-FU", "5-FU toksisitesi"))
        XCTAssertFalse(matches("5 FU", "5-FU toksisitesi"))
    }

    // MARK: Which fields are read

    func testTheAnswerAndExplanationAreSearched() {
        XCTAssertTrue(CardSearch.matches(
            query: "adrenalin", front: "Anaflakside ilk doz?",
            back: "0,5 mg IM adrenalin", explanation: nil
        ))
        XCTAssertTrue(CardSearch.matches(
            query: "uyluk", front: "Anaflakside ilk doz?",
            back: "0,5 mg IM adrenalin", explanation: "Uyluk ön-dış yüzü."
        ))
    }

    /// A card whose only mention of the term sits in a distractor. On the
    /// owner's deck this is a real card, not a hypothetical — searching
    /// "Glomus" missed one until the option texts were included.
    func testOptionTextsTagsAndClassificationAreSearched() {
        XCTAssertTrue(CardSearch.matches(
            query: "glomus", front: "Hangisi?", back: "Kapiller hemanjiyom",
            explanation: nil, optionTexts: ["Glomus tümörü", "Piyojenik granülom"]
        ))
        XCTAssertTrue(CardSearch.matches(
            query: "nefrotik", front: "Soru", back: "Cevap", explanation: nil,
            tags: ["nefrotik sendrom"]
        ))
        XCTAssertTrue(CardSearch.matches(
            query: "patoloji", front: "Soru", back: "Cevap", explanation: nil,
            subject: "Patoloji", topic: "Hücre zedelenmesi"
        ))
    }

    func testATermInNoFieldDoesNotMatch() {
        XCTAssertFalse(CardSearch.matches(
            query: "kardiyoloji", front: "Soru", back: "Cevap",
            explanation: "Açıklama", tags: ["etiket"],
            subject: "Patoloji", topic: "İnflamasyon", optionTexts: ["A", "B"]
        ))
    }

    // MARK: The option decode is not paid for unless it is needed

    /// `Card.options` parses JSON out of `optionsRaw` on every read, so the
    /// texts arrive as an autoclosure. These pin the two cases where the whole
    /// deck would otherwise be parsed for nothing — on this screen the filter
    /// runs for every card, on every keystroke.
    func testOptionsAreNotDecodedForAnEmptyQuery() {
        var decoded = false
        _ = CardSearch.matches(
            query: "", front: "Soru", back: "Cevap", explanation: nil,
            optionTexts: { decoded = true; return ["Şık"] }()
        )
        XCTAssertFalse(decoded, "sorgu boşken şıklara hiç bakılmamalı")
    }

    func testOptionsAreNotDecodedOnceAnEarlierFieldMatches() {
        var decoded = false
        XCTAssertTrue(CardSearch.matches(
            query: "nekroz", front: "Koagülatif nekroz nedir?", back: "Cevap",
            explanation: nil, optionTexts: { decoded = true; return ["Şık"] }()
        ))
        XCTAssertFalse(decoded, "soru zaten eşleştiyse şıklar çözülmemeli")
    }

    // MARK: Empty query

    /// So the caller can pass the field through unbranched. Every section
    /// skipping that branch is what made the search look broken in the first
    /// place, so the safe default belongs here rather than at each call site.
    func testAnEmptyOrBlankQueryMatchesEverything() {
        XCTAssertTrue(matches("", "Herhangi bir kart"))
        XCTAssertTrue(matches("   \n", "Herhangi bir kart"))
    }

    func testSurroundingWhitespaceInTheQueryIsIgnored() {
        XCTAssertTrue(matches("  nekroz  ", "Koagülatif nekroz"))
    }
}
