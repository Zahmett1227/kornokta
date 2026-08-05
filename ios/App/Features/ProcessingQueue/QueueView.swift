import SwiftUI
import SwiftData
import CizgiCore
#if canImport(UIKit)
// `UIImage(data:)` below is declared in UIKit, not SwiftUI.
import UIKit
#endif

/// The processing queue (ANA-PLAN §6.3). Every item can be retried, and a
/// failed provider call never loses the image or the local OCR (§21.2).
struct QueueView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context

    @Query(sort: \CapturedPage.captureDate, order: .reverse)
    private var pages: [CapturedPage]

    var body: some View {
        List {
            if pages.isEmpty {
                ContentUnavailableView(
                    "Kuyruk boş",
                    systemImage: "tray",
                    description: Text("Çektiğin sayfalar burada görünür.")
                )
            }

            ForEach(pages) { page in
                row(for: page)
                    .listRowBackground(Cizgi.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("İşleme Kuyruğu")
        .homeButtonToolbar()
        .refreshable {
            await environment.queue.processPending()
        }
    }

    @ViewBuilder
    private func row(for page: CapturedPage) -> some View {
        let state = page.processingState

        // Faz 6 (docs/FAZ6-PLAN.md): pages never stop at `.confirmationRequired`
        // any more, so every row opens the read-only page detail. `ConfirmationView`
        // stays on disk for the rollback path but is no longer navigated to.
        NavigationLink {
            PageDetailView(page: page)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: state.systemImage)
                    .foregroundStyle(state.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.label)
                        .font(.body)
                    Text(page.captureDate, format: .dateTime.hour().minute().day().month())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = page.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                if state == .temporaryFailure || state == .permanentFailure {
                    Button("Tekrar dene") {
                        Task { await environment.queue.retry(page) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            // Colour alone must not carry the status (§29).
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(state.label), \(page.captureDate.formatted(.dateTime.hour().minute()))")
        }
        .swipeActions {
            Button("Sil", role: .destructive) {
                environment.queue.delete(page)
            }
            if state != .cancelled {
                Button("İptal") {
                    environment.queue.cancel(page)
                }
                .tint(.orange)
            }
        }
    }
}

/// Read-only view of a page that is not waiting on the user.
struct PageDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let page: CapturedPage

    var body: some View {
        List {
            Section("Durum") {
                Label(page.processingState.label, systemImage: page.processingState.systemImage)
                    .foregroundStyle(page.processingState.tint)
                LabeledContent("Çekim", value: page.captureDate.formatted())
                LabeledContent("Kalite", value: String(format: "%.2f", page.documentQualityScore))
                if page.retryCount > 0 {
                    LabeledContent("Deneme", value: "\(page.retryCount)")
                }
            }

            if let image = loadImage() {
                Section("Sayfa") {
                    image
                        .resizable()
                        .scaledToFit()
                }
            }

            ForEach(page.regions) { region in
                Section("Pasaj") {
                    Text(region.finalText)
                    ForEach(region.knowledgeUnits) { unit in
                        ForEach(unit.cards) { card in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(card.front).font(.subheadline).bold()
                                Text(card.back).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sayfa")
        .homeButtonToolbar()
    }

    private func loadImage() -> Image? {
        guard let data = try? environment.imageStore.load(relativePath: page.originalImagePath) else {
            return nil
        }
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}
