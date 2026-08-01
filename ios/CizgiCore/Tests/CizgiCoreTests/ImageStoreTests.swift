import XCTest
@testable import CizgiCore

final class ImageStoreTests: XCTestCase {
    var root: URL!
    var store: ImageStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cizgi-tests-\(UUID().uuidString)", isDirectory: true)
        store = try ImageStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStoredImageCanBeReadBack() throws {
        let id = UUID()
        let data = Data("jpeg-bytes".utf8)
        let path = try store.store(data, id: id)
        XCTAssertTrue(store.exists(relativePath: path))
        XCTAssertEqual(try store.load(relativePath: path), data)
    }

    func testPathIsRelativeSoItSurvivesReinstall() throws {
        // The container path changes between installs; an absolute path in the
        // store would break every capture (§16.2).
        let path = try store.store(Data("x".utf8), id: UUID())
        XCTAssertFalse(path.hasPrefix("/"))
        XCTAssertFalse(path.contains(root.path))
    }

    func testOriginalAndProcessedDoNotOverwriteEachOther() throws {
        // §8.1: the original must be kept unchanged alongside the processed copy.
        let id = UUID()
        let original = try store.store(Data("original".utf8), id: id, kind: .original)
        let processed = try store.store(Data("processed".utf8), id: id, kind: .processed)
        XCTAssertNotEqual(original, processed)
        XCTAssertEqual(try store.load(relativePath: original), Data("original".utf8))
        XCTAssertEqual(try store.load(relativePath: processed), Data("processed".utf8))
    }

    func testFilesAreShardedIntoSubdirectories() throws {
        let path = try store.store(Data("x".utf8), id: UUID())
        XCTAssertTrue(path.contains("/"))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try store.load(relativePath: "yok/olmayan.jpg"))
    }

    func testRemoveIsIdempotent() throws {
        let path = try store.store(Data("x".utf8), id: UUID())
        try store.remove(relativePath: path)
        XCTAssertFalse(store.exists(relativePath: path))
        // Removing again must not throw — retention cleanup may run twice.
        XCTAssertNoThrow(try store.remove(relativePath: path))
    }

    func testStoringTwiceWithSameIdReplacesContent() throws {
        let id = UUID()
        _ = try store.store(Data("first".utf8), id: id)
        let path = try store.store(Data("second".utf8), id: id)
        XCTAssertEqual(try store.load(relativePath: path), Data("second".utf8))
    }
}
