import Foundation

/// Coverage findings for one page (docs/PLAN-kapsama-sozlesmesi.md).
///
/// The failure this file exists for is the one the app could never see: a mark
/// the owner made that never became a card. A wrong card is visible — it is
/// flagged, listed under "Gözden geçir" and readable in Tekrar — while a
/// missing card has no flag, because it has no card. The page photo that could
/// prove it is the only evidence, and it is not kept forever.
///
/// Two readers answer that question and neither can answer all of it:
///
/// - **The generator's own register** (schema v2.3, `source == .generator`).
///   The model writes down every mark it saw and which mark each card came
///   from; the server subtracts one list from the other. This catches "read it
///   and did not card it" — the defect the owner reported on real pages, where
///   the starred passage sat in `readText` while the cards came from unmarked
///   text. It cannot catch a mark the model never perceived: a register does
///   not contain what its author never saw.
/// - **The independent audit** (`source == .auditor`), a different model family
///   re-reading the same photo. That is the only thing that can catch the
///   never-perceived mark, and the only reason it can is that it does not share
///   the first reader's blind spots.
///
/// Everything here is Foundation-only and pure so it can be tested by
/// `swift test` on any machine; SwiftData sees it as one JSON string on
/// `CapturedPage.coverageJSON`.
public struct PageMark: Codable, Equatable, Sendable, Identifiable {
    /// Which reader reported this mark.
    public enum Source: String, Codable, Sendable {
        /// The card generator's own register (schema v2.3).
        case generator
        /// The independent second reader (`/api/coverage`).
        case auditor
    }

    /// Stable within a page, derived from the mark's own text rather than from
    /// the model's `m1`-style label.
    ///
    /// The label is not usable as identity: it is only unique inside one
    /// response, so a page regenerated later reuses `m1` for a different
    /// passage — and a dismissal recorded against `m1` would then silently hide
    /// an unrelated mark. Deriving it from the folded quote makes "the owner
    /// dismissed this passage" mean what it says, and makes the two readers'
    /// reports comparable without either of them agreeing on labels.
    public let id: String
    public let kind: MarkKind
    /// The marked text as the reader transcribed it, verbatim from the page.
    public let quote: String
    public let source: Source

    public init(kind: MarkKind, quote: String, source: Source) {
        self.kind = kind
        self.quote = quote
        self.source = source
        self.id = PageMark.identity(kind: kind, quote: quote)
    }

    /// `kind:folded-quote`, so the same passage reported by both readers — or
    /// by the same reader twice — collapses to one identity.
    ///
    /// Folded with `CardSearch.fold` rather than `lowercased()`: on a Turkish
    /// device `"İ".lowercased()` is `"i̇"` and `"I".lowercased()` is `"ı"`, so
    /// two readings of the same word would produce two identities and the
    /// dismissal would not stick (the bug ADR-001 records, and the one that
    /// made Bilgilerim's search miss `İnflamasyon`).
    static func identity(kind: MarkKind, quote: String) -> String {
        "\(kind.rawValue):\(CardSearch.fold(quote.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }

    /// Where this mark sits on prompt rule 3's ladder — handwriting first,
    /// highlighter last. Taken from `MarkKind`'s declaration order, which the
    /// contract-sync tests pin to the schema's own enum order.
    var priority: Int {
        MarkKind.allCases.firstIndex(of: kind) ?? MarkKind.allCases.count
    }
}

/// What one page's coverage looks like right now.
///
/// Stored on the page rather than derived on the fly: the generator's half
/// arrives once, with the cards, and the server's copy of the page (and of the
/// result) is deleted long before anyone reviews it.
public struct PageCoverage: Codable, Equatable, Sendable {
    /// One completed run of the independent audit.
    public struct Audit: Codable, Equatable, Sendable {
        public var performedAt: Date
        /// Marks the auditor found no card for.
        public var uncovered: [PageMark]
        /// How many marks it reported in total — the denominator for "it saw
        /// N marks and N-k of them were carded".
        public var markCount: Int
        /// Rows the server dropped as unusable. Surfaced rather than hidden: a
        /// number that climbs says the audit is confused, which is worth
        /// knowing before its findings are trusted.
        public var discarded: Int

        public init(performedAt: Date, uncovered: [PageMark], markCount: Int, discarded: Int) {
            self.performedAt = performedAt
            self.uncovered = uncovered
            self.markCount = markCount
            self.discarded = discarded
        }
    }

    /// Whether the generator reported a register at all.
    ///
    /// `false` is "no information", which is emphatically not "nothing was
    /// missed": a page captured before schema v2.3, or a model that ignored the
    /// field, lands here. Without this flag an empty list would read as a clean
    /// bill of health for a page nobody ever checked.
    public var reported: Bool
    /// Marks the generator registered and no surviving card claimed.
    public var uncovered: [PageMark]
    /// Cards the generator bound to no mark — prompt rule 1's own violation.
    /// Ids only; the cards themselves live in SwiftData.
    public var unmarkedCardIds: [String]
    /// The independent audit, once it has been run for this page.
    public var audit: Audit?
    /// Marks the owner has dismissed. Kept for ever, and kept as identities
    /// rather than as a count: a re-audit reports the same page again, and a
    /// dismissal that did not survive it would make the button useless.
    public var dismissedMarkIds: [String]

    public init(
        reported: Bool = false,
        uncovered: [PageMark] = [],
        unmarkedCardIds: [String] = [],
        audit: Audit? = nil,
        dismissedMarkIds: [String] = []
    ) {
        self.reported = reported
        self.uncovered = uncovered
        self.unmarkedCardIds = unmarkedCardIds
        self.audit = audit
        self.dismissedMarkIds = dismissedMarkIds
    }

    /// The rows to show the owner: both readers' findings, dismissals removed,
    /// duplicates collapsed, most valuable tier first.
    ///
    /// The generator's version of a mark wins a tie because it is the reading
    /// the cards were actually built from; the auditor's copy of the same
    /// passage would say the same thing in slightly different words and take a
    /// second row for it.
    public var openFindings: [PageMark] {
        // Dismissals are matched by the same overlap rule the deduplication
        // uses, not by id alone. Ids differ whenever the two readers transcribe
        // a passage slightly differently — or file it under different tiers —
        // and matching only on equality left a hole with teeth: dismissing the
        // generator's row skipped it before it could seed `seen`, so the
        // auditor's near-identical row surfaced and the owner had to dismiss
        // the same passage twice (Codex, PR #47). "Yoksay" is a decision about
        // the passage, so it has to be recognised however it is worded.
        let dismissedQuotes = dismissedMarkIds.map(PageCoverage.quote(inMarkId:))
        var seen: [String] = []
        var findings: [PageMark] = []

        for mark in uncovered + (audit?.uncovered ?? []) {
            let folded = CardSearch.fold(mark.quote)
            guard !dismissedQuotes.contains(where: { PageCoverage.overlaps($0, folded) }) else { continue }
            // Containment, not equality: two readers rarely transcribe the same
            // handwriting identically, and one of them quoting a few words more
            // does not make it a second mark. Equality here would show the
            // owner the same passage twice and cost two dismissals.
            guard !seen.contains(where: { PageCoverage.overlaps($0, folded) }) else { continue }
            seen.append(folded)
            findings.append(mark)
        }

        return findings.enumerated()
            .sorted { left, right in
                if left.element.priority != right.element.priority {
                    return left.element.priority < right.element.priority
                }
                // Stable within a tier: the readers list marks roughly in page
                // order, and re-sorting equals would hand back an order nothing
                // produced.
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Whether either reader has anything open for this page.
    public var hasOpenFindings: Bool { !openFindings.isEmpty }

    /// Marks one finding as handled. Idempotent, so a double tap is harmless.
    ///
    /// Both ways of finishing with a mark land here: "Yoksay" (no card needed)
    /// and writing the card it was asking for. One list rather than two,
    /// because the list answers one question — does this mark still need a
    /// card? — and a second store for "resolved" would be a second place for
    /// that answer to fall out of step.
    public mutating func dismiss(_ mark: PageMark) {
        guard !dismissedMarkIds.contains(mark.id) else { return }
        dismissedMarkIds.append(mark.id)
    }

    /// Records an audit run, replacing any earlier one.
    ///
    /// Replacing rather than merging: an audit is a snapshot of "what is
    /// missing *now*", and cards added since the last run are exactly what
    /// should shrink it. Keeping both would make the list grow with every run.
    /// Dismissals are unaffected — they live outside this and are matched by
    /// identity.
    public mutating func record(audit: Audit) {
        self.audit = audit
    }

    /// The folded quote inside a mark id (`kind:folded-quote`).
    ///
    /// Reading it back out of the id rather than storing quotes separately: the
    /// id already carries it, and a second stored list would be one more thing
    /// that can fall out of step with the first. Tier raw values never contain
    /// a colon, so the first one is always the separator; an id from a future
    /// shape with no colon degrades to itself, which can then only match
    /// exactly — the safe direction.
    static func quote(inMarkId id: String) -> String {
        guard let separator = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: separator)...])
    }

    /// Two quotes are the same passage when either contains the other.
    ///
    /// Short quotes are excluded from the containment half: a three-character
    /// fragment is contained in half the page and would swallow unrelated
    /// marks. Below that length only equality counts.
    static func overlaps(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let shortest = min(left.count, right.count)
        guard shortest >= 8 else { return false }
        return left.contains(right) || right.contains(left)
    }
}

extension PageCoverage {
    /// JSON for `CapturedPage.coverageJSON`. Same storage shape as
    /// `ExerciseFilter.storageValue`: one column, no second entity, nothing
    /// that needs a cascade rule.
    public var storageValue: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes a stored value, or an empty coverage for anything unreadable.
    ///
    /// Never throws and never returns nil: a page whose coverage blob cannot be
    /// read is a page with no findings to show, which is exactly what an empty
    /// value means. Failing louder here would take a whole page detail screen
    /// down over an audit extra.
    public static func fromStorage(_ raw: String?) -> PageCoverage {
        guard let raw, let data = raw.data(using: .utf8) else { return PageCoverage() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PageCoverage.self, from: data)) ?? PageCoverage()
    }
}
