# Çizgi — iOS (Faz 1 + Faz 2 tamam, Faz 3 istemci tarafı yazıldı)

Faz 1 hedefi (ANA-PLAN §25) tamam: uygulama çevrimdışı fotoğraf alıp kart
oluşturabiliyor ve tekrar edebiliyor. Faz 2 de tamam: cihaz üstü işaret
tespiti (fosforlu/alt çizgi), bulut OCR (backend üzerinden Google Document
AI) ve iki motorun uzlaştırması çalışıyor. Backend URL ve cihaz tokenı
girilmemişse kart üretimi hâlâ sahte (`MockCardProvider`); girilmişse
`BackendCardProvider` gerçek `/api/cards` çağrısı yapar (§25 Faz 3) — ikisi
de aynı `CardGenerating` protokolünün arkasında, Ayarlar'daki tek anahtar
ikisini de birlikte açıp kapatıyor. Tekrar aralıkları hâlâ geçici (FSRS
Faz 4'te). **Bu istemci kod yazıldı, henüz gerçek bir cihazda/gerçek bir
backend'e karşı elle denenmedi** — bkz. `docs/FAZ3-PLAN.md`.

`swift test` gerçek bir Mac'te **114/114** geçiyor (2026-08-02) — kod elle
incelendi ve ayrıca gerçek derleyicide doğrulandı. Faz 3 istemci kodu ve
yeni testleri (`BackendCardProviderTests.swift`, `BackendPipelineTests.swift`
içindeki `CardGenerationRequestTests`) bu ortamda **yazıldı ama henüz bir
Mac'te `swift test` ile doğrulanmadı** — bu depoda Swift derleyicisi yok.
Bulunan hatalar ve düzeltmeleri `docs/FAZ2-PLAN.md`'de.

## Apple Vision Türkçe okumuyor — bilerek

`docs/ADR-002-birincil-ocr-secimi.md`: Apple Vision Türkçe metin tanımayı
desteklemiyor (ölçüldü — `ı ş ğ İ` sıfır kez). Bu yüzden Vision'ın metni
hiçbir zaman karta gitmiyor; yalnız canlı önizleme ve işaret tespitinin
çalıştığı satır geometrisi için kullanılıyor. Gerçek metin backend
üzerinden Google Document AI'dan geliyor (`CizgiCore/Backend/BackendClient.swift`).

## Yapı

```
ios/
├── CizgiCore/          Swift paketi — mantık, Xcode'suz test edilebilir
│   ├── Models/             SwiftData modelleri (§16)
│   ├── Queue/              Durum makinesi ve işlem hattı (§17)
│   ├── OCR/                TextRecognizing + Vision uygulaması — önizleme/geometri (§10.1)
│   ├── Backend/             BackendClient, DeviceTokenStore (Keychain), UploadImageEncoder
│   ├── MarkerDetection/     İşaret tespiti — evals/spikes/marker_detection'ın Swift portu (§9)
│   ├── Providers/          Kart üretimi protokolü + sahte sağlayıcı
│   ├── Scheduling/         Tekrar planlama (FSRS Faz 4'te gelecek)
│   └── Storage/            Görüntü deposu (§8.3)
├── App/                SwiftUI uygulaması
│   └── Features/Capture, ProcessingQueue, Confirmation, Review, Library, Settings
├── spikes/AppleVisionSpike/   Ölçüm aracı — --input bir klasörü özyinelemeli tarar
└── project.yml         XcodeGen spec
```

## Mantığı test et (Xcode gerekmez)

```bash
cd ios/CizgiCore
swift test
```

114 test: durum makinesi, işlem hattı, planlayıcı, görüntü deposu, backend
istemcisi, işaret tespiti (paylaşılan Python vakalarına karşı sabitlenmiş),
yükleme sıkıştırma. Kamera ve SwiftUI dışarıda kalır — onlar cihazda
denenir.

## Uygulamayı çalıştır

### Yol A — XcodeGen (önerilen)

```bash
brew install xcodegen      # bir kez
cd ios
xcodegen generate
open Cizgi.xcodeproj
```

`.xcodeproj` bilinçli olarak commit edilmiyor: `.pbxproj` diff'te okunamaz ve her değişiklikte çakışır.

### Yol B — Elle Xcode projesi

XcodeGen kurmak istemezsen:

1. Xcode → **File > New > Project… > iOS > App**
   - Product Name: `Cizgi`
   - Interface: **SwiftUI**, Language: **Swift**, Storage: **None**
   - Konum: `ios/` klasörünün **dışı** (üretilen dosyalar repoya karışmasın) veya `ios/Cizgi/`
2. Xcode'un oluşturduğu `ContentView.swift` ve `CizgiApp.swift` dosyalarını **sil**.
3. Finder'dan `ios/App` klasörünü Xcode'a sürükle → **Create groups** seçili, **Copy items if needed** işaretsiz.
4. **File > Add Package Dependencies… > Add Local…** → `ios/CizgiCore` klasörünü seç.
5. Target → **General > Frameworks, Libraries** altında `CizgiCore`'un ekli olduğunu doğrula.
6. Target → **Info** sekmesine iki satır ekle:
   - `NSCameraUsageDescription` → "Kitap sayfalarındaki işaretlediğin bölümleri karta dönüştürmek için kamerayı kullanır. Görüntüler yalnız cihazında saklanır."
   - `NSPhotoLibraryUsageDescription` → "Daha önce çektiğin sayfa fotoğraflarını içe aktarmak için kullanılır."
7. Deployment target: **iOS 17.0** (SwiftData ve `ContentUnavailableView` için gerekli).

### Cihazda dene

Belge kamerası **simülatörde çalışmaz**. Gerçek iPhone gerekiyor: Signing & Capabilities altında kendi Apple ID'ni takım olarak seç, telefonu bağla, çalıştır.

## Faz 1 çıkış kapısı — elle kontrol listesi

Cihazda sırayla:

- [ ] **Uçak modunda** bir kitap sayfası çek → tarama tamamlanınca "kuyruğa alındı" görünüyor
- [ ] Arka arkaya 3 sayfa çek → çekim, işleme bitmesini beklemiyor (§P1)
- [ ] Kuyrukta sayfalar "Onay gerekli" durumuna geçiyor
- [ ] Onay ekranında satırlara dokunup "Kart oluştur" → kartlar üretiliyor
- [ ] Tekrar sekmesinde kart geliyor, cevap açılıyor, dört puan çalışıyor
- [ ] "Kaynağı göster" pasajı gösteriyor
- [ ] Uygulamayı tamamen kapat, tekrar aç → kartlar ve kuyruk duruyor (§24.1)
- [ ] Bilgilerim'de kart görünüyor, askıya alma çalışıyor

Hepsi geçerse Faz 1 kapısı geçilmiş sayılır. Faz 2 için Ayarlar'a backend
URL'i ve cihaz tokenı gir (`backend/README.md`) — girilmezse uygulama yerel
moda düşer, işaret tespiti ve satır seçimi çalışır ama pasaj Vision'ın
(Türkçe okumayan) metniyle dolar; bu bilerek böyle, sessizce yanlış metin
göndermektense hiç göndermemeyi seçiyor.

## Bilinçli olarak henüz yok

| Eksik | Nerede |
|---|---|
| Gerçek kart üretimi (yapay zeka) — istemci kodu yazıldı, cihazda henüz denenmedi | Faz 3 |
| FSRS | Faz 4 — şu an `PlaceholderScheduler` |
| Bildirimler, dışa aktarma, maliyet limiti | Faz 4/5 |

İşaret tespiti kararsız kaldığında (`quick_confirm`) ya da hiçbir şey
bulamadığında (`user_selection`) çekim onay ekranına düşer, pasajı elle
seçersin. Bu bilinçli: §19.3, işaret algılanmayan ve elle seçilmeyen bir
çekimin karta dönüşmesini yasaklıyor. Eşikler
(`evals/spikes/marker_detection/config.json`) "ilk kalibrasyon başlangıcı" —
gerçek sayfalarda ne kadar isabetli olduğu henüz ölçülmedi (`docs/FAZ2-PLAN.md`).
