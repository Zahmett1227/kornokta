import SwiftUI
import SwiftData
import CizgiCore
import UniformTypeIdentifiers

/// Importing a concept pack: pick a JSON file, write it into the Kavramlar
/// deck, say what happened.
///
/// Deliberately not part of Ayarlar's backup flow. A backup restores *this*
/// deck's own history and is additive to it; this brings in a second deck from
/// outside. Putting them in one place would invite the file for one to be
/// handed to the other, and only one of the two carries FSRS history worth
/// protecting.
struct ConceptPackImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var isPickingFile = false

    private enum Phase: Equatable {
        case idle
        /// Cards written so far, and how many the file asked for. Progress is
        /// reported rather than spun, because on the real pack this is 3.017
        /// writes and an indeterminate spinner would be indistinguishable from
        /// a hang.
        case importing(done: Int, total: Int)
        case finished(ConceptPackImporter.Summary)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: Cizgi.Space.lg) {
            switch phase {
            case .idle:
                idleState
            case .importing(let done, let total):
                importingState(done: done, total: total)
            case .finished(let summary):
                finishedState(summary)
            case .failed(let message):
                failedState(message)
            }
        }
        .padding(Cizgi.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("Kavram paketi")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: startImport
        )
    }

    private var idleState: some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 52))
                .foregroundStyle(Cizgi.accent)
            Text("Kavram paketi içe aktar")
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text("Dışarıda hazırlanmış bir kavram paketi (JSON) seç. "
                 + "Kartlar Kavramlar destesine girer; çektiğin sayfalardan "
                 + "üretilen kartlara dokunulmaz.")
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
            Text("Aynı paketi ikinci kez seçmek hiçbir şey eklemez — "
                 + "zaten burada olan kartlar atlanır.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
            Button("Dosya seç") { isPickingFile = true }
                .buttonStyle(.borderedProminent)
                .tint(Cizgi.accent)
                .padding(.top, Cizgi.Space.sm)
        }
    }

    private func importingState(done: Int, total: Int) -> some View {
        VStack(spacing: Cizgi.Space.md) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(Cizgi.accent)
            Text("\(done) / \(total) kart")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.ink)
            Text("Uygulamayı açık tut.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        }
    }

    private func finishedState(_ summary: ConceptPackImporter.Summary) -> some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Cizgi.accent)
            Text(summary.insertedCards == 0 ? "Zaten buradaydı" : "İçe aktarıldı")
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text(summaryLine(summary))
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
            Button("Bitti") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Cizgi.accent)
                .padding(.top, Cizgi.Space.sm)
        }
    }

    private func summaryLine(_ summary: ConceptPackImporter.Summary) -> String {
        var parts: [String] = []
        if summary.insertedCards > 0 {
            parts.append("\(summary.insertedConcepts) kavram, \(summary.insertedCards) kart eklendi.")
        }
        if summary.skippedCards > 0 {
            parts.append("\(summary.skippedCards) kart zaten buradaydı, atlandı.")
        }
        return parts.isEmpty ? "Pakette eklenecek kart yok." : parts.joined(separator: " ")
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: Cizgi.Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("İçe aktarılamadı")
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
            Button("Tekrar dene") { phase = .idle }
                .buttonStyle(.bordered)
                .tint(Cizgi.accent)
        }
    }

    private func startImport(_ result: Result<[URL], Error>) {
        Task { await runImport(result) }
    }

    private func runImport(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first else { return }
            // A file from the Files app lives outside the sandbox until asked
            // for; without this the read fails with a permission error that
            // reads like a corrupt pack — the same reason Ayarlar's restore
            // does it.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let pack = try ConceptPackImporter.decode(try Data(contentsOf: url))
            let existing = Set(try context.fetch(FetchDescriptor<Card>()).map(\.id))
            let plan = ConceptPackImporter.plan(pack: pack, existingCardIds: existing)

            guard !plan.isEmpty else {
                phase = .finished(.init(
                    insertedCards: 0,
                    insertedConcepts: 0,
                    skippedCards: plan.skipped.count
                ))
                return
            }

            phase = .importing(done: 0, total: plan.cardCount)
            let summary = try await ConceptPackImporter.run(
                plan: plan,
                into: context,
                progress: { done, total in
                    phase = .importing(done: done, total: total)
                }
            )
            phase = .finished(summary)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
