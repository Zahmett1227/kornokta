import SwiftUI
import CizgiCore

/// "İkinci görüş iste" — the on-demand Gemini re-read of a `lowConfidence`
/// card's source page (§10.4's surviving idea; backend `/api/second-opinion`).
///
/// Lives only on cards the model itself doubted: this is the moment the human
/// is squinting at the same handwriting the first reader could not resolve,
/// and an *independent* second reading is exactly the help that moment wants.
/// Spend happens on the tap, never automatically.
///
/// The opinion is deliberately ephemeral — `@State`, gone when the screen is
/// left. Persisting it would mean a SwiftData field and a backup-format bump
/// for a value whose whole job is to be read once, while the user decides to
/// fix or accept the card (§10.4 spirit: it informs the human, it never enters
/// the deck on its own).
struct SecondOpinionSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context
    let card: Card

    private enum Phase: Equatable {
        case idle
        case loading
        case loaded(SecondOpinion)
        case failed(message: String, retryable: Bool)
    }

    @State private var phase: Phase = .idle

    var body: some View {
        switch phase {
        case .idle:
            requestButton(title: "İkinci görüş iste")
            explainer(
                "Sayfa, kartı üretenden bağımsız bir modele (Gemini) yeniden okutulur; "
                    + "cevap kaydedilmez, yalnız şimdi gösterilir."
            )

        case .loading:
            HStack(spacing: Cizgi.Space.sm) {
                ProgressView()
                Text("Sayfa bağımsız modele okutuluyor…")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
            }

        case .loaded(let opinion):
            verdictLabel(opinion)
            VStack(alignment: .leading, spacing: 2) {
                Text("İkinci okuma (Gemini)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Cizgi.muted)
                Text(opinion.reading)
                    .font(.footnote)
                    .foregroundStyle(Cizgi.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let note = opinion.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message, let retryable):
            Text(message)
                .font(.footnote)
                .foregroundStyle(Cizgi.danger)
                .fixedSize(horizontal: false, vertical: true)
            if retryable {
                requestButton(title: "Tekrar dene")
            }
        }
    }

    private func requestButton(title: String) -> some View {
        Button {
            phase = .loading
            Task { await requestOpinion() }
        } label: {
            Label(title, systemImage: "person.2.badge.gearshape")
        }
        .disabled(!environment.isBackendConfigured || pageImagePath == nil)
    }

    @ViewBuilder
    private func explainer(_ text: String) -> some View {
        if !environment.isBackendConfigured {
            Text("Backend ayarlı değil (Ayarlar → Backend).")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        } else if pageImagePath == nil {
            // The one honest limit of the on-demand variant: the server's copy
            // is long deleted, so no stored original means nothing to re-read.
            Text("Orijinal sayfa saklanmadığı için ikinci görüş istenemiyor (Ayarlar → Veri).")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        } else {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        }
    }

    @ViewBuilder
    private func verdictLabel(_ opinion: SecondOpinion) -> some View {
        switch opinion.verdict {
        case .supports:
            Label("İkinci okuma kartı destekliyor", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.success)
        case .contradicts:
            Label("İkinci okuma kartla çelişiyor", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.danger)
        case .unclear:
            Label("İkinci okuma da emin olamadı", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.warning)
        case nil:
            // A verdict this build has not heard of: shown raw rather than
            // dropped, same lenient-decode contract as the rest of the wire.
            Label(opinion.verdictRaw, systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.muted)
        }
    }

    /// Path of the stored original, only when the file is really still there —
    /// the record keeps its path after "Orijinal sayfayı sakla" is turned off,
    /// so the file has to be asked about rather than assumed (CardSourceView).
    private var pageImagePath: String? {
        guard
            let path = card.knowledgeUnit?.region?.page?.originalImagePath,
            environment.imageStore.exists(relativePath: path)
        else { return nil }
        return path
    }

    private func requestOpinion() async {
        guard let provider = environment.makeSecondOpinionProvider() else {
            phase = .failed(message: "Backend ayarlı değil (Ayarlar → Backend).", retryable: false)
            return
        }
        guard let path = pageImagePath else {
            phase = .failed(
                message: "Orijinal sayfa bulunamadı; ikinci görüş istenemiyor.",
                retryable: false
            )
            return
        }

        let front = card.front
        let back = card.back
        let explanation = card.explanation
        let requestId = card.id.uuidString
        let pageId = card.knowledgeUnit?.region?.page?.id.uuidString
        let store = environment.imageStore
        let started = Date()

        do {
            // Load + downscale off the main actor: the stored original is
            // megabytes, and the same budget that protects a capture upload
            // (Vercel's body cap) protects this one.
            let prepared = try await Task.detached(priority: .userInitiated) {
                let original = try store.load(relativePath: path)
                return UploadImageEncoder.prepare(original: original, mimeType: "image/jpeg")
            }.value

            let opinion = try await provider.request(
                requestId: requestId,
                imageData: prepared.data,
                mimeType: prepared.mimeType,
                front: front,
                back: back,
                explanation: explanation
            )

            // The opinion text stays ephemeral, its *cost* does not: Ayarlar →
            // Kullanım totals `ModelRun`, and a paid call that never lands
            // there permanently underreports spend (Codex, PR #39). Recorded
            // only on success, the same deliberate gap card generation has
            // (docs/FAZ3-PLAN.md F3-8).
            if let usage = opinion.usage {
                context.insert(ModelRun(
                    requestId: requestId,
                    jobId: pageId ?? requestId,
                    provider: usage.provider,
                    model: usage.model,
                    purpose: "second_opinion",
                    promptVersion: opinion.promptVersion ?? "",
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    estimatedCostUSD: usage.estimatedCostUSD,
                    success: true
                ))
                try? context.save()
            }

            phase = .loaded(opinion)
        } catch let error as SecondOpinionError {
            // The server's message travels verbatim — it already names the
            // real suspect (an exhausted Gemini quota says "kota/kredi tükendi",
            // per the owner's requirement), and rewording would hide it.
            phase = .failed(message: error.localizedDescription, retryable: error.retryable)
        } catch {
            phase = .failed(message: error.localizedDescription, retryable: true)
        }
    }
}
