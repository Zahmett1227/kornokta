import Foundation

/// Builds the coverage payload the Karanlık Harita endpoint ranks (docs/ADR-009).
///
/// The deck's side of a closed-universe question. `/api/dark-map` answers "which
/// canonical topics are you dark in", and that question only has a meaning
/// because `subject_topics.json` is finite: 11 subjects, 143 topics, so the
/// complement of what the deck covers is *knowable* rather than a matter of
/// opinion. Everything here exists to keep that property true on the way out.
///
/// Two rules follow from it, and both are the opposite of what a naive
/// "summarise my deck" payload would do:
///
/// 1. **Only canonical pairs are sent.** A card classified under a subject or
///    topic the bundled schema does not know contributes to nothing. It is not
///    dropped silently — `unclassifiedCards` counts it so the screen can say so
///    — but it never becomes a row, because a row the server cannot match
///    against its own copy of the schema would be discarded there anyway.
/// 2. **Absence is not encoded.** Zero-card topics are deliberately *not* in the
///    payload. The server zero-fills from its own canonical list, so a topic
///    this phone forgot to mention still appears as empty. Sending the zeros
///    would double the payload to say something the server already knows, and
///    worse, it would make the client's list authoritative — a stale app build
///    with an older schema copy could then hide a topic from the analysis
///    entirely.
///
/// Suspended cards do not count as coverage. That is a judgement, not an
/// oversight: the 117 duplicates `DuplicateSuspendMigration` put away are cards
/// the owner will never see again, and counting them would make a topic look
/// studied because it once held a redundant card. The same reasoning covers
/// drafts. `needsReview` cards are excluded for the same reason and the
/// approval-gate migration has already emptied that state on this deck.
public enum DarkMapCoverage {

    /// One card, reduced to what coverage arithmetic needs.
    ///
    /// A separate type from `KnowledgeMapCard` even though the two overlap,
    /// because this one needs `front` (the sample question) and that one needs
    /// `lapseCount` (weakness colouring). Merging them would push a field each
    /// caller does not use into the other's call site, and `KnowledgeMapCard` is
    /// built once per render of Bilgi Haritası.
    public struct Card: Equatable, Sendable {
        public let subject: String?
        public let topic: String?
        public let front: String
        public let isActive: Bool
        public let lowConfidence: Bool

        public init(
            subject: String?,
            topic: String?,
            front: String,
            isActive: Bool,
            lowConfidence: Bool
        ) {
            self.subject = subject
            self.topic = topic
            self.front = front
            self.isActive = isActive
            self.lowConfidence = lowConfidence
        }
    }

    /// One canonical (ders, konu) pair the deck actually covers.
    public struct Row: Equatable, Sendable, Codable {
        public let subject: String
        public let topic: String
        public let cardCount: Int
        /// Cards the deck itself already doubts. A subset of `cardCount`.
        public let weakCardCount: Int
        /// A few question texts, so the model can see what counts cannot.
        public let sampleFronts: [String]
    }

    public struct Payload: Equatable, Sendable {
        /// Canonical pairs with at least one active card, in schema order.
        public let rows: [Row]
        /// Active cards whose subject or topic is not canonical (or absent).
        ///
        /// Reported rather than hidden: on a deck where most cards still carry
        /// no topic, a map built only from `rows` would describe a small corner
        /// of the deck while looking like it described all of it.
        public let unclassifiedCards: Int
        /// Cards excluded because they are suspended, draft, or awaiting review.
        public let inactiveCards: Int

        public var coveredTopicCount: Int { rows.count }
        public var classifiedCards: Int { rows.reduce(0) { $0 + $1.cardCount } }
    }

    /// Why a payload produced no rows.
    ///
    /// Three genuinely different situations that all look like "no coverage",
    /// and telling them apart matters because only one is something the user
    /// can act on. Lives here, and is tested, because the view got this wrong
    /// twice: first by asserting a cause it could not know ("önce ders/konu
    /// atanmalı"), then by calling an all-suspended deck empty (Codex, PR #49).
    /// A `switch` over a closed enum is what stops a third miss.
    public enum Emptiness: Equatable, Sendable {
        /// Active cards exist, but none carries a canonical (ders, konu) pair.
        /// The only actionable case: classifying them personalises the ranking.
        case unclassifiedOnly
        /// Cards exist but every one is suspended, draft, or awaiting review.
        /// Nothing to act on — and emphatically *not* an empty deck.
        case inactiveOnly
        /// No cards at all.
        case noCards
    }

    /// `nil` when the payload has rows; otherwise which of the three it is.
    ///
    /// `unclassifiedOnly` is checked first on purpose: when a deck has both
    /// unclassified active cards and suspended ones, the actionable cause is
    /// the one worth naming.
    public static func emptiness(of payload: Payload) -> Emptiness? {
        guard payload.rows.isEmpty else { return nil }
        if payload.unclassifiedCards > 0 { return .unclassifiedOnly }
        if payload.inactiveCards > 0 { return .inactiveOnly }
        return .noCards
    }

    /// Default questions forwarded per topic. Mirrors the server's own default;
    /// the server clamps to its configured ceiling either way, so a mismatch
    /// costs a slightly larger request, never a wrong answer.
    public static let defaultSampleFronts = 4

    /// Groups the deck into canonical rows.
    ///
    /// Sample fronts are taken from the **longest** questions rather than the
    /// first few. A topic's shortest cards are its bare definitions, which are
    /// exactly the ones that make a shallow topic look covered; the longer
    /// questions are where distinctions and exceptions live. Rule 4 of the
    /// prompt asks the model to notice "twelve cards that all restate one
    /// definition", and handing it the twelve shortest would hide the very
    /// signal it is being asked to read.
    public static func build(
        cards: [Card],
        schema: SubjectTopicSchema,
        maxSampleFronts: Int = defaultSampleFronts
    ) -> Payload {
        var grouped: [String: [Card]] = [:]
        var unclassified = 0
        var inactive = 0

        for card in cards {
            guard card.isActive else {
                inactive += 1
                continue
            }
            guard
                let subject = card.subject,
                let topic = card.topic,
                schema.isValidTopic(topic, subject: subject)
            else {
                unclassified += 1
                continue
            }
            grouped[key(subject: subject, topic: topic), default: []].append(card)
        }

        // Emitted in schema order rather than dictionary order so two runs over
        // the same deck produce byte-identical payloads. That is what lets the
        // provider's prompt cache hit between a first look and a re-run, and a
        // cached input token bills at roughly a tenth of the rate.
        var rows: [Row] = []
        for subject in schema.subjects {
            for topic in subject.topics {
                guard let group = grouped[key(subject: subject.name, topic: topic)] else { continue }
                rows.append(
                    Row(
                        subject: subject.name,
                        topic: topic,
                        cardCount: group.count,
                        weakCardCount: group.filter(\.lowConfidence).count,
                        sampleFronts: samples(from: group, limit: maxSampleFronts)
                    )
                )
            }
        }

        return Payload(rows: rows, unclassifiedCards: unclassified, inactiveCards: inactive)
    }

    /// Written as explicit statements rather than a `map/filter/sorted/prefix`
    /// chain on purpose. The chained version type-checked so slowly it looked
    /// like a hung build — a long inferred pipeline ending in the heavily
    /// overloaded `String.init` is a known Swift inference blowup, and the
    /// compiler gives no hint that *that* is what it is doing.
    private static func samples(from group: [Card], limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        var trimmed: [String] = []
        trimmed.reserveCapacity(group.count)
        for card in group {
            let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
            if !front.isEmpty { trimmed.append(front) }
        }

        // `count` on a Swift String is grapheme clusters, which is the right
        // notion of "longer" for Turkish text: "ğ" and "İ" must not count double
        // just because they take more UTF-8 bytes. The length tie-break on the
        // text itself keeps the choice stable across runs, which is what lets
        // two identical decks produce byte-identical payloads.
        trimmed.sort { (lhs: String, rhs: String) -> Bool in
            let left = lhs.count
            let right = rhs.count
            if left != right { return left > right }
            return lhs < rhs
        }

        if trimmed.count > limit { trimmed.removeLast(trimmed.count - limit) }
        return trimmed
    }

    /// Separator matches the backend's `TOPIC_KEY_SEPARATOR`. Local to this
    /// grouping step and never sent, so the two only have to agree on being
    /// unambiguous, not on being the same character — but keeping them the same
    /// makes a payload readable next to a server log.
    private static func key(subject: String, topic: String) -> String {
        "\(subject)|\(topic)"
    }
}
