import Foundation
import SwiftData

/// Builds the chain a restored card's photo is found through (backup version
/// 9, docs/ADR-011):
///
///     CapturedPage(.ready) → TextRegion (whole page, .manual) → KnowledgeUnit → Card
///
/// It is the shape `ProcessingQueue.persist` leaves behind — one page, one
/// full-page region, units hanging off that region — so "Kaynağı göster", the
/// full-screen viewer and the page detail need no change to show a restored
/// card's photograph: they already walk `card.knowledgeUnit.region.page`.
///
/// Every decision about *which* pages and cards is `BackupRestorer.plan`'s.
/// This only carries it out, in two halves that run on different actors
/// (Codex, PR #50):
///
/// 1. `writeImages` — the disk and CPU work: every planned page's JPEG to the
///    image store, and its perceptual hash. Touches no `ModelContext`, so a
///    restore of many photos runs it off the main actor instead of freezing
///    the screen.
/// 2. `install` — the store work: `CapturedPage`, region and `Source` inserts,
///    on the context the restore saves. Inserts without saving: the restore
///    owns the one `save()` and the rollback around it.
public enum BackupPageInstaller {

    /// One page image already on disk.
    public struct WrittenImage: Sendable, Equatable {
        /// Relative image-store path, as `CapturedPage.originalImagePath`.
        public let path: String
        public let perceptualHash: String?

        public init(path: String, perceptualHash: String?) {
            self.path = path
            self.perceptualHash = perceptualHash
        }
    }

    /// Writes each planned page's image and computes its hash. Keyed by page id.
    ///
    /// If a write throws half-way, the images written before it are removed
    /// before the error leaves: the caller never sees those paths.
    ///
    /// The bytes are written exactly as the file carried them — no resizing or
    /// re-compression. This image is shown, not sent to the model.
    ///
    /// - Parameter hash: the perceptual hash to record for a page's image, or
    ///   `nil` to record none. A closure because the hasher lives with the
    ///   capture screen; recording one is what lets a *later* camera capture
    ///   of the same page be recognised and asked about.
    public static func writeImages(
        for plan: RestorePlan,
        imageStore: ImageStore,
        hash: (@Sendable (Data) -> String?)? = nil
    ) throws -> [UUID: WrittenImage] {
        var written: [UUID: WrittenImage] = [:]
        do {
            for record in plan.pagesToInsert {
                let path = try imageStore.store(record.jpegData, id: record.id, kind: .original, fileExtension: "jpg")
                written[record.id] = WrittenImage(path: path, perceptualHash: hash?(record.jpegData))
            }
        } catch {
            discard(written.values.map(\.path), imageStore: imageStore)
            throw error
        }
        return written
    }

    /// Inserts each planned page's `CapturedPage` and region, and finds the
    /// region of each linked page the device already has. Returns page id →
    /// the region cards linked to that page attach to, new and existing alike.
    ///
    /// The page is born `.ready`, which is the one state `ProcessingQueue`
    /// never selects (`shouldProcess`): a restored page must never reach
    /// `POST /api/jobs`. That would pay to regenerate cards the file already
    /// holds, and put a second set next to them.
    ///
    /// A planned page with no entry in `images` is skipped — its cards then go
    /// in without a photo — rather than recorded with a path nothing was
    /// written to.
    public static func install(
        _ plan: RestorePlan,
        images: [UUID: WrittenImage],
        context: ModelContext,
        schema: SubjectTopicSchema?
    ) throws -> [UUID: TextRegion] {
        var regions: [UUID: TextRegion] = [:]
        var sources: [String: Source] = [:]

        for record in plan.pagesToInsert {
            guard let image = images[record.id] else { continue }
            let page = CapturedPage(
                id: record.id,
                originalImagePath: image.path,
                captureDate: record.captureDate,
                state: .ready
            )
            page.pageNumber = nonEmpty(record.pageLabel)
            page.perceptualHash = image.perceptualHash
            if let subject = pageSubject(record.subject, schema: schema) {
                if let cached = sources[subject] {
                    page.source = cached
                } else {
                    let source = try SourceBinding.existingOrNew(subject: subject, context: context)
                    sources[subject] = source
                    page.source = source
                }
            }
            context.insert(page)
            regions[record.id] = makeRegion(on: page, readText: record.readText, context: context)
        }

        let planned = Set(plan.pagesToInsert.map(\.id))
        let existingIds = Array(Set(plan.pageLinks.values).subtracting(planned))
        if !existingIds.isEmpty {
            let descriptor = FetchDescriptor<CapturedPage>(
                predicate: #Predicate { existingIds.contains($0.id) }
            )
            for page in try context.fetch(descriptor) {
                // The region an earlier restore of the same file built. The
                // image is not rewritten: the page already has one.
                regions[page.id] = page.regions.first
                    ?? makeRegion(on: page, readText: nil, context: context)
            }
        }
        return regions
    }

    /// Removes the images `writeImages` wrote, after the restore that should
    /// have recorded them failed — otherwise a half restore leaves JPEGs on disk
    /// that no page points at and nothing will ever delete.
    ///
    /// Best effort by nature: this runs on the way out of a failure that is
    /// already being reported, and a file that will not delete is left where
    /// it is rather than replacing that error with a lesser one.
    public static func discard(_ paths: [String], imageStore: ImageStore) {
        for path in paths {
            try? imageStore.remove(relativePath: path)
        }
    }

    /// The unit a restored card hangs off on `region`.
    ///
    /// Shared the way `persist` shares units — cards from one page with the same
    /// ders/konu sit on one unit — but matched on the record's *whole* unit
    /// payload, tags included. `KnowledgeUnitBinding.findOrCreate` ignores tags
    /// on a match, which is right for moving one card between classifications
    /// and wrong here: two records with different tags would restore with one
    /// of them silently gone.
    public static func unit(
        on region: TextRegion,
        subject: String?,
        topic: String?,
        claim: String,
        tags: [String],
        createdAt: Date,
        context: ModelContext
    ) -> KnowledgeUnit {
        if let existing = region.knowledgeUnits.first(where: {
            $0.subject == subject && $0.topic == topic && $0.canonicalClaim == claim && $0.tags == tags
        }) {
            return existing
        }
        let unit = KnowledgeUnit(
            canonicalClaim: claim,
            subject: subject,
            topic: topic,
            tags: tags,
            createdAt: createdAt
        )
        unit.region = region
        context.insert(unit)
        return unit
    }

    /// The same shape `ManualCardSheet` gives a page it has to add a region to:
    /// the whole page, marked `.manual`. The difference is that here there is a
    /// reading to carry.
    private static func makeRegion(on page: CapturedPage, readText: String?, context: ModelContext) -> TextRegion {
        let text = readText ?? ""
        let region = TextRegion(
            boundingBox: (0, 0, 1, 1),
            lineIds: [],
            finalText: text,
            contextText: text,
            confidence: 1,
            selectionType: .manual
        )
        region.page = page
        context.insert(region)
        return region
    }

    /// Canonical when the template knows the name, so "Kart ekle" locks the
    /// same ders a captured page would; the trimmed original otherwise, since a
    /// label nobody recognises is still better kept than invented away.
    private static func pageSubject(_ raw: String?, schema: SubjectTopicSchema?) -> String? {
        guard let trimmed = nonEmpty(raw) else { return nil }
        return schema?.canonicalSubject(matching: trimmed) ?? trimmed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// The one `Source` per ders (2026-09-14, lifted out of `ProcessingQueue`).
///
/// A capture and a restore both hang a page off its subject's `Source`, and
/// creating one per page would fill the store with copies of the same book.
public enum SourceBinding {
    public static func existingOrNew(subject: String, context: ModelContext) throws -> Source {
        var descriptor = FetchDescriptor<Source>(
            predicate: #Predicate { $0.subject == subject }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let source = Source(title: subject, subject: subject)
        context.insert(source)
        return source
    }
}
