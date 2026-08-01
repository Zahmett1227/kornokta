# Çizgi — iOS (Faz 1)

Faz 1 hedefi (ANA-PLAN §25): **uygulama çevrimdışı fotoğraf alıp sahte kart oluşturabilmeli ve tekrar edebilmelidir.** Bulut OCR, gerçek kart üretimi ve FSRS bu fazda yok.

> ⚠️ **Varsayım:** Bu faz, Faz 0 çıkış kapılarının geçildiği **varsayılarak** yazıldı. Apple Vision ölçümü (`docs/MAC-ADIMLARI.md`) henüz yapılmadı. Ölçüm beklenenden kötü çıkarsa etkilenecek yer `CizgiCore/Sources/CizgiCore/OCR/` ve onay ekranıdır; veri modeli ve kuyruk etkilenmez.

## Yapı

```
ios/
├── CizgiCore/          Swift paketi — mantık, Xcode'suz test edilebilir
│   ├── Models/         SwiftData modelleri (§16)
│   ├── Queue/          Durum makinesi ve işlem hattı (§17)
│   ├── OCR/            TextRecognizing + Vision uygulaması (§10.1)
│   ├── Providers/      Kart üretimi protokolü + sahte sağlayıcı
│   ├── Scheduling/     Tekrar planlama (FSRS Faz 4'te gelecek)
│   └── Storage/        Görüntü deposu (§8.3)
├── App/                SwiftUI uygulaması
│   ├── Features/Capture, ProcessingQueue, Confirmation, Review, Library, Settings
├── spikes/AppleVisionSpike/   Faz 0 ölçüm aracı
└── project.yml         XcodeGen spec
```

## Mantığı test et (Xcode gerekmez)

```bash
cd ios/CizgiCore
swift test
```

Bu, durum makinesi, işlem hattı, planlayıcı ve görüntü deposunu kapsar. Kamera ve SwiftUI dışarıda kalır — onlar cihazda denenir.

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

Hepsi geçerse Faz 1 kapısı geçilmiş sayılır.

## Bu fazda bilinçli olarak yok

| Eksik | Nerede |
|---|---|
| Cihaz üstü işaret tespiti | Faz 2 — prototip `evals/spikes/marker_detection/` |
| Google Document AI | Faz 2 |
| Gerçek kart üretimi (GPT-5.6 Sol) | Faz 3 |
| FSRS | Faz 4 — şu an `PlaceholderScheduler` |
| Bildirimler, dışa aktarma, maliyet limiti | Faz 4/5 |

İşaret tespiti olmadığı için **her çekim onay ekranına düşer** ve pasajı elle seçersin. Bu bilinçli: §19.3, işaret algılanmayan ve elle seçilmeyen bir çekimin karta dönüşmesini yasaklıyor.
