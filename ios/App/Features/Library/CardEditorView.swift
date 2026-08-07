import SwiftUI
import SwiftData
import CizgiCore

/// Correcting a card (ANA-PLAN §6.5 "Kartı düzenle", §6.6).
///
/// This is the other half of Faz 6's bargain. Removing the approval step was
/// justified on the grounds that a wrong card could be fixed afterwards
/// (docs/FAZ6-PLAN.md §9, docs/ADR-005) — but nothing to fix it with was ever
/// built, so a misread handwritten note could only be deleted and re-captured.
/// Onaysız üretim ancak düzeltilebiliyorsa makul.
///
/// Reached from both places a bad card is noticed: Bilgilerim, and the review
/// screen itself.
struct CardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let card: Card

    @State private var front = ""
    @State private var back = ""
    @State private var explanation = ""
    @State private var isLoaded = false

    private var validation: CardEditValidation {
        CardEditor.validate(front: front, back: back, explanation: explanation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $front)
                        .frame(minHeight: 80)
                        .font(.body.weight(.medium))
                } header: {
                    header("Soru")
                }

                Section {
                    TextEditor(text: $back)
                        .frame(minHeight: 100)
                } header: {
                    header("Cevap")
                }

                Section {
                    TextEditor(text: $explanation)
                        .frame(minHeight: 100)
                } header: {
                    header("Açıklama")
                } footer: {
                    Text("İsteğe bağlı. Boş bırakırsan kartta hiç görünmez.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }

                if let message = validation.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Cizgi.paper.ignoresSafeArea())
            .navigationTitle("Kartı düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { save() }
                        .disabled(validation.edit == nil)
                }
            }
            // `onAppear` rather than initialising the `@State` from `card`: a
            // `@State` default is captured the first time the view is created
            // and would go stale if the sheet is reopened for a different card.
            .onAppear {
                guard !isLoaded else { return }
                front = card.front
                back = card.back
                explanation = card.explanation ?? ""
                isLoaded = true
            }
        }
        .tint(Cizgi.accent)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Cizgi.ink)
            .textCase(nil)
    }

    /// Scheduling state is deliberately untouched.
    ///
    /// A correction is usually a wording fix on a card the user already knows;
    /// resetting its FSRS history would throw away real evidence about their
    /// memory to no benefit, and would quietly punish them for fixing the
    /// model's mistake. If a card has changed so much that its history is
    /// meaningless, deleting it is the honest move and that is one tap away.
    private func save() {
        guard let edit = validation.edit else { return }
        guard CardEditor.changes(edit, from: card.front, card.back, card.explanation) else {
            dismiss()
            return
        }
        card.front = edit.front
        card.back = edit.back
        card.explanation = edit.explanation
        card.updatedAt = .now
        try? context.save()
        dismiss()
    }
}
