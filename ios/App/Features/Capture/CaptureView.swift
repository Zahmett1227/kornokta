import SwiftUI
import SwiftData
import CizgiCore

/// The capture tab (ANA-PLAN §6.2).
///
/// The rule that shapes this screen: capture is independent of generation (P1).
/// Nothing here waits on OCR or card generation, and finishing a scan never
/// pushes the user into an editor — they go straight back to shooting.
///
/// Faz 6 (docs/FAZ6-PLAN.md): there is no confirmation step any more — the
/// marked page goes straight to the vision endpoint and cards enter the active
/// deck. The old "onay bekliyor" summary is gone.
struct CaptureView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context

    @Query(sort: \CapturedPage.captureDate, order: .reverse)
    private var pages: [CapturedPage]

    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var lastCapturedIds: [UUID] = []
    /// Held while the duplicate question is on screen — nothing is written to
    /// disk until the user answers it.
    @State private var pendingImages: [Data] = []
    /// Which of `pendingImages` duplicate something. Computed once, so the
    /// "yalnız yenilerini ekle" path skips exactly what the question described.
    @State private var pendingDuplicates: Set<Int> = []

    private var duplicateCount: Int { pendingDuplicates.count }

    private var inFlight: [CapturedPage] {
        pages.filter { !$0.processingState.isTerminal }
    }

    private var readyCount: Int {
        pages.filter { $0.processingState == .ready }.count
    }

    var body: some View {
        NavigationStack(path: $navigator.capturePath) {
            ScrollView {
                VStack(spacing: Cizgi.Space.xl) {
                    hero
                    captureButton
                    if !lastCapturedIds.isEmpty {
                        Label("\(lastCapturedIds.count) sayfa kuyruğa alındı",
                              systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Cizgi.success)
                    }
                    queueSummary
                }
                .padding(Cizgi.Space.lg)
                .frame(maxWidth: .infinity)
            }
            .background(Cizgi.paper.ignoresSafeArea())
            .navigationTitle("Yakala")
            .homeButtonToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        QueueView()
                    } label: {
                        Label("Kuyruk", systemImage: "tray.full")
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
            .confirmationDialog(
                duplicateCount == pendingImages.count
                    ? "Bu sayfayı daha önce çekmişsin."
                    : "\(duplicateCount) sayfayı daha önce çekmişsin.",
                isPresented: Binding(
                    get: { duplicateCount > 0 },
                    set: { if !$0 { clearPending() } }
                ),
                titleVisibility: .visible
            ) {
                if duplicateCount < pendingImages.count {
                    Button("Yalnız yenilerini ekle") { storeSkippingDuplicates() }
                }
                Button("Yine de ekle") { storeAllPending() }
                Button("Vazgeç", role: .cancel) { clearPending() }
            } message: {
                Text("Tekrar eklersen aynı sayfadan ikinci bir kart takımı üretilir "
                     + "ve üretim ücreti yeniden ödenir.")
            }
        }
        .tint(Cizgi.accent)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Cizgi.Space.lg) {
            // A stylised marked page: text lines with one amber highlighter sweep.
            ZStack {
                RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                    .fill(Cizgi.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                            .stroke(Cizgi.hairline, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<5, id: \.self) { row in
                        ZStack(alignment: .leading) {
                            if row == 2 {
                                Capsule().fill(Cizgi.accentSoft)
                                    .frame(width: 150, height: 14)
                            }
                            Capsule().fill(Cizgi.hairline)
                                .frame(width: row == 4 ? 90 : 170, height: 5)
                        }
                    }
                }
                .padding(Cizgi.Space.lg)
            }
            .frame(width: 210, height: 150)
            .shadow(color: .black.opacity(0.07), radius: 12, x: 0, y: 6)
            .rotationEffect(.degrees(-3))

            VStack(spacing: Cizgi.Space.xs) {
                Text("Kitapta işaretlediğin sayfayı çek")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Cizgi.ink)
                    .multilineTextAlignment(.center)
                Text("Fosforlu, altını çizdiğin ve not aldığın yerlerden\nonaysız, doğrudan kart üretilir.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, Cizgi.Space.lg)
    }

    private var captureButton: some View {
        Group {
            #if os(iOS)
            Button {
                isScanning = true
            } label: {
                Label("İşaretli sayfayı çek", systemImage: "camera.fill")
            }
            .buttonStyle(CizgiPrimaryButtonStyle())
            #else
            Text("Kamera yalnız iOS'ta kullanılabilir.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
            #endif
        }
    }

    // MARK: Queue summary

    @ViewBuilder
    private var queueSummary: some View {
        if !inFlight.isEmpty || readyCount > 0 {
            CardSurface {
                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    Text("Durum")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.ink)
                    if !inFlight.isEmpty {
                        Label("\(inFlight.count) sayfa işleniyor", systemImage: "clock.fill")
                            .font(.subheadline)
                            .foregroundStyle(Cizgi.accent)
                    }
                    if readyCount > 0 {
                        Label("\(readyCount) sayfadan kart üretildi", systemImage: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundStyle(Cizgi.success)
                    }
                    NavigationLink {
                        QueueView()
                    } label: {
                        Text("Kuyruğu aç")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Cizgi.accent)
                    }
                }
            }
        }
    }

    private func handleScanned(_ images: [Data]) {
        // A page you have already captured is easy to shoot twice — a blurry
        // first attempt, or simply losing your place in the book — and until now
        // nothing noticed, so it produced a duplicate set of cards and a second
        // charge from the provider. Asked, never enforced: the similarity
        // threshold is a first calibration, and re-shooting a page on purpose is
        // a perfectly normal thing to do.
        //
        // The batch is compared against itself as well as against the store: one
        // scan can hand back the same page twice, and neither copy is in the
        // store yet (Codex, PR #27).
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: images.map { PageImageHasher.hash($0) },
            storedHashes: environment.queue.storedPageHashes()
        )
        guard duplicates.isEmpty else {
            pendingImages = images
            pendingDuplicates = duplicates
            return
        }
        store(images)
    }

    /// Keeps only the images the question did not flag.
    private func storeSkippingDuplicates() {
        let fresh = pendingImages.enumerated()
            .filter { !pendingDuplicates.contains($0.offset) }
            .map(\.element)
        clearPending()
        guard !fresh.isEmpty else {
            lastCapturedIds = []
            return
        }
        store(fresh)
    }

    private func storeAllPending() {
        let images = pendingImages
        clearPending()
        store(images)
    }

    private func clearPending() {
        pendingImages = []
        pendingDuplicates = []
    }

    private func store(_ images: [Data]) {
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
