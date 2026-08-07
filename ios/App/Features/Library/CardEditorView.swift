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
    /// Editable copies of the five options; empty when this is a plain card.
    @State private var options: [EditableOption] = []

    /// A row in the option editor. `id` is stable across edits so SwiftUI does
    /// not lose the keyboard focus every time a character is typed.
    private struct EditableOption: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var why: String
        var isCorrect: Bool
    }

    private var validation: CardEditValidation {
        CardEditor.validate(front: front, back: effectiveBack, explanation: explanation)
    }

    /// On a five-option card the answer key **is** the ticked option, so `back`
    /// is derived from it rather than edited separately.
    ///
    /// Without this, moving the tick to another option left `back` on the old
    /// answer: the review screen marked the new option correct while Bilgilerim,
    /// search and every backup still carried the old one (Codex, PR #29). The
    /// server holds the same invariant (`back_rewritten` in `multipleChoice.ts`);
    /// the editor was the one place it could be broken.
    private var effectiveBack: String {
        guard let editedOptions, case .valid = MultipleChoice.validate(editedOptions) else { return back }
        return editedOptions.first(where: \.isCorrect)?.text ?? back
    }

    private var editedOptions: [CardOption]? {
        guard !options.isEmpty else { return nil }
        return options.map {
            CardOption(
                text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                isCorrect: $0.isCorrect,
                why: $0.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : $0.why.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// `nil` when there is nothing to complain about — either a plain card or a
    /// sound set of options.
    private var optionValidation: MultipleChoiceValidation? {
        guard let editedOptions else { return nil }
        let result = MultipleChoice.validate(editedOptions)
        return result == .valid ? nil : result
    }

    private var canSave: Bool {
        validation.edit != nil && optionValidation == nil
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

                if options.isEmpty {
                    Section {
                        TextEditor(text: $back)
                            .frame(minHeight: 100)
                    } header: {
                        header("Cevap")
                    }
                } else {
                    Section {
                        Text(effectiveBack.isEmpty ? "—" : effectiveBack)
                            .foregroundStyle(Cizgi.ink)
                    } header: {
                        header("Cevap")
                    } footer: {
                        Text("Beş şıklı kartta cevap, işaretlediğin doğru şıktır; "
                             + "ayrıca yazılmaz. Şıkları kaldırırsan yeniden düzenlenebilir.")
                    }
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

                if !options.isEmpty {
                    optionsSection
                }

                if let message = validation.message ?? optionValidation?.message {
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
                        .disabled(!canSave)
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
                options = (card.options ?? []).map {
                    EditableOption(text: $0.text, why: $0.why ?? "", isCorrect: $0.isCorrect)
                }
                isLoaded = true
            }
        }
        .tint(Cizgi.accent)
    }

    /// The five options (§13.3): text, which one is correct, and why each wrong
    /// one is wrong.
    private var optionsSection: some View {
        Section {
            ForEach($options) { $option in
                VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
                    HStack(alignment: .top, spacing: Cizgi.Space.sm) {
                        // Radio rather than a toggle per row: §13.3 allows
                        // exactly one correct answer, so choosing one has to
                        // clear the others rather than leave two ticked.
                        Button {
                            let chosen = option.id
                            for index in options.indices {
                                options[index].isCorrect = options[index].id == chosen
                            }
                        } label: {
                            Image(systemName: option.isCorrect ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(option.isCorrect ? Cizgi.success : Cizgi.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.isCorrect ? "Doğru şık" : "Doğru şık yap")

                        TextField("Şık", text: $option.text, axis: .vertical)
                    }
                    if !option.isCorrect {
                        TextField("Neden yanlış (isteğe bağlı)", text: $option.why, axis: .vertical)
                            .font(.footnote)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
                .padding(.vertical, 2)
            }

            Button("Şıkları kaldır", role: .destructive) {
                // The derived answer is written down *before* the options go,
                // or it goes with them: after moving the tick from A to B and
                // then removing the options, `effectiveBack` would fall back to
                // the stale `back` (A) and save it as the card's answer — the
                // user's last choice lost without a word (Codex, PR #29).
                back = effectiveBack
                options = []
            }
        } header: {
            header("Şıklar")
        } footer: {
            Text("Beş şık, tek doğru cevap. Şıkları kaldırırsan kart düz kart "
                 + "olarak kalır — silinmez.")
        }
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
        guard let edit = validation.edit, optionValidation == nil else { return }
        let optionsChanged = editedOptions != card.options
        guard CardEditor.changes(edit, from: card.front, card.back, card.explanation) || optionsChanged else {
            dismiss()
            return
        }
        card.front = edit.front
        // `edit.back` is already `effectiveBack`, i.e. the ticked option on a
        // five-option card — the answer and the answer key cannot drift apart.
        card.back = edit.back
        card.explanation = edit.explanation
        if optionsChanged {
            card.options = editedOptions
            // Removing the options has to leave a usable plain card, not a
            // five-option card with nothing to choose from (§13.3).
            card.type = MultipleChoice.resolvedType(current: card.type, options: editedOptions)
        }
        card.updatedAt = .now
        try? context.save()
        dismiss()
    }
}
