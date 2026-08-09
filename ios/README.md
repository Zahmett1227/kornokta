# Çizgi — iOS (Faz 6 tamam + galeri içe aktarma + beş şıklı kart)

Ana akış: **işaretli sayfayı çek → sayfa doğrudan bir vision modeline gider →
kartlar onaysız aktif desteye girer → FSRS-6 ile tekrar edilir.** Onay ekranı,
cihaz-üstü işaret tespiti ve bulut OCR ana akıştan çıktı (kod geri dönüş için
diskte, çağrılmıyor — `docs/ADR-005-kisisel-vision-yeniden-tasarim.md`).

Kart üretimi **asenkron**: telefon `POST /api/jobs` ile sayfayı bırakır ve
saniyeler içinde 202 alır, üretim sunucuda sürer, telefon `GET /api/jobs?ids=`
ile yoklar. İş kimliği = sayfa kimliği, yani uygulama beklerken kapansa bile
sonuç kaybolmaz ve aynı sayfa iki kez üretilmez
(`docs/ADR-006-supabase-is-kuyrugu.md`).

Backend URL ve cihaz tokenı girilmemişse kart üretimi sahte (`MockCardProvider`)
ve vision modunda anlamlı kart üretmez — Faz 6 yapılandırılmış bir backend
bekler. Tekrar etmek her zaman çevrimdışı çalışır.

Sayfa **galeriden** de eklenebilir: seçilen her fotoğraf tek noktada JPEG'e ve
düz yöne normalize edilip (`ImportedImage`) kameranın yoluna girer — yinelenen
sayfa sorusu, kuyruk ve iş kuyruğu ondan sonrasını aynı şekilde işler.

Kartların bir kısmı **beş şıklı (TUS tipi)** olabilir (§13.3). Şıkka dokununca
doğru/yanlış işaretlenir ve her yanlış şıkkın neden yanlış olduğu açılır;
**yanlış şık seçmek doğrudan "Unuttum"dur**, doğru seçince Zor/İyi/Kolay
sorulur. Ne kadarının beş şıklı olacağı Ayarlar → "Beş şıklı kart"
(Kapalı/Karışık/Hepsi) ile ayarlanır; sunucu kendi ayarını tavan kabul eder.

**Yeni dosya eklendiyse `cd ios && xcodegen generate` şart** — `.xcodeproj`
bilinçli olarak commit edilmiyor.

## Cihazda OCR yok — bilerek

Faz 6'dan beri uygulama cihazda hiç OCR yapmıyor; sayfayı okuyan tek şey
backend'deki vision modeli. Apple Vision zaten Türkçe metin tanımayı
desteklemiyordu (ölçüldü — `docs/ADR-002`, tarihsel); eski OCR/işaret-tespiti
katmanı 2026-08-09 tıraşında koddan silindi.

## Yapı

```
ios/
├── CizgiCore/          Swift paketi — mantık, Xcode'suz test edilebilir
│   ├── Models/             SwiftData modelleri (§16), ders/konu şeması, Bilgi Haritası
│   ├── Annotation/         AnnotationGroup — persist'in konuştuğu grup sözleşmesi
│   ├── Queue/              Durum makinesi ve vision işlem hattı (§17)
│   ├── Backend/             BackendConfiguration, DeviceTokenStore (Keychain), UploadImageEncoder
│   ├── Providers/          Kart üretimi protokolü: sahte + gerçek backend sağlayıcı
│   ├── Scheduling/         FSRS-6 + oturum kurgusu + Egzersiz (ExerciseSession,
│   │                       EarlyPractice — ADR-007 köprüsü, ReviewSession, ReviewPace)
│   └── Storage/            Görüntü deposu (§8.3), yedek al/geri yükle (v5), algısal hash
├── App/                SwiftUI uygulaması
│   └── Features/Capture, ProcessingQueue, Review (Tekrar + Egzersiz),
│                Library (Bilgilerim + Bilgi Haritası), Settings
├── spikes/AppleVisionSpike/   Tarihsel ölçüm aracı (bağımsız paket)
└── project.yml         XcodeGen spec
```

## Mantığı test et (Xcode gerekmez)

```bash
cd ios/CizgiCore
swift test
```

Kapsam: durum makinesi, işlem hattı, tekrar oturumu (kuyruk/öğrenme adımı/geri
alma/günlük hak), Egzersiz oturumu ve `EarlyPractice` köprüsü, kart düzenleme
ve kaynak çözümleme kuralları, yedek al/geri yükle, algısal hash, hatırlatıcı
planı, görüntü deposu, backend sağlayıcısı, beş şıklı kart kuralları ve FSRS-6
(paylaşılan Python vakalarına karşı sabitlenmiş). Kamera ve SwiftUI dışarıda
kalır — onlar cihazda denenir.

Paket **yalnız bir Mac'te derlenir** (CoreGraphics, SwiftData). Linux'ta
Foundation'a bağlı dosyalar izole bir pakete alınıp gerçekten koşturulabilir;
SwiftUI dosyaları için elde yalnız `swiftc -parse` vardır ve o tip hatalarını
yakalamaz — App hedefinin tek gerçek kapısı Xcode derlemesidir.

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

## Cihazda elle kontrol listesi (Faz 6 kabulü)

Önce Ayarlar'a backend adresini ve cihaz tokenını gir (`backend/README.md`);
"Bağlı" ve "Vision — işaretli sayfadan doğrudan kart" görünmeli.

- [ ] İşaretli bir sayfa çek → **hiçbir onay adımı olmadan** kartlar aktif
      desteye giriyor; kartlar ağırlıklı olarak işaretlediğin yerden
- [ ] **Galeriden ekle** → seçilen fotoğraf kamerayla çekilmiş gibi kart
      üretiyor. Özellikle dene: **küçük boyutlu bir HEIC** (galerinin varsayılan
      formatı) ve **yan çekilmiş** bir fotoğraf — ikisi de içe aktarmada JPEG'e
      ve düz yöne çevriliyor
- [ ] Sayfa olmayan bir fotoğraf seç → kuyrukta "Bu fotoğrafta işaretlenmiş bir
      şey bulunamadı" yazıyor (ham hata adı değil)
- [ ] **5–10 fotoğrafı tek partide** yükle → gönderim saniyeler sürüyor, ekran
      kilitlense/uygulama kapatılsa bile kartlar sonradan geliyor, hiçbir sayfa
      iki kez üretilmiyor
- [ ] Aynı sayfayı ikinci kez çek → "daha önce çekmişsin" sorusu çıkıyor
      (reddetmiyor, soruyor)
- [ ] Uçak modunda çek → hata kaybolmuyor; ağ gelince "Tekrar dene" aynı kaydı
      tamamlıyor
- [ ] Tekrar: normal oturum bugün bekleyen **tüm** kartları veriyor; hızlı
      oturum ayrı bir seçenek ve süre bütçesine uyuyor
- [ ] "Unuttum" dediğin kart aynı oturumun sonunda geri geliyor; "Geri al" son
      puanlamayı gerçekten geri alıyor
- [ ] Tekrar ekranından kartı düzenle / askıya al çalışıyor; askıya alınan kart
      oturumdan çıkıyor
- [ ] "Kaynağı göster" sayfa fotoğrafını ve modelin okuduğu metni gösteriyor
      ("Orijinal sayfayı sakla" kapalıysa bunu söylüyor)
- [ ] Günlük yeni kart limiti ekranı yeniden açınca sıfırlanmıyor
- [ ] Bildirim izni verildiğinde hatırlatma **gerçek sayıyı** söylüyor ve
      dokununca Tekrar sekmesi açılıyor
- [ ] "Yedeği hazırla → paylaş" JSON'unda görüntü/base64 yok; "Yedekten geri
      yükle" mevcut kartları ezmeden eksikleri ekliyor
- [ ] Uygulamayı tamamen kapat, tekrar aç → kartlar ve kuyruk duruyor (§24.1)

Beş şıklı kart (§13.3) için ayrıca:

- [ ] Ayarlar → **Beş şıklı kart: Hepsi** yapıp bir sayfa çek → kartların bir
      kısmı beş şıklı geliyor
- [ ] Yanlış şık seç → kart otomatik "Unuttum" alıyor (dört puan gösterilmiyor)
      ve seçtiğin şıkkın **neden yanlış** olduğu yazıyor
- [ ] Doğru şık seç → Zor/İyi/Kolay soruluyor
- [ ] Aynı kartı iki tekrarda gör → şıkların sırası değişiyor, ama bir tekrar
      boyunca sabit kalıyor
- [ ] Bilgilerim → kartı düzenle → doğru şıkkı değiştir → "Cevap" da onunla
      değişiyor; "Şıkları kaldır" kartı silmeden düz karta çeviriyor
- [ ] Bilgilerim'de **"Gözden geçir"** bölümü: sunucunun emin olamadığı kartlar
      orada listeleniyor ve tekrar ekranında rozetle görünüyor

Tam liste ve geçmiş bulgular: `docs/FAZ5-DURUM.md`, `CLAUDE.md` → "Sıradaki iş".

## Bilinçli olarak henüz yok

| Eksik | Nerede |
|---|---|
| Gerçek iPhone kabul testi (yukarıdaki liste) | `docs/FAZ5-DURUM.md`, `docs/FAZ6-PLAN.md` §11 |
| `Models` alan sadeleşmesi + SwiftData göçü | `docs/FAZ6-PLAN.md` §9 |
| Kartlarda kaynak kırpıntısı ve kitap/sayfa bilgisi (§5.5) | Vision akışında tam sayfa var, kırpıntı yok — uydurulmadı |
