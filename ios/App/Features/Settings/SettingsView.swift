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

                Section("Veri") {
                    LabeledContent("Kart", value: "\(cards.count)")
                    LabeledContent("Çekilen sayfa", value: "\(pages.count)")
                    Toggle("Orijinal sayfayı sakla", isOn: Binding(
                        get: { environment.settings.keepOriginalPage },
                        set: { environment.settings.keepOriginalPage = $0; environment.settings.save() }
                    ))
                }

                Section {
                    LabeledContent("Aşama", value: environment.isBackendConfigured ? "Faz 3 — yapay zeka kart üretimi" : "Faz 2 — bulut OCR")
                    LabeledContent("Metin tanıma", value: environment.isBackendConfigured ? "Google Document AI" : "Yalnız cihaz (Türkçe okumaz)")
                    LabeledContent("Kart üretimi", value: environment.isBackendConfigured ? "Gerçek (backend)" : "Sahte sağlayıcı")
                    LabeledContent("Tekrar algoritması", value: "Geçici (FSRS Faz 4)")
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
}
