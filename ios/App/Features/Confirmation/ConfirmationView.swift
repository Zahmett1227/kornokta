import SwiftUI
import SwiftData
import CizgiCore

/// Confirmation screen (ANA-PLAN §6.4, §5.3).
///
/// Faz 1 has no on-device marker detection yet, so every capture lands here and
/// the user taps the lines they marked. That is the honest behaviour for now:
/// §19.3 says a capture with no detected marker and no manual selection must
/// not become a card. Faz 2 adds detection and this screen shrinks to the
/// genuinely ambiguous cases.
struct ConfirmationView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let page: CapturedPage

    @State private var lines: [RecognizedLine] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Sayfa okunuyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView(
                    "Metin bulunamadı",
                    systemImage: "doc.questionmark",
                    description: Text("Bu sayfada okunabilir satır yok. Yeniden çekmeyi dene.")
                )
            } else {
                content
            }
        }
        .navigationTitle("İşaretlediğin yeri seç")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLines() }
        .alert("Hata", isPresented: .constant(errorMessage != nil)) {
            Button("Tamam") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            List {
                if page.lastError != nil || !page.confirmationFlags.isEmpty {
                    disagreementSection
                }

                Section {
                    ForEach(lines) { line in
                        Button {
                            toggle(line.id)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selected.contains(line.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(line.id) ? .green : .secondary)
                                Text(line.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(line.id) ? [.isSelected] : [])
                    }
                } header: {
                    Text("Karta dönüşmesini istediğin satırlara dokun")
                } footer: {
                    Text("Seçtiğin satırlar sırayla tek bir pasaj olur.")
                }
            }

            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !selected.isEmpty {
                Text(passagePreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal)
            }

            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Kart oluştur").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected.isEmpty || isSubmitting)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    /// Why the page is here (§19.2).
    ///
    /// A confirmation with no reason attached is one the user cannot answer
    /// well: "check this page" invites a reflexive tap, while "IM okundu, IV
    /// yazıyor" is a question with an answer. The flags are shown verbatim —
    /// they name both readings, which is the whole point of the ordered
    /// comparison producing them.
    @ViewBuilder
    private var disagreementSection: some View {
        Section {
            if let reason = page.lastError, !reason.isEmpty {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
            ForEach(page.confirmationFlags, id: \.self) { flag in
                Text(flag)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Neden soruluyor")
        } footer: {
            Text("İki okuma bu değerlerde ayrıştı. Kaynak sayfaya bakıp doğru olanı seç; hiçbir değer senin onayın olmadan kaydedilmiyor.")
        }
    }

    private var passagePreview: String {
        lines.filter { selected.contains($0.id) }.map(\.text).joined(separator: " ")
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func loadLines() async {
        isLoading = true
        defer { isLoading = false }

        let url = environment.imageStore.url(forRelativePath: page.originalImagePath)
        #if canImport(Vision)
        let recognizer = VisionTextRecognizer()
        #else
        let recognizer = UnavailableRecognizer()
        #endif
        do {
            lines = try await recognizer.recognize(imageAt: url).lines
        } catch {
            errorMessage = "Sayfa okunamadı: \(error.localizedDescription)"
            lines = []
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        // Resume the job with the user's selection; the queue owns persistence
        // so replaying cannot create a second set of cards (§17).
        await environment.queue.process(page, selection: Array(selected))
        dismiss()
    }
}
