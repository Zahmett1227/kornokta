import SwiftUI
import SwiftData
import CizgiCore

/// The capture tab (ANA-PLAN §6.2).
///
/// The rule that shapes this screen: capture is independent of generation (P1).
/// Nothing here waits on OCR or card generation, and finishing a scan never
/// pushes the user into an editor — they go straight back to shooting.
struct CaptureView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context

    @Query(sort: \CapturedPage.captureDate, order: .reverse)
    private var pages: [CapturedPage]

    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var lastCapturedIds: [UUID] = []

    private var inFlight: [CapturedPage] {
        pages.filter { !$0.processingState.isTerminal && $0.processingState != .confirmationRequired }
    }

    private var awaitingConfirmation: [CapturedPage] {
        pages.filter { $0.processingState == .confirmationRequired }
    }

    var body: some View {
        NavigationStack(path: $navigator.capturePath) {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("Kitapta işaretlediğin sayfayı çek")
                    .font(.headline)
                Text("Arka arkaya çekebilirsin; işleme arkada sürer.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                #if os(iOS)
                Button {
                    isScanning = true
                } label: {
                    Label("Çek", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
                #else
                Text("Kamera yalnız iOS'ta kullanılabilir.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif

                if !lastCapturedIds.isEmpty {
                    Label("\(lastCapturedIds.count) sayfa kuyruğa alındı",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }

                Spacer()

                queueSummary
            }
            .padding()
            .navigationTitle("Yakala")
            .homeButtonToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        QueueView()
                    } label: {
                        Label("Kuyruk", systemImage: "list.bullet.rectangle")
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $isScanning) {
                DocumentScanner(
                    onFinish: { pages in
                        isScanning = false
                        handleScanned(pages)
                    },
                    onCancel: { isScanning = false },
                    onError: { error in
                        isScanning = false
                        errorMessage = "Tarama başarısız: \(error.localizedDescription)"
                    }
                )
                .ignoresSafeArea()
            }
            #endif
            .alert("Hata", isPresented: .constant(errorMessage != nil)) {
                Button("Tamam") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var queueSummary: some View {
        VStack(spacing: 12) {
            if !inFlight.isEmpty {
                Label("\(inFlight.count) sayfa işleniyor", systemImage: "clock.fill")
                    .foregroundStyle(.blue)
            }
            if !awaitingConfirmation.isEmpty {
                NavigationLink {
                    QueueView()
                } label: {
                    Label("\(awaitingConfirmation.count) sayfa onay bekliyor",
                          systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.subheadline)
    }

    private func handleScanned(_ images: [Data]) {
        var ids: [UUID] = []
        do {
            for data in images {
                // enqueue returns only after the bytes are on disk, so the
                // success message below is never a lie (§24.1).
                let id = try environment.queue.enqueue(
                    imageData: data,
                    subject: environment.settings.defaultSubject
                )
                ids.append(id)
            }
        } catch {
            errorMessage = "Görüntü kaydedilemedi: \(error.localizedDescription)"
            return
        }
        lastCapturedIds = ids

        Task {
            await environment.queue.processPending()
        }
    }
}
