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

    /// The page a destructive swipe is waiting on confirmation for.
    ///
    /// Only pages that already produced cards get here: deleting one takes the
    /// cards *and* their whole FSRS review history with it (`performDelete`
    /// cascades), which is a very different act from dropping a page that is
    /// still queued — and both were the same single swipe.
    @State private var pagePendingDeletion: CapturedPage?

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
        .confirmationDialog(
            "Bu sayfayı sil?",
            isPresented: Binding(
                get: { pagePendingDeletion != nil },
                set: { if !$0 { pagePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sayfayı ve kartlarını sil", role: .destructive) {
                if let page = pagePendingDeletion {
                    environment.queue.delete(page)
                }
                pagePendingDeletion = nil
            }
            Button("Vazgeç", role: .cancel) { pagePendingDeletion = nil }
        } message: {
            Text(
                "Bu sayfadan üretilen \(cardCount(of: pagePendingDeletion)) kart ve "
                    + "tekrar geçmişi de silinir. Geri alınamaz."
            )
        }
    }

    /// Cards reachable from this page, through the same relationship chain
    /// `ProcessingQueue.performDelete` cascades down.
    private func cardCount(of page: CapturedPage?) -> Int {
        guard let page else { return 0 }
        return page.regions.reduce(0) { total, region in
            total + region.knowledgeUnits.reduce(0) { $0 + $1.cards.count }
        }
    }

    @ViewBuilder
    private func row(for page: CapturedPage) -> some View {
        let state = page.processingState

        // Faz 6 (docs/FAZ6-PLAN.md): pages never stop at `.confirmationRequired`
        // any more, so every row opens the read-only page detail. The
        // destination is registered at the Capture root (`CaptureView`), once
        // per stack.
        NavigationLink(value: page) {
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
                // A page with no cards yet has nothing to lose but itself, so
                // it still goes on one swipe; one that produced cards asks
                // first, because the cascade takes the review history too.
                if cardCount(of: page) > 0 {
                    pagePendingDeletion = page
                } else {
                    environment.queue.delete(page)
                }
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

/// A finished page: the photo, what the model read, and the cards it produced.
///
/// Was read-only until 2026-08-15. The two things it now allows are the two the
/// vision flow cannot do for itself — correcting a card the model got wrong, and
/// adding one it never produced. Both belong here rather than only in
/// Bilgilerim: this is the one screen where the photo, the reading and the cards
/// are visible together, which is what makes a missing card noticeable at all.
struct PageDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context
    let page: CapturedPage

    /// The card whose editor is open. `sheet(item:)` rather than a push: editors
    /// are sheets everywhere in this app, and the Capture stack does not register
    /// a `Card` destination.
    @State private var editingCard: Card?
    @State private var addTarget: AddCardTarget?

    /// Which passage a new card is being written under. A wrapper rather than
    /// `TextRegion?` directly, so `sheet(item:)` can tell "no passage" (a page
    /// that produced nothing) from "no sheet".
    private struct AddCardTarget: Identifiable {
        let id = UUID()
        let region: TextRegion?
        /// The mark this card is being written for, when the sheet was opened
        /// from a coverage finding rather than from the passage's own button.
        var prefill: String?
    }

    var body: some View {
        List {
            Section("Durum") {
                Label(page.processingState.label, systemImage: page.processingState.systemImage)
                    .foregroundStyle(page.processingState.tint)
                LabeledContent("Çekim", value: page.captureDate.formatted())
                // No "Kalite" row: the score came from the pre-Faz-6 local OCR
                // pass and the vision flow never fills it, so it always read
                // 0.00 — a number that looked like an assessment and wasn't.
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
                    if !region.finalText.isEmpty {
                        Text(region.finalText)
                    }
                    ForEach(region.knowledgeUnits) { unit in
                        ForEach(unit.cards) { card in
                            cardRow(card)
                        }
                    }
                    addCardButton(for: region)
                }
            }

            // A job can finish having produced nothing (`noContent`, or a
            // permanent failure). That is exactly when a card most needs adding
            // by hand, so the button has to survive having no passage to sit
            // under.
            if page.regions.isEmpty && page.processingState.isTerminal {
                Section("Kartlar") {
                    Text("Bu sayfadan kart üretilmedi.")
                        .foregroundStyle(Cizgi.muted)
                    addCardButton(for: nil)
                }
            }

            // Last, deliberately: it answers "what is NOT above?", and that
            // question only means something once the photo, the reading and
            // the cards have been seen (docs/PLAN-kapsama-sozlesmesi.md).
            if page.processingState.isTerminal {
                Section("Kartlaşmamış işaretler") {
                    CoverageSection(page: page) { mark in
                        addTarget = AddCardTarget(region: page.regions.first, prefill: mark.quote)
                    }
                }
            }
        }
        .navigationTitle("Sayfa")
        .homeButtonToolbar()
        .sheet(item: $editingCard) { CardEditorView(card: $0) }
        .sheet(item: $addTarget) { ManualCardSheet(page: page, region: $0.region, prefill: $0.prefill) }
    }

    private func cardRow(_ card: Card) -> some View {
        Button {
            editingCard = card
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.front).font(.subheadline).bold()
                Text(card.back).font(.subheadline).foregroundStyle(.secondary)
                Label(card.type.displayName, systemImage: card.type.icon)
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Cizgi.ink)
        .accessibilityHint("Kartı düzenle")
        .swipeActions(edge: .trailing) {
            Button("Sil", role: .destructive) { delete(card) }
        }
    }

    /// Deleting a single card the owner is looking at — the same act as the
    /// swipe in Bilgilerim (`LibraryView.deleteCards`), and unconfirmed for the
    /// same reason. The dialog on the queue *list* guards something else: that
    /// swipe takes a whole page's cards and their review history at once, which
    /// is not what one row here can do. `Card → ReviewLog` still cascades
    /// (`Models.swift`), so this card's own history goes with it.
    ///
    /// A `KnowledgeUnit` left holding no cards is allowed to stay, exactly as it
    /// is when the last card is deleted from Bilgilerim: the unit carries the
    /// model's reading (`canonicalClaim`) that "Kaynağı göster" prints, and
    /// pruning it is a separate decision from deleting a card.
    private func delete(_ card: Card) {
        context.delete(card)
        // `try?` here is the app-wide pattern (24 call sites); giving these two
        // screens an error surface the neighbouring buttons don't have is the
        // inconsistency PR #44 deliberately avoided.
        try? context.save()
    }

    /// Only on a page the queue has finished with: while it is still working,
    /// the cards under this button are about to change, and adding one to a page
    /// mid-generation would invite a duplicate of a card that is on its way.
    @ViewBuilder
    private func addCardButton(for region: TextRegion?) -> some View {
        if page.processingState.isTerminal {
            Button {
                addTarget = AddCardTarget(region: region)
            } label: {
                Label("Kart ekle", systemImage: "plus.circle")
            }
        }
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
