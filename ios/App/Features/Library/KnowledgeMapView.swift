import SwiftUI
import CizgiCore

/// The first useful layer of Bilgi Haritasi: canonical subject/topic coverage
/// built from the cards already on device. Concept nodes and model-generated
/// relations can be added on top without replacing this stable hierarchy.
struct KnowledgeMapView: View {
    @EnvironmentObject private var navigator: AppNavigator
    let cards: [Card]

    private var summaries: [KnowledgeMapSubjectSummary] {
        guard let schema = SubjectPickerBar.schema else { return [] }
        return KnowledgeMapBuilder.build(
            cards: cards.map {
                KnowledgeMapCard(
                    subject: $0.knowledgeUnit?.subject,
                    topic: $0.knowledgeUnit?.topic,
                    isActive: $0.status == .active,
                    lapseCount: $0.lapseCount,
                    lowConfidence: $0.lowConfidence
                )
            },
            schema: schema
        )
    }

    private var coveredTopics: Int {
        summaries.reduce(0) { $0 + $1.coveredTopicCount }
    }

    private var totalTopics: Int {
        summaries.reduce(0) { $0 + $1.totalTopicCount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                ScreenHero(
                    eyebrow: "Bilgi Haritası",
                    title: "Neyi bildiğini gör",
                    subtitle: "Ders ve konularının kapsamını, zayıf alanlarını ve kartlarını tek yerde izle.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                HStack(spacing: Cizgi.Space.sm) {
                    StatTile(value: "\(cards.count)", label: "Kart")
                    StatTile(value: "\(coveredTopics)", label: "Kapsanan konu")
                    StatTile(value: "\(totalTopics)", label: "Toplam konu")
                }

                CizgiSectionTitle(
                    "Dersler",
                    subtitle: "Bir dersi açarak konu dağılımını ve zayıf noktaları incele."
                )

                if summaries.isEmpty {
                    ContentUnavailableView(
                        "Harita yüklenemedi",
                        systemImage: "map",
                        description: Text("Ders ve konu şeması şu anda kullanılamıyor.")
                    )
                } else {
                    LazyVStack(spacing: Cizgi.Space.md) {
                        ForEach(summaries) { summary in
                            NavigationLink {
                                KnowledgeSubjectView(summary: summary)
                            } label: {
                                subjectCard(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
        .background(Cizgi.paper.ignoresSafeArea())
    }

    private func subjectCard(_ summary: KnowledgeMapSubjectSummary) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.subject)
                        .font(.headline)
                        .foregroundStyle(Cizgi.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Cizgi.muted)
                }

                ProgressView(value: summary.coverage)
                    .tint(Cizgi.accent)

                HStack(spacing: Cizgi.Space.md) {
                    Label("\(summary.cardCount) kart", systemImage: "rectangle.stack")
                    Label(
                        "\(summary.coveredTopicCount)/\(summary.totalTopicCount) konu",
                        systemImage: "map"
                    )
                    if summary.weakCardCount > 0 {
                        Label("\(summary.weakCardCount) zayıf", systemImage: "scope")
                            .foregroundStyle(Cizgi.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(Cizgi.muted)
            }
        }
    }
}

private struct KnowledgeSubjectView: View {
    @EnvironmentObject private var navigator: AppNavigator
    let summary: KnowledgeMapSubjectSummary

    private var visibleTopics: [KnowledgeMapTopicSummary] {
        summary.topics.filter { $0.cardCount > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                CardSurface(highlighted: true) {
                    VStack(alignment: .leading, spacing: Cizgi.Space.md) {
                        Text("\(summary.coveredTopicCount) / \(summary.totalTopicCount) konu kapsanıyor")
                            .font(.headline)
                            .foregroundStyle(Cizgi.ink)
                        ProgressView(value: summary.coverage)
                            .tint(Cizgi.accent)
                        HStack(spacing: Cizgi.Space.sm) {
                            StatTile(value: "\(summary.cardCount)", label: "Kart")
                            StatTile(value: "\(summary.activeCount)", label: "Aktif")
                            StatTile(value: "\(summary.weakCardCount)", label: "Zayıf")
                        }
                        Button {
                            navigator.openExercise(subject: summary.subject)
                        } label: {
                            Label("Bu dersten Egzersiz", systemImage: "brain.head.profile")
                        }
                        .buttonStyle(CizgiPrimaryButtonStyle())
                        .disabled(summary.cardCount == 0)
                    }
                }

                CizgiSectionTitle("Konular", subtitle: "Konuya dokunarak hedefli Egzersiz başlat.")

                if visibleTopics.isEmpty {
                    ContentUnavailableView(
                        "Henüz konulu kart yok",
                        systemImage: "tag.slash",
                        description: Text("Bu derste üretilen yeni kartlar konu atandıkça burada görünecek.")
                    )
                } else {
                    LazyVStack(spacing: Cizgi.Space.sm) {
                        ForEach(visibleTopics) { topic in
                            Button {
                                navigator.openExercise(subject: topic.subject, topic: topic.topic)
                            } label: {
                                topicRow(topic)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Cizgi.Space.lg)
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle(summary.subject)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topicRow(_ topic: KnowledgeMapTopicSummary) -> some View {
        CardSurface {
            HStack(spacing: Cizgi.Space.md) {
                VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
                    Text(topic.topic)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Cizgi.ink)
                    HStack(spacing: Cizgi.Space.md) {
                        Label("\(topic.cardCount) kart", systemImage: "rectangle.stack")
                        if topic.weakCardCount > 0 {
                            Label("\(topic.weakCardCount) zayıf", systemImage: "scope")
                                .foregroundStyle(Cizgi.warning)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Cizgi.accent)
            }
        }
    }
}
