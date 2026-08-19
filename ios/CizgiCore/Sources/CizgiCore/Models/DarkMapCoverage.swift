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

    /// Hard ceiling on one sampled question, in characters.
    ///
    /// Mirrors the server's `MAX_SAMPLE_FRONT_LENGTH`, and exists here for the
    /// same reason the count ceiling does: not to be the guarantee — the server
    /// re-applies its own, and is authoritative — but so the phone does not put
    /// megabytes on the wire in the first place. The two caps may drift without
    /// harm; the server's is always the binding one.
    ///
    /// It matters most *here* because `samples` deliberately takes the longest
    /// questions, which is exactly the set a length cap would otherwise let
    /// through unbounded (Codex, PR #49).
    public static let maxSampleFrontLength = 240

    /// The topics with no active card, reconciling the two things that can be
    /// stale in opposite directions.
    ///
    /// The deck is the fast-moving side: `@Query` updates the moment a card is
    /// suspended in another tab, so any count held from an earlier run goes
    /// wrong immediately. The schema is the slow-moving side: a deployed
    /// backend can know a topic a released app does not, and that topic's gap
    /// would otherwise be invisible.
    ///
    /// So neither source wins outright — each owns what it is actually
    /// authoritative about. The local payload decides **coverage** (it is the
    /// only one that knows the deck right now); the server list only **adds**
    /// topics the bundled schema has never heard of. A previous version handed
    /// the whole answer to the server after a run and traded one staleness for
    /// the other (Codex, PR #49, twice).
    public static func untouched(
        schema: SubjectTopicSchema,
        payload: Payload,
        serverUntouched: [(subject: String, topic: String)] = []
    ) -> [(subject: String, topic: String)] {
        let covered = Set(payload.rows.map { key(subject: $0.subject, topic: $0.topic) })

        var result: [(subject: String, topic: String)] = []
        var known: Set<String> = []
        for subject in schema.subjects {
            for topic in subject.topics {
                let id = key(subject: subject.name, topic: topic)
                known.insert(id)
                if !covered.contains(id) { result.append((subject: subject.name, topic: topic)) }
            }
        }

        // Only the genuinely unknown ones. A server row this build *does* know
        // was already decided above, from the current deck.
        for row in serverUntouched where !known.contains(key(subject: row.subject, topic: row.topic)) {
            result.append((subject: row.subject, topic: row.topic))
        }
        return result
    }

    /// Refreshes each zone's card counts from the current deck.
    ///
    /// A ranking is bought once and then read for as long as the screen lives,
    /// while `@Query` keeps the deck current underneath it. The model's
    /// *judgement* survives that — "TUS leans hard on this topic and you are
    /// thin there" does not stop being true because a card was suspended — but
    /// the **counts** beside it are deck facts and go wrong immediately. A zone
    /// showing a stale count also keeps offering "Bu konuyu çalış", which then
    /// opens an empty session.
    ///
    /// One choke point rather than a fix per call site: the same staleness was
    /// patched twice at the places that happened to be looked at, and turned up
    /// a third time in the zone rows (Codex, PR #49). Everything that reads a
    /// loaded result now passes through here.
    ///
    /// Deliberately does **not** re-rank, re-order or drop zones. A topic that
    /// has become covered still belongs on the list the user paid for; it just
    /// says so honestly now.
    public static func reconcile(zones: [DarkZone], with payload: Payload) -> [DarkZone] {
        var counts: [String: Row] = [:]
        for row in payload.rows { counts[key(subject: row.subject, topic: row.topic)] = row }

        return zones.map { zone in
            var refreshed = zone
            let row = counts[key(subject: zone.subject, topic: zone.topic)]
            refreshed.cardCount = row?.cardCount ?? 0
            refreshed.weakCardCount = row?.weakCardCount ?? 0
            return refreshed
        }
    }

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
            let front = Self.flattened(card.front)
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
        return trimmed.map(clamped)
    }

    /// Collapses every run of whitespace — newlines included — into one space.
    ///
    /// Card editors accept multiline text, and the server renders these samples
    /// into a **line-oriented** coverage table; a newline inside one opened what
    /// read as another coverage row, which would have had a paid ranker reason
    /// over a topic count that never came from the deck (Codex, PR #49). The
    /// server flattens and escapes again on its side and that is the actual
    /// guarantee — this keeps the phone from putting the problem on the wire,
    /// and makes the length ceiling mean something, since 240 newlines is short
    /// and still ruinous.
    private static func flattened(_ front: String) -> String {
        front.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Truncation is marked, so the model reads a cut sentence as cut.
    private static func clamped(_ front: String) -> String {
        guard front.count > maxSampleFrontLength else { return front }
        return front.prefix(maxSampleFrontLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Separator matches the backend's `TOPIC_KEY_SEPARATOR`. Local to this
    /// grouping step and never sent, so the two only have to agree on being
    /// unambiguous, not on being the same character — but keeping them the same
    /// makes a payload readable next to a server log.
    private static func key(subject: String, topic: String) -> String {
        "\(subject)|\(topic)"
    }
}
