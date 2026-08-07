# Plan — galeriden fotoğraf ekleme

**Durum:** ✅ tamam — G1–G3 uygulandı ve **G4 gerçek iPhone'da doğrulandı**
(kullanıcı, 2026-08-07) ·
**Tarih:** 2026-08-07 · **Büyüklük:** küçük (bir oturum) ·
**Dayanak:** ANA-PLAN §8.1 (yakalama), §21.2 (bir çekim kaybolmaz), §24.6
(görüntü gizliliği), §4.3 (PDF/Share Sheet *sonraki* sürüm adayı).

## 0. Bir cümlede

Yakala ekranına **"Galeriden ekle"** koy: kullanıcı daha önce çekilmiş sayfa
fotoğraflarını seçsin, uygulama onları **kamera çekimiyle birebir aynı yola**
soksun (yinelenen sorusu → kuyruk → asenkron üretim → onaysız kart).

## 1. Neden

- Telefonda **zaten çekilmiş** sayfa fotoğrafları var; bugün onları uygulamaya
  sokmanın hiçbir yolu yok — kitabı tekrar açıp aynı sayfayı yeniden çekmek
  gerekiyor.
- Arkadaşın gönderdiği bir sayfa fotoğrafı, bir ekran görüntüsü, ders notunun
  fotoğrafı — hepsi aynı boşluğa düşüyor.
- Maliyeti düşük: **üretim tarafında hiçbir şey değişmiyor.** Kuyruk,
  paralellik, iş kuyruğu, yinelenen tespiti, kart yazma — hepsi zaten
  `Data` alıyor. Eklenen tek şey o `Data`'nın ikinci bir kaynağı.

## 2. Bugünkü yol ve nereye takılıyor

Bugün tek giriş var:

```
DocumentScanner (VNDocumentCameraViewController)
  → [Data] (JPEG, q=0.9, perspektifi düzeltilmiş)
  → CaptureView.handleScanned  → dHash yinelenen sorusu
  → ProcessingQueue.enqueue    → ImageStore.store(..., fileExtension: "jpg")
  → CapturePipeline            → UploadImageEncoder.prepare → /api/jobs
```

"Sadece `PhotosPicker` ekle" **yetmez**; kodu okuyunca üç gerçek tuzak çıkıyor:

### 2.1 HEIC (en kritik)

iPhone galerisindeki fotoğraflar çoğunlukla **HEIC**. Zincirin iki yeri bunu
sessizce yanlış etiketler:

- `ImageStore.store(_:id:kind:fileExtension:)` uzantıyı **varsayılan `"jpg"`**
  yazıyor.
- `CapturePipeline.mimeType(for:)` MIME'ı **uzantıdan** türetiyor → `image/jpeg`.

Sonra `UploadImageEncoder.prepare`, görüntü zaten 2600 px ve 3.2 MB altındaysa
**yeniden kodlamadan geçiriyor** ("untouched" dalı — bilinçli, JPEG'i yeniden
kodlamak kalite kaybı). Yani: **HEIC baytları, `image/jpeg` etiketiyle
sunucuya gider.** OpenAI HEIC kabul etmiyor → sayfa `permanentFailure`.

Büyük bir fotoğrafta sorun görünmez (yeniden kodlanır, gerçekten JPEG olur),
küçük bir fotoğrafta patlar. Bu tür "bazen çalışıyor" hataları en pahalısıdır.

### 2.2 EXIF yönü

Galeri fotoğrafı yönünü bir **EXIF bayrağında** taşır; belge kamerasının
çıktısı taşımaz (pikseller zaten düz). Yön piksellere işlenmezse vision modeli
sayfayı yan/ters okur — ve model bunu "okuyamadım" diye söylemez, sessizce kötü
kart üretir. Yön, içe aktarmada **piksellere yazılmalı**.

### 2.3 Belge kamerasının yaptığı işi kimse yapmıyor

`VNDocumentCameraViewController` sayfa kenarını buluyor, perspektifi düzeltiyor,
kırpıyor. Galeriden gelen fotoğrafta masa, parmak, eğri sayfa olabilir. Vision
modeli buna kameradan daha toleranslı (tüm sayfayı yorumluyor), ama kart
kalitesi düşer.

**Karar: ilk sürümde otomatik kırpma/düzeltme yok.** Sebep: yanlış kırpmak,
kırpmamaktan kötü (§0.5'in ruhu — sessizce içerik atmak). Sonraki adım olarak
`VNDetectRectanglesRequest` ile *öneri* sunulabilir; kapsam dışı (§9).

## 3. Tasarım kararı — tek noktada normalize et

İçe aktarma anında **her fotoğraf JPEG'e çevrilir**, yönü piksellere işlenir ve
gerekirse küçültülür. Böylece o noktadan sonra sistemin geri kalanı hiçbir
format dallanması görmez: depolama, dHash, "Kaynağı göster", yükleme, hepsi
bugünkü kamera çekimiyle aynı baytlarla çalışır.

Alternatif — "formatı taşı, en sonda dönüştür" — daha az kayıplı ama `ImageStore`,
`CapturedPage`, `mimeType(for:)`, `UploadImageEncoder` ve yedek yolunu birden
etkiler. Kişisel bir uygulamada tek bir yeniden kodlamanın maliyeti, beş yerde
format bilgisi taşımanın karmaşasından ucuz.

Nerede yaşayacağı:

| Parça | Yer | Neden |
|---|---|---|
| **Karar mantığı** — bu bayt dizisi yeniden kodlanmalı mı, hangi uzun kenar, hangi kalite | `ios/CizgiCore/.../Backend/ImportedImage.swift` (Foundation-only) | **Bu ortamda gerçekten test edilebilir** (imza tespiti bayt başlıklarından: JPEG `FFD8`, PNG `89504E47`, HEIC `ftypheic/heix/mif1`) |
| **Piksel işi** — decode, yön uygula, JPEG yaz | Aynı dosyada `#if canImport(ImageIO)` bloğu | ImageIO Linux'ta yok; kalıp `UploadImageEncoder`'ın bugünkü kalıbının aynısı |
| **Seçici (picker)** | `ios/App/Features/Capture/PhotoLibraryImporter.swift` | SwiftUI/PhotosUI, App hedefi |

## 4. Arayüz

- **`PhotosPicker`** (PhotosUI, iOS 16+; hedef zaten iOS 17).
  `matching: .images`, `maxSelectionCount:` (öneri **10** — üstü kuyruk için
  değil, maliyet için: 20 sayfa 20 üretim demek), `photoLibrary: .shared()`.
- **İzin istemez.** `PhotosPicker` ayrı bir süreçte çalışır; uygulama
  kütüphaneye **hiç erişmez**, yalnız kullanıcının seçtiği öğeleri alır. Yani
  "Fotoğraflara Erişim" izni sorulmaz ve `Info.plist`'teki
  `NSPhotoLibraryUsageDescription` bu akış için gereksizdir (dursun, zararsız —
  ileride doğrudan erişim gerekirse lazım olur).
- **Yerleşim:** Yakala ekranında birincil "İşaretli sayfayı çek" düğmesinin
  altında **ikincil** bir düğme: `Label("Galeriden ekle", systemImage: "photo.on.rectangle")`.
  Kamera birincil kalır — ana akış hâlâ kitabı açıp çekmek.
- **İlerleme:** iCloud'da duran (cihazda optimize edilmiş) bir fotoğraf
  indirilir; bu saniyeler sürebilir. Seçim sonrası "N fotoğraf hazırlanıyor…"
  göstergesi şart, yoksa uygulama donmuş görünür.

## 5. Akış

```
PhotosPicker seçimi
  → her öğe için loadTransferable(type: Data.self)      (sırayla — aşağıya bak)
  → ImportedImage.normalize(...)                        → JPEG + yön + boyut
  → CaptureView.handleScanned([Data])                   ← BURADAN SONRASI AYNI
      → PerceptualHasher.duplicateIndices(...)          → "daha önce çekmişsin?"
      → ProcessingQueue.enqueue → /api/jobs → kartlar
```

Yükleme **sırayla**, paralel değil: iCloud'da duran bir öğe burada indiriliyor
ve aynı anda on indirme başlatmak hepsini yavaşlatırken ilerleme sayısını da
anlamsızlaştırır.

Kritik nokta: **`handleScanned`'e giriyor**, kendi yolunu açmıyor. Yinelenen
sorusu, kuyruk, paralellik, retry, iş kuyruğu — hiçbiri değişmiyor ve galeriden
içe aktarma bunların hepsini kendiliğinden miras alıyor. (Yinelenen tespiti
burada özellikle değerli: aynı fotoğrafı ikinci kez içe aktarmak, aynı sayfayı
ikinci kez çekmekten **daha** olası.)

## 6. Kenar durumlar

| Durum | Davranış |
|---|---|
| Bir öğe okunamadı / iCloud'dan inmedi | O öğe atlanır, **diğerleri devam eder**; sonda "N fotoğraftan M'si alınamadı" (§21.2: bir çekim sessizce kaybolmaz) |
| Live Photo | `.images` filtresiyle sabit kare gelir — sorun yok |
| Ekran görüntüsü (PNG) | Desteklenir; PNG zaten kabul edilen bir format, yine de JPEG'e normalize edilir |
| Video / GIF | Filtre dışı, seçilemez |
| Çok büyük panorama | `UploadImageEncoder`'ın bugünkü 2600 px / 3.2 MB bütçesi zaten uygular |
| Aynı fotoğraf ikinci kez | dHash sorar (reddetmez) |
| Sayfa olmayan fotoğraf (kedi resmi) | Model kart üretmez → bugün `.invalidResponse` → arayüzde "geçersiz yanıt" gibi okunur. **Bu plana dahil düzeltme:** ayrı bir hata nedeni (`FailureKind` ya da mesaj katmanı) → *"Bu fotoğrafta işaretlenmiş bir şey bulunamadı."* Galeri bunu sık hâle getireceği için şart. |

## 7. Gizlilik (§24.6)

- Galeriden gelen fotoğraf da diğerleri gibi: yalnız üretim için yüklenir, iş
  bitince Supabase Storage'dan silinir, yedeğe **girmez**.
- Uygulama kullanıcının galerisine **hiç dokunmaz**: içe aktarılan fotoğraf
  galeride kalır, silinmez, değiştirilmez. (İçe aktardıktan sonra galeriden
  silme gibi bir "temizlik" özelliği bilerek yok.)
- "Orijinal sayfayı sakla" ayarı aynen geçerli — kapalıysa üretim biter bitmez
  uygulamanın kendi kopyası silinir, galerideki asıl fotoğrafa dokunulmaz.

## 8. Dosya bazlı değişiklikler

| Dosya | Değişiklik |
|---|---|
| `ios/CizgiCore/.../Backend/ImportedImage.swift` | **Yeni.** Bayt imzasından format tespiti, "yeniden kodla mı" kararı, ImageIO ile JPEG'e normalize + yön |
| `ios/App/Features/Capture/PhotoLibraryImporter.swift` | **Yeni.** `PhotosPicker` yükleyicisi, sıralı indirme, ilerleme, kısmi hata sayımı |
| `ios/App/Features/Capture/CaptureView.swift` | "Galeriden ekle" düğmesi, seçim durumu, `handleScanned`'e bağlanma, "N alınamadı" mesajı |
| `ios/CizgiCore/.../Queue/StateMachine.swift` + `CapturePipeline.swift` | Kart üretilmeyen sayfa için ayrı hata nedeni/mesajı (§6 son satır) |
| `ios/App/Features/ProcessingQueue/QueueView.swift` | O mesajın gösterimi |
| `ios/project.yml` | Değişiklik **gerekmiyor** (`PhotosUI` sistem çerçevesi, izin metni zaten var). Yeni dosyalar için `xcodegen generate` şart |
| `docs/`, `ios/README.md` | Cihaz kontrol listesine galeri maddeleri |

## 9. Kapsam dışı (bilerek)

- **PDF ve Dosyalar'dan içe aktarma** — ANA-PLAN §4.3'te ayrı bir sonraki sürüm
  adayı; farklı bir sözleşme (çok sayfalı, metin katmanlı).
- **Share Sheet ile "Çizgi'ye gönder"** — aynı yerde, ayrı iş (App Extension).
- **Otomatik sayfa kırpma/perspektif düzeltme** — §2.3'teki gerekçe.
- **Toplu tarih/albüm bazlı içe aktarma** ("son 30 günün tüm sayfa
  fotoğrafları") — maliyeti görünmez biçimde büyütür.

## 10. Aşamalar

| Adım | Kapsam | Nerede doğrulanır |
|---|---|---|
| **G1** | `ImportedImage`: format tespiti + karar mantığı + testler | ✅ **Bu ortamda gerçekten koşuldu** — izole pakette 100 test yeşil (15'i yeni), her yeni test mutasyonla doğrulandı |
| **G2** | ImageIO normalize (JPEG + yön), `PhotoLibraryImporter`, `CaptureView` bağlantısı | ✅ Yazıldı — **Mac derlemesi bekliyor** |
| **G3** | "Kart üretilmedi" hata nedeni ve mesajı | ✅ `FailureKind.noContent` + her hataya Türkçe `message`; kuyruk artık ham enum adı basmıyor |
| **G4** | Cihaz doğrulaması (§11) | ✅ Kullanıcı gerçek iPhone'da denedi, sorun çıkmadı (2026-08-07) |

## 11. Kabul kriterleri

- Galeriden seçilen bir sayfa fotoğrafı, kamerayla çekilmiş gibi kart üretiyor.
- **HEIC bir fotoğraf** (küçük boyutlu olan dahil) sorunsuz gidiyor — bu, §2.1
  yüzünden ilk denenecek şey.
- **Yan çekilmiş** bir fotoğraf düz okunuyor (kartlar tutarlı çıkıyor).
- Aynı fotoğrafı ikinci kez seçince "daha önce çekmişsin" sorusu çıkıyor.
- 5+ fotoğraf tek seferde seçilince hepsi kuyruğa giriyor, uygulama kapatılsa
  bile kartlar geliyor (mevcut iş kuyruğu davranışı).
- iCloud'dan inmesi gereken bir fotoğrafta ilerleme görünüyor; inemezse
  **diğerleri yine de** ekleniyor ve kaçının alınamadığı söyleniyor.
- Sayfa olmayan bir fotoğrafta anlaşılır bir mesaj çıkıyor ("işaretlenmiş bir
  şey bulunamadı"), "geçersiz yanıt" değil.

## 12. Sıra önerisi

Bu iş **beş şıklı karttan önce** yapılmalı: küçük, bağımsız, sözleşmeye
dokunmuyor (`docs/FAZ7-PLAN-coktan-secmeli.md` şema v2.1 + beş dosyalık
anti-drift zinciri demek), ve elindeki fotoğraf arşivini hemen kullanılabilir
hâle getirdiği için beş şıklı kartın kalite döngüsüne (A6) **daha çok gerçek
sayfa** sağlar.
