#if os(iOS)
import SwiftUI
import PhotosUI
import CizgiCore

/// Bringing pages in from the photo library (docs/PLAN-galeriden-foto.md).
///
/// `PhotosPicker` runs out of process: the app never gets access to the
/// library, only to the items the user hands it. So there is no permission
/// prompt and nothing to ask for — a better privacy position than the old
/// `UIImagePickerController`, and the reason `NSPhotoLibraryUsageDescription`
/// is not needed for this flow.
///
/// Everything this type does is turn picked items into the same bytes the
/// document scanner produces. The queue, the duplicate question, the job queue
/// and the retry loop are then inherited unchanged — which is what makes the
/// feature small.
@MainActor
final class PhotoLibraryImporter: ObservableObject {
    struct Result {
        /// Normalised JPEGs, ready for `ProcessingQueue.enqueue`.
        let images: [Data]
        /// How many picked items could not be read or converted.
        let failedCount: Int
    }

    /// The cap is about money, not about the queue: ten pages is ten
    /// generations. The queue itself would happily take more.
    static let selectionLimit = 10

    @Published private(set) var isLoading = false
    @Published private(set) var loadedCount = 0
    @Published private(set) var totalCount = 0

    /// Loads and normalises the picked items.
    ///
    /// One bad item never costs the others: a photo that will not download from
    /// iCloud, or bytes no decoder accepts, is counted and skipped (§21.2 —
    /// a capture is not lost silently, and the caller reports the count).
    func load(_ items: [PhotosPickerItem]) async -> Result {
        guard !items.isEmpty else { return Result(images: [], failedCount: 0) }

        isLoading = true
        totalCount = items.count
        loadedCount = 0
        defer {
            isLoading = false
            totalCount = 0
            loadedCount = 0
        }

        var images: [Data] = []
        var failed = 0
        // Sequential on purpose: an item that lives in iCloud is downloaded
        // here, and starting ten downloads at once makes every one of them
        // slower while the progress figure stops meaning anything.
        for item in items {
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else {
                    failed += 1
                    continue
                }
                // The single conversion point. After this the rest of the app
                // cannot tell an import from a capture.
                images.append(try ImportedImage.normalize(raw).data)
            } catch {
                failed += 1
            }
            loadedCount += 1
        }
        return Result(images: images, failedCount: failed)
    }
}
#endif
