import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// `manifest.json` of a package (tools/exam_bank/package.py). Only what the
/// import checks is decoded; the gates and the human check stay on the Mac.
public struct ExamBankManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int64

        public init(path: String, sha256: String, bytes: Int64) {
            self.path = path
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    public struct Counts: Codable, Equatable, Sendable {
        public let papers: Int
        public let questions: Int

        public init(papers: Int, questions: Int) {
            self.papers = papers
            self.questions = questions
        }
    }

    public let bankVersion: String
    public let schemaVersion: Int
    public let builtAt: String
    public let files: [File]
    public let counts: Counts

    public init(bankVersion: String, schemaVersion: Int, builtAt: String, files: [File], counts: Counts) {
        self.bankVersion = bankVersion
        self.schemaVersion = schemaVersion
        self.builtAt = builtAt
        self.files = files
        self.counts = counts
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

public enum ExamBankInstallError: Error, Equatable, LocalizedError {
    case notAPackage
    case unreadableManifest
    case unsupportedSchema(Int)
    case unsafePath(String)
    case missingFile(String)
    case corruptFile(String)
    case bankUnreadable(String)
    case countMismatch(expected: Int, found: Int)
    case missingPDF(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .notAPackage:
            return "Seçilen klasörde manifest.json yok. \"CizgiSoruBankasi\" klasörünün kendisini seç."
        case .unreadableManifest:
            return "manifest.json okunamadı."
        case .unsupportedSchema(let version):
            return "Bu banka biçimi (sürüm \(version)) bu uygulama sürümünde desteklenmiyor. Uygulamayı güncelle."
        case .unsafePath(let path):
            return "Pakette beklenmeyen bir dosya yolu var: \(path)"
        case .missingFile(let path):
            return "Pakette dosya eksik: \(path)"
        case .corruptFile(let path):
            return "Dosya bozuk: \(path)"
        case .bankUnreadable(let reason):
            return "bank.json okunamadı: \(reason)"
        case .countMismatch(let expected, let found):
            return "Manifest \(expected) soru diyor, bank.json'da \(found) var."
        case .missingPDF(let path):
            return "Bir soru pakette olmayan bir PDF'e bağlı: \(path)"
        case .unavailable:
            return "Bu cihazda soru bankası içe aktarılamıyor."
        }
    }
}

public struct ExamBankInstallResult: Sendable {
    public let bank: ExamBank
    public let bytes: Int64
    public let replacedVersion: String?
}

/// The bank's home on the phone: `Application Support/Cizgi/ExamBank/`
/// (plan §7.1).
///
///     ExamBank/
///       active.json            {"bankVersion": "2026-09-25.2"}
///       2026-09-25.2/          manifest.json, bank.json, pdf/<sha256>.pdf
///
/// The whole folder is excluded from iCloud backup (plan D10): the booklets
/// are someone else's, and the app's own backup carries only ids and results.
///
/// An import either replaces the active bank completely or leaves it exactly
/// as it was. Files are copied into a staging folder while their SHA-256 is
/// checked against the manifest, `bank.json` is decoded and cross-checked
/// there, and only then does the staging folder become the new version and
/// `active.json` move to it. Anything that throws before that point deletes
/// the staging folder and nothing else.
///
/// Synchronous and main-actor-free on purpose: a 160 MB copy belongs on a
/// detached task (the ADR-011 lesson), and the caller decides where that is.
public final class ExamBankStore: @unchecked Sendable {
    public let root: URL
    private let fileManager: FileManager

    public static let manifestName = "manifest.json"
    public static let bankName = "bank.json"
    static let activeName = "active.json"
    private static let chunkSize = 1 << 20

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("Cizgi/ExamBank", isDirectory: true)
    }

    // MARK: Reading

    private struct Active: Codable {
        let bankVersion: String
    }

    public var activeVersion: String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(Self.activeName)),
              let active = try? JSONDecoder().decode(Active.self, from: data),
              Self.isSafeVersion(active.bankVersion),
              fileManager.fileExists(atPath: root.appendingPathComponent(active.bankVersion).path)
        else { return nil }
        return active.bankVersion
    }

    public var activeDirectory: URL? {
        activeVersion.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// `nil` when no bank has been imported.
    public func loadActive() throws -> ExamBank? {
        guard let directory = activeDirectory else { return nil }
        let data = try Data(contentsOf: directory.appendingPathComponent(Self.bankName), options: .mappedIfSafe)
        return try ExamBank.decode(data)
    }

    public func activeManifest() -> ExamBankManifest? {
        guard let directory = activeDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(Self.manifestName))
        else { return nil }
        return try? JSONDecoder().decode(ExamBankManifest.self, from: data)
    }

    /// A packaged PDF of the active bank, by the path the bank uses
    /// (`pdf/<sha256>.pdf`).
    public func pdfURL(for path: String) -> URL? {
        guard Self.isSafePackagePath(path), path != Self.bankName, let directory = activeDirectory else { return nil }
        let url = directory.appendingPathComponent(path)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Removing

    /// Deletes every bank file. The owner's answers live in SwiftData and are
    /// not touched here — whether they go too is a separate question the
    /// screen asks (plan §7.1).
    public func remove() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.removeItem(at: root)
    }

    // MARK: Installing

    public func install(from package: URL, progress: (Double) -> Void = { _ in }) throws -> ExamBankInstallResult {
        #if canImport(CryptoKit)
        let manifestURL = package.appendingPathComponent(Self.manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw ExamBankInstallError.notAPackage }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ExamBankManifest.self, from: manifestData)
        else { throw ExamBankInstallError.unreadableManifest }
        guard manifest.schemaVersion == ExamBankDocument.supportedSchemaVersion else {
            throw ExamBankInstallError.unsupportedSchema(manifest.schemaVersion)
        }
        guard Self.isSafeVersion(manifest.bankVersion) else {
            throw ExamBankInstallError.unsafePath(manifest.bankVersion)
        }
        for file in manifest.files where !Self.isSafePackagePath(file.path) {
            throw ExamBankInstallError.unsafePath(file.path)
        }
        guard manifest.files.contains(where: { $0.path == Self.bankName }) else {
            throw ExamBankInstallError.missingFile(Self.bankName)
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging.appendingPathComponent("pdf"), withIntermediateDirectories: true)

        do {
            let total = max(1, manifest.totalBytes)
            var copied: Int64 = 0
            for file in manifest.files {
                let source = package.appendingPathComponent(file.path)
                guard fileManager.fileExists(atPath: source.path) else {
                    throw ExamBankInstallError.missingFile(file.path)
                }
                try copyVerifying(from: source, to: staging.appendingPathComponent(file.path), expected: file) { chunk in
                    copied += Int64(chunk)
                    progress(min(1, Double(copied) / Double(total)))
                }
            }
            try manifestData.write(to: staging.appendingPathComponent(Self.manifestName))

            let bank: ExamBank
            do {
                let data = try Data(contentsOf: staging.appendingPathComponent(Self.bankName), options: .mappedIfSafe)
                bank = try ExamBank.decode(data)
            } catch let error as ExamBank.ValidationError {
                throw ExamBankInstallError.bankUnreadable(error.localizedDescription)
            } catch {
                throw ExamBankInstallError.bankUnreadable(String(describing: error))
            }
            guard bank.counts.questions == manifest.counts.questions else {
                throw ExamBankInstallError.countMismatch(expected: manifest.counts.questions, found: bank.counts.questions)
            }
            let shipped = Set(manifest.files.map(\.path))
            for question in bank.questions {
                for region in question.provenance + question.altProvenance where !shipped.contains(region.pdf) {
                    throw ExamBankInstallError.missingPDF(region.pdf)
                }
            }

            let previous = activeVersion
            try promote(staging, to: manifest.bankVersion)
            try writeActive(manifest.bankVersion)
            removeEverything(except: manifest.bankVersion)
            return ExamBankInstallResult(bank: bank, bytes: manifest.totalBytes, replacedVersion: previous)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        #else
        throw ExamBankInstallError.unavailable
        #endif
    }

    #if canImport(CryptoKit)
    /// One pass: copy and hash together, so 160 MB is read once.
    private func copyVerifying(
        from source: URL,
        to destination: URL,
        expected: ExamBankManifest.File,
        onChunk: (Int) -> Void
    ) throws {
        fileManager.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try input.read(upToCount: Self.chunkSize) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            bytes += Int64(chunk.count)
            onChunk(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytes == expected.bytes, digest == expected.sha256.lowercased() else {
            throw ExamBankInstallError.corruptFile(expected.path)
        }
    }
    #endif

    /// Staging becomes `<version>/`. A bank of the same version already there
    /// (re-importing) is moved aside first and put back if the swap fails.
    private func promote(_ staging: URL, to version: String) throws {
        let final = root.appendingPathComponent(version, isDirectory: true)
        guard fileManager.fileExists(atPath: final.path) else {
            try fileManager.moveItem(at: staging, to: final)
            return
        }
        let aside = root.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: final, to: aside)
        do {
            try fileManager.moveItem(at: staging, to: final)
        } catch {
            try? fileManager.moveItem(at: aside, to: final)
            throw error
        }
        try? fileManager.removeItem(at: aside)
    }

    private func writeActive(_ version: String) throws {
        let data = try JSONEncoder().encode(Active(bankVersion: version))
        try data.write(to: root.appendingPathComponent(Self.activeName), options: .atomic)
    }

    /// The previous version and any leftover staging folder. Best effort: a
    /// folder that will not delete costs space, not correctness — `active.json`
    /// already points past it.
    private func removeEverything(except version: String) {
        let entries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in entries where entry != version && entry != Self.activeName {
            try? fileManager.removeItem(at: root.appendingPathComponent(entry))
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }

    /// Bytes the bank occupies on disk.
    public func diskUsage() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Path rules

    /// `bank.json` or `pdf/<64 hex>.pdf` — the only two shapes a package
    /// holds. Anything else, `..` included, is refused before it is joined to
    /// a path on this phone.
    static func isSafePackagePath(_ path: String) -> Bool {
        if path == bankName { return true }
        guard path.hasPrefix("pdf/"), path.hasSuffix(".pdf") else { return false }
        let hash = path.dropFirst(4).dropLast(4)
        return hash.count == 64 && hash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `2026-09-25.2` — also the folder name, so nothing else gets through.
    static func isSafeVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy({ ("0"..."9").contains($0) }) else { return false }
        let date = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        return date.count == 3 && date.map(\.count) == [4, 2, 2]
            && date.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) } }
    }
}
