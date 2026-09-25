import Foundation
import SwiftUI
import CizgiCore

/// The imported past exam bank, loaded once and shared by every Çıkmış screen
/// (docs/PLAN-cikmis-soru-bankasi.md §7.1).
///
/// Its own `ObservableObject` rather than a property of `AppEnvironment`: a
/// nested object's changes do not reach views observing the outer one, and
/// the bank arrives asynchronously — the screens must redraw when it does.
///
/// Decoding (8.410 questions, ~7 MB) and installing (a ~160 MB copy with a
/// hash per file) both run detached; only the published results come back to
/// the main actor — the ADR-011 lesson about large files on the main thread.
@MainActor
final class ExamLibrary: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// Nothing imported yet — a normal state, not an error.
        case absent
        case ready
        case failed(String)
    }

    @Published private(set) var bank: ExamBank?
    @Published private(set) var phase: Phase = .loading
    /// 0…1 while an import runs, `nil` otherwise.
    @Published private(set) var installProgress: Double?

    let store: ExamBankStore?
    private var hasLoaded = false

    init() {
        store = (try? ExamBankStore.defaultRoot()).map { ExamBankStore(root: $0) }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func reload() async {
        guard let store else {
            phase = .failed("Uygulama klasörü açılamadı.")
            return
        }
        phase = .loading
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try store.loadActive() }.value
            bank = loaded
            phase = loaded == nil ? .absent : .ready
        } catch {
            bank = nil
            phase = .failed("Soru bankası okunamadı: \(error.localizedDescription)")
        }
    }

    /// Copies a `CizgiSoruBankasi` folder the owner picked in Files.
    func install(from folder: URL) async throws -> ExamBankInstallResult {
        guard let store else { throw ExamBankInstallError.unavailable }
        installProgress = 0
        defer { installProgress = nil }
        let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> ExamBankInstallResult in
            // Outside the sandbox until asked for, like a backup file.
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var lastReported = 0.0
            return try store.install(from: folder) { fraction in
                // A progress bar needs a few dozen updates, not one per MB.
                guard fraction - lastReported >= 0.02 || fraction >= 1 else { return }
                lastReported = fraction
                Task { @MainActor in self?.installProgress = fraction }
            }
        }.value
        bank = result.bank
        phase = .ready
        hasLoaded = true
        return result
    }

    /// Deletes the bank files. The owner's answers are the caller's decision.
    func remove() throws {
        try store?.remove()
        bank = nil
        phase = .absent
    }

    func pdfURL(for path: String) -> URL? {
        store?.pdfURL(for: path)
    }

    var diskUsage: Int64 { store?.diskUsage() ?? 0 }
}
