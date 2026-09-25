import SwiftUI
import SwiftData
import CizgiCore

/// How a finished run scored — the one computation the result screen, the
/// home screen's history and the comparison line share, so they can never
/// show two different nets for the same run.
///
/// A mock is scored over its whole queue (an unreached question is blank on
/// the answer sheet); a Pratik run over what was answered — stopping a
/// practice early must not turn the rest of the queue into blanks.
enum ExamRunScore {
    static func answers(for run: ExamRun, attempts: [ExamAttempt], bank: ExamBank) -> [ExamScoredAnswer] {
        if run.mode == .mock {
            let marks = Dictionary(
                attempts.map { ($0.questionId, (selectedOption: $0.selectedOption, responseTimeMs: $0.responseTimeMs)) },
                uniquingKeysWith: { first, _ in first }
            )
            return bank.mockScoredAnswers(queue: run.queuedQuestionIds, answers: marks)
        }
        return bank.scoredAnswers(attempts.map {
            ($0.questionId, bank.result(questionId: $0.questionId, selectedOption: $0.selectedOption), $0.responseTimeMs)
        })
    }

    static func score(for run: ExamRun, attempts: [ExamAttempt], bank: ExamBank) -> ExamScore {
        ExamScoring.score(answers(for: run, attempts: attempts, bank: bank))
    }

    /// "2019 İlkbahar · Temel", "Karma deneme · Klinik", "Pratik".
    static func title(for run: ExamRun, bank: ExamBank) -> String {
        if run.mode == .mock {
            if let paper = run.paperId.flatMap({ bank.papersById[$0] }) { return ExamText.paperName(paper) }
            let group = run.filter.testGroups.first.map(ExamText.testGroup) ?? "karışık"
            return "Karma deneme · \(group)"
        }
        return ExamText.mode(run.mode)
    }

    /// The same kind of sitting before this one: the same paper, or a mixed
    /// mock of the same group.
    static func previous(of run: ExamRun, among runs: [ExamRun]) -> ExamRun? {
        guard run.mode == .mock else { return nil }
        return runs
            .filter { other in
                other.id != run.id && other.mode == .mock && other.finishedAt != nil && other.startedAt < run.startedAt
                    && (run.paperId != nil
                        ? other.paperId == run.paperId
                        : other.paperId == nil && other.filter.testGroups == run.filter.testGroups)
            }
            .max { $0.startedAt < $1.startedAt }
    }
}

/// The end of a run (plan §7.4 f): right / wrong / blank, the net, per
/// subject net and accuracy, time, the comparison with the last sitting of
/// the same paper, and the way into the misses — where a mock's bridge
/// questions are asked, since a mock never asks them mid-exam.
struct ExamResultView: View {
    let run: ExamRun
    let bank: ExamBank
    let onClose: () -> Void

    @Query private var attempts: [ExamAttempt]
    @Query(filter: #Predicate<ExamRun> { $0.modeRaw == "mock" && $0.finishedAt != nil }) private var mocks: [ExamRun]

    init(run: ExamRun, bank: ExamBank, onClose: @escaping () -> Void) {
        self.run = run
        self.bank = bank
        self.onClose = onClose
        let id = run.id
        _attempts = Query(filter: #Predicate<ExamAttempt> { $0.run?.id == id })
    }

    private var misses: [ExamAttempt] {
        attempts.filter { attempt in
            bank.result(questionId: attempt.questionId, selectedOption: attempt.selectedOption).isMiss
        }
    }

    var body: some View {
        let answers = ExamRunScore.answers(for: run, attempts: attempts, bank: bank)
        let score = ExamScoring.score(answers)
        let bySubject = ExamScoring.bySubject(answers)
        let misses = self.misses
        let pending = misses.filter { $0.bridgeOutcome == nil }.count
        let gapsAdded = attempts.filter { $0.bridgeOutcome == .noCard }.count
        let linked = attempts.filter { $0.bridgeOutcome == .linked }.count

        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                header(score)

                HStack(spacing: Cizgi.Space.sm) {
                    StatTile(value: "\(score.correct)", label: "Doğru")
                    StatTile(value: "\(score.wrong)", label: "Yanlış")
                    StatTile(value: "\(score.blank)", label: "Boş")
                }

                facts(score: score, linked: linked, gapsAdded: gapsAdded)

                if let comparison = comparisonLine(score) {
                    Label(comparison, systemImage: "arrow.left.arrow.right")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.ink)
                }

                if !misses.isEmpty {
                    NavigationLink(value: AppNavigator.ExamRoute.review(run.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Yanlışları gözden geçir (\(misses.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Cizgi.ink)
                                Text(pending > 0
                                     ? "\(pending) soruda \"karşılayan kartın var mı?\" sorusu bekliyor"
                                     : "Doğru cevaplar, kaynak sayfa ve kart bağları")
                                    .font(.caption)
                                    .foregroundStyle(Cizgi.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Cizgi.hairline)
                        }
                        .padding(Cizgi.Space.md)
                        .background(Cizgi.surface, in: RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                                .stroke(pending > 0 ? Cizgi.accent : Cizgi.hairline, lineWidth: pending > 0 ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if bySubject.count > 1 {
                    subjectTable(bySubject)
                }

                Button("Çıkmış'a dön") { onClose() }
                    .buttonStyle(CizgiPrimaryButtonStyle())
            }
            .padding(Cizgi.Space.xl)
        }
    }

    private func header(_ score: ExamScore) -> some View {
        VStack(spacing: Cizgi.Space.md) {
            ZStack {
                RingGauge(progress: score.accuracy ?? 0, tint: Cizgi.accent, lineWidth: 10)
                    .frame(width: 104, height: 104)
                VStack(spacing: 0) {
                    Text(ExamText.net(score.net))
                        .font(Cizgi.serif(30, relativeTo: .title))
                        .foregroundStyle(Cizgi.ink)
                    Text("net")
                        .font(.caption2)
                        .foregroundStyle(Cizgi.muted)
                }
            }
            Text(ExamRunScore.title(for: run, bank: bank))
                .font(.title3.weight(.bold))
                .foregroundStyle(Cizgi.ink)
                .multilineTextAlignment(.center)
            if run.endedByTimeLimit {
                Label("Süre doldu — cevapladıkların puanlandı.", systemImage: "timer")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Cizgi.warning)
            }
            Text(score.usesDefaultPenalty
                 ? "Net: doğru − yanlış/4 (\(run.paperId == nil ? "soruların bir kısmının kitapçığında" : "bu kitapçıkta") kural basılı değil; varsayılan)."
                 : "Net: doğru − yanlış/4.")
                .font(.caption)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func facts(score: ExamScore, linked: Int, gapsAdded: Int) -> some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
            if let accuracy = score.accuracy {
                Label("Doğru oranı \(ExamText.percent(accuracy))", systemImage: "percent")
            }
            if run.mode == .mock, let finishedAt = run.finishedAt {
                let paused = run.clock.totalPausedSeconds(at: finishedAt)
                Label("Süre \(ExamText.duration(run.clock.activeSeconds(at: finishedAt)))"
                      + (paused >= 1 ? " · duraklama \(ExamText.duration(paused))" : ""),
                      systemImage: "clock")
            }
            if let seconds = score.averageSeconds {
                Label("Soru başına \(Int(seconds.rounded())) sn", systemImage: "timer")
            }
            if score.unscored > 0 {
                Label("\(score.unscored) anahtarsız soru puanlanmadı", systemImage: "key.slash")
            }
            if linked > 0 {
                Label("\(linked) yanlış bir kartına bağlandı", systemImage: "link")
            }
            if gapsAdded > 0 {
                Label("Kitaba dönünce'ye eklenen: \(gapsAdded)", systemImage: "book.closed")
            }
        }
        .font(.footnote)
        .foregroundStyle(Cizgi.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A paper against its own last sitting by net; mixed mocks, whose
    /// questions differ each time, by accuracy.
    private func comparisonLine(_ score: ExamScore) -> String? {
        guard let previous = ExamRunScore.previous(of: run, among: mocks) else { return nil }
        let before = ExamRunScore.score(for: previous, attempts: previous.attempts, bank: bank)
        let day = previous.startedAt.formatted(.dateTime.day().month())
        if run.paperId != nil {
            let delta = score.net - before.net
            let sign = delta > 0 ? "+" : ""
            return "Önceki deneme (\(day)): net \(ExamText.net(before.net)) → \(ExamText.net(score.net)) (\(sign)\(ExamText.net(delta)))"
        }
        guard let now = score.accuracy, let then = before.accuracy else { return nil }
        return "Önceki karma deneme (\(day)): \(ExamText.percent(then)) → \(ExamText.percent(now))"
    }

    private func subjectTable(_ rows: [ExamSubjectScore]) -> some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
            CizgiSectionTitle("Ders bazında")
            ForEach(rows, id: \.subject) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.subject ?? "Dersi belirsiz")
                            .font(.subheadline)
                            .foregroundStyle(Cizgi.ink)
                        Text("D \(entry.score.correct) · Y \(entry.score.wrong) · B \(entry.score.blank)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Cizgi.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("net \(ExamText.net(entry.score.net))")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Cizgi.ink)
                        if let accuracy = entry.score.accuracy {
                            Text(ExamText.percent(accuracy))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Cizgi.muted)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// A finished run opened from the home screen's history.
struct ExamResultScreen: View {
    @EnvironmentObject private var examLibrary: ExamLibrary
    @Environment(\.dismiss) private var dismiss
    @Query private var runs: [ExamRun]

    init(runId: UUID) {
        _runs = Query(filter: #Predicate<ExamRun> { $0.id == runId })
    }

    var body: some View {
        Group {
            if let run = runs.first, let bank = examLibrary.bank {
                ExamResultView(run: run, bank: bank) { dismiss() }
            } else {
                Text("Oturum bulunamadı.").foregroundStyle(Cizgi.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle("Sonuç")
        .navigationBarTitleDisplayMode(.inline)
    }
}
