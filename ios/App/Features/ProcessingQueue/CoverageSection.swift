import SwiftUI
import SwiftData
import CizgiCore

/// "Kartlaşmamış işaretler" — what the readers say this page still owes
/// (docs/PLAN-kapsama-sozlesmesi.md).
///
/// This is the only screen in the app that can show a card that does not exist.
/// Everything else — Tekrar, Bilgilerim, Egzersiz, Bilgi Haritası — works on
/// cards the deck has; a mark that never became one is invisible to all of
/// them, carries no `lowConfidence`, and its only evidence is the photo two
/// sections above this one.
///
/// Two readers feed it and neither is enough alone. The generator's own
/// register (schema v2.3) catches "read it and did not card it" — the defect
/// reported on real pages, where the starred passage sat in `readText` while
/// the cards came from unmarked text. Only the independent audit can catch a
/// mark the first reader never perceived, and only because it does not share
/// that reader's blind spots.
///
/// The audit is a button, not an automatic pass. That is the plan's own
/// staging: a manual trigger has no false positives, costs nothing when unused,
/// and is the cheapest way to learn how often the automatic version would be
/// right before paying for it on every page.
struct CoverageSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context

    let page: CapturedPage
    /// Opens the manual card sheet with this mark's text in hand. The card is
    /// written by the owner, not generated: what the model missed here is a
    /// judgement about their own book, and the sheet is where that judgement
    /// already lives.
    let onAddCard: (PageMark) -> Void

    private enum Phase: Equatable {
        case idle
        case loading
        case failed(message: String, retryable: Bool)
    }

    @State private var phase: Phase = .idle

    private var coverage: PageCoverage {
        PageCoverage.fromStorage(page.coverageJSON)
    }

    var body: some View {
        let coverage = self.coverage
        let findings = coverage.openFindings

        if findings.isEmpty {
            summaryRow(coverage)
        } else {
            ForEach(findings) { mark in
                findingRow(mark)
            }
        }

        auditRow(coverage)
    }

    // MARK: Rows

    private func findingRow(_ mark: PageMark) -> some View {
        Button {
            onAddCard(mark)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(mark.kind.label, systemImage: mark.kind.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mark.source == .auditor ? Cizgi.accent : Cizgi.muted)
                Text(mark.quote)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Cizgi.ink)
        .accessibilityHint("Bu işaret için kart ekle")
        .swipeActions(edge: .trailing) {
            // Not destructive-red: nothing is deleted. The mark stays on the
            // page and in the register; the owner is saying "I looked, this
            // does not need a card" — and it must not come back after the next
            // audit, which is why the decision is stored by identity.
            Button("Yoksay") { dismiss(mark) }
                .tint(Cizgi.muted)
        }
    }

    @ViewBuilder
    private func summaryRow(_ coverage: PageCoverage) -> some View {
        if !coverage.reported && coverage.audit == nil {
            // Deliberately not phrased as good news. A page captured before
            // schema v2.3 — or one whose model ignored the register — has no
            // information either way, and "no findings" would read as "nothing
            // was missed".
            Text("Bu sayfa kapsama defteri olmadan üretilmiş; kartlaşmamış işaret olup olmadığı bilinmiyor.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        } else if !coverage.dismissedMarkIds.isEmpty {
            // "Kapatıldı", not "yoksayıldı": the same list holds both ways of
            // finishing with a mark — writing its card and deciding it does not
            // need one — and the copy has to be true of both.
            Label(
                "Açık işaret yok (\(coverage.dismissedMarkIds.count) işaret kapatıldı).",
                systemImage: "checkmark.circle"
            )
            .font(.footnote)
            .foregroundStyle(Cizgi.muted)
        } else {
            Label("Bildirilen her işaret bir karta dönüşmüş.", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(Cizgi.success)
        }
    }

    @ViewBuilder
    private func auditRow(_ coverage: PageCoverage) -> some View {
        switch phase {
        case .idle:
            if let audit = coverage.audit {
                Text(auditSummary(audit))
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            auditButton(title: coverage.audit == nil ? "Kapsama denetle" : "Yeniden denetle")
            explainer()

        case .loading:
            HStack(spacing: Cizgi.Space.sm) {
                ProgressView()
                Text("Sayfa bağımsız bir modele denetletiliyor…")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
            }

        case .failed(let message, let retryable):
            Text(message)
                .font(.footnote)
                .foregroundStyle(Cizgi.danger)
                .fixedSize(horizontal: false, vertical: true)
            if retryable {
                auditButton(title: "Tekrar dene")
            }
        }
    }

    private func auditButton(title: String) -> some View {
        Button {
            phase = .loading
            Task { await runAudit() }
        } label: {
            Label(title, systemImage: "eye.trianglebadge.exclamationmark")
        }
        .disabled(!environment.isBackendConfigured || pageImagePath == nil)
    }

    @ViewBuilder
    private func explainer() -> some View {
        if !environment.isBackendConfigured {
            Text("Backend ayarlı değil (Ayarlar → Backend).")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        } else if pageImagePath == nil {
            // The honest limit of the on-demand variant: the server's copy is
            // long deleted, so no stored original means nothing to re-read.
            Text("Orijinal sayfa saklanmadığı için denetim yapılamıyor (Ayarlar → Veri).")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        } else {
            Text("Sayfa, kartları üretenden bağımsız bir modele (Gemini) yeniden okutulur; "
                 + "yalnız \"bu işaret kartlaşmış mı?\" sorusu sorulur, kart üretilmez.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        }
    }

    private func auditSummary(_ audit: PageCoverage.Audit) -> String {
        var text = "Bağımsız denetim \(audit.markCount) işaret gördü, "
            + "\(audit.uncovered.count) tanesine kart bulamadı"
        if audit.discarded > 0 {
            // Not hidden: a climbing number says the auditor is losing track of
            // the card list, which is worth knowing before trusting the rest.
            text += " (\(audit.discarded) satır okunamadı)"
        }
        return text + " — \(audit.performedAt.formatted(date: .abbreviated, time: .shortened))."
    }

    // MARK: Actions

    private func dismiss(_ mark: PageMark) {
        var coverage = self.coverage
        coverage.dismiss(mark)
        page.coverageJSON = coverage.storageValue
        // `try?` is the app-wide pattern at 24 call sites; giving this one row
        // an error surface its neighbours lack is the inconsistency PR #44
        // deliberately avoided (CLAUDE.md, "Küçük ve gerçek kalanlar" 6).
        try? context.save()
    }

    /// Path of the stored original, only when the file is really still there —
    /// the record keeps its path after "Orijinal sayfayı sakla" is turned off,
    /// so the file has to be asked about rather than assumed.
    private var pageImagePath: String? {
        guard environment.imageStore.exists(relativePath: page.originalImagePath) else { return nil }
        return page.originalImagePath
    }

    private func runAudit() async {
        guard let provider = environment.makeCoverageAuditProvider() else {
            phase = .failed(message: "Backend ayarlı değil (Ayarlar → Backend).", retryable: false)
            return
        }
        guard let path = pageImagePath else {
            phase = .failed(message: "Orijinal sayfa bulunamadı; denetim yapılamıyor.", retryable: false)
            return
        }

        // Read on the main actor, before the hop: these are SwiftData objects.
        let cards = page.regions
            .flatMap(\.knowledgeUnits)
            .flatMap(\.cards)
            .filter { $0.status != .draft }
            .map { CoverageAuditCard(front: $0.front, back: $0.back) }
        let requestId = page.id.uuidString
        let store = environment.imageStore
        let started = Date()

        do {
            // Load + downscale off the main actor: the stored original is
            // megabytes, and the same budget that protects a capture upload
            // protects this one.
            let prepared = try await Task.detached(priority: .userInitiated) {
                let original = try store.load(relativePath: path)
                return UploadImageEncoder.prepare(original: original, mimeType: "image/jpeg")
            }.value

            let audit = try await provider.request(
                requestId: requestId,
                imageData: prepared.data,
                mimeType: prepared.mimeType,
                cards: cards
            )

            var coverage = self.coverage
            coverage.record(audit: PageCoverage.Audit(
                performedAt: Date(),
                uncovered: audit.uncovered,
                markCount: audit.markCount,
                discarded: audit.discarded
            ))
            page.coverageJSON = coverage.storageValue

            // The findings are stored; the *cost* has to be too. Ayarlar →
            // Kullanım totals `ModelRun`, and a paid call that never lands
            // there permanently underreports spend (Codex, PR #39).
            if let usage = audit.usage {
                context.insert(ModelRun(
                    requestId: requestId,
                    jobId: requestId,
                    provider: usage.provider,
                    model: usage.model,
                    purpose: "coverage_audit",
                    promptVersion: audit.promptVersion ?? "",
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                    inputTokens: usage.inputTokens,
                    cachedInputTokens: usage.cachedInputTokens,
                    outputTokens: usage.outputTokens,
                    reasoningTokens: usage.reasoningTokens,
                    estimatedCostUSD: usage.estimatedCostUSD,
                    success: true,
                    billing: ModelRunBilling.measured
                ))
            }
            try? context.save()

            phase = .idle
        } catch let error as CoverageAuditError {
            // A failed audit is a paid one whenever the request actually
            // reached the model — the same asymmetry card generation has. The
            // verdict comes from the server, which is the only party that sees
            // whether Gemini rejected the request or died mid-generation;
            // deriving it from `retryable` here got a free 429 and a billed
            // safety stop backwards in both directions (Codex, PR #47).
            recordFailedCall(billing: error.billing, requestId: requestId, started: started)
            // The server's message travels verbatim: it already names the real
            // suspect (an exhausted Gemini quota says so in as many words).
            phase = .failed(message: error.localizedDescription, retryable: error.retryable)
        } catch {
            recordFailedCall(billing: ModelRunBilling.unmeasured, requestId: requestId, started: started)
            phase = .failed(message: error.localizedDescription, retryable: true)
        }
    }

    /// A ledger line for an audit that cost money and returned nothing.
    ///
    /// Zero tokens, deliberately: Gemini reported none, and inventing an
    /// average would be worse than a `billing` flag that says plainly the
    /// amount is unknown (§0.6 — never invent a number).
    private func recordFailedCall(billing: String, requestId: String, started: Date) {
        context.insert(ModelRun(
            requestId: requestId,
            jobId: requestId,
            provider: "gemini",
            // Unknown on this path: the model id lives in the response that
            // never arrived. Empty rather than guessed from settings, which
            // could name a model this call did not use.
            model: "",
            purpose: "coverage_audit",
            promptVersion: "",
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            inputTokens: 0,
            outputTokens: 0,
            estimatedCostUSD: 0,
            success: false,
            billing: billing
        ))
        try? context.save()
    }
}
