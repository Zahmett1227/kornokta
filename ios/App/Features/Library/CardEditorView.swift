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
    /// The kind of card, chosen directly rather than only inferred from whether
    /// the options are sound. Kept in lockstep with `options` by
    /// `CardTypeChange` — see `applyTypeChange`.
    @State private var selectedType: CardType = .directRecall
    /// Options put aside by a switch to a plain type, so changing your mind
    /// inside the same sheet does not cost four retyped distractors. Not
    /// persisted: dismissing the sheet drops it, which is the same "unsaved
    /// edits are lost" the rest of the form already has.
    @State private var optionStash: [CardOption]?
    /// Empty string means "Seçilmedi"/"Konusuz" — `Picker` tags cannot be nil.
    @State private var subject = ""
    @State private var topic = ""

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

    /// The type as it will actually be stored: the picked one, with
    /// `resolvedType` as the same final guard every other save path uses.
    private var resolvedType: CardType {
        MultipleChoice.resolvedType(current: selectedType, options: editedOptions)
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

                typeSection

                classificationSection

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
                // Resolved rather than taken raw, so the invariant holds from
                // the first frame: a card stored as `.multipleChoice` whose
                // options no longer decode has nothing to choose from, and
                // showing "Beş şık" over an absent options section would offer
                // no way back. It opens as what it actually is.
                selectedType = MultipleChoice.resolvedType(current: card.type, options: card.options)
                subject = SubjectPickerBar.canonicalSubject(card.knowledgeUnit?.subject) ?? ""
                topic = card.knowledgeUnit?.topic ?? ""
                isLoaded = true
            }
        }
        .tint(Cizgi.accent)
    }

    /// Clearing the topic belongs to the *setter*, not to `onChange`.
    ///
    /// `onAppear` loads the card by assigning straight to `@State`, and an
    /// `onChange(of: subject)` observer could not tell that initial write apart
    /// from a real edit: opening any classified card fired it, wiped the topic
    /// that had just been loaded, and the next save persisted the card as
    /// "Konusuz" without the user touching the ders (Codex, PR #32). A binding
    /// setter only ever runs from the Picker itself.
    private var subjectBinding: Binding<String> {
        Binding(
            get: { subject },
            set: { newValue in
                guard newValue != subject else { return }
                subject = newValue
                // Topic names are unique only within a subject, so one can
                // never carry over to another ders.
                topic = ""
            }
        )
    }

    /// Kart tipi. The model picks one at generation; this is where a card that
    /// should have been a beş şık — or should never have been one — is changed.
    ///
    /// The binding routes every pick through `applyTypeChange` rather than
    /// assigning `selectedType`, so the picker cannot leave the type and the
    /// option list disagreeing.
    private var typeSection: some View {
        Section {
            Picker("Kart tipi", selection: typeBinding) {
                ForEach(CardType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.icon).tag(type)
                }
            }
        } header: {
            header("Kart tipi")
        } footer: {
            Text(selectedType == .multipleChoice
                 ? "Beş şıklı kartta cevap, aşağıda işaretlediğin doğru şıktır."
                 : "Düz kartta soru ve cevabı sen yazarsın.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        }
    }

    private var typeBinding: Binding<CardType> {
        Binding(
            get: { selectedType },
            set: { applyTypeChange(to: $0) }
        )
    }

    /// The single door onto "this card is now a different kind".
    ///
    /// Both the picker and "Şıkları kaldır" come through here so the invariant
    /// `options UI visible ⟺ .multipleChoice ⟺ options non-empty` holds without
    /// anyone having to remember it. The decision itself is in `CardTypeChange`,
    /// where `swift test` can hold it still.
    private func applyTypeChange(to newType: CardType) {
        // Re-picking the type already selected is not an edit. Without this,
        // tapping the ticked row rebuilds every option row with a fresh id and
        // takes the keyboard focus with it, mid-sentence.
        guard newType != selectedType else { return }

        let effect = CardTypeChange.effect(
            picking: newType,
            currentType: selectedType,
            derivedBack: effectiveBack,
            currentOptions: editedOptions ?? [],
            stash: optionStash
        )
        switch effect {
        case .setTypeOnly(let type):
            selectedType = type
        case .enterMultipleChoice(let seeded):
            options = seeded.map { EditableOption(text: $0.text, why: $0.why ?? "", isCorrect: $0.isCorrect) }
            selectedType = .multipleChoice
        case .leaveMultipleChoice(let type, let derivedBack, let stash):
            // The answer is written down before the options go, or it goes with
            // them (Codex, PR #29).
            back = derivedBack
            optionStash = stash
            options = []
            selectedType = type
        }
    }

    /// Ders/konu (schema v2.2). The model assigns these at capture time; this
    /// is where a wrong guess — or a card captured before the feature existed —
    /// gets corrected.
    @ViewBuilder
    private var classificationSection: some View {
        if let schema = SubjectTopicSchema.shared {
            Section {
                Picker("Ders", selection: subjectBinding) {
                    Text("Seçilmedi").tag("")
                    ForEach(schema.subjectNames, id: \.self) { Text($0).tag($0) }
                }

                if let topics = schema.topics(for: subject) {
                    Picker("Konu", selection: $topic) {
                        Text("Konusuz").tag("")
                        ForEach(topics, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                header("Sınıflandırma")
            } footer: {
                Text("Kartın dersi ve konusu; Bilgilerim ve Egzersiz "
                     + "filtrelerinde kullanılır.")
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
            }
        }
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

            // Same operation as picking a plain type above, so it goes through
            // the same funnel: `.directRecall` is `resolvedType`'s own
            // degradation target, which is what stops the button and the picker
            // from ever disagreeing about what a card without options becomes.
            Button("Şıkları kaldır", role: .destructive) {
                applyTypeChange(to: .directRecall)
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
        // Without this a pure type change (beş şık → mekanizma, say) would fall
        // into the "nothing to write" branch below and be dropped silently.
        let typeChanged = resolvedType != card.type
        applyClassification()
        guard CardEditor.changes(edit, from: card.front, card.back, card.explanation)
            || optionsChanged || typeChanged else {
            // Still saved: `applyClassification` may have moved the card even
            // when its text is untouched.
            try? context.save()
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
        }
        // Removing the options has to leave a usable plain card, not a
        // five-option card with nothing to choose from (§13.3). `resolvedType`
        // stays the last word even though the picker already maintains the
        // invariant — it is the rule every save path in the app shares.
        card.type = resolvedType
        card.updatedAt = .now
        try? context.save()
        dismiss()
    }

    /// Moves the card onto a unit carrying the chosen ders/konu.
    ///
    /// Always find-or-create-and-rebind rather than writing the new values onto
    /// the current unit: a unit is shared by every card on the page that got the
    /// same topic, so editing it in place would silently reclassify its
    /// siblings. Re-binding touches exactly the card in front of the user. A
    /// unit left with no cards is harmless — it keeps its region, which is what
    /// "Kaynağı göster" reads.
    private func applyClassification() {
        let newSubject = subject.isEmpty ? nil : subject
        let newTopic = topic.isEmpty ? nil : topic
        let current = card.knowledgeUnit
        guard current?.subject != newSubject || current?.topic != newTopic else { return }

        // Nothing to share with, and nothing to preserve: a fresh unit is the
        // only way a unitless card can carry a subject at all.
        guard let current else {
            let unit = KnowledgeUnit(canonicalClaim: card.front, subject: newSubject, topic: newTopic)
            context.insert(unit)
            card.knowledgeUnit = unit
            card.updatedAt = .now
            return
        }

        // The card is alone on its unit: no sibling can be affected, so the
        // unit itself moves and its region link and claim survive intact.
        if current.cards.count <= 1 {
            current.subject = newSubject
            current.topic = newTopic
            current.updatedAt = .now
            card.updatedAt = .now
            return
        }

        // Shared with the manual-card sheet: the same "find the unit carrying
        // this pair, or make one on the same region" decision, written once
        // (`KnowledgeUnitBinding`). The old `$0.id != current.id` filter is not
        // needed — the guard above already established that `current`'s pair is
        // not the one being looked for.
        card.knowledgeUnit = KnowledgeUnitBinding.findOrCreate(
            on: current.region,
            subject: newSubject,
            topic: newTopic,
            claim: current.canonicalClaim,
            tags: current.tags,
            sourceConcern: current.sourceConcern,
            context: context
        )
        card.updatedAt = .now
    }
}
