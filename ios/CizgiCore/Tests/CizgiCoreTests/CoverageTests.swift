import XCTest
@testable import CizgiCore

/// Coverage findings (docs/PLAN-kapsama-sozlesmesi.md).
///
/// What is worth testing here is not the data shuffling but the three
/// decisions: which findings the owner sees, in what order, and what makes one
/// stop coming back.
final class CoverageTests: XCTestCase {

    private func mark(
        _ quote: String,
        _ kind: MarkKind = .symbol,
        source: PageMark.Source = .generator
    ) -> PageMark {
        PageMark(kind: kind, quote: quote, source: source)
    }

    // MARK: Identity

    func testIdentityIgnoresCaseWhitespaceAndTurkishFolding() {
        // The dismissal has to survive the same word coming back capitalised or
        // padded, and on a Turkish device `"İ".lowercased()` is not `"i"` —
        // the fold ADR-001 records, and the one that made search miss
        // `İnflamasyon`.
        let a = mark(" İnflamasyon bulguları ")
        let b = mark("inflamasyon bulguları")
        XCTAssertEqual(a.id, b.id)
    }

    func testIdentitySeparatesTiers() {
        // The same words underlined and starred are two different marks: the
        // tier is what decides which one the owner is shown first, and merging
        // them would hide the more valuable one behind the weaker one.
        XCTAssertNotEqual(mark("aynı metin", .symbol).id, mark("aynı metin", .underline).id)
    }

    // MARK: Ordering

    func testFindingsFollowThePriorityLadder() {
        let coverage = PageCoverage(
            reported: true,
            uncovered: [
                mark("fosforlu yer", .highlight),
                mark("el yazısı not", .handwriting),
                mark("yıldızlı yer", .symbol),
                mark("altı çizili yer", .underline),
            ]
        )
        // Prompt rule 3's ladder, shared with the server: the most valuable
        // thing the model skipped is the first row.
        XCTAssertEqual(
            coverage.openFindings.map(\.mark.quote),
            ["el yazısı not", "yıldızlı yer", "altı çizili yer", "fosforlu yer"]
        )
    }

    func testOrderInsideATierIsTheOrderReported() {
        let coverage = PageCoverage(
            reported: true,
            uncovered: [mark("birinci"), mark("ikinci"), mark("üçüncü")]
        )
        // Readers list marks roughly in page order; re-sorting equals would
        // hand back an order nothing produced.
        XCTAssertEqual(coverage.openFindings.map(\.mark.quote), ["birinci", "ikinci", "üçüncü"])
    }

    func testGeneratorFindingsComeBeforeAuditOnlyOnes() {
        let coverage = PageCoverage(
            reported: true,
            uncovered: [mark("kayıttan gelen", .underline)],
            audit: PageCoverage.Audit(
                performedAt: Date(),
                uncovered: [mark("denetimden gelen", .underline, source: .auditor)],
                markCount: 2,
                discarded: 0
            )
        )
        XCTAssertEqual(coverage.openFindings.map(\.mark.source), [.generator, .auditor])
    }

    // MARK: Merging the two readers

    func testTheSamePassageFromBothReadersIsOneRow() {
        // Two readers rarely transcribe handwriting identically, and one of
        // them quoting a few words more does not make it a second mark. Showing
        // both would cost the owner two dismissals for one passage.
        let coverage = PageCoverage(
            reported: true,
            uncovered: [mark("Reed-Sternberg hücresi CD30 pozitiftir", .symbol)],
            audit: PageCoverage.Audit(
                performedAt: Date(),
                uncovered: [mark("Reed-Sternberg hücresi CD30", .symbol, source: .auditor)],
                markCount: 1,
                discarded: 0
            )
        )
        XCTAssertEqual(coverage.openFindings.count, 1)
        // The generator's version wins: it is the reading the cards were
        // actually built from.
        XCTAssertEqual(coverage.openFindings.first?.mark.source, .generator)
    }

    func testShortQuotesAreNotMergedByContainment() {
        // A three-character fragment is contained in half the page; letting it
        // swallow neighbours would hide real marks behind an unrelated one.
        let coverage = PageCoverage(
            reported: true,
            uncovered: [mark("IgA", .underline), mark("IgA nefropatisi tanısı", .underline)]
        )
        XCTAssertEqual(coverage.openFindings.count, 2)
    }

    func testTheSameWordsMarkedTwiceAreCountedNotDropped() {
        // Codex, PR #47: the same drug name highlighted in two passages is two
        // real marks. Collapsing them into one row is right — both rows would
        // carry identical words and an identical tier, so there is nothing to
        // act on differently, and the dismissal identity *is* that text — but
        // dropping the second one silently is the loss this layer exists to
        // end. So the row states how many it stands for.
        let coverage = PageCoverage(
            reported: true,
            uncovered: [
                mark("Adenozin infüzyonu", .highlight),
                mark("Adenozin infüzyonu", .highlight),
                mark("başka bir yer", .highlight),
            ]
        )
        let findings = coverage.openFindings
        XCTAssertEqual(findings.map(\.mark.quote), ["Adenozin infüzyonu", "başka bir yer"])
        XCTAssertEqual(findings.map(\.occurrences), [2, 1])
    }

    func testTheOtherReaderSeeingItAgainIsNotASecondOccurrence() {
        // Across readers the same passage is one mark seen twice, not two
        // marks — that is reconciliation, and counting it would tell the owner
        // they marked something twice when they did not.
        let coverage = PageCoverage(
            reported: true,
            uncovered: [mark("tek bir işaret", .underline)],
            audit: PageCoverage.Audit(
                performedAt: Date(),
                uncovered: [mark("tek bir işaret", .underline, source: .auditor)],
                markCount: 1,
                discarded: 0
            )
        )
        XCTAssertEqual(coverage.openFindings.map(\.occurrences), [1])
    }

    // MARK: Dismissal

    func testDismissedMarkStaysDismissedAcrossAReAudit() {
        // The whole reason identity is derived from the text: an audit run
        // later reports the same passage again, and a dismissal that did not
        // survive it would make the button useless.
        var coverage = PageCoverage(reported: true, uncovered: [mark("gerekmiyor", .highlight)])
        coverage.dismiss(coverage.openFindings[0].mark)
        XCTAssertTrue(coverage.openFindings.isEmpty)

        coverage.record(audit: PageCoverage.Audit(
            performedAt: Date(),
            uncovered: [mark("gerekmiyor", .highlight, source: .auditor)],
            markCount: 5,
            discarded: 0
        ))
        XCTAssertTrue(coverage.openFindings.isEmpty, "yoksayılan işaret denetimden geri geldi")
    }

    func testDismissingOneReadersWordingSilencesTheOthers() {
        // Codex, PR #47. The two rows collapse into one while both are open, so
        // the owner only ever sees — and only ever dismisses — one of them.
        // Matching dismissals by id alone then skipped the generator's row
        // before it could seed the dedup set, and the auditor's near-identical
        // row popped back up demanding a second dismissal for one passage.
        var coverage = PageCoverage(
            reported: true,
            uncovered: [mark("Reed-Sternberg hücresi CD30 pozitiftir", .symbol)],
            audit: PageCoverage.Audit(
                performedAt: Date(),
                uncovered: [mark("Reed-Sternberg hücresi CD30", .symbol, source: .auditor)],
                markCount: 1,
                discarded: 0
            )
        )
        XCTAssertEqual(coverage.openFindings.count, 1)

        coverage.dismiss(coverage.openFindings[0].mark)

        XCTAssertTrue(coverage.openFindings.isEmpty, "aynı pasaj ikinci kez yoksayma istedi")
    }

    func testDismissalCrossesTiersForTheSamePassage() {
        // The readers can disagree about *how* a passage was marked — one calls
        // it a symbol, the other an underline — and the owner's "bu karta gerek
        // yok" is a decision about the passage, not about the tier.
        var coverage = PageCoverage(
            reported: true,
            uncovered: [mark("kenar notundaki ayrıntı", .symbol)]
        )
        coverage.dismiss(coverage.openFindings[0].mark)

        coverage.record(audit: PageCoverage.Audit(
            performedAt: Date(),
            uncovered: [mark("kenar notundaki ayrıntı", .underline, source: .auditor)],
            markCount: 3,
            discarded: 0
        ))
        XCTAssertTrue(coverage.openFindings.isEmpty)
    }

    func testDismissalDoesNotSwallowAShortUnrelatedMark() {
        // The overlap rule's own guard still applies to dismissals: a short
        // fragment must not silence every neighbour that happens to contain it.
        var coverage = PageCoverage(reported: true, uncovered: [mark("IgA", .underline)])
        coverage.dismiss(coverage.openFindings[0].mark)

        coverage.record(audit: PageCoverage.Audit(
            performedAt: Date(),
            uncovered: [mark("IgA nefropatisi tanısı", .underline, source: .auditor)],
            markCount: 2,
            discarded: 0
        ))
        XCTAssertEqual(coverage.openFindings.map(\.mark.quote), ["IgA nefropatisi tanısı"])
    }

    func testDismissingTwiceIsHarmless() {
        var coverage = PageCoverage(reported: true, uncovered: [mark("bir kez")])
        let target = coverage.openFindings[0].mark
        coverage.dismiss(target)
        coverage.dismiss(target)
        XCTAssertEqual(coverage.dismissedMarkIds.count, 1)
    }

    func testRecordingAnAuditReplacesTheEarlierOne() {
        // An audit is a snapshot of what is missing *now*; cards added since
        // the last run are exactly what should shrink it. Merging would make
        // the list grow with every run.
        var coverage = PageCoverage(reported: true)
        coverage.record(audit: PageCoverage.Audit(
            performedAt: Date(timeIntervalSince1970: 0),
            uncovered: [mark("eski", .symbol, source: .auditor)],
            markCount: 4,
            discarded: 0
        ))
        coverage.record(audit: PageCoverage.Audit(
            performedAt: Date(timeIntervalSince1970: 100),
            uncovered: [],
            markCount: 4,
            discarded: 0
        ))
        XCTAssertTrue(coverage.openFindings.isEmpty)
        XCTAssertEqual(coverage.audit?.markCount, 4)
    }

    // MARK: "No register" is not "nothing missed"

    func testSilenceIsNotACleanBillOfHealth() {
        // A page captured before schema v2.3 has no information either way, and
        // the screen has to be able to say so rather than showing a tick.
        let old = PageCoverage()
        XCTAssertFalse(old.reported)
        XCTAssertTrue(old.openFindings.isEmpty)

        let checked = PageCoverage(reported: true)
        XCTAssertTrue(checked.reported)
        XCTAssertTrue(checked.openFindings.isEmpty)
    }

    // MARK: Storage

    func testStorageRoundTripKeepsFindingsAuditAndDismissals() {
        var coverage = PageCoverage(
            reported: true,
            uncovered: [mark("el yazısı", .handwriting), mark("kutu içi", .symbol)],
            unmarkedCardIds: ["card_9"]
        )
        coverage.record(audit: PageCoverage.Audit(
            performedAt: Date(timeIntervalSince1970: 1_700_000_000),
            uncovered: [mark("denetim", .underline, source: .auditor)],
            markCount: 7,
            discarded: 1
        ))
        coverage.dismiss(coverage.openFindings[0].mark)

        let restored = PageCoverage.fromStorage(coverage.storageValue)
        XCTAssertEqual(restored, coverage)
        XCTAssertEqual(restored.unmarkedCardIds, ["card_9"])
        XCTAssertEqual(restored.audit?.discarded, 1)
        XCTAssertEqual(restored.dismissedMarkIds.count, 1)
    }

    func testUnreadableStorageDegradesToNoFindings() {
        // A page whose blob cannot be read is a page with nothing to show;
        // failing louder would take a whole detail screen down over an extra.
        XCTAssertEqual(PageCoverage.fromStorage(nil), PageCoverage())
        XCTAssertEqual(PageCoverage.fromStorage("{bozuk"), PageCoverage())
        XCTAssertFalse(PageCoverage.fromStorage("{bozuk").reported)
    }
}
