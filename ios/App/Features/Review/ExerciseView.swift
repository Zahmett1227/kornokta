import SwiftUI
import SwiftData
import CizgiCore

/// Egzersiz modu — free practice over the whole deck, independent of FSRS.
///
/// Same question → "Cevabı göster" → answer rhythm as `ReviewView`, and the
/// same card-edit affordance, but **nothing is written**: no `ReviewLog`, no
/// scheduling update, no daily new-card ledger entry. That is the point — going
/// over a subject before an exam should not disturb a spaced-repetition history
/// that took months to build, and the grade buttons are what would.
///
/// The queue itself (shuffle, position, finish) lives in `ExerciseSession` so
/// `swift test` covers it; this file is the shell.
struct ExerciseView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Card.createdAt, order: .reverse) private var allCards: [Card]

    @State private var session: ExerciseSession?
    @State private var isAnswerVisible = false
    @State private var selectedOption: Int?
    @State private var editingCard: Card?
    @State private var subjectFilter: String?
    @State private var topicFilter: TopicFilter = .all

    /// Suspended cards stay out — the user has said they do not want to see
    /// them. Everything else is fair game regardless of its due date, which is
    /// the whole difference from `ReviewView`.
    private var eligibleCards: [Card] {
        allCards.filter { card in
            card.status != .suspended
                && LibraryCardFilter.matches(
                    subject: card.knowledgeUnit?.subject,
                    topic: card.knowledgeUnit?.topic,
                    subjectFilter: subjectFilter,
                    topicFilter: topicFilter
                )
        }
    }

    private var currentCard: Card? {
        guard let id = session?.current else { return nil }
        return allCards.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Cizgi.paper.ignoresSafeArea()
            Group {
                if let session, !session.isFinished {
                    if let card = currentCard {
                        cardBody(card, session: session)
                    } else {
                        // Deleted from the editor mid-session. Keyed on `total`
                        // and not `completed`, unlike ReviewView: dropping a
                        // missing card shrinks the queue without moving the
                        // cursor, so `completed` would stay put, SwiftUI would
                        // reuse this view, `onAppear` would never fire again
                        // and a *run* of deleted cards would park the session
                        // on a blank screen.
                        Color.clear
                            .onAppear { skipCurrentCard() }
                            .id(session.total)
                    }
                } else if session != nil {
                    completionScreen
                } else {
                    startScreen
                }
            }
        }
        .navigationTitle("Egzersiz")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let session, !session.isFinished {
                    Text("\(session.completed + 1) / \(session.total)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Cizgi.muted)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let card = currentCard {
                    // Kept from the review screen on purpose: the exercise run
                    // is exactly where a wrong card gets noticed.
                    Button {
                        editingCard = card
                    } label: {
                        Label("Kartı düzenle", systemImage: "pencil")
                    }
                    .tint(Cizgi.accent)
                    .disabled(session?.isFinished ?? true)
                    .accessibilityLabel("Kartı düzenle")
                } else if session == nil {
                    SubjectTopicFilterMenu(subjectFilter: $subjectFilter, topicFilter: $topicFilter)
                }
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(card: card)
        }
        .tint(Cizgi.accent)
    }

    // MARK: Start

    @ViewBuilder
    private var startScreen: some View {
        let count = eligibleCards.count
        VStack(spacing: Cizgi.Space.xl) {
            VStack(spacing: Cizgi.Space.xs) {
                Text("\(count)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Cizgi.ink)
                Text("kart hazır")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
            }

            ActiveFilterChips(subjectFilter: $subjectFilter, topicFilter: $topicFilter)
                .padding(.horizontal, Cizgi.Space.lg)

            if count == 0 {
                Text("Bu filtreye uyan kart yok.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
            } else {
                Button("Başla") { start() }
                    .buttonStyle(CizgiPrimaryButtonStyle())
                    .padding(.horizontal, Cizgi.Space.xl)
            }

            Text("Karışık sırada; puanlama yok, tekrar planın değişmez.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Cizgi.Space.xl)
        }
        .padding(Cizgi.Space.xl)
    }

    @ViewBuilder
    private var completionScreen: some View {
        VStack(spacing: Cizgi.Space.lg) {
            VStack(spacing: Cizgi.Space.md) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Cizgi.accent)
                Text("Egzersiz bitti")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Cizgi.ink)
                Text("\(session?.total ?? 0) kart gözden geçirildi.")
                    .font(.subheadline)
                    .foregroundStyle(Cizgi.muted)
            }
            Button("Baştan karıştır") { restart() }
                .buttonStyle(CizgiPrimaryButtonStyle())
                .padding(.horizontal, Cizgi.Space.xl)
            Button("Bitir") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.accent)
        }
        .padding(Cizgi.Space.xl)
    }

    // MARK: Card

    private func cardBody(_ card: Card, session: ExerciseSession) -> some View {
        VStack(spacing: Cizgi.Space.lg) {
            progressBar(session)

            ScrollView {
                flashcard(card)
                    .padding(.horizontal, Cizgi.Space.lg)
                    .padding(.top, Cizgi.Space.sm)
            }

            actionArea(card)
                .padding(.horizontal, Cizgi.Space.lg)
                .padding(.bottom, Cizgi.Space.md)
        }
        .padding(.top, Cizgi.Space.sm)
    }

    private func progressBar(_ session: ExerciseSession) -> some View {
        GeometryReader { geo in
            let fraction = session.total == 0 ? 0 : Double(session.completed) / Double(session.total)
            ZStack(alignment: .leading) {
                Capsule().fill(Cizgi.hairline)
                Capsule().fill(Cizgi.highlighter)
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .padding(.horizontal, Cizgi.Space.lg)
    }

    private func flashcard(_ card: Card) -> some View {
        CardSurface(highlighted: true, padding: Cizgi.Space.xl) {
            VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                HStack(spacing: Cizgi.Space.sm) {
                    CardTypeBadge(type: card.type)
                    if let topic = card.knowledgeUnit?.topic {
                        TagChip(topic, systemImage: "tag")
                    }
                    if card.lowConfidence {
                        TagChip("Gözden geçir", systemImage: "exclamationmark.triangle.fill")
                    }
                }

                Text(card.front)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Cizgi.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let options = card.options {
                    optionList(card, options: options)
                }

                if isAnswerVisible {
                    Rectangle().fill(Cizgi.hairline).frame(height: 1)

                    if card.options == nil {
                        Text(card.back)
                            .font(.title3)
                            .foregroundStyle(Cizgi.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let explanation = card.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(Cizgi.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let source = CardSourceView.material(for: card, imageStore: environment.imageStore)
                    if !source.isEmpty {
                        DisclosureGroup("Kaynağı göster") {
                            CardSourceView(material: source, imageStore: environment.imageStore)
                                .padding(.top, Cizgi.Space.sm)
                        }
                        .font(.subheadline)
                        .tint(Cizgi.accent)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isAnswerVisible)
    }

    @ViewBuilder
    private func actionArea(_ card: Card) -> some View {
        if isAnswerVisible {
            // One button where the review screen has four. Nothing to record,
            // so nothing to ask.
            Button("Sıradaki") { advance() }
                .buttonStyle(CizgiPrimaryButtonStyle())
        } else if card.options != nil {
            Text("Bir şık seç")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
                .frame(maxWidth: .infinity)
        } else {
            Button("Cevabı göster") {
                withAnimation { isAnswerVisible = true }
            }
            .buttonStyle(CizgiPrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private func optionList(_ card: Card, options: [CardOption]) -> some View {
        let order = MultipleChoice.presentationOrder(
            cardId: card.id,
            reviewCount: card.reviewCount,
            count: options.count
        )
        VStack(spacing: Cizgi.Space.sm) {
            ForEach(order, id: \.self) { index in
                optionRow(card, options: options, index: index)
            }
        }
    }

    private func optionRow(_ card: Card, options: [CardOption], index: Int) -> some View {
        let option = options[index]
        let picked = selectedOption == index
        let revealed = isAnswerVisible
        let tint: Color = revealed
            ? (option.isCorrect ? Cizgi.success : (picked ? Cizgi.danger : Cizgi.muted))
            : Cizgi.ink
        let icon: String? = revealed
            ? (option.isCorrect ? "checkmark.circle.fill" : (picked ? "xmark.circle.fill" : nil))
            : nil

        return Button {
            guard !isAnswerVisible else { return }
            withAnimation {
                selectedOption = index
                isAnswerVisible = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Cizgi.Space.sm) {
                    if let icon {
                        Image(systemName: icon).foregroundStyle(tint)
                    }
                    Text(option.text)
                        .font(.body)
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if revealed, !option.isCorrect, let why = option.why, !why.isEmpty {
                    Text(why)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Cizgi.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .stroke(revealed && (option.isCorrect || picked) ? tint : Cizgi.hairline,
                            lineWidth: revealed && (option.isCorrect || picked) ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAnswerVisible)
        .accessibilityLabel(
            revealed
                ? "\(option.text), \(option.isCorrect ? "doğru cevap" : (picked ? "senin seçimin, yanlış" : "yanlış"))"
                : option.text
        )
    }

    // MARK: Actions

    private func start() {
        var generator = SystemRandomNumberGenerator()
        session = ExerciseSession(cardIds: eligibleCards.map(\.id), using: &generator)
        resetCardState()
    }

    private func restart() {
        var generator = SystemRandomNumberGenerator()
        session?.restart(using: &generator)
        resetCardState()
    }

    private func advance() {
        session?.advance()
        resetCardState()
    }

    private func skipCurrentCard() {
        guard let id = session?.current else { return }
        session?.remove(id)
        resetCardState()
    }

    private func resetCardState() {
        isAnswerVisible = false
        selectedOption = nil
    }
}
