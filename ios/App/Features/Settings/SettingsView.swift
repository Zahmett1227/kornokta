import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CizgiCore

/// Settings (ANA-PLAN §6.7). Faz 1 exposes the options that already do
/// something; cost limits and export arrive with the backend in Faz 3/5.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var context
    @Query private var cards: [Card]
    @Query private var pages: [CapturedPage]
    @Query private var modelRuns: [ModelRun]

    @State private var deviceToken = ""
    @State private var tokenSaved = false
    @State private var tokenError: String?
    @State private var notificationError: String?
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var isImportingBackup = false
    @State private var restoreSummary: String?
    @State private var restoreError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A picker, not free text: the subject now decides which
                    // topic list the model is constrained to (schema v2.2), so
                    // a name outside the template would silently mean "no
                    // topics at all". Same stored value as the capture screen's
                    // strip — changing it in either place changes both.
                    if let names = SubjectTopicSchema.shared?.subjectNames {
                        Picker("Ders", selection: Binding(
                            get: { SubjectPickerBar.canonicalSubject(environment.settings.defaultSubject) ?? "" },
                            set: { environment.settings.defaultSubject = $0; environment.settings.save() }
                        )) {
                            Text("Seçilmedi").tag("")
                            ForEach(names, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }

                    Stepper(
                        "Sayfa başına kart: \(environment.settings.maxCardsPerPage)",
                        value: Binding(
                            get: { environment.settings.maxCardsPerPage },
                            set: { environment.settings.maxCardsPerPage = $0; environment.settings.save() }
                        ),
                        in: 1...12
                    )

                    Picker("Beş şıklı kart", selection: Binding(
                        get: { environment.settings.multipleChoiceMode },
                        set: { environment.settings.multipleChoiceMode = $0; environment.settings.save() }
                    )) {
                        ForEach(MultipleChoiceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Text(environment.settings.multipleChoiceMode.detail)
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                } header: {
                    Text("Yakalama")
                } footer: {
                    // Until now this control did nothing at all: the value was
                    // never put in the request and the server always used its own
                    // ceiling. Fewer cards also means a faster, cheaper call.
                    Text("Ders, Yakala ekranındaki şeritle aynı ayardır; seçilen "
                         + "dersin konu listesinden her karta bir konu atanır. "
                         + "İşaretli bir sayfadan en fazla kaç kart üretilsin. "
                         + "Az kart daha hızlı ve daha ucuz üretilir. Beş şıklı "
                         + "kartlarda TUS tipi soru ve şıklar üretilir; sunucu "
                         + "kendi ayarını tavan kabul eder.")
                }

                Section {
                    Toggle("Kaynağa sadık mod", isOn: Binding(
                        get: { environment.settings.sourceFaithfulOnly },
                        set: { environment.settings.sourceFaithfulOnly = $0; environment.settings.save() }
                    ))
                } footer: {
                    Text("Açıkken kartlar yalnızca sayfada yazan bilgiye dayanır. Kapatmak zenginleştirilmiş içeriğe izin verir ve her ek bilgi ayrıca işaretlenir.")
                }

                Section("Tekrar") {
                    Toggle("Günlük hatırlatıcı", isOn: Binding(
                        get: { environment.settings.notificationsEnabled },
                        set: { enabled in
                            environment.settings.notificationsEnabled = enabled
                            environment.settings.save()
                            updateNotification()
                        }
                    ))
                    Stepper(
                        "Hatırlatma saati: \(environment.settings.notificationHour):00",
                        value: Binding(
                            get: { environment.settings.notificationHour },
                            set: { environment.settings.notificationHour = $0; environment.settings.save(); updateNotification() }
                        ), in: 0...23
                    )
                    .disabled(!environment.settings.notificationsEnabled)
                    Stepper("Günlük yeni kart: \(environment.settings.dailyNewCardLimit)", value: Binding(
                        get: { environment.settings.dailyNewCardLimit },
                        set: { environment.settings.dailyNewCardLimit = $0; environment.settings.save() }
                    ), in: 0...100)
                    Stepper("Hızlı oturum: \(environment.settings.quickSessionMinutes) dk", value: Binding(
                        get: { environment.settings.quickSessionMinutes },
                        set: { environment.settings.quickSessionMinutes = $0; environment.settings.save() }
                    ), in: 1...30)
                    // Both numbers used to be quieter than they looked: the new-card
                    // limit reset every time the review screen was reopened, and the
                    // quick session was not a choice but the ceiling on every session.
                    Text("Yeni kart sınırı gün boyunca geçerlidir. Hızlı oturum, "
                         + "Tekrar ekranındaki ayrı bir seçenektir — normal oturum "
                         + "bugün bekleyen tüm kartları gösterir.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                    if let notificationError { Text(notificationError).font(.footnote).foregroundStyle(.red) }
                }

                Section("Veri") {
                    LabeledContent("Kart", value: "\(cards.count)")
                    LabeledContent("Çekilen sayfa", value: "\(pages.count)")
                    Toggle("Orijinal sayfayı sakla", isOn: Binding(
                        get: { environment.settings.keepOriginalPage },
                        set: { environment.settings.keepOriginalPage = $0; environment.settings.save() }
                    ))
                    // Worth spelling out now that the photo is the *only* trace a
                    // Faz 6 card has: there is no crop and no per-card alıntı, so
                    // turning this off leaves cards you cannot check against
                    // anything (§5.5).
                    Text("Kapatırsan kartların \"Kaynağı göster\" bölümünde "
                         + "sayfa fotoğrafı olmaz — kartı kaynağıyla "
                         + "karşılaştıramazsın.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                    Button("Yedeği hazırla") { prepareExport() }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("JSON yedeğini paylaş", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let exportError { Text(exportError).font(.footnote).foregroundStyle(.red) }

                    Button("Yedekten geri yükle") { isImportingBackup = true }
                    if let restoreSummary {
                        Text(restoreSummary).font(.footnote).foregroundStyle(Cizgi.success)
                    }
                    if let restoreError {
                        Text(restoreError).font(.footnote).foregroundStyle(Cizgi.danger)
                    }
                    Text("Geri yükleme yalnızca ekler: bu cihazda zaten olan bir kart "
                         + "olduğu gibi bırakılır. Yedekte fotoğraflar yok.")
                        .font(.footnote)
                        .foregroundStyle(Cizgi.muted)
                }

                usageSection

                Section {
                    LabeledContent(
                        "Akış",
                        value: environment.isBackendConfigured
                            ? "Vision — işaretli sayfadan doğrudan kart"
                            : "Ayarlanmadı"
                    )
                    LabeledContent(
                        "Kart üretimi",
                        value: environment.isBackendConfigured ? "Gerçek (backend)" : "Sahte sağlayıcı"
                    )
                    LabeledContent("Tekrar algoritması", value: environment.scheduler is FSRSScheduler ? "FSRS-6" : "Geçici (bundled ağırlıklar okunamadı)")
                } header: {
                    Text("Durum")
                } footer: {
                    // Was still describing the Faz 2/3 architecture — "Google
                    // Document AI", "Faz 3" — two phases after the vision flow
                    // stopped doing any OCR at all (docs/ADR-005).
                    Text(
                        environment.isBackendConfigured
                            ? "İşaretli sayfa doğrudan vision modeline gidiyor; ayrı bir OCR adımı yok ve kartlar onaysız desteye giriyor. Tekrar etmek her zaman çevrimdışı çalışır."
                            : "Backend ayarlanmadan kart üretimi sahte; kartlar taslak niteliğindedir. Tekrar etmek her zaman çevrimdışı çalışır."
                    )
                }

                // Single-user daily controls stay first. Provider credentials
                // are necessary setup, but not part of the ordinary learning
                // loop, so they live at the bottom as an advanced section.
                backendSection
            }
            .rootTabBarInset()
            .fileImporter(
                isPresented: $isImportingBackup,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: restore
            )
            .navigationTitle("Ayarlar")
            // Value-based like every other push in the app (AppNavigator's
            // note): only a value push appends to the stack's path.
            .navigationDestination(for: AppNavigator.SettingsRoute.self) { route in
                switch route {
                case .usageDetail: UsageDetailView()
                }
            }
            .onAppear {
                // Shown as a placeholder, never as text: reading the stored
                // token back into an on-screen field would put it somewhere a
                // screenshot or a shoulder can reach (§7.3).
                deviceToken = ""
            }
        }
    }

    /// What the provider calls have actually cost (§16.8, §20.3).
    ///
    /// This screen used to add up successful calls only, which made it
    /// structurally incapable of matching the provider's invoice: a generation
    /// that burns its whole output budget and then fails costs exactly what a
    /// working one costs, and there are three separate ways for that to happen.
    /// The gap between this total and the provider's dashboard *was* the
    /// diagnosis, and there was no way to see it from here.
    ///
    /// So the split is the point now, not the total. "Boşa giden" is money
    /// spent on pages that produced no cards; "ölçülemedi" is calls known to
    /// have been billed without reporting how much, kept as a count because
    /// averaging them into a figure would invent a number (§0.6).
    @ViewBuilder
    private var usageSection: some View {
        if !modelRuns.isEmpty {
            let entries = modelRuns.map(Self.entry(for:))
            let summary = UsageSummary.of(entries)
            Section {
                LabeledContent("Model çağrısı", value: "\(summary.callCount)")

                if summary.totalCostUSD > 0 {
                    LabeledContent("Tahmini maliyet", value: Self.usd(summary.totalCostUSD))
                    LabeledContent("Çağrı başına ortalama") {
                        Text(Self.usd(summary.averageCostPerMeasuredCallUSD))
                            .foregroundStyle(Cizgi.muted)
                    }
                }

                if summary.billedFailureCount > 0 {
                    LabeledContent("Boşa giden") {
                        // Colour is never the only signal (§29): the count and
                        // the share say it in words too.
                        Text(
                            "\(Self.usd(summary.wastedCostUSD)) · \(summary.billedFailureCount) çağrı "
                                + "(%\(Int((summary.wastedShare * 100).rounded())))"
                        )
                        .foregroundStyle(Cizgi.danger)
                    }
                }

                if summary.hasUnmeasuredSpend {
                    LabeledContent("Ölçülemedi") {
                        Text("\(summary.unmeasuredCount) çağrı")
                            .foregroundStyle(Cizgi.warning)
                    }
                }

                if summary.freeFailureCount > 0 {
                    LabeledContent("Reddedildi (ücretsiz)", value: "\(summary.freeFailureCount)")
                }

                NavigationLink(value: AppNavigator.SettingsRoute.usageDetail) {
                    Text("Çağrı dökümü")
                }
            } header: {
                Text("Kullanım")
            } footer: {
                Text(Self.usageFooter(summary))
            }
        }
    }

    /// Projects a stored row into the value type the arithmetic works on.
    ///
    /// Rows written before per-call accounting carry an empty `billing`; they
    /// were only ever written on success, so treating them as measured is
    /// exactly right and keeps the old totals intact.
    static func entry(for run: ModelRun) -> UsageEntry {
        UsageEntry(
            purpose: run.purpose,
            model: run.model,
            success: run.success,
            billing: run.billing.isEmpty ? ModelRunBilling.measured : run.billing,
            inputTokens: run.inputTokens,
            cachedInputTokens: run.cachedInputTokens,
            outputTokens: run.outputTokens,
            reasoningTokens: run.reasoningTokens,
            estimatedCostUSD: run.estimatedCostUSD
        )
    }

    /// Four decimals, not two: a single page costs single-digit cents, and
    /// "0,00 USD" for a real call reads as free.
    static func usd(_ value: Double) -> String {
        String(format: "%.4f USD", value)
    }

    static func usageFooter(_ summary: UsageSummary) -> String {
        if summary.totalCostUSD <= 0 {
            return "Maliyet için sunucuda OPENAI_/GEMINI_USD_PER_MILLION_* değerleri "
                + "ayarlanmalı; uydurma bir fiyat gösterilmiyor."
        }
        var lines = ["Sunucudaki fiyat ayarlarından hesaplanır."]
        if summary.hasUnmeasuredSpend {
            // The honest caveat, and the reason this screen can disagree with
            // the provider's dashboard by a knowable amount rather than an
            // unknown one.
            lines.append(
                "\(summary.unmeasuredCount) çağrı modele ulaştıktan sonra kesildi; sağlayıcı "
                    + "bunları faturalamış olabilir ama ne kadar olduğunu bildirmedi. Toplam bu "
                    + "yüzden bir alt sınırdır."
            )
        }
        return lines.joined(separator: " ")
    }

    /// Cloud OCR setup (§7.2, §7.3).
    @ViewBuilder
    private var backendSection: some View {
        Section {
            TextField("https://sunucu-adresin", text: Binding(
                get: { environment.settings.backendURL },
                set: {
                    environment.settings.backendURL = $0
                    environment.settings.save()
                    environment.backendChanged()
                }
            ))
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif

            SecureField(environment.hasDeviceToken ? "Kayıtlı — değiştirmek için yaz" : "Cihaz anahtarı", text: $deviceToken)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            HStack {
                Button("Anahtarı kaydet") { saveToken() }
                    .disabled(deviceToken.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if environment.hasDeviceToken {
                    Button("Sil", role: .destructive) { clearToken() }
                }
            }

            LabeledContent("Durum") {
                Label(
                    environment.isBackendConfigured ? "Bağlı" : "Ayarlanmadı",
                    systemImage: environment.isBackendConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(environment.isBackendConfigured ? .green : .orange)
            }

            if let tokenError {
                Text(tokenError).font(.footnote).foregroundStyle(.red)
            } else if tokenSaved {
                Text("Anahtar kaydedildi.").font(.footnote).foregroundStyle(.green)
            }
        } header: {
            Text("Bulut OCR")
        } footer: {
            Text("Apple Vision Türkçe okumuyor; ı, ş, ğ ve İ harflerini hiç üretemiyor. Bu yüzden metin tanıma sunucu üzerinden yapılıyor. Anahtar yalnız bu cihazın Keychain'inde durur, uygulamanın içine gömülmez.")
        }
    }

    private func saveToken() {
        do {
            try environment.tokenStore.write(deviceToken)
            deviceToken = ""
            tokenError = nil
            tokenSaved = true
            environment.backendChanged()
        } catch {
            tokenSaved = false
            tokenError = "Anahtar kaydedilemedi: \(error)"
        }
    }

    private func clearToken() {
        try? environment.tokenStore.clear()
        deviceToken = ""
        tokenSaved = false
        tokenError = nil
        environment.backendChanged()
    }

    private func updateNotification() {
        Task {
            do {
                try await ReviewNotificationManager.reschedule(
                    enabled: environment.settings.notificationsEnabled,
                    hour: environment.settings.notificationHour,
                    // Suspended cards are excluded for the same reason the
                    // review screen excludes them.
                    dueDates: cards.filter { $0.status == .active }.map(\.dueDate)
                )
                notificationError = nil
            } catch {
                environment.settings.notificationsEnabled = false
                environment.settings.save()
                notificationError = error.localizedDescription
            }
        }
    }

    private func prepareExport() {
        do {
            let records = cards.map { card in
                BackupExporter.CardRecord(
                    id: card.id, type: card.type.rawValue, front: card.front, back: card.back,
                    explanation: card.explanation, sourceQuote: card.sourceQuote,
                    subject: card.knowledgeUnit?.subject, status: card.status.rawValue,
                    dueDate: card.dueDate, stability: card.stability, difficulty: card.difficulty,
                    reviewCount: card.reviewCount, lapseCount: card.lapseCount,
                    createdAt: card.createdAt, updatedAt: card.updatedAt,
                    lastReviewedAt: card.lastReviewedAt,
                    tags: card.knowledgeUnit?.tags ?? [],
                    canonicalClaim: card.knowledgeUnit?.canonicalClaim,
                    // The review history is the point of version 2: it is the
                    // only record of how this memory behaved, and the input FSRS
                    // weight optimisation needs (docs/FAZ4-PLAN.md). Until now it
                    // could never leave the device.
                    reviews: card.reviews
                        .sorted { $0.reviewedAt < $1.reviewedAt }
                        .map { log in
                            BackupExporter.ReviewRecord(
                                reviewedAt: log.reviewedAt,
                                rating: log.rating.rawValue,
                                responseTimeMs: log.responseTimeMs,
                                scheduledDays: log.scheduledDays,
                                elapsedDays: log.elapsedDays,
                                stabilityBefore: log.stabilityBefore,
                                stabilityAfter: log.stabilityAfter,
                                difficultyBefore: log.difficultyBefore,
                                difficultyAfter: log.difficultyAfter,
                                deviceTimeZone: log.deviceTimeZone
                            )
                        },
                    // §13.3: without these a restored five-option card would be
                    // a question with nothing to choose from.
                    options: card.options,
                    lowConfidence: card.lowConfidence,
                    // Alongside `subject`: without it a restored deck lands
                    // entirely in "Konusuz" and no topic filter reproduces it.
                    topic: card.knowledgeUnit?.topic,
                    softLapseCount: card.softLapseCount,
                    lastPracticedAt: card.lastPracticedAt,
                    // docs/ADR-008: exported as already-finalized (see
                    // `CardRecord.fesInitializedAt`'s doc comment) — Egzersiz's
                    // own history never travels in this file, so the receiving
                    // device cannot recompute this from scratch.
                    fesScore: card.fesScore,
                    fesNegativeCount: card.fesNegativeCount,
                    fesInitializedAt: card.fesInitializedAt
                )
            }
            let data = try BackupExporter.encode(cards: records)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cizgi-yedek.json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = "Yedek hazırlanamadı: \(error.localizedDescription)"
        }
    }

    /// Reads a backup and inserts the cards this device does not already have.
    ///
    /// Additive, never destructive — `BackupRestorer.plan` decides that, and the
    /// reasoning is with it. Restoring is also the one place the app takes a
    /// file it did not write, so the decode is allowed to fail loudly rather
    /// than half-succeed.
    private func restore(from result: Result<[URL], Error>) {
        restoreSummary = nil
        restoreError = nil
        do {
            guard let url = try result.get().first else { return }
            // A file from the Files app lives outside the sandbox until asked
            // for; without this the read fails with a permission error that
            // looks like a corrupt backup.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let backup = try BackupExporter.decode(try Data(contentsOf: url))
            let plan = BackupRestorer.plan(
                records: backup.cards,
                existingIds: Set(cards.map(\.id))
            )
            guard !plan.isEmpty else {
                restoreSummary = "Yedekteki \(backup.cards.count) kartın hepsi zaten burada."
                return
            }

            for record in plan.toInsert {
                insert(record, into: context)
            }
            do {
                try context.save()
            } catch {
                // A failed save leaves every inserted object sitting in the
                // context, where an unrelated later save would flush half a
                // restore into the store. Rolling back is the only way to make
                // "the restore failed" mean nothing was written.
                context.rollback()
                throw error
            }

            // A restored pre-v6 card arrives with `fesInitializedAt == nil`.
            // Without this call, studying it before the next cold start would
            // let the live-update paths in `ReviewView.grade`/
            // `ExerciseView.applyFesScore` stamp that field over a score that
            // never replayed the just-restored `ReviewLog` history — a real
            // and permanent loss, not a defensive no-op (Codex review, PR #41,
            // second pass). Running it here, on this restore's own context,
            // closes the gap before the user can ever touch the card.
            FesBackfillMigration.runIfNeeded(context: context)

            restoreSummary = plan.skipped.isEmpty
                ? "\(plan.toInsert.count) kart geri yüklendi."
                : "\(plan.toInsert.count) kart geri yüklendi, \(plan.skipped.count) tanesi zaten vardı."
        } catch {
            restoreError = (error as? LocalizedError)?.errorDescription
                ?? "Yedek okunamadı: \(error.localizedDescription)"
        }
    }

    /// A restored card gets its own `KnowledgeUnit` to carry the subject, tags
    /// and read text — there is no page to attach it to, because images are
    /// deliberately not in the backup (§24.6). "Kaynağı göster" will therefore
    /// show the text but no photograph, which is the honest result.
    private func insert(_ record: BackupExporter.CardRecord, into context: ModelContext) {
        let card = Card(
            id: record.id,
            type: CardType(rawValue: record.type) ?? .directRecall,
            front: record.front,
            back: record.back,
            explanation: record.explanation,
            sourceQuote: record.sourceQuote,
            status: CardStatus(rawValue: record.status) ?? .active,
            createdAt: record.createdAt == .distantPast ? .now : record.createdAt,
            dueDate: record.dueDate,
            options: record.options,
            lowConfidence: record.lowConfidence
        )
        // Scheduling state is assigned after init, which resets it to zero.
        card.stability = record.stability
        card.difficulty = record.difficulty
        card.reviewCount = record.reviewCount
        card.lapseCount = record.lapseCount
        card.softLapseCount = record.softLapseCount
        card.lastPracticedAt = record.lastPracticedAt
        card.lastReviewedAt = record.lastReviewedAt
        card.fesScore = record.fesScore
        card.fesNegativeCount = record.fesNegativeCount
        // `nil` on a pre-v6 backup is correct as-is: it tells
        // `FesBackfillMigration` to replay this card from its restored
        // `ReviewLog` history, which is the honest best effort available.
        card.fesInitializedAt = record.fesInitializedAt
        card.updatedAt = record.updatedAt == .distantPast ? card.createdAt : record.updatedAt

        // A backup can carry pre-picker subjects ("patoloji", free text) that
        // the one-time migration will never see: on a fresh install its flag is
        // set during the first launch, while the store is still empty, and a
        // restore happens afterwards. Normalizing here is what keeps a restored
        // card inside the same picker and filters as a captured one.
        let schema = SubjectTopicSchema.shared
        let subject = schema.map {
            SubjectBackfill.restoredSubject(existing: record.subject, schema: $0, fallback: "Patoloji")
        } ?? record.subject
        // Re-checked against the subject the card actually ends up with: a
        // remapped subject can leave a stored topic belonging to another ders.
        let topic = TopicGrouping.validatedTopic(record.topic, subject: subject, schema: schema)

        if subject != nil || topic != nil || !record.tags.isEmpty || record.canonicalClaim != nil {
            let unit = KnowledgeUnit(
                canonicalClaim: record.canonicalClaim ?? record.front,
                subject: subject,
                topic: topic,
                tags: record.tags,
                createdAt: card.createdAt
            )
            context.insert(unit)
            card.knowledgeUnit = unit
        }
        context.insert(card)

        for review in record.reviews {
            let log = ReviewLog(
                reviewedAt: review.reviewedAt,
                rating: ReviewRating(rawValue: review.rating) ?? .good,
                responseTimeMs: review.responseTimeMs,
                scheduledDays: review.scheduledDays,
                elapsedDays: review.elapsedDays,
                stabilityBefore: review.stabilityBefore,
                stabilityAfter: review.stabilityAfter,
                difficultyBefore: review.difficultyBefore,
                difficultyAfter: review.difficultyAfter,
                deviceTimeZone: review.deviceTimeZone
            )
            log.card = card
            context.insert(log)
        }
    }
}
