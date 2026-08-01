import SwiftUI
import SwiftData
import CizgiCore

/// Settings (ANA-PLAN §6.7). Faz 1 exposes the options that already do
/// something; cost limits and export arrive with the backend in Faz 3/5.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Query private var cards: [Card]
    @Query private var pages: [CapturedPage]

    var body: some View {
        NavigationStack {
            Form {
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
                    LabeledContent("Aşama", value: "Faz 1 — yerel iskelet")
                    LabeledContent("Kart üretimi", value: "Sahte sağlayıcı")
                    LabeledContent("Tekrar algoritması", value: "Geçici (FSRS Faz 4)")
                } header: {
                    Text("Durum")
                } footer: {
                    Text("Bu sürümde bulut OCR ve gerçek kart üretimi yok; her şey cihazda ve çevrimdışı çalışır. Kartlar taslak niteliğindedir.")
                }
            }
            .navigationTitle("Ayarlar")
        }
    }
}
