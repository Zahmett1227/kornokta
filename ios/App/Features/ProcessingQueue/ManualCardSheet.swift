import SwiftUI
import SwiftData
import CizgiCore

/// Writing a card by hand on the page it belongs to (2026-08-15).
///
/// Opened from the page detail screen, with the photo and the model's reading
/// still one tap away. That placement is the whole point: the model's dangerous
/// failure is not a wrong card but a *missing* one, and nothing automatic can
/// see it — an ungenerated card carries no `lowConfidence`
/// (`docs/PLAN-model-karsilastirma.md`). Only the person who marked the page
/// knows what is not there, and only while looking at it.
///
/// The rules are in `ManualCardDraft`; this view collects text and picks.
struct ManualCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let page: CapturedPage
    /// The passage the card is being added under. `nil` when the page produced
    /// none at all — a failed or empty job — in which case one is made on save.
    let region: TextRegion?

    @State private var draft = ManualCardDraft()
    @State private var isLoaded = false

    private let schema = SubjectTopicSchema.shared

    /// The page's own ders, canonicalised. Non-nil means the ders is settled and
    /// the picker stays off screen: the card belongs to the page it is being
    /// added to, and offering to change that here would only be a way to file it
    /// under the wrong one.
    private var lockedSubject: String? {
        schema?.canonicalSubject(matching: page.source?.subject)
    }

    private var validation: ManualCardValidation {
        draft.validate(schema: schema)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft.front)
                        .frame(minHeight: 80)
                        .font(.body.weight(.medium))
                } header: {
                    header("Soru")
                }

                Section {
                    TextEditor(text: $draft.back)
                        .frame(minHeight: 100)
                } header: {
                    header("Cevap")
                } footer: {
                    if draft.type == .multipleChoice {
                        Text("Beş şıklı kartta cevap, doğru şık olarak kullanılır; "
                             + "aşağıya yalnız yanlış şıkları yazarsın.")
                            .font(.footnote)
                            .foregroundStyle(Cizgi.muted)
                    }
                }

                Section {
                    TextEditor(text: $draft.explanation)
                        .frame(minHeight: 80)
                } header: {
                    header("Açıklama")
                } footer: {
                    Text("İsteğe bağlı. Boş bırakırsan kartta hiç görünmez.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }

                typeSection

                if draft.type == .multipleChoice {
                    distractorsSection
                }

                classificationSection

                if let message = validation.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.danger)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Cizgi.paper.ignoresSafeArea())
            .navigationTitle("Kart ekle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { save() }
                        .disabled(validation.card == nil)
                }
            }
            // Same reason as the editor's: a `@State` default is captured when
            // the view is first created and would go stale if the sheet is
            // reopened for another page.
            .onAppear {
                guard !isLoaded else { return }
                draft.subject = lockedSubject
                isLoaded = true
            }
        }
        .tint(Cizgi.accent)
    }

    private var typeSection: some View {
        Section {
            Picker("Kart tipi", selection: $draft.type) {
                ForEach(CardType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.icon).tag(type)
                }
            }
        } header: {
            header("Kart tipi")
        }
    }

    /// The four wrong options. The fifth is the answer, which is why this list is
    /// four long and has no "which one is correct" control: on a hand-written
    /// card the answer cannot drift away from the correct option, because there
    /// is nothing to move.
    private var distractorsSection: some View {
        Section {
            ForEach(draft.distractors.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
                    TextField("Yanlış şık \(index + 1)", text: $draft.distractors[index].text, axis: .vertical)
                    TextField(
                        "Neden yanlış (isteğe bağlı)",
                        text: $draft.distractors[index].why,
                        axis: .vertical
                    )
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
                }
                .padding(.vertical, 2)
            }
        } header: {
            header("Yanlış şıklar")
        } footer: {
            Text("Dördü de dolu olmalı ve cevaptan farklı olmalı — beş şık, tek doğru cevap.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
        }
    }

    /// Ders/konu. The topic comes from the subject's own template list; typing a
    /// new one is not offered, because a name outside the template is a name
    /// Bilgi Haritası can never place on a canonical node.
    @ViewBuilder
    private var classificationSection: some View {
        if let schema {
            Section {
                if let locked = lockedSubject {
                    LabeledContent("Ders", value: locked)
                } else {
                    Picker("Ders", selection: subjectBinding) {
                        Text("Seçilmedi").tag("")
                        ForEach(schema.subjectNames, id: \.self) { Text($0).tag($0) }
                    }
                }

                if let topics = schema.topics(for: draft.subject ?? "") {
                    Picker("Konu", selection: topicBinding) {
                        Text("Seçilmedi").tag("")
                        ForEach(topics, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                header("Sınıflandırma")
            } footer: {
                Text(lockedSubject == nil
                     ? "Bu sayfada ders seçilmemiş; kartın dersini ve konusunu burada seç."
                     : "Konu, sayfanın dersinin şablonundan seçilir.")
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
            }
        }
    }

    /// Clearing the topic belongs to the setter, not to `onChange` — the lesson
    /// `CardEditorView.subjectBinding` records (Codex, PR #32).
    private var subjectBinding: Binding<String> {
        Binding(
            get: { draft.subject ?? "" },
            set: { newValue in
                guard newValue != draft.subject else { return }
                draft.subject = newValue.isEmpty ? nil : newValue
                // Topic names are unique only within a subject.
                draft.topic = nil
            }
        )
    }

    private var topicBinding: Binding<String> {
        Binding(
            get: { draft.topic ?? "" },
            set: { draft.topic = $0.isEmpty ? nil : $0 }
        )
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Cizgi.ink)
            .textCase(nil)
    }

    /// Inserts the card the same way the generator's `persist` does, so a
    /// hand-written card is indistinguishable from a generated one once saved.
    private func save() {
        guard let manual = validation.card else { return }

        // A page whose job produced nothing has no region, and a card with no
        // region has no "Kaynağı göster". One is made here, marked `.manual` and
        // with empty text: the photo is real, the reading is not.
        let target = region ?? page.regions.first ?? makeRegion()

        let unit = KnowledgeUnitBinding.findOrCreate(
            on: target,
            subject: manual.subject,
            topic: manual.topic,
            // The card's own question, never the model's page text: claiming the
            // model read something for a card it never produced would be a lie
            // dressed as provenance, and `CardSourceResolver` drops a read text
            // equal to the front for exactly that reason.
            claim: manual.front,
            context: context
        )

        let card = Card(
            type: manual.type,
            front: manual.front,
            back: manual.back,
            explanation: manual.explanation,
            // Explicit: `Card.init` defaults to `.draft`, and a draft card is
            // silently absent from Tekrar, Egzersiz and Bilgilerim. Everything
            // else — `dueDate = .now`, zeroed FSRS state — is the init's own
            // default and is exactly what the generator's cards get.
            status: .active,
            options: manual.options
        )
        card.knowledgeUnit = unit
        context.insert(card)
        try? context.save()
        dismiss()
    }

    private func makeRegion() -> TextRegion {
        let region = TextRegion(
            boundingBox: (0, 0, 1, 1),
            lineIds: [],
            finalText: "",
            confidence: 1,
            selectionType: .manual
        )
        region.page = page
        context.insert(region)
        return region
    }
}
