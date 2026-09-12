import Foundation
import SwiftData

/// Bulk import of a concept pack: one JSON file holding concepts, each with its
/// own cards, produced outside this app and imported as its own deck.
///
/// Deliberately not `BackupExporter`'s format. A backup is a flat list of cards
/// and cannot express "these four cards are four questions about one concept" —
/// `SettingsView.insert` gives every restored card a `KnowledgeUnit` of its own,
/// which is right for a backup and wrong here. Keeping the two formats apart
/// also keeps the working system untouched: nothing about restore changes
/// because this exists.
public enum ConceptPackImporter {

    // MARK: - The file

    /// The wire shape. Turkish keys because the pack is authored in Turkish and
    /// renaming them here would only move the mapping somewhere less visible;
    /// everything below this boundary is in the codebase's usual English.
    public struct Pack: Decodable, Sendable {
        public let formatVersion: Int
        public let ders: String
        public let kavramlar: [Concept]

        public struct Concept: Decodable, Equatable, Sendable {
            public let id: UUID
            public let slug: String
            public let ad: String
            public let tanim: String
            public let ders: String
            public let konu: String?
            public let dogrulama: String?
            public let uyari: String?
            public let kaynakDuzeltmesi: String?
            public let altKonu: String?
            public let kartlar: [PackCard]

            /// The book page this concept came from — a reference, not a
            /// quantity, and the pack writes it both ways: 741 of its 831
            /// concepts as a string ("242-243", "243") and 90 as a bare JSON
            /// number (448). Decoding it as `String` alone throws on the first
            /// numeric one, which fails the *whole* file rather than one
            /// concept, because a `JSONDecoder` gives up at the first mismatch.
            ///
            /// Found by running the importer against the real 3.017-card pack;
            /// it would have aborted at concept 559 with a type-mismatch and
            /// nothing else in the file would have been imported.
            private let kitapSayfa: LooseString?

            /// Always a string by the time anything here reads it.
            public var pageReference: String? { kitapSayfa?.value }
        }

        /// A JSON value that is semantically a label but is written sometimes
        /// quoted and sometimes not. Numbers are rendered back to their
        /// printed form; nothing downstream does arithmetic on a page number.
        struct LooseString: Decodable, Equatable, Sendable {
            let value: String

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    value = text
                } else if let whole = try? container.decode(Int.self) {
                    value = String(whole)
                } else {
                    throw DecodingError.typeMismatch(
                        String.self,
                        .init(
                            codingPath: container.codingPath,
                            debugDescription: "Expected a string or a number."
                        )
                    )
                }
            }
        }

        public struct PackCard: Decodable, Equatable, Sendable {
            public let id: UUID
            public let type: String
            public let front: String
            public let back: String
            public let explanation: String?
        }
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case unreadable(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Dosya bir kavram paketi gibi görünmüyor."
            case .unsupportedVersion(let version):
                return "Bu paket daha yeni bir sürümle üretilmiş (biçim \(version)). "
                    + "Uygulamayı güncelleyip tekrar dene."
            }
        }
    }

    /// The highest pack format this build understands.
    public static let formatVersion = 1

    /// Marks every unit this importer creates, so an imported concept is
    /// identifiable from its tags alone — including inside a backup, which
    /// carries tags but not the pack.
    public static let tag = "kavram-paketi"

    public static func decode(_ data: Data) throws -> Pack {
        let pack: Pack
        do {
            pack = try JSONDecoder().decode(Pack.self, from: data)
        } catch {
            throw ImportError.unreadable(String(describing: error))
        }
        guard pack.formatVersion <= formatVersion else {
            throw ImportError.unsupportedVersion(pack.formatVersion)
        }
        return pack
    }

    // MARK: - Planning

    /// A concept reduced to the cards this device does not already have.
    public struct PlannedConcept: Equatable, Sendable {
        public let concept: Pack.Concept
        public let cards: [Pack.PackCard]
    }

    public struct Plan: Equatable, Sendable {
        public let concepts: [PlannedConcept]
        /// Cards already in the store, left exactly as they are.
        public let skipped: [UUID]

        public var cardCount: Int { concepts.reduce(0) { $0 + $1.cards.count } }
        public var isEmpty: Bool { concepts.isEmpty }
    }

    /// Additive, exactly like `BackupRestorer.plan` and for the same reason: a
    /// card already here has review history the file cannot know about, and
    /// overwriting would roll it back. Because pack ids are `uuid5`-derived and
    /// therefore stable across regenerations, this is also what makes importing
    /// the same file twice a no-op instead of a duplicate deck.
    ///
    /// Skipping is decided per *card*, not per concept: a pack that gains a
    /// card in a later revision should import that one card into the concept
    /// that already exists, which is why `insert` binds to an existing unit
    /// when it finds one.
    public static func plan(pack: Pack, existingCardIds: Set<UUID>) -> Plan {
        var seen = existingCardIds
        var concepts: [PlannedConcept] = []
        var skipped: [UUID] = []

        for concept in pack.kavramlar {
            var fresh: [Pack.PackCard] = []
            for card in concept.kartlar {
                if seen.contains(card.id) {
                    skipped.append(card.id)
                    continue
                }
                // Guards against a malformed file repeating an id inside
                // itself, which would otherwise violate `@Attribute(.unique)`.
                seen.insert(card.id)
                fresh.append(card)
            }
            if !fresh.isEmpty {
                concepts.append(PlannedConcept(concept: concept, cards: fresh))
            }
        }
        return Plan(concepts: concepts, skipped: skipped)
    }

    // MARK: - Writing

    public struct Summary: Equatable, Sendable {
        public let insertedCards: Int
        public let insertedConcepts: Int
        public let skippedCards: Int

        public init(insertedCards: Int, insertedConcepts: Int, skippedCards: Int) {
            self.insertedCards = insertedCards
            self.insertedConcepts = insertedConcepts
            self.skippedCards = skippedCards
        }
    }

    /// Writes one concept and its cards.
    ///
    /// All of the concept's cards hang off a single `KnowledgeUnit` — that is
    /// the whole reason this format exists — and the unit has no `region`. The
    /// chain from `Card` up to `CapturedPage` is optional precisely so a card
    /// can exist without a photographed page; inventing a placeholder page here
    /// would put a lie in front of "Kaynağı göster".
    ///
    /// Never saves: the caller owns the transaction, so a failure rolls back a
    /// whole batch rather than leaving a half-written concept behind.
    @discardableResult
    public static func insert(
        _ planned: PlannedConcept,
        into context: ModelContext,
        existingUnit: KnowledgeUnit? = nil,
        schema: SubjectTopicSchema? = SubjectTopicSchema.shared,
        now: Date = .now
    ) -> Int {
        let concept = planned.concept

        // Normalised the same way a restored card is (`SubjectBackfill` /
        // `TopicGrouping`), so an imported card lands inside the same pickers,
        // filters and Bilgi Haritası buckets as a photographed one. The pack is
        // already remapped to the canonical schema, which makes this a no-op
        // today — and the guard that keeps it one if the pack ever drifts.
        let subject = schema?.canonicalSubject(matching: concept.ders) ?? concept.ders
        let topic = TopicGrouping.validatedTopic(concept.konu, subject: subject, schema: schema)

        // The unit may already exist: a re-import that carries new cards for a
        // concept already here must extend it, not fork a second copy that
        // would split the concept across two rows in every grouped view. The
        // caller looks it up — `run` does so once for the whole pack rather
        // than issuing a fetch per concept.
        let unit: KnowledgeUnit
        if let existingUnit {
            unit = existingUnit
        } else {
            unit = KnowledgeUnit(
                id: concept.id,
                canonicalClaim: concept.tanim,
                subject: subject,
                topic: topic,
                // `slug` first so a card can be traced back to its source file;
                // `altKonu` carries the finer heading the pack was remapped
                // away from, which is otherwise unrecoverable.
                tags: [concept.slug, tag] + (concept.altKonu.map { [$0] } ?? []),
                // "korpus" means the concept was reconstructed rather than read
                // off the source, which is exactly what this flag records.
                sourceFaithful: concept.dogrulama != "korpus",
                sourceConcern: sourceConcern(for: concept),
                createdAt: now
            )
            context.insert(unit)
        }

        for packCard in planned.cards {
            let card = Card(
                id: packCard.id,
                // An unrecognised type reads as `direct_recall` rather than
                // failing the import: `CardType` is locked to the backend
                // schema (`test_swift_contract_sync.py`), so a pack written
                // against a newer one must degrade, not refuse. The pack
                // already does this for `sirali_coklu` and keeps the original
                // name in its own `originalType`.
                type: CardType(rawValue: packCard.type) ?? .directRecall,
                front: packCard.front,
                back: packCard.back,
                explanation: packCard.explanation,
                // The book page, so "Kaynağı göster" has something true to say
                // about a card with no photograph behind it.
                sourceQuote: concept.pageReference,
                // Queued, not active: a pack is thousands of cards and letting
                // them all in at once would make every one of them due on day
                // one — a backlog FSRS cannot drain and the owner abandons.
                // `ConceptRelease` is the only way out, driven by a button he
                // presses on the days he wants cards (2026-09-10). Capture
                // cards are unaffected; nothing else in the app writes this
                // status.
                status: .queued,
                createdAt: now,
                // Meaningless while queued and overwritten at release, so that
                // a pack imported today and released in three months does not
                // arrive three months overdue.
                dueDate: now,
                // Flagged into Bilgilerim's "Gözden geçir" for the same reason
                // `sourceFaithful` is false: nobody has checked these against
                // the page they claim to come from.
                lowConfidence: concept.dogrulama == "korpus",
                collection: .concept
            )
            card.knowledgeUnit = unit
            context.insert(card)
        }
        return planned.cards.count
    }

    /// Both of the pack's caveat fields, kept rather than one of them: they say
    /// different things (`uyari` warns about the content, `kaynakDuzeltmesi`
    /// records a correction made to the source) and the card detail has exactly
    /// one place to show either.
    static func sourceConcern(for concept: Pack.Concept) -> String? {
        let parts = [concept.uyari, concept.kaynakDuzeltmesi]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Runs a plan in batches, saving each batch and yielding between them.
    ///
    /// One transaction for 3.017 cards blocks the main thread long enough to
    /// look like a hang, and fails all-or-nothing. Batching bounds both: a
    /// batch that throws rolls back only itself, and the summary reports what
    /// actually landed rather than claiming the whole file.
    @MainActor
    public static func run(
        plan: Plan,
        into context: ModelContext,
        batchSize: Int = 50,
        schema: SubjectTopicSchema? = SubjectTopicSchema.shared,
        now: Date = .now,
        progress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> Summary {
        var insertedCards = 0
        var insertedConcepts = 0
        var pending = 0
        let total = plan.cardCount

        // One fetch for the whole run. The alternative — a predicate per
        // concept — is 831 round trips on this pack, all of them misses on the
        // ordinary first import.
        let planned = Set(plan.concepts.map(\.concept.id))
        let existingUnits = Dictionary(
            ((try? context.fetch(FetchDescriptor<KnowledgeUnit>())) ?? [])
                .filter { planned.contains($0.id) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for planned in plan.concepts {
            insertedCards += insert(
                planned,
                into: context,
                existingUnit: existingUnits[planned.concept.id],
                schema: schema,
                now: now
            )
            insertedConcepts += 1
            pending += planned.cards.count

            if pending >= batchSize {
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
                pending = 0
                progress(insertedCards, total)
                await Task.yield()
            }
        }

        if pending > 0 {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            progress(insertedCards, total)
        }

        return Summary(
            insertedCards: insertedCards,
            insertedConcepts: insertedConcepts,
            skippedCards: plan.skipped.count
        )
    }
}
