import XCTest
@testable import CizgiCore

/// docs/ADR-001's rule applied to display text rather than to comparison keys.
final class TurkishTextTests: XCTestCase {

    /// The case that produced the bug: a real topic name from
    /// `subject_topics.json`, set in caps on the review screen's eyebrow.
    func testDottedIUppercasesToDottedCapital() {
        XCTAssertEqual(
            TurkishText.uppercased("Endokrin Sistem Farmakolojisi"),
            "ENDOKRİN SİSTEM FARMAKOLOJİSİ"
        )
    }

    /// The other half of the pair — the dotless ı must not gain a dot.
    func testDotlessIUppercasesToPlainCapital() {
        XCTAssertEqual(TurkishText.uppercased("Kadın Hastalıkları"), "KADIN HASTALIKLARI")
    }

    /// Both letters in one string, which is where a half-right rule shows up.
    func testBothLettersInOneString() {
        XCTAssertEqual(TurkishText.uppercased("İstisna ve ayırt etme"), "İSTİSNA VE AYIRT ETME")
    }

    /// Turkish is not the only thing on these labels; the rest must be
    /// untouched.
    func testOtherLettersAreUnaffected() {
        XCTAssertEqual(TurkishText.uppercased("Patoloji · FES"), "PATOLOJİ · FES")
    }
}
