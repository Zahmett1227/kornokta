import SwiftUI
import SwiftData
import CizgiCore

/// Ayarlar → Veri → "Çıkmış soru bankası" (plan §7.1): what is imported,
/// importing or updating it from a `CizgiSoruBankasi` folder, removing it.
struct ExamBankSettingsView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @Environment(\.modelContext) private var context
    @Query private var states: [ExamQuestionState]
    @Query private var runs: [ExamRun]

    @State private var isPickingFolder = false
    @State private var isInstalling = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var isConfirmingRemoval = false
    @State private var diskUsage: Int64?

    /// States whose question the imported bank no longer has — kept, never
    /// deleted by an update (plan §7.1), and said out loud here.
    private var orphanCount: Int {
        guard let bank = examLibrary.bank else { return 0 }
        return states.filter { bank.questionsById[$0.questionId] == nil }.count
    }

    var body: some View {
        Form {
            Section {
                switch examLibrary.phase {
                case .loading:
                    HStack(spacing: Cizgi.Space.sm) {
                        ProgressView()
                        Text("Okunuyor…").foregroundStyle(Cizgi.muted)
                    }
                case .absent:
                    Text("Henüz içe aktarılmadı.")
                        .foregroundStyle(Cizgi.muted)
                case .failed(let message):
                    Text(message).foregroundStyle(Cizgi.danger)
                case .ready:
                    if let bank = examLibrary.bank {
                        LabeledContent("Sürüm", value: bank.bankVersion)
                        LabeledContent("Soru", value: bank.counts.questions.formatted())
                        LabeledContent("Puanlanabilir", value: bank.counts.scoreable.formatted())
                        LabeledContent("Anahtarsız", value: bank.counts.keyless.formatted())
                        LabeledContent("İptal", value: bank.counts.cancelled.formatted())
                        LabeledContent("Kağıt", value: bank.counts.papers.formatted())
                        if let diskUsage {
                            LabeledContent("Boyut", value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                        }
                        if orphanCount > 0 {
                            LabeledContent("Bankada yok", value: "\(orphanCount) soru")
                        }
                    }
                }
            } header: {
                Text("Banka")
            } footer: {
                if orphanCount > 0 {
                    Text("\"Bankada yok\": çözdüğün ama bu banka sürümünde olmayan sorular. "
                         + "Geçmişleri silinmedi; banka yeniden o soruları içerirse kendiliğinden bağlanır.")
                }
            }

            Section {
                Button(examLibrary.bank == nil ? "İçe aktar" : "Güncelle") { isPickingFolder = true }
                    .disabled(isInstalling)
                if let progress = examLibrary.installProgress {
                    ProgressView(value: progress) {
                        Text("Dosyalar doğrulanıyor ve kopyalanıyor…")
                            .font(.footnote)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                if let resultMessage {
                    Text(resultMessage).font(.footnote).foregroundStyle(Cizgi.success)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Cizgi.danger)
                }
            } footer: {
                Text("Mac'te üretilen \"CizgiSoruBankasi\" klasörünü Dosyalar'dan seç. Her dosya "
                     + "manifestteki sağlama değeriyle karşılaştırılır; biri tutmazsa hiçbir şey "
                     + "değişmez. Güncellemede çözüm geçmişin korunur — sorular kalıcı kimlikleriyle bağlı.")
            }

            if examLibrary.bank != nil || !states.isEmpty || !runs.isEmpty {
                Section {
                    Button("Kaldır…", role: .destructive) { isConfirmingRemoval = true }
                        .disabled(isInstalling)
                } footer: {
                    Text("Banka yalnız bu telefonda durur; iCloud yedeğine ve uygulamanın "
                         + "yedeğine girmez (ADR-012).")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Cizgi.paper)
        .navigationTitle("Çıkmış soru bankası")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: install
        )
        .confirmationDialog("Çıkmış soru bankasını kaldır", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Yalnız bankayı kaldır", role: .destructive) { remove(includingHistory: false) }
            Button("Bankayı ve çözüm geçmişini sil", role: .destructive) { remove(includingHistory: true) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Banka dosyaları silinir. Çözüm geçmişini, kart bağlarını ve \"Kitaba dönünce\" "
                 + "listesini saklarsan bankayı yeniden içe aktardığında hepsi yerine oturur.")
        }
        .task(id: examLibrary.bank?.bankVersion) {
            diskUsage = await Task.detached { [store = examLibrary.store] in store?.diskUsage() }.value
        }
    }

    private func install(_ result: Result<[URL], Error>) {
        resultMessage = nil
        errorMessage = nil
        guard case .success(let urls) = result, let folder = urls.first else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return
        }
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                let installed = try await examLibrary.install(from: folder)
                let counts = installed.bank.counts
                let size = ByteCountFormatter.string(fromByteCount: installed.bytes, countStyle: .file)
                // No suffixes after the numbers: Turkish picks "'i"/"'si"/"'ı"
                // by how the number is read aloud, and a fixed one is wrong
                // for most of them.
                resultMessage = "\(counts.questions.formatted()) soru içe aktarıldı: "
                    + "\(counts.scoreable.formatted()) puanlanabilir, \(counts.keyless.formatted()) anahtarsız, "
                    + "\(counts.cancelled.formatted()) iptal. \(size)."
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func remove(includingHistory: Bool) {
        resultMessage = nil
        errorMessage = nil
        do {
            try examLibrary.remove()
            if includingHistory {
                // Runs cascade to their attempts; states stand alone.
                runs.forEach(context.delete)
                states.forEach(context.delete)
                try context.save()
            }
            resultMessage = includingHistory ? "Banka ve çözüm geçmişi silindi." : "Banka kaldırıldı; çözüm geçmişin duruyor."
        } catch {
            errorMessage = "Kaldırılamadı: \(error.localizedDescription)"
        }
    }
}
