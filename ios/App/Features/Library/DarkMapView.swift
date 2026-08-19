import CizgiCore
import SwiftData
import SwiftUI

/// Karanlık Harita — what the deck does *not* cover (docs/ADR-009).
///
/// Every other screen in this app answers a question about cards that exist.
/// This one answers the opposite question, and it can only be asked because the
/// ders/konu template is closed: 143 canonical topics, so "which ones am I
/// missing" is a complete list rather than an impression.
///
/// The screen keeps the two halves of the answer visually apart, because they
/// have different warranties:
///
/// - **Aktif kartı olmayan konular** is arithmetic over the bundled schema. It
///   needs no network, costs nothing, and is shown before anything is pressed.
///   It cannot be wrong about *whether* a topic holds an active card. Every
///   label on this half names that predicate rather than saying "no cards":
///   a topic whose cards are all suspended belongs here, and it is not empty
///   (Codex, PR #49).
/// - **Öncelik sırası** is two model families' judgement about which of the thin
///   topics actually cost points on TUS. It costs money, needs a button, and can
///   be wrong — so each row carries who said it and whether the other family
///   agreed.
///
/// Presenting them in one undifferentiated list was the tempting design and the
/// wrong one: it would give a model's opinion the same visual authority as a
/// count.
struct DarkMapView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.modelContext) private var context

    /// The whole deck. Same shape `KnowledgeMapView` uses — coverage is a
    /// question about all of it, so there is nothing to narrow with a predicate.
    @Query private var allCards: [Card]

    @State private var phase: Phase = .idle
    @State private var expandedSubject: String?

    private let schema = SubjectTopicSchema.shared

    private enum Phase: Equatable {
        case idle
        case loading
        case loaded(DarkMapResult)
        case failed(message: String, retryable: Bool)
    }

    var body: some View {
        // Built once per render and handed down, for the reason
        // `KnowledgeMapView` learned: totals in the header and rows below have
        // to come from the same value or they will disagree. It also keeps the
        // O(deck) grouping to one pass instead of one per section.
        let payload = schema.map { DarkMapCoverage.build(cards: allCards.map(Self.coverageCard), schema: $0) }

        return List {
            if let schema, let payload {
                localSummarySection(schema: schema, payload: payload)

                switch phase {
                case .idle:
                    runSection(title: "Öncelik sırasını çıkar", payload: payload)
                case .loading:
                    loadingSection
                case .failed(let message, let retryable):
                    failureSection(message: message, retryable: retryable)
                case .loaded(let result):
                    resultSections(result)
                }

                untouchedSection(schema: schema, payload: payload)
            } else {
                // Same policy as Bilgi Haritası: without the template there are
                // no canonical topics, so there is no coverage question to ask.
                ContentUnavailableView(
                    "Şablon yüklenemedi",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Ders/konu şablonu okunamadı; karanlık harita çıkarılamıyor.")
                )
            }
        }
        .navigationTitle("Karanlık Harita")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Deterministic half

    private static func coverageCard(_ card: Card) -> DarkMapCoverage.Card {
        DarkMapCoverage.Card(
            subject: card.knowledgeUnit?.subject,
            topic: card.knowledgeUnit?.topic,
            front: card.front,
            isActive: card.status == .active,
            lowConfidence: card.lowConfidence
        )
    }

    @ViewBuilder
    private func localSummarySection(
        schema: SubjectTopicSchema,
        payload: DarkMapCoverage.Payload
    ) -> some View {
        let total = schema.subjects.reduce(0) { $0 + $1.topics.count }
        let covered = payload.coveredTopicCount

        Section {
            HStack {
                statTile(value: "\(covered)", label: "aktif kartlı")
                Divider()
                statTile(value: "\(total - covered)", label: "aktif kartsız")
                Divider()
                statTile(value: "\(total)", label: "toplam konu")
            }
            .frame(maxWidth: .infinity)

            if payload.unclassifiedCards > 0 {
                // Without this the covered count reads as a verdict on the whole
                // deck, when on this deck most cards may still carry no topic.
                Label(
                    "\(payload.unclassifiedCards) aktif kart konusuz ya da tanınmayan bir konuda; "
                        + "kapsama sayısına girmiyor.",
                    systemImage: "questionmark.folder"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if payload.inactiveCards > 0 {
                Label(
                    "\(payload.inactiveCards) kart askıda ya da taslak; kapsama sayılmıyor.",
                    systemImage: "pause.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Kapsama")
        } footer: {
            // Names the predicate once, for all three tiles. Without it "boş"
            // reads as "no cards at all", which is false for a topic whose
            // cards are all suspended — and this screen deliberately treats
            // those as not-studied while Bilgi Haritası still counts them as
            // deck (Codex, PR #49).
            Text(
                "Bir konu, en az bir aktif kartı varsa kapsanmış sayılır; askıdaki ve taslak "
                    + "kartlar çalışılmıyor sayılır. Bu üç sayı cihazda hesaplanır, model "
                    + "çağrısı gerektirmez."
            )
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Model half

    @ViewBuilder
    private func runSection(title: String, payload: DarkMapCoverage.Payload) -> some View {
        Section {
            Button(title) {
                Task { await run() }
            }
            .disabled(!environment.isBackendConfigured)

            if !environment.isBackendConfigured {
                Text("Backend ayarlı değil (Ayarlar → Backend).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if payload.rows.isEmpty {
                // Said before the button, not after it: the ranking still runs
                // and is still useful, it just has nothing personal to lean on.
                // The two causes are distinguished because only one of them is
                // something the user can act on.
                Label(
                    payload.unclassifiedCards > 0
                        ? "Sınıflandırılmış aktif kartın yok, o yüzden sıralama yalnız TUS "
                            + "ağırlığına bakacak. Kartlara ders/konu atadıkça kişiselleşir."
                        : "Deste boş görünüyor, o yüzden sıralama yalnız TUS ağırlığına bakacak — "
                            + "yani \"nereden başlamalı\" sorusunun cevabı.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Öncelik sırası")
        } footer: {
            Text(
                "Boş konuların hepsi eşit acil değil. İki bağımsız model — kart üreten OpenAI ve "
                    + "ondan bağımsız Gemini — aynı tabloyu ayrı ayrı okuyup TUS'ta en pahalıya "
                    + "mal olacak konuları sıralar. Yalnız ikisinin de işaretlediği konu "
                    + "\"iki model de\" damgası alır."
            )
        }
    }

    private var loadingSection: some View {
        Section("Öncelik sırası") {
            HStack(spacing: 10) {
                ProgressView()
                Text("İki model tabloyu ayrı ayrı okuyor…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func failureSection(message: String, retryable: Bool) -> some View {
        Section("Öncelik sırası") {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            if retryable {
                Button("Tekrar dene") { Task { await run() } }
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ result: DarkMapResult) -> some View {
        Section {
            if result.singleRater {
                // The degradation that must never look like agreement.
                Label(
                    "Yalnız tek model değerlendirdi; hiçbir konu karşılıklı doğrulanmadı.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            ForEach(result.raters) { rater in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: rater.ok ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(rater.ok ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Self.familyLabel(rater.family)) — \(rater.model)")
                            .font(.footnote)
                        if let error = rater.error {
                            Text(error).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Yeniden çıkar") { Task { await run() } }
        } header: {
            Text("Değerlendirenler")
        }

        if result.zones.isEmpty {
            Section("Öncelik sırası") {
                Text("Modeller öne çıkaracak bir konu bulamadı.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(result.zones) { zone in
                    zoneRow(zone)
                }
            } header: {
                Text("Öncelik sırası")
            } footer: {
                Text(
                    "Sıra, TUS ağırlığı ile destedeki eksiğin çarpımıdır — yalnız boşluğa göre "
                        + "değil. Kart sayıları destenden okunur, modelden değil."
                )
            }
        }
    }

    @ViewBuilder
    private func zoneRow(_ zone: DarkZone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(zone.topic).font(.body.weight(.medium))
                Spacer()
                consensusBadge(zone)
            }
            Text(zone.subject).font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                darknessBar(zone.darkness)
                Text(Self.cardCountLabel(zone))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let tusYield = zone.tusYield {
                    Text(Self.yieldLabel(tusYield))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            if !zone.missingConcepts.isEmpty {
                Text(zone.missingConcepts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // One line per family rather than an averaged sentence: when two
            // raters disagree about *why*, that is the interesting part.
            ForEach(Array(zone.reasons.enumerated()), id: \.offset) { _, reason in
                Text("\(Self.familyLabel(reason.family)): \(reason.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if zone.cardCount > 0 {
                // Only offered where it can do something: Egzersiz filters the
                // cards that exist, so a genuinely empty topic has nothing to
                // practise and the button would open an empty session.
                Button("Bu konuyu çalış") {
                    navigator.openExercise(subject: zone.subject, topic: .topic(zone.topic))
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func consensusBadge(_ zone: DarkZone) -> some View {
        let confirmed = zone.consensus == .confirmed
        return Text(confirmed ? "iki model de" : "tek model")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (confirmed ? Color.accentColor : Color.secondary).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(confirmed ? Color.accentColor : Color.secondary)
    }

    /// Five pips rather than a number: the score is a coarse judgement and a
    /// decimal like "4.5" would suggest a precision two opinions cannot carry.
    private func darknessBar(_ darkness: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { step in
                Circle()
                    .fill(Double(step) <= darkness.rounded() ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Karanlık: 5 üzerinden \(Int(darkness.rounded()))")
    }

    // MARK: - Untouched

    /// A named struct rather than a tuple: `ForEach(_:id:)` needs a key path,
    /// and Swift has no key paths into tuple elements.
    private struct UntouchedGroup: Identifiable {
        var id: String { subject }
        let subject: String
        let topics: [String]
    }

    @ViewBuilder
    private func untouchedSection(
        schema: SubjectTopicSchema,
        payload: DarkMapCoverage.Payload
    ) -> some View {
        let grouped = untouchedBySubject(schema: schema, payload: payload)
        if !grouped.isEmpty {
            Section {
                ForEach(grouped) { entry in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedSubject == entry.subject },
                            set: { expandedSubject = $0 ? entry.subject : nil }
                        )
                    ) {
                        ForEach(entry.topics, id: \.self) { topic in
                            Text(topic).font(.callout).foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Text(entry.subject)
                            Spacer()
                            Text("\(entry.topics.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Aktif kartı olmayan konular")
            } footer: {
                Text("Şablondaki konulardan destende tek aktif kartı bulunmayanlar. Sayım cihazda yapılır.")
            }
        }
    }

    /// Built from the bundled schema, not from the response.
    ///
    /// So the list is there before the first run and stays there if both model
    /// calls fail — an empty topic is empty whether or not anyone ranked it.
    private func untouchedBySubject(
        schema: SubjectTopicSchema,
        payload: DarkMapCoverage.Payload
    ) -> [UntouchedGroup] {
        let covered = Set(payload.rows.map { "\($0.subject)\u{1F}\($0.topic)" })
        return schema.subjects.compactMap { subject in
            let topics = subject.topics.filter { !covered.contains("\(subject.name)\u{1F}\($0)") }
            return topics.isEmpty ? nil : UntouchedGroup(subject: subject.name, topics: topics)
        }
    }

    // MARK: - Running

    private func run() async {
        guard let provider = environment.makeDarkMapProvider() else {
            phase = .failed(message: "Backend ayarlı değil (Ayarlar → Backend).", retryable: false)
            return
        }
        guard let schema else {
            phase = .failed(message: DarkMapError.schemaUnavailable.localizedDescription, retryable: false)
            return
        }
        let payload = DarkMapCoverage.build(cards: allCards.map(Self.coverageCard), schema: schema)

        // No guard on an empty `rows`. It used to refuse here with "önce
        // kartlara ders/konu atanmalı", which is a *cause* the phone cannot
        // actually know: rows are also empty when every card is suspended, or
        // when the deck is new — and in both cases the sentence is simply false
        // (Codex, PR #49).
        //
        // Refusing was wrong on its own terms too. The server zero-fills all 143
        // canonical topics from an empty `coverage`, so the ranking it returns
        // is "what TUS leans on hardest, none of which you hold" — which is the
        // single most useful thing this feature can tell someone starting out.
        // The un-personalised case is explained in `runSection` instead, before
        // the button rather than after it.

        phase = .loading
        let requestId = UUID().uuidString

        do {
            let result = try await provider.request(requestId: requestId, coverage: payload.rows)

            record(result.usage, jobId: requestId)
            phase = .loaded(result)
        } catch let error as DarkMapError {
            // The failure path records too. Both rankers can burn their whole
            // output budget and then truncate — billed in full, nothing
            // returned — and that is exactly the spend Ayarlar → Kullanım exists
            // to make visible. `usage` is empty for the guard failures that
            // never reached a model, so this writes nothing when nothing was
            // spent rather than inventing a zero-token line (§0.6).
            record(error.usage, jobId: requestId)
            phase = .failed(message: error.localizedDescription, retryable: error.retryable)
        } catch {
            phase = .failed(message: error.localizedDescription, retryable: true)
        }
    }

    /// Writes the server's own priced ledger to `ModelRun`. The phone stores; it
    /// never prices, because only the server knows which model actually ran.
    private func record(_ runs: [ModelRunMetadata], jobId: String) {
        guard !runs.isEmpty else { return }
        for run in runs {
            context.insert(ModelRun(
                requestId: run.requestId,
                // No page behind this call, so the request id doubles as the
                // ledger's job id — the dedup key is (jobId, purpose, attempt)
                // and each map gets a fresh uuid.
                jobId: jobId,
                attempt: run.attempt,
                provider: run.provider,
                model: run.model,
                purpose: run.purpose,
                promptVersion: run.promptVersion,
                latencyMs: run.latencyMs,
                inputTokens: run.inputTokens,
                cachedInputTokens: run.cachedInputTokens,
                outputTokens: run.outputTokens,
                reasoningTokens: run.reasoningTokens,
                estimatedCostUSD: run.estimatedCostUSD,
                success: run.success,
                billing: run.billing,
                failureReason: run.failureReason
            ))
        }
        try? context.save()
    }

    // MARK: - Labels

    private static func familyLabel(_ family: String) -> String {
        switch family {
        case "openai": return "OpenAI"
        case "gemini": return "Gemini"
        default: return family
        }
    }

    private static func yieldLabel(_ tusYield: DarkZone.Yield) -> String {
        switch tusYield {
        case .high: return "TUS: yüksek verim"
        case .medium: return "TUS: orta verim"
        case .low: return "TUS: düşük verim"
        }
    }

    private static func cardCountLabel(_ zone: DarkZone) -> String {
        if zone.cardCount == 0 { return "kart yok" }
        if zone.weakCardCount > 0 { return "\(zone.cardCount) kart · \(zone.weakCardCount) şüpheli" }
        return "\(zone.cardCount) kart"
    }
}
