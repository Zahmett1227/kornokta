import SwiftUI
import SwiftData
import CizgiCore

/// Bilgilerim → İstatistik (2026-09-14): per subject, how many cards, how
/// often they were seen, how often they were missed.
///
/// Two columns, never one sum. Tekrar comes from `ReviewLog`, which is kept for
/// ever; Egzersiz comes from `ExerciseAttempt`, which is deleted after 90 days
/// and labelled so on screen. `StudyStatistics` explains why adding them would
/// have been quietly wrong.
///
/// The data is read on a background context and turned into plain values
/// before the view sees it. This is the first screen in the app that reads the
/// review history in bulk — thousands of rows on a months-old deck — and the
/// profiler has already caught this codebase paying for whole-table reads on
/// the main thread (`ExerciseView.currentCard`).
struct StatisticsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var navigator: AppNavigator
    @AppStorage("cizgi.stats.window") private var windowRaw = StatsWindow.all.rawValue

    @State private var summary: StudyStatisticsSummary?
    @State private var failed = false

    private var window: StatsWindow { StatsWindow(rawValue: windowRaw) ?? .all }

    /// Reloads when the window changes and whenever Bilgilerim comes back on
    /// screen — a tab switch does not recreate this view, and the numbers must
    /// include the reviews done in the tab the owner just left.
    private struct LoadKey: Hashable {
        let window: StatsWindow
        let isOnScreen: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                Picker("Dönem", selection: $windowRaw) {
                    ForEach(StatsWindow.allCases, id: \.self) { window in
                        Text(window.title).tag(window.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if let summary {
                    StatsOverview(line: summary.total)

                    CizgiSectionTitle("Dersler", subtitle: window.periodNote)

                    if summary.subjects.isEmpty {
                        Text("Henüz kart yok.")
                            .font(.subheadline)
                            .foregroundStyle(Cizgi.muted)
                    }

                    LazyVStack(spacing: Cizgi.Space.md) {
                        ForEach(summary.subjects) { subject in
                            NavigationLink(value: AppNavigator.LibraryRoute.subjectStats(subject.subject)) {
                                StatsCardView(title: subject.title,
                                              subject: CizgiSubject.matching(subject.subject),
                                              line: subject.line,
                                              window: window,
                                              showsChevron: subject.subject != nil)
                            }
                            .buttonStyle(.plain)
                            .disabled(subject.subject == nil)
                        }
                    }
                } else if failed {
                    ContentUnavailableView(
                        "İstatistik yüklenemedi",
                        systemImage: "chart.bar",
                        description: Text("Ders şeması ya da veri okunamadı.")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Cizgi.Space.xxl)
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .task(id: LoadKey(window: window, isOnScreen: navigator.selectedTab == .library)) {
            guard navigator.selectedTab == .library else { return }
            await load()
        }
    }

    private func load() async {
        guard let schema = SubjectTopicSchema.shared else {
            failed = true
            return
        }
        let result = await StatisticsLoader.load(container: context.container, window: window, schema: schema)
        summary = result
        failed = result == nil
    }
}

/// One subject's topics, same columns.
struct SubjectStatisticsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("cizgi.stats.window") private var windowRaw = StatsWindow.all.rawValue
    let subject: String

    @State private var stats: SubjectStats?
    /// Loaded, and the subject has no cards left (they were deleted or moved
    /// since the row was tapped).
    @State private var isEmpty = false

    private var window: StatsWindow { StatsWindow(rawValue: windowRaw) ?? .all }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.lg) {
                Picker("Dönem", selection: $windowRaw) {
                    ForEach(StatsWindow.allCases, id: \.self) { window in
                        Text(window.title).tag(window.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if let stats {
                    StatsOverview(line: stats.line)
                    CizgiSectionTitle("Konular", subtitle: window.periodNote)
                    LazyVStack(spacing: Cizgi.Space.md) {
                        ForEach(stats.topics) { topic in
                            StatsCardView(title: topic.title,
                                          subject: CizgiSubject.matching(subject),
                                          line: topic.line,
                                          window: window,
                                          showsChevron: false)
                        }
                    }
                } else if isEmpty {
                    ContentUnavailableView("Bu derste kart kalmadı", systemImage: "rectangle.stack")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Cizgi.Space.xxl)
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: window) {
            guard let schema = SubjectTopicSchema.shared else { return }
            let summary = await StatisticsLoader.load(container: context.container, window: window, schema: schema)
            stats = summary?.subjects.first { $0.subject == subject }
            isEmpty = stats == nil
        }
    }
}

// MARK: - Loading

enum StatisticsLoader {
    /// Reads cards, review logs and exercise attempts on a context of its own,
    /// off the main thread, and returns only the finished value. `nil` if the
    /// store cannot be read.
    static func load(
        container: ModelContainer,
        window: StatsWindow,
        schema: SubjectTopicSchema
    ) async -> StudyStatisticsSummary? {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let now = Date()
            do {
                let cards = try context.fetch(FetchDescriptor<Card>()).map(StatsCard.init)

                var reviewDescriptor = FetchDescriptor<ReviewLog>()
                if let start = window.start(now: now) {
                    reviewDescriptor.predicate = #Predicate { $0.reviewedAt >= start }
                }
                reviewDescriptor.relationshipKeyPathsForPrefetching = [\.card]
                let reviews = try context.fetch(reviewDescriptor).compactMap { log -> StatsReview? in
                    guard let id = log.card?.id else { return nil }
                    return StatsReview(cardId: id, at: log.reviewedAt, rating: log.rating)
                }

                // The builder applies the 90-day cut itself; narrowing the fetch
                // to it as well just keeps the read small.
                let exerciseStart = max(
                    window.start(now: now) ?? .distantPast,
                    now.addingTimeInterval(-ExerciseHistory.retention)
                )
                let attemptDescriptor = FetchDescriptor<ExerciseAttempt>(
                    predicate: #Predicate { $0.answeredAt >= exerciseStart }
                )
                let attempts = try context.fetch(attemptDescriptor).map {
                    StatsAttempt(cardId: $0.cardId, at: $0.answeredAt, result: $0.result)
                }

                return StudyStatistics.build(
                    cards: cards, reviews: reviews, attempts: attempts,
                    window: window, now: now, schema: schema
                )
            } catch {
                return nil
            }
        }.value
    }
}

// MARK: - Pieces

private extension StatsWindow {
    /// Says which period each column really covers. Under "Tümü" the two
    /// differ — the review history is complete, the exercise history is not —
    /// and under 30 or 7 days they are the same period, so saying "son 90 gün"
    /// there would be a label contradicting its own numbers.
    var periodNote: String {
        switch self {
        case .all: return "Tekrar tüm geçmişten, Egzersiz son 90 günden sayılır."
        case .last30Days: return "Son 30 gün."
        case .last7Days: return "Son 7 gün."
        }
    }

    var exerciseColumnTitle: String {
        self == .all ? "Egzersiz · son 90 gün" : "Egzersiz"
    }
}

/// The four numbers at the top.
private struct StatsOverview: View {
    let line: StatsLine

    var body: some View {
        HStack(spacing: Cizgi.Space.sm) {
            StatTile(value: "\(line.cardCount)", label: "Kart")
            StatTile(value: "\(line.review.seenCards)", label: "Görülen")
            StatTile(value: "\(line.review.reviews)", label: "Tekrar")
            StatTile(value: percent(line.review.accuracy), label: "Doğruluk")
        }
    }
}

/// A subject or topic card with the two columns.
private struct StatsCardView: View {
    let title: String
    let subject: CizgiSubject?
    let line: StatsLine
    let window: StatsWindow
    let showsChevron: Bool

    var body: some View {
        CardSurface(highlighted: true, subject: subject) {
            VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Cizgi.ink)
                    Spacer()
                    Text("\(line.cardCount) kart")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Cizgi.muted)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Cizgi.muted)
                    }
                }

                StatsColumns(
                    title: "Tekrar",
                    items: [
                        ("\(line.review.seenCards)", "görülen"),
                        ("\(line.review.reviews)", "tekrar"),
                        ("\(line.review.forgotten)", "unutma"),
                        (percent(line.review.accuracy), "doğru"),
                    ],
                    alertIndex: line.review.forgotten > 0 ? 2 : nil
                )
                StatsColumns(
                    title: window.exerciseColumnTitle,
                    items: [
                        ("\(line.exercise.attempts)", "deneme"),
                        ("\(line.exercise.missed)", "bilemedim"),
                        ("\(line.exercise.unsure)", "kararsız"),
                        (percent(line.exercise.accuracy), "doğru"),
                    ],
                    alertIndex: line.exercise.missed > 0 ? 1 : nil
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatsColumns: View {
    let title: String
    let items: [(String, String)]
    /// The one number worth colouring — never the only carrier of meaning, its
    /// label says what it is.
    let alertIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
            Text(TurkishText.uppercased(title))
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Cizgi.faint)
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 0) {
                        Text(item.0)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(index == alertIndex ? Cizgi.danger : Cizgi.ink)
                        Text(item.1)
                            .font(.caption2)
                            .foregroundStyle(Cizgi.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// "%84", or "—" when there is nothing to divide — never a 0% for a subject
/// nobody has studied.
private func percent(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "%\(Int((value * 100).rounded()))"
}
