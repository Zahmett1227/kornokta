import Foundation

/// A stable, versioned and provider-neutral backup format (ANA-PLAN §24.6).
/// Exports never carry images: the JSON the app writes contains the learning
/// data and source quotations, while original copyrighted pages remain on the
/// device. A version 9 file *may* carry page photographs, and restore honours
/// them — see `PageRecord` and docs/ADR-011.
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
    /// 3 adds a card's five options (§13.3); 4 adds its topic (schema v2.2);
    /// 6 adds the FES record (docs/ADR-008); 7 added the card's collection,
    /// and 8 takes it away again with the concept deck (2026-09-14). 9 adds
    /// optional page photographs and a card's `pageId` (docs/ADR-011).
    ///
    /// Older files still restore: every field added after version 1 is decoded
    /// with `decodeIfPresent`, and a v7 file's `collection` key is simply not
    /// read. Its concept cards are recognised by their tag instead and left out
    /// — `BackupRestorer.plan` counts them so the restore can say so.
    public static let formatVersion = 9

    /// A photographed page, carried so a restored card's "Kaynağı göster" can
    /// show the photo and not only the text (version 9, docs/ADR-011).
    ///
    /// Only ever *read* by this build: `encode` is given none from Ayarlar →
    /// "Yedeği hazırla", so a backup the app writes stays image-free. The files
    /// that carry pages are written outside the app — cards made by reading the
    /// page photos directly — and restore is the only door those cards have.
    ///
    /// The bytes are decoded once, here, rather than kept as base64: a restore
    /// needs them twice (the plan asks "is this usable?", the install writes
    /// them), and a page's image is the largest thing in the file.
    public struct PageRecord: Codable, Sendable, Equatable {
        public let id: UUID
        /// The JPEG as written to the file. Empty when the file's base64 was
        /// empty or would not decode — such a page is kept in the backup value
        /// (it *is* in the file) but `hasUsableImage` is false and restore
        /// treats every card pointing at it as having no photo.
        public let jpegData: Data
        public let captureDate: Date
        /// Becomes the page's `Source` — what locks the ders in "Kart ekle".
        public let subject: String?
        /// What was read off the page; the region's `finalText`, printed above
        /// the cards in the page detail.
        public let readText: String?
        /// A human label ("FA Mikrobiyoloji s.126"); `CapturedPage.pageNumber`.
        public let pageLabel: String?

        public init(
            id: UUID,
            jpegData: Data,
            captureDate: Date,
            subject: String? = nil,
            readText: String? = nil,
            pageLabel: String? = nil
        ) {
            self.id = id
            self.jpegData = jpegData
            self.captureDate = captureDate
            self.subject = subject
            self.readText = readText
            self.pageLabel = pageLabel
        }

        /// A whole JPEG: its segments run from start to end-of-image and
        /// ImageIO reads it as a JPEG with real dimensions (`JPEGIntegrity`).
        ///
        /// Not just "base64 decoded", and not just "starts with `FF D8 FF`":
        /// the image is stored as `-original.jpg` and later sent as a JPEG by
        /// "İkinci görüş" and "Kapsama denetle", and a field cut off half-way
        /// keeps its first bytes. Without the full check such a page would be
        /// counted as restored with a photo and then show a broken one (Codex,
        /// PR #50) — instead of the card going in photoless and being counted.
        public var hasUsableImage: Bool {
            JPEGIntegrity.isComplete(jpegData)
        }

        enum CodingKeys: String, CodingKey {
            case id, jpegBase64, captureDate, subject, readText, pageLabel
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            // Content, not shape, is what is forgiven here: a present-but-bad
            // image drops that one page's photo, never the whole restore.
            // `.ignoreUnknownCharacters` lets line-wrapped base64 through.
            let base64 = try values.decode(String.self, forKey: .jpegBase64)
            jpegData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
            captureDate = try values.decode(Date.self, forKey: .captureDate)
            subject = try values.decodeIfPresent(String.self, forKey: .subject)
            readText = try values.decodeIfPresent(String.self, forKey: .readText)
            pageLabel = try values.decodeIfPresent(String.self, forKey: .pageLabel)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(jpegData.base64EncodedString(), forKey: .jpegBase64)
            try values.encode(captureDate, forKey: .captureDate)
            try values.encodeIfPresent(subject, forKey: .subject)
            try values.encodeIfPresent(readText, forKey: .readText)
            try values.encodeIfPresent(pageLabel, forKey: .pageLabel)
        }
    }

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
        // --- added in version 6 ---
        /// FES sicili (docs/ADR-008), exported as already-finalized.
        /// `fesInitializedAt` non-nil tells `FesBackfillMigration` not to
        /// replay this card's history again on the receiving device — which
        /// matters because `ExerciseAttempt` never travels in a backup (see
        /// `ExerciseRun`), so a replay after restore would silently drop
        /// every Egzersiz-sourced signal the original score included and
        /// only see the restored `ReviewLog` half of the picture.
        public let fesScore: Int
        public let fesNegativeCount: Int
        public let fesInitializedAt: Date?
        // Version 7's `collection` field was removed in version 8 with the
        // concept deck. A v7 file still carries the key; nothing reads it.
        // --- added in version 9 ---
        /// The `PageRecord` this card was read from, if the file carries one.
        /// `nil` is never written (the synthesized encoder skips it), so a
        /// card without a page encodes exactly as it did in version 8.
        public let pageId: UUID?

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
            lastPracticedAt: Date? = nil,
            fesScore: Int = 0,
            fesNegativeCount: Int = 0,
            fesInitializedAt: Date? = nil,
            pageId: UUID? = nil
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
            self.fesScore = fesScore
            self.fesNegativeCount = fesNegativeCount
            self.fesInitializedAt = fesInitializedAt
            self.pageId = pageId
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
            fesScore = try values.decodeIfPresent(Int.self, forKey: .fesScore) ?? 0
            fesNegativeCount = try values.decodeIfPresent(Int.self, forKey: .fesNegativeCount) ?? 0
            fesInitializedAt = try values.decodeIfPresent(Date.self, forKey: .fesInitializedAt)
            pageId = try values.decodeIfPresent(UUID.self, forKey: .pageId)
        }
    }

    /// A decoded backup file.
    public struct Backup: Sendable, Equatable {
        public let formatVersion: Int
        public let exportedAt: Date
        public let cards: [CardRecord]
        /// Empty for every file before version 9, and for every file the app
        /// itself writes.
        public let pages: [PageRecord]

        public init(formatVersion: Int, exportedAt: Date, cards: [CardRecord], pages: [PageRecord] = []) {
            self.formatVersion = formatVersion
            self.exportedAt = exportedAt
            self.cards = cards
            self.pages = pages
        }
    }

    private struct Document: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let cards: [CardRecord]
        let pages: [PageRecord]

        init(formatVersion: Int, exportedAt: Date, cards: [CardRecord], pages: [PageRecord]) {
            self.formatVersion = formatVersion
            self.exportedAt = exportedAt
            self.cards = cards
            self.pages = pages
        }

        enum CodingKeys: String, CodingKey {
            case formatVersion, exportedAt, cards, pages
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decode(Int.self, forKey: .formatVersion)
            exportedAt = try values.decode(Date.self, forKey: .exportedAt)
            cards = try values.decode([CardRecord].self, forKey: .cards)
            pages = try values.decodeIfPresent([PageRecord].self, forKey: .pages) ?? []
        }

        /// `pages` is left out entirely when there are none, so the file the
        /// app writes has the same keys a version 8 file had.
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(formatVersion, forKey: .formatVersion)
            try values.encode(exportedAt, forKey: .exportedAt)
            try values.encode(cards, forKey: .cards)
            if !pages.isEmpty {
                try values.encode(pages, forKey: .pages)
            }
        }
    }

    public enum BackupError: Error, Equatable, LocalizedError {
        case unreadable(String)
        /// Written by a newer build than this one.
        case unsupportedVersion(Int)
        /// Larger than `BackupRestorer.maxFileBytes` (version 9 files carry
        /// photos, and a restore holds every decoded page at once).
        case tooLarge(bytes: Int, limit: Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Dosya bir Çizgi yedeği gibi görünmüyor."
            case .unsupportedVersion(let version):
                return "Bu yedek daha yeni bir sürümle alınmış (biçim \(version)). "
                    + "Uygulamayı güncelleyip tekrar dene."
            case .tooLarge(let bytes, let limit):
                let megabyte = 1024 * 1024
                return "Bu yedek çok büyük (\(bytes / megabyte) MB; sınır \(limit / megabyte) MB). "
                    + "Sayfaları birkaç dosyaya bölüp ayrı ayrı geri yükle — her sayfayı "
                    + "kartlarıyla aynı dosyada tut. Geri yükleme yalnız eklediği için "
                    + "parçalar birbirini bozmaz."
            }
        }
    }

    /// `pages` exists for tests and for any future writer of version 9 files;
    /// Ayarlar → "Yedeği hazırla" passes none (docs/ADR-011).
    public static func encode(
        cards: [CardRecord],
        pages: [PageRecord] = [],
        exportedAt: Date = .now
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(
            formatVersion: formatVersion,
            exportedAt: exportedAt,
            cards: cards.sorted { $0.id.uuidString < $1.id.uuidString },
            pages: pages.sorted { $0.id.uuidString < $1.id.uuidString }
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
            cards: document.cards,
            pages: document.pages
        )
    }
}

/// What a restore would do, decided before anything is written.
public struct RestorePlan: Equatable, Sendable {
    public let toInsert: [BackupExporter.CardRecord]
    /// Cards the store already has, left exactly as they are.
    public let skipped: [UUID]
    /// Cards from the removed concept deck, found in a file written while it
    /// existed (v7). Left out on purpose and *counted* on purpose: a v7 backup
    /// holds 3.017 of them next to the photographed cards, and a restore that
    /// quietly inserted fewer records than the file contains would read as
    /// data loss.
    public let skippedLegacyConcept: [UUID]
    /// Pages to build — image, `CapturedPage` and its one full-page
    /// `TextRegion` — in file order, each once (version 9). Only pages that at
    /// least one inserted card points at and the device does not already have.
    public let pagesToInsert: [BackupExporter.PageRecord]
    /// Card id → page id, for every inserted card that will hang off a page:
    /// one planned above *or* one already on the device. The restore links by
    /// this map alone, so which cards get a photo is decided here, once.
    public let pageLinks: [UUID: UUID]
    /// Inserted cards that named a page the restore cannot give them — not in
    /// the file, or in it with an image that would not decode. They go in
    /// without a photo, exactly as a version 8 card does, and are counted so
    /// the summary can say so.
    public let cardsWithMissingPage: [UUID]

    public var isEmpty: Bool { toInsert.isEmpty }

    /// Distinct pages the inserted cards hang off, new and existing alike —
    /// what the summary means by "N sayfa fotoğrafıyla".
    public var linkedPageCount: Int { Set(pageLinks.values).count }

    public init(
        toInsert: [BackupExporter.CardRecord],
        skipped: [UUID],
        skippedLegacyConcept: [UUID] = [],
        pagesToInsert: [BackupExporter.PageRecord] = [],
        pageLinks: [UUID: UUID] = [:],
        cardsWithMissingPage: [UUID] = []
    ) {
        self.toInsert = toInsert
        self.skipped = skipped
        self.skippedLegacyConcept = skippedLegacyConcept
        self.pagesToInsert = pagesToInsert
        self.pageLinks = pageLinks
        self.cardsWithMissingPage = cardsWithMissingPage
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
    ///
    /// ### Pages (version 9)
    ///
    /// Pages follow the cards, never the other way round. A page is built only
    /// for a card that is actually going in, so a file restored a second time
    /// — every card skipped — builds nothing, and a page whose cards are all
    /// already here does not come back as an orphan with no cards under it.
    /// A page the device already has (`existingPageIds`) is not built again
    /// and its image is not rewritten; new cards pointing at it still link to
    /// it. A broken reference costs that card its photo, not the restore.
    public static func plan(
        records: [BackupExporter.CardRecord],
        pages: [BackupExporter.PageRecord] = [],
        existingIds: Set<UUID>,
        existingPageIds: Set<UUID> = []
    ) -> RestorePlan {
        var seen = existingIds
        var toInsert: [BackupExporter.CardRecord] = []
        var skipped: [UUID] = []
        var legacyConcept: [UUID] = []

        for record in records {
            // Checked before the duplicate test: a concept card is not
            // "already here", it is not wanted at all, and counting it under
            // `skipped` would tell the user it exists on the device.
            if ConceptDeckLegacy.isConcept(tags: record.tags, status: record.status) {
                legacyConcept.append(record.id)
                continue
            }
            if seen.contains(record.id) {
                skipped.append(record.id)
                continue
            }
            seen.insert(record.id)
            toInsert.append(record)
        }

        // The first *usable* record per id: a file that repeats a page with a
        // broken image first and a good one second should still get the photo.
        var usablePages: [UUID: BackupExporter.PageRecord] = [:]
        var pageOrder: [UUID] = []
        for page in pages where page.hasUsableImage && usablePages[page.id] == nil {
            usablePages[page.id] = page
            pageOrder.append(page.id)
        }

        var pageLinks: [UUID: UUID] = [:]
        var plannedPageIds = Set<UUID>()
        var missing: [UUID] = []
        for record in toInsert {
            guard let pageId = record.pageId else { continue }
            if existingPageIds.contains(pageId) {
                pageLinks[record.id] = pageId
            } else if usablePages[pageId] != nil {
                pageLinks[record.id] = pageId
                plannedPageIds.insert(pageId)
            } else {
                missing.append(record.id)
            }
        }

        return RestorePlan(
            toInsert: toInsert,
            skipped: skipped,
            skippedLegacyConcept: legacyConcept,
            pagesToInsert: pageOrder.filter(plannedPageIds.contains).compactMap { usablePages[$0] },
            pageLinks: pageLinks,
            cardsWithMissingPage: missing
        )
    }

    /// The largest backup file a restore will open: 256 MB.
    ///
    /// A version 9 file carries its pages as base64, and a restore holds every
    /// decoded page at once — `JSONDecoder` has no streaming mode, and the plan
    /// needs all of them to decide which to keep. One phone photo is roughly
    /// 3–4 MB in the file, so this is some sixty pages: past it the realistic
    /// outcome is the system ending the app mid-restore, not a slow one. Said
    /// before anything is read, with the way out (split the file — a restore
    /// only adds, so the parts cannot conflict) (Codex, PR #50).
    public static let maxFileBytes = 256 * 1024 * 1024

    /// Reads, decodes and plans a backup file. Everything here is the
    /// expensive, store-free half of a restore, so it is meant to run off the
    /// main actor; the caller passes the ids it read from the store first.
    ///
    /// The file is mapped rather than read where the system allows it, so its
    /// bytes are clean pages the system can drop instead of a second copy of
    /// the archive in the app's own memory.
    public static func plan(
        fileAt url: URL,
        existingIds: Set<UUID>,
        existingPageIds: Set<UUID>,
        maxBytes: Int = maxFileBytes
    ) throws -> RestorePlan {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw BackupExporter.BackupError.tooLarge(bytes: size, limit: maxBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxBytes else {
            throw BackupExporter.BackupError.tooLarge(bytes: data.count, limit: maxBytes)
        }
        let backup = try BackupExporter.decode(data)
        return plan(
            records: backup.cards,
            pages: backup.pages,
            existingIds: existingIds,
            existingPageIds: existingPageIds
        )
    }
}
