import SwiftUI
import SwiftData
import CizgiCore

/// "Bu soruyu karşılayan bir kartın var mı?" (plan §7.5) — asked after a miss.
///
/// Three answers, each written through `ExamRecorder` so the rules live in
/// one tested place: a card (linked, its FES gets `.wrong` once per run),
/// "Hiçbiri" (the question goes on "Kitaba dönünce"), or "Atla" (nothing).
/// The candidates come from `ExamBridgeRanking` — deterministic, on the
/// phone, no API.
struct ExamBridgePanel: View {
    let question: ExamQuestion
    let attempt: ExamAttempt
    /// Already ranked, best first.
    let candidates: [Card]
    let onChange: () -> Void

    @Environment(\.modelContext) private var context

    private var outcome: ExamBridgeOutcome? { attempt.bridgeOutcome }
    private var linkedIds: Set<UUID> {
        Set(ExamRecorder(context: context).existingState(for: question.id)?.linkedCards ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.md) {
            Text("Bu soruyu karşılayan bir kartın var mı?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Cizgi.ink)

            switch outcome {
            case .noCard:
                Label("Kitaba dönünce'ye eklendi — kitabı açtığında bu soru neyi çekeceğini söyleyecek.",
                      systemImage: "book.closed")
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
            case .skipped:
                Text("Atlandı.")
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
            default:
                if candidates.isEmpty {
                    Text("Bu konuda kartın yok.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                } else {
                    VStack(spacing: Cizgi.Space.sm) {
                        ForEach(candidates) { card in
                            candidateRow(card)
                        }
                    }
                }
                if outcome != .linked {
                    HStack(spacing: Cizgi.Space.sm) {
                        Button(candidates.isEmpty ? "Kitaba dönünce'ye ekle" : "Hiçbiri — destemde yok") {
                            let recorder = ExamRecorder(context: context)
                            recorder.markNoCard(attempt, at: .now)
                            try? context.save()
                            onChange()
                        }
                        .buttonStyle(CizgiSecondaryButtonStyle(tint: Cizgi.accent))
                        Button("Atla") {
                            ExamRecorder(context: context).skipBridge(attempt)
                            try? context.save()
                            onChange()
                        }
                        .buttonStyle(CizgiSecondaryButtonStyle(tint: Cizgi.muted))
                    }
                } else {
                    Text("Kartın FES'i işlendi. Başka bir kart da karşılıyorsa ona da dokunabilirsin.")
                        .font(.caption)
                        .foregroundStyle(Cizgi.muted)
                }
            }
        }
        .padding(Cizgi.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cizgi.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
    }

    private func candidateRow(_ card: Card) -> some View {
        let isLinked = linkedIds.contains(card.id)
        return Button {
            ExamRecorder(context: context).link(card, to: attempt, at: .now)
            try? context.save()
            onChange()
        } label: {
            HStack(alignment: .top, spacing: Cizgi.Space.sm) {
                Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isLinked ? Cizgi.success : Cizgi.hairline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.front)
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(card.back)
                        .font(.caption)
                        .foregroundStyle(Cizgi.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let topic = card.knowledgeUnit?.topic {
                        Text(topic)
                            .font(.caption2)
                            .foregroundStyle(Cizgi.faint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Cizgi.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .stroke(isLinked ? Cizgi.success : Cizgi.hairline, lineWidth: isLinked ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.front)\(isLinked ? ", bağlandı" : "")")
        .accessibilityHint(isLinked ? "" : "Bu kartı soruya bağlar ve FES'ini işler.")
    }
}

/// The owner's active cards as the bridge ranks them. Shared by the session
/// and the gap screens so both offer the same list for the same question.
enum ExamBridgeCandidates {
    static func rank(for question: ExamQuestion, linked: [UUID], cards: [Card]) -> [Card] {
        let active = cards.filter { $0.status == .active }
        let query = ExamBridgeQuery(
            stem: question.stem,
            correctOption: question.correctOptionText,
            subject: question.subject,
            topic: question.topic,
            linkedCardIds: Set(linked)
        )
        let ranked = ExamBridgeRanking.rank(query, cards: active.map {
            ExamBridgeCard(
                id: $0.id,
                subject: $0.knowledgeUnit?.subject,
                topic: $0.knowledgeUnit?.topic,
                front: $0.front,
                back: $0.back,
                explanation: $0.explanation
            )
        })
        let byId = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byId[$0.cardId] }
    }
}
