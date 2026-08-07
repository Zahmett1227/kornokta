import Foundation

/// On-disk storage for captured pages (ANA-PLAN §8.3).
///
/// Writes are atomic and the shutter's success feedback must wait for the write
/// to return: §24.1 forbids showing a capture as saved before it is actually on
/// disk. Paths are stored relative to `root` because the container path changes
/// between installs.
public struct ImageStore: Sendable {
    public enum StoreError: Error, Sendable {
        case writeFailed(String)
        case notFound(String)
    }

    public let root: URL
    /// `FileManager` is not `Sendable`, which makes storing one in a `Sendable`
    /// struct a warning today and an error under the Swift 6 language mode.
    ///
    /// Kept (rather than reaching for `.default` at each call site) because the
    /// injection seam is what lets a test point a store at a scratch directory.
    /// `nonisolated(unsafe)` is the honest annotation for it: the only
    /// operations used here — `createDirectory`, `fileExists`, `removeItem`,
    /// `url(for:in:)` — are documented as safe to call concurrently on a single
    /// instance, and `FileManager.default` is shared process-wide anyway.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Default location: Application Support, excluded from iCloud backup is
    /// *not* set — the user's captures are theirs to keep.
    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Cizgi/Captures", isDirectory: true)
    }

    public func url(forRelativePath path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// Stores `data` and returns the relative path to record on the model.
    @discardableResult
    public func store(_ data: Data, id: UUID, kind: Kind = .original, fileExtension: String = "jpg") throws -> String {
        let relative = Self.relativePath(id: id, kind: kind, fileExtension: fileExtension)
        let destination = url(forRelativePath: relative)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            // .atomic so a crash mid-write cannot leave a truncated image that
            // later reads as a corrupt capture.
            try data.write(to: destination, options: .atomic)
        } catch {
            throw StoreError.writeFailed(String(describing: error))
        }
        return relative
    }

    public func load(relativePath: String) throws -> Data {
        let source = url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: source.path) else {
            throw StoreError.notFound(relativePath)
        }
        return try Data(contentsOf: source)
    }

    public func exists(relativePath: String) -> Bool {
        fileManager.fileExists(atPath: url(forRelativePath: relativePath).path)
    }

    /// Removes a stored image. Used when the user deletes a capture, and by the
    /// retention setting that drops full pages once cards are ready (§22).
    public func remove(relativePath: String) throws {
        let target = url(forRelativePath: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    public enum Kind: String, Sendable {
        case original
        case processed
        case crop
    }

    static func relativePath(id: UUID, kind: Kind, fileExtension: String) -> String {
        // Shard by the first two characters so one directory does not collect
        // thousands of files.
        let name = id.uuidString
        let shard = String(name.prefix(2))
        return "\(shard)/\(name)-\(kind.rawValue).\(fileExtension)"
    }
}
