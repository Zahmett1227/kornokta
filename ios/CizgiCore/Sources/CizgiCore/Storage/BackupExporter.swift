import Foundation

/// A stable, versioned and provider-neutral backup format (ANA-PLAN §24.6).
/// Images are intentionally excluded: the JSON contains the learning data and
/// source quotations, while original copyrighted pages remain on the device.
///
/// ### Version 2
///
/// Version 1 could only be written. There was no decoder, `Document` was
/// private, and the record dropped almost everything that made a card worth
/// keeping — tags, when it was made, and the entire review history. A file you
/// cannot restore is an export, not a backup, and this deck lives on exactly one
/// device.
///
/// The review log matters twice over: it is the only record of how this user's
/// memory actually behaved, and it is the input FSRS weight optimisation needs
/// (docs/FAZ4-PLAN.md). Leaving it out meant that data could never leave the
/// phone and would vanish with it.
///
/// Version 1 files still decode. Every field added since is optional with a
/// defined fallback, so an old backup restores as the subset it always was
/// rather than failing.
public enum BackupExporter {
    /// 3 adds a card's five options (§13.3); 4 adds its topic (schema v2.2).
    /// Older files still restore: every field added after version 1 is decoded
    /// with `decodeIfPresent`.
    public static let formatVersion = 5

    /// One graded review, as recorded at the time (§16.7).
    public struct ReviewRecord: Codable, Sendable, Equatable {
        public let reviewedAt: Date
        public let rating: String
        public let responseTimeMs: Int
        public let scheduledDays: Double
        public let elapsedDays: Double
        public let stabilityBefore: Double
        public let stabilityAfter: Double
        public let difficultyBefore: Double
        public let difficultyAfter: Double
        public let deviceTimeZone: String

        public init(
            reviewedAt: Date,
            rating: String,
            responseTimeMs: Int,
            scheduledDays: Double,
            elapsedDays: Double,
            stabilityBefore: Double,
            stabilityAfter: Double,
            difficultyBefore: Double,
            difficultyAfter: Double,
            deviceTimeZone: String
        ) {
            self.reviewedAt = reviewedAt
            self.rating = rating
            self.responseTimeMs = responseTimeMs
            self.scheduledDays = scheduledDays
            self.elapsedDays = elapsedDays
            self.stabilityBefore = stabilityBefore
            self.stabilityAfter = stabilityAfter
            self.difficultyBefore = difficultyBefore
            self.difficultyAfter = difficultyAfter
            self.deviceTimeZone = deviceTimeZone
        }
    }

    public struct CardRecord: Codable, Sendable, Equatable {
        public let id: UUID
        public let type: String
        public let front: String
        public let back: String
        public let explanation: String?
        public let sourceQuote: String?
        public let subject: String?
        public let status: String
        public let dueDate: Date
        public let stability: Double
        public let difficulty: Double
        public let reviewCount: Int
        public let lapseCount: Int
        // --- added in version 2 ---
        public let createdAt: Date
        public let updatedAt: Date
        public let lastReviewedAt: Date?
        public let tags: [String]
        /// What the model reported reading off the page this card came from.
        /// The nearest thing to provenance that survives without the image.
        public let canonicalClaim: String?
        public let reviews: [ReviewRecord]
        // --- added in version 3 ---
        /// Five options for a `multiple_choice` card, `nil` otherwise (§13.3).
        /// Part of the card, so a backup without them would restore a question
        /// with no answers to choose from.
        public let options: [CardOption]?
        /// Whether the card is waiting to be looked at (§13.3 rule 6). Restoring
        /// without it would quietly launder a flagged card into a clean one.
        public let lowConfidence: Bool
        // --- added in version 4 ---
        /// The card's konu (schema v2.2). Exported alongside `subject` because
        /// without it every restored card falls into the "Konusuz" bucket and
        /// the topic filters no longer reproduce the deck that was backed up.
        public let topic: String?
        // --- added in version 5 ---
        /// Early practice misses (docs/ADR-007). Scheduling state like
        /// `lapseCount`, so it travels with the card.
        public let softLapseCount: Int
        /// When Egzersiz last touched FSRS state (docs/ADR-007) — restoring
        /// without it would disarm the one-day practice freeze.
        public let lastPracticedAt: Date?

        public init(
            id: UUID,
            type: String,
            front: String,
            back: String,
            explanation: String?,
            sourceQuote: String?,
            subject: String?,
            status: String,
            dueDate: Date,
            stability: Double,
            difficulty: Double,
            reviewCount: Int,
            lapseCount: Int,
            createdAt: Date = .distantPast,
            updatedAt: Date = .distantPast,
            lastReviewedAt: Date? = nil,
            tags: [String] = [],
            canonicalClaim: String? = nil,
            reviews: [ReviewRecord] = [],
            options: [CardOption]? = nil,
            lowConfidence: Bool = false,
            topic: String? = nil,
            softLapseCount: Int = 0,
            lastPracticedAt: Date? = nil
        ) {
            self.id = id
            self.type = type
            self.front = front
            self.back = back
            self.explanation = explanation
            self.sourceQuote = sourceQuote
            self.subject = subject
            self.status = status
            self.dueDate = dueDate
            self.stability = stability
            self.difficulty = difficulty
            self.reviewCount = reviewCount
            self.lapseCount = lapseCount
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.lastReviewedAt = lastReviewedAt
            self.tags = tags
            self.canonicalClaim = canonicalClaim
            self.reviews = reviews
            self.options = options
            self.lowConfidence = lowConfidence
            self.topic = topic
            self.softLapseCount = softLapseCount
            self.lastPracticedAt = lastPracticedAt
        }

        /// Decoded field by field so a version 1 file — which has none of the
        /// keys below `lapseCount` — restores as the subset it always was
        /// instead of failing outright.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            type = try values.decode(String.self, forKey: .type)
            front = try values.decode(String.self, forKey: .front)
            back = try values.decode(String.self, forKey: .back)
            explanation = try values.decodeIfPresent(String.self, forKey: .explanation)
            sourceQuote = try values.decodeIfPresent(String.self, forKey: .sourceQuote)
            subject = try values.decodeIfPresent(String.self, forKey: .subject)
            status = try values.decode(String.self, forKey: .status)
            dueDate = try values.decode(Date.self, forKey: .dueDate)
            stability = try values.decode(Double.self, forKey: .stability)
            difficulty = try values.decode(Double.self, forKey: .difficulty)
            reviewCount = try values.decode(Int.self, forKey: .reviewCount)
            lapseCount = try values.decode(Int.self, forKey: .lapseCount)
            createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
            updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
            lastReviewedAt = try values.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
            tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
            canonicalClaim = try values.decodeIfPresent(String.self, forKey: .canonicalClaim)
            reviews = try values.decodeIfPresent([ReviewRecord].self, forKey: .reviews) ?? []
            options = try values.decodeIfPresent([CardOption].self, forKey: .options)
            lowConfidence = try values.decodeIfPresent(Bool.self, forKey: .lowConfidence) ?? false
            topic = try values.decodeIfPresent(String.self, forKey: .topic)
            softLapseCount = try values.decodeIfPresent(Int.self, forKey: .softLapseCount) ?? 0
            lastPracticedAt = try values.decodeIfPresent(Date.self, forKey: .lastPracticedAt)
        }
    }

    /// A decoded backup file.
    public struct Backup: Sendable, Equatable {
        public let formatVersion: Int
        public let exportedAt: Date
        public let cards: [CardRecord]

        public init(formatVersion: Int, exportedAt: Date, cards: [CardRecord]) {
            self.formatVersion = formatVersion
            self.exportedAt = exportedAt
            self.cards = cards
        }
    }

    private struct Document: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let cards: [CardRecord]
    }

    public enum BackupError: Error, Equatable, LocalizedError {
        case unreadable(String)
        /// Written by a newer build than this one.
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Dosya bir Çizgi yedeği gibi görünmüyor."
            case .unsupportedVersion(let version):
                return "Bu yedek daha yeni bir sürümle alınmış (biçim \(version)). "
                    + "Uygulamayı güncelleyip tekrar dene."
            }
        }
    }

    public static func encode(cards: [CardRecord], exportedAt: Date = .now) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(
            formatVersion: formatVersion,
            exportedAt: exportedAt,
            cards: cards.sorted { $0.id.uuidString < $1.id.uuidString }
        ))
    }

    public static func decode(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw BackupError.unreadable(String(describing: error))
        }
        // A file from a future version may hold fields this build would drop on
        // the floor; refusing is better than restoring a lossy copy of it.
        guard document.formatVersion <= formatVersion else {
            throw BackupError.unsupportedVersion(document.formatVersion)
        }
        return Backup(
            formatVersion: document.formatVersion,
            exportedAt: document.exportedAt,
            cards: document.cards
        )
    }
}

/// What a restore would do, decided before anything is written.
public struct RestorePlan: Equatable, Sendable {
    public let toInsert: [BackupExporter.CardRecord]
    /// Cards the store already has, left exactly as they are.
    public let skipped: [UUID]

    public var isEmpty: Bool { toInsert.isEmpty }

    public init(toInsert: [BackupExporter.CardRecord], skipped: [UUID]) {
        self.toInsert = toInsert
        self.skipped = skipped
    }
}

public enum BackupRestorer {

    /// Additive by design: a card already in the store is skipped, never
    /// overwritten.
    ///
    /// The realistic restore is onto a device that has been used since the
    /// backup was taken — a reinstall, a second phone, a file kept "just in
    /// case". Overwriting would silently roll back review history the file
    /// predates, and losing a week of scheduling to a restore that was meant to
    /// *prevent* loss is the worst possible outcome. Skipping can only ever
    /// leave the user with what they already had.
    ///
    /// Duplicate ids within one file collapse to the first occurrence rather
    /// than throwing: this is an untrusted file, and a malformed one should
    /// restore what it can.
    public static func plan(
        records: [BackupExporter.CardRecord],
        existingIds: Set<UUID>
    ) -> RestorePlan {
        var seen = existingIds
        var toInsert: [BackupExporter.CardRecord] = []
        var skipped: [UUID] = []

        for record in records {
            if seen.contains(record.id) {
                skipped.append(record.id)
                continue
            }
            seen.insert(record.id)
            toInsert.append(record)
        }
        return RestorePlan(toInsert: toInsert, skipped: skipped)
    }
}
