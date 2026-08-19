import SwiftUI
import CizgiCore

/// The first useful layer of Bilgi Haritasi: canonical subject/topic coverage
/// built from the cards already on device. Concept nodes and model-generated
/// relations can be added on top without replacing this stable hierarchy.
struct KnowledgeMapView: View {
    @EnvironmentObject private var navigator: AppNavigator
    let cards: [Card]

    /// Built once per render, not once per number on screen: the totals in the
    /// header and the rows below have to come from the same value or they will
    /// disagree the moment a card falls outside the canonical schema.
    private var map: KnowledgeMapSummary? {
        guard let schema = SubjectTopicSchema.shared else { return nil }
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

    var body: some View {
        let map = self.map
        ScrollView {
            VStack(alignment: .leading, spacing: Cizgi.Space.xl) {
                ScreenHero(
                    eyebrow: "Bilgi Haritası",
                    title: "Neyi bildiğini gör",
                    subtitle: "Ders ve konularının kapsamını, zayıf alanlarını ve kartlarını tek yerde izle.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )

                if let map {
                    HStack(spacing: Cizgi.Space.sm) {
                        StatTile(value: "\(map.totalCardCount)", label: "Toplam kart")
                        StatTile(value: "\(map.coveredTopicCount)", label: "Kapsanan konu")
                        StatTile(value: "\(map.totalTopicCount)", label: "Toplam konu")
                    }

                    // Says out loud what the deck looks like today: the backfill
                    // gave every existing card a subject and left its topic nil,
                    // so a coverage-only map reads as "you have nothing" to a
                    // user with hundreds of cards.
                    if let uncategorized = totalUncategorized(map), uncategorized > 0 {
                        Label(
                            "\(uncategorized) kart henüz konusuz. Konu ataması yeni "
                                + "üretilen kartlarla geliyor; eskiler ders sayfasındaki "
                                + "\"Konusuz\" bölümünden çalışılabilir.",
                            systemImage: "tag.slash"
                        )
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                    }

                    // The inverse of everything below it. This screen counts the
                    // cards that exist; the Karanlık Harita asks which canonical
                    // topics have none — a question only worth asking because
                    // the template is a closed list (docs/ADR-009).
                    NavigationLink(value: AppNavigator.LibraryRoute.darkMap) {
                        darkMapCard(map)
                    }
                    .buttonStyle(.plain)

                    CizgiSectionTitle(
                        "Dersler",
                        subtitle: "Bir dersi açarak konu dağılımını ve zayıf noktaları incele."
                    )

                    LazyVStack(spacing: Cizgi.Space.md) {
                        ForEach(map.subjects) { summary in
                            // Value push; the destination is registered at the
                            // Library stack root (`LibraryView`).
                            NavigationLink(value: summary) {
                                subjectCard(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let unclassified = map.unclassified {
                        // Not a map node — an unknown name must never invent one
                        // — but counted, so the tiles above add up to the deck.
                        CardSurface {
                            VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
                                Label("\(unclassified.cardCount) kart sınıflandırılmamış",
                                      systemImage: "questionmark.folder")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Cizgi.ink)
                                Text("Dersi ders listesinde olmayan kartlar. Kart "
                                     + "detayındaki \"Sınıflandırma\" bölümünden bir "
                                     + "derse taşıyabilirsin.")
                                    .font(.caption)
                                    .foregroundStyle(Cizgi.muted)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Harita yüklenemedi",
                        systemImage: "map",
                        description: Text("Ders ve konu şeması şu anda kullanılamıyor.")
                    )
                }
            }
            .padding(.horizontal, Cizgi.Space.lg)
            .padding(.vertical, Cizgi.Space.md)
        }
        .background(Cizgi.paper.ignoresSafeArea())
    }

    private func totalUncategorized(_ map: KnowledgeMapSummary) -> Int? {
        let total = map.subjects.reduce(0) { $0 + ($1.uncategorized?.cardCount ?? 0) }
        return total > 0 ? total : nil
    }

    /// Entry point for the Karanlık Harita.
    ///
    /// Its headline number is the one this screen never shows: the count of
    /// canonical topics holding no card. Both numbers come from `map`, so the
    /// card cannot disagree with the tiles above it, and the difference is
    /// exactly the point — everything else here measures what the deck has.
    private func darkMapCard(_ map: KnowledgeMapSummary) -> some View {
        let dark = max(0, map.totalTopicCount - map.coveredTopicCount)
        return CardSurface {
            VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Karanlık Harita", systemImage: "moon.stars")
                        .font(.headline)
                        .foregroundStyle(Cizgi.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Cizgi.muted)
                }
                Text("\(dark) konuda tek kartın yok.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Cizgi.ink)
                Text(
                    "Hangilerinin TUS'ta pahalıya mal olduğunu iki bağımsız model ayrı ayrı "
                        + "değerlendirir; yalnız ikisinin de işaretlediği konu onaylanır."
                )
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
            }
        }
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

struct KnowledgeSubjectView: View {
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

                if visibleTopics.isEmpty && summary.uncategorized == nil {
                    ContentUnavailableView(
                        "Bu derste kart yok",
                        systemImage: "tray",
                        description: Text("Bu derse ait bir sayfa çektiğinde kartlar burada görünecek.")
                    )
                } else {
                    LazyVStack(spacing: Cizgi.Space.sm) {
                        ForEach(visibleTopics) { topic in
                            Button {
                                navigator.openExercise(subject: topic.subject, topic: .topic(topic.topic))
                            } label: {
                                topicRow(
                                    title: topic.topic,
                                    cardCount: topic.cardCount,
                                    weakCardCount: topic.weakCardCount
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        // The bucket that keeps this screen honest. Without it a
                        // deck whose topics were never assigned — which is the
                        // whole deck today — shows "no cards" under a subject
                        // holding all of them, and offers no way to practise it.
                        if let uncategorized = summary.uncategorized {
                            Button {
                                navigator.openExercise(subject: summary.subject, topic: .none)
                            } label: {
                                topicRow(
                                    title: "Konusuz",
                                    cardCount: uncategorized.cardCount,
                                    weakCardCount: uncategorized.weakCardCount,
                                    icon: "tag.slash"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Not tappable: "Konusuz" filters on a missing topic, so it
                    // would not actually contain these. Shown so the rows above
                    // add up to the subject's card count.
                    if let unrecognized = summary.unrecognizedTopic {
                        Text("\(unrecognized.cardCount) kartın konusu bu dersin "
                             + "listesinde yok. Kart detayından yeniden "
                             + "sınıflandırabilirsin.")
                            .font(.footnote)
                            .foregroundStyle(Cizgi.muted)
                    }
                }
            }
            .padding(Cizgi.Space.lg)
        }
        .background(Cizgi.paper.ignoresSafeArea())
        .navigationTitle(summary.subject)
        .navigationBarTitleDisplayMode(.inline)
        .homeButtonToolbar()
    }

    private func topicRow(
        title: String,
        cardCount: Int,
        weakCardCount: Int,
        icon: String? = nil
    ) -> some View {
        CardSurface {
            HStack(spacing: Cizgi.Space.md) {
                VStack(alignment: .leading, spacing: Cizgi.Space.xs) {
                    Label {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Cizgi.ink)
                    } icon: {
                        if let icon {
                            Image(systemName: icon).foregroundStyle(Cizgi.muted)
                        }
                    }
                    HStack(spacing: Cizgi.Space.md) {
                        Label("\(cardCount) kart", systemImage: "rectangle.stack")
                        if weakCardCount > 0 {
                            Label("\(weakCardCount) zayıf", systemImage: "scope")
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
