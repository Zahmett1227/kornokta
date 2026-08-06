import SwiftUI
import SwiftData
import CizgiCore

/// Settings (ANA-PLAN §6.7). Faz 1 exposes the options that already do
/// something; cost limits and export arrive with the backend in Faz 3/5.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Query private var cards: [Card]
    @Query private var pages: [CapturedPage]

    @State private var deviceToken = ""
    @State private var tokenSaved = false
    @State private var tokenError: String?
    @State private var notificationError: String?
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                backendSection

                Section("Yakalama") {
                    TextField("Varsayılan ders", text: Binding(
                        get: { environment.settings.defaultSubject },
                        set: { environment.settings.defaultSubject = $0; environment.settings.save() }
                    ))

                    Stepper(
                        "Pasaj başına kart: \(environment.settings.maxCardsPerPassage)",
                        value: Binding(
                            get: { environment.settings.maxCardsPerPassage },
                            set: { environment.settings.maxCardsPerPassage = $0; environment.settings.save() }
                        ),
                        in: 1...4
                    )
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
                    Button("Yedeği hazırla") { prepareExport() }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("JSON yedeğini paylaş", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let exportError { Text(exportError).font(.footnote).foregroundStyle(.red) }
                }

                Section {
                    LabeledContent("Aşama", value: environment.isBackendConfigured ? "Faz 3 — yapay zeka kart üretimi" : "Faz 2 — bulut OCR")
                    LabeledContent("Metin tanıma", value: environment.isBackendConfigured ? "Google Document AI" : "Yalnız cihaz (Türkçe okumaz)")
                    LabeledContent("Kart üretimi", value: environment.isBackendConfigured ? "Gerçek (backend)" : "Sahte sağlayıcı")
                    LabeledContent("Tekrar algoritması", value: environment.scheduler is FSRSScheduler ? "FSRS-6" : "Geçici (bundled ağırlıklar okunamadı)")
                } header: {
                    Text("Durum")
                } footer: {
                    Text(
                        environment.isBackendConfigured
                            ? "Kartlar backend üzerinden gerçek bir modelden üretiliyor; kaynağı belirsiz olanlar onaya düşer. Tekrar etmek her zaman çevrimdışı çalışır."
                            : "Kart üretimi hâlâ sahte; kartlar taslak niteliğindedir. Tekrar etmek her zaman çevrimdışı çalışır."
                    )
                }
            }
            .navigationTitle("Ayarlar")
            .homeButtonToolbar()
            .onAppear {
                // Shown as a placeholder, never as text: reading the stored
                // token back into an on-screen field would put it somewhere a
                // screenshot or a shoulder can reach (§7.3).
                deviceToken = ""
            }
        }
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
                try await ReviewNotificationManager.update(
                    enabled: environment.settings.notificationsEnabled,
                    hour: environment.settings.notificationHour
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
                    reviewCount: card.reviewCount, lapseCount: card.lapseCount
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
}
