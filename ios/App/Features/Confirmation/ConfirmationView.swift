import SwiftUI
import SwiftData
import UIKit
import CizgiCore

/// Photo-first confirmation for a grounded OCR snapshot (ANA-PLAN §6.4,
/// §19.2). The text list below is an accessibility/editor fallback, never the
/// source of a new Vision pass.
struct ConfirmationView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let page: CapturedPage

    @State private var snapshot: OCRSnapshot?
    @State private var image: UIImage?
    @State private var selectedGroupIds = Set<String>()
    @State private var manualEvidence: [AnnotationEvidence] = []
    @State private var manualGroups: [AnnotationGroup] = []
    @State private var isDrawingManualRectangle = false
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Onay hazırlanıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot, let image {
                content(snapshot: snapshot, image: image)
            } else {
                ContentUnavailableView(
                    "Onay verisi bulunamadı",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(errorMessage ?? "Bu sayfanın saklanan OCR görüntüsü açılamadı.")
                )
            }
        }
        .navigationTitle("İşaretlenen bölgeler")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSnapshot() }
        .alert("Hata", isPresented: .constant(errorMessage != nil && !isLoading)) {
            Button("Tamam") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func content(snapshot: OCRSnapshot, image: UIImage) -> some View {
        VStack(spacing: 0) {
            if page.lastError != nil || !page.confirmationFlags.isEmpty {
                disagreementBanner
            }

            PhotoOverlayCanvas(
                image: image,
                groups: snapshot.selection.groups + manualGroups,
                selectedGroupIds: $selectedGroupIds,
                manualEvidence: $manualEvidence,
                manualGroups: $manualGroups,
                isDrawingManualRectangle: $isDrawingManualRectangle
            )
            .accessibilityLabel("Sayfa fotoğrafı ve işaretli bilgi bölgeleri")

            DisclosureGroup("Metni incele (erişilebilirlik)") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(displayLines(snapshot)) { line in
                        Text(line.text)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .font(.footnote)
            .padding(.horizontal)

            footer(snapshot: snapshot)
        }
    }

    private var disagreementBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reason = page.lastError, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            ForEach(page.confirmationFlags, id: \.self) { flag in
                Text(flag)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func footer(snapshot: OCRSnapshot) -> some View {
        VStack(spacing: 8) {
            Text("Yeşil otomatik aday, turuncu kesikli hızlı onay, mor el yazısı notudur. Bölgeye dokunarak seçimi değiştir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(isDrawingManualRectangle ? "Fotoğrafta dikdörtgen çiz" : "Manuel alan ekle") {
                isDrawingManualRectangle.toggle()
            }
            .buttonStyle(.bordered)

            Button {
                Task { await submit(snapshot: snapshot) }
            } label: {
                if isSubmitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Seçili gruplardan kart oluştur").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedGroupIds.isEmpty || isSubmitting)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    private func displayLines(_ snapshot: OCRSnapshot) -> [ConfirmationLine] {
        if let remote = snapshot.remote {
            return remote.page.lines.map { ConfirmationLine(id: $0.lineId, text: $0.text) }
        }
        return snapshot.localLines.map { ConfirmationLine(id: $0.lineId, text: $0.text) }
    }

    private func loadSnapshot() async {
        isLoading = true
        defer { isLoading = false }
        guard
            let data = page.ocrSnapshotData,
            let decoded = try? JSONDecoder().decode(OCRSnapshot.self, from: data)
        else {
            errorMessage = "Saklanan OCR snapshot'ı yok. Bu sayfa yeniden işlenmeli."
            return
        }
        let url = environment.imageStore.url(forRelativePath: page.originalImagePath)
        guard let loaded = UIImage(contentsOfFile: url.path) else {
            errorMessage = "Orijinal sayfa fotoğrafı açılamadı."
            return
        }
        snapshot = decoded
        image = loaded
        selectedGroupIds = Set(decoded.selection.autoSelectedGroupIds)
    }

    private func submit(snapshot: OCRSnapshot) async {
        let chosenGroups = (snapshot.selection.groups + manualGroups)
            .filter { selectedGroupIds.contains($0.id) }
            .map { $0.markedConfirmed() }
        guard !chosenGroups.isEmpty else { return }
        guard chosenGroups.contains(where: {
            $0.selectionType == .manual || !$0.contextText.isEmpty || !$0.selectedText.isEmpty
        }) else {
            errorMessage = "Bağımsız el yazısı notunu önce bir bilgi grubuna bağla."
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }
        let evidenceIds = Set(chosenGroups.flatMap(\.evidenceIds))
        let confirmed = MarkerSelectionResult(
            evidence: (snapshot.selection.evidence + manualEvidence)
                .filter { evidenceIds.contains($0.id) },
            groups: chosenGroups,
            autoSelectedGroupIds: chosenGroups.map(\.id)
        )
        await environment.queue.process(page, selection: confirmed)
        dismiss()
    }
}

private struct ConfirmationLine: Identifiable {
    let id: String
    let text: String
}

private struct PhotoOverlayCanvas: View {
    let image: UIImage
    let groups: [AnnotationGroup]
    @Binding var selectedGroupIds: Set<String>
    @Binding var manualEvidence: [AnnotationEvidence]
    @Binding var manualGroups: [AnnotationGroup]
    @Binding var isDrawingManualRectangle: Bool

    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var manualDragRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let transform = PageOverlayTransform(
                imageWidth: image.size.width,
                imageHeight: image.size.height,
                viewportWidth: proxy.size.width,
                viewportHeight: proxy.size.height,
                zoom: zoom,
                panX: pan.width,
                panY: pan.height
            )
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(
                        width: max(0, transform.renderedWidth),
                        height: max(0, transform.renderedHeight)
                    )
                    .position(
                        x: transform.originX + transform.renderedWidth / 2,
                        y: transform.originY + transform.renderedHeight / 2
                    )

                ForEach(groups) { group in
                    let rect = transform.viewRect(for: group.boundingBox)
                    Button {
                        toggle(group.id)
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color(for: group).opacity(selectedGroupIds.contains(group.id) ? 0.20 : 0.06))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(
                                        color(for: group),
                                        style: group.needsConfirmation
                                            ? StrokeStyle(lineWidth: 2, dash: [6, 4])
                                            : StrokeStyle(lineWidth: 2)
                                    )
                            }
                            .frame(width: max(24, rect.width), height: max(24, rect.height))
                    }
                    .buttonStyle(.plain)
                    .position(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
                    .accessibilityLabel(accessibilityLabel(for: group))
                    .accessibilityAddTraits(selectedGroupIds.contains(group.id) ? .isSelected : [])
                }

                if let manualDragRect {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.blue.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }
                        .frame(width: manualDragRect.width, height: manualDragRect.height)
                        .position(x: manualDragRect.midX, y: manualDragRect.midY)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnificationGesture().onChanged { value in
                    zoom = min(4, max(1, value))
                }
            )
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    if isDrawingManualRectangle {
                        updateManualRectangle(transform: transform, value: value)
                    } else {
                        pan = value.translation
                    }
                }
                .onEnded { value in
                    if isDrawingManualRectangle {
                        finishManualRectangle(transform: transform, value: value)
                    }
                }
            )
        }
        .frame(minHeight: 320, maxHeight: 500)
        .background(.black.opacity(0.06))
    }

    private func toggle(_ id: String) {
        if selectedGroupIds.contains(id) {
            selectedGroupIds.remove(id)
        } else {
            selectedGroupIds.insert(id)
        }
    }

    private func updateManualRectangle(transform: PageOverlayTransform, value: DragGesture.Value) {
        guard transform.normalizedPoint(viewX: value.startLocation.x, viewY: value.startLocation.y) != nil,
              transform.normalizedPoint(viewX: value.location.x, viewY: value.location.y) != nil
        else { return }
        manualDragRect = CGRect(
            x: min(value.startLocation.x, value.location.x),
            y: min(value.startLocation.y, value.location.y),
            width: abs(value.location.x - value.startLocation.x),
            height: abs(value.location.y - value.startLocation.y)
        )
    }

    private func finishManualRectangle(transform: PageOverlayTransform, value: DragGesture.Value) {
        defer {
            manualDragRect = nil
            isDrawingManualRectangle = false
        }
        guard
            let start = transform.normalizedPoint(viewX: value.startLocation.x, viewY: value.startLocation.y),
            let end = transform.normalizedPoint(viewX: value.location.x, viewY: value.location.y)
        else { return }
        let box = NormalizedRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        // A tap remains an overlay toggle; only a visible rectangle becomes a
        // new manual annotation candidate.
        guard box.width >= 0.01, box.height >= 0.01 else { return }

        let id = "manual_\(UUID().uuidString)"
        let evidence = AnnotationEvidence(
            id: id,
            type: .manual,
            boundingBox: box,
            lineIds: [],
            confidence: 1,
            decision: .userSelection
        )
        let group = AnnotationGroup(
            id: "\(id)_group",
            evidenceIds: [id],
            selectedLineIds: [],
            contextLineIds: [],
            boundingBox: box,
            confidence: 1,
            needsConfirmation: false,
            selectionType: .manual
        )
        manualEvidence.append(evidence)
        manualGroups.append(group)
        selectedGroupIds.insert(group.id)
    }

    private func color(for group: AnnotationGroup) -> Color {
        switch group.selectionType {
        case .handwriting: return .purple
        case .manual: return .blue
        default: return group.needsConfirmation ? .orange : .green
        }
    }

    private func accessibilityLabel(for group: AnnotationGroup) -> String {
        let kind: String
        switch group.selectionType {
        case .handwriting: kind = "El yazısı not"
        case .manual: kind = "Kullanıcı seçimi"
        case .highlight: kind = "Fosforlu kalem"
        case .underline: kind = "Alt çizgi"
        case .marginMark: kind = "Kenar işareti"
        }
        return group.needsConfirmation ? "\(kind), hızlı onay gerekli" : kind
    }
}
