import SwiftUI
import SwiftData
import CizgiCore

/// "Yanlışları gözden geçir" (plan §7.4 e–f): a finished run's misses one by
/// one, key revealed, with the bridge question a mock never asks mid-exam.
///
/// The same `ExamBridgePanel` and `ExamRecorder` as Pratik, so linking a card
/// here writes FES the same way — once per run per card.
struct ExamReviewView: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @Environment(\.dismiss) private var dismiss
    @Query private var runs: [ExamRun]
    @Query private var attempts: [ExamAttempt]
    @State private var index = 0

    init(runId: UUID) {
        _runs = Query(filter: #Predicate<ExamRun> { $0.id == runId })
        _attempts = Query(filter: #Predicate<ExamAttempt> { $0.run?.id == runId })
    }

    /// Misses in the order the run asked them.
    private func misses(_ run: ExamRun, bank: ExamBank) -> [(ExamQuestion, ExamAttempt)] {
        let order = Dictionary(run.queuedQuestionIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return attempts
            .compactMap { attempt -> (ExamQuestion, ExamAttempt)? in
                guard bank.result(questionId: attempt.questionId, selectedOption: attempt.selectedOption).isMiss,
                      let question = bank.question(attempt.questionId) else {
                    return nil
                }
                return (question, attempt)
            }
            .sorted { (order[$0.0.id] ?? .max) < (order[$1.0.id] ?? .max) }
    }

    var body: some View {
        Group {
            if let run = runs.first, let bank = examLibrary.bank {
                let items = misses(run, bank: bank)
                if items.isEmpty {
                    Text("Gözden geçirilecek yanlış yok.")
                        .foregroundStyle(Cizgi.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let current = min(index, items.count - 1)
                    VStack(spacing: Cizgi.Space.md) {
                        ExamReviewPage(question: items[current].0, attempt: items[current].1)
                            .id(items[current].1.id)
                        pager(count: items.count, current: current)
                            .padding(.horizontal, Cizgi.Space.lg)
                            .padding(.bottom, Cizgi.Space.md)
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("Yanlış \(current + 1) / \(items.count)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Cizgi.muted)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ExamReportMenu(questionId: items[current].0.id)
                        }
                    }
                }
            } else {
                Text("Oturum bulunamadı.").foregroundStyle(Cizgi.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pager(count: Int, current: Int) -> some View {
        HStack(spacing: Cizgi.Space.sm) {
            Button {
                index = max(0, current - 1)
            } label: {
                Label("Önceki", systemImage: "chevron.left")
            }
            .buttonStyle(CizgiSecondaryButtonStyle())
            .disabled(current == 0)
            .opacity(current == 0 ? 0.45 : 1)

            if current + 1 < count {
                Button {
                    index = current + 1
                } label: {
                    Label("Sonraki", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(CizgiPrimaryButtonStyle())
            } else {
                Button("Bitti") { dismiss() }
                    .buttonStyle(CizgiPrimaryButtonStyle())
            }
        }
    }
}

/// "Sonraki ›": the icon after the words.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// One missed question with its key, its figure, the bridge and the booklet.
private struct ExamReviewPage: View {
    let question: ExamQuestion
    let attempt: ExamAttempt

    @Query(filter: #Predicate<Card> { $0.statusRaw == "active" }) private var activeCards: [Card]
    @Query private var states: [ExamQuestionState]
    @State private var candidates: [Card] = []
    @State private var revision = 0

    init(question: ExamQuestion, attempt: ExamAttempt) {
        self.question = question
        self.attempt = attempt
        let id = question.id
        _states = Query(filter: #Predicate<ExamQuestionState> { $0.questionId == id })
    }

    var body: some View {
        ScrollView {
            ReviewCardFace(
                content: StudyFaceContent(question: question, reportedIssue: states.first?.reportedIssue),
                isAnswerVisible: true
            ) {
                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    if question.hasFigure { ExamFigureView(question: question) }
                    ExamOptionList(question: question, selected: attempt.selectedOption, isRevealed: true)
                }
            } footer: {
                VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                    ExamResultLine(question: question, selectedOption: attempt.selectedOption)
                    ExamBridgePanel(question: question, attempt: attempt, candidates: candidates) {
                        revision += 1
                    }
                    .id(revision)
                    DisclosureGroup("Kaynağı göster") {
                        ExamSourceView(question: question).padding(.top, Cizgi.Space.sm)
                    }
                    .font(.subheadline)
                    .tint(Cizgi.accent)
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.top, Cizgi.Space.sm)
            .padding(.bottom, Cizgi.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            candidates = ExamBridgeCandidates.rank(
                for: question,
                linked: states.first?.linkedCards ?? [],
                cards: activeCards
            )
        }
    }
}
