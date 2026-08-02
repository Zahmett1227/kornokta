# Faz 2 — OCR ve işaret algılama

**Dal:** `claude/faz1-ios-iskelet` (Faz 1'in üstüne)
**ANA-PLAN:** §25 Faz 2
**Çıkış kapısı:** Altın test OCR ve seçim eşikleri karşılanmalı.

---

## Neden bölünüyor

§25 Faz 2'yi yedi kalem olarak sayıyor. Hepsi tek seferde yazılırsa hiçbiri
ayrı ayrı doğrulanamaz; §0 "işi küçük ve doğrulanabilir adımlara böl" diyor.
Sıra, en çok şeyi açan işten başlıyor.

| Adım | İş | Nerede çalışır | Durum |
|---|---|---|---|
| **F2-1** | Backend HTTP ucu + cihaz tokenı | Vercel Functions (§7.2) | ✅ |
| **F2-2** | Kritik token motoru (TypeScript) | Backend | ✅ |
| **F2-3** | OCR uzlaştırma (Apple ↔ Google) | Backend | ✅ |
| **F2-4** | iOS istemcisi; kuyruğa bağlama | Uygulama | ✅ |
| **F2-5** | İşaret tespiti (OpenCV spike'ın Swift'e taşınması) | Cihaz | ✅ |
| **F2-6** | Satır eşleştirme (işaret ↔ OCR satır kutusu) | Cihaz | ✅ |
| **F2-7** | Onay ekranının gerçek verilerle çalışması | Uygulama | ✅ |

**Kod tarafı tamam; çıkış kapısı değil.** Aşağıya bakın.

Sayfa düzeltme (§25'in ilk kalemi) Faz 1'de bitti: `VNDocumentCameraViewController`
kenar algılama ve perspektif düzeltmeyi zaten yapıyor.

---

## Kritik token motoru neden backend'de

Motor bugün Python'da (`evals/ocr_eval/critical_tokens.py`, 385 test). Üç
seçenek vardı:

| Nerede | Artı | Eksi |
|---|---|---|
| Python'da kalsın | Yazılmış ve test edilmiş | iPhone'da Python çalışmıyor; yalnız ölçüm aracı olarak kalır |
| Swift'e taşı | Çevrimdışı çalışır | Uzlaştırmanın ihtiyaç duyduğu Google sonucu zaten ağdan geliyor; çevrimdışı olması bir şey kazandırmıyor |
| **TypeScript'e taşı (seçilen)** | Google sonucu zaten backend'de; uzlaştırma tek yerde olur | Port işi ve iki uygulamanın ayrışma riski |

Ayrışma riski somut bir önlemle karşılanıyor: Python sürümü **referans** kabul
edilecek ve TypeScript portu aynı vaka listesine karşı test edilecek. Vaka
listesi tek bir JSON dosyasında tutulup iki taraftan da okunacak, böylece bir
tarafa vaka eklenip diğerinin unutulması mümkün olmayacak.

Bu, daha önce iki kez düştüğümüz tuzağın aynısı: aynı davranışı iki yerde
uygulayıp yalnız birini güncellemek.

## İşaret tespiti neden cihazda

§24.1 çekimin anında bitmesini istiyor ve §19.3 işaret bulunamayınca kullanıcıya
sorulmasını. İkisi de kullanıcı sayfaya bakarken olup bitmeli; ağ turu beklemek
akışı bozar. Ayrıca işaret tespiti görüntü işleme — model çağrısı değil — yani
§0.8 gereği deterministik kodda kalmalı.

Algoritma `evals/spikes/marker_detection/` içinde Python/OpenCV olarak
prototiplendi ve sentetik görüntülerde çalışıyor. Swift'e taşınması F2-5.

---

## Yol boyunca bulunan hatalar

Ortak vaka dosyaları yazılırken üç gerçek hata çıktı. Üçü de "aynı davranış
birden fazla yerde, yalnız biri güncel" kalıbının örneği:

1. **Yol eş anlamlıları üç ölçüden yalnız ikisinde katlanıyordu.** "damar içi"
   yazan bir sayfa doğru şekilde "IV" okunduğunda sıralı karşılaştırma ve
   fazlalık ölçüsü temiz derken eksik-oranı %100 kayıp diyordu. Doğru bir okuma
   quick_confirm'e giderdi — §24.2'nin tam tersi.
2. **Satırlar `lineId` ile eşleştiriliyordu.** İki motor kendi satırlarını
   bağımsız numaralandırıyor: Google 156, Vision 148. Alakasız satırlar
   karşılaştırılıp var olmayan uyuşmazlıklar üretilirdi.
3. **Kalıp üreticisi `\w`'yi karakter sınıfının içinde de değiştiriyordu**,
   geçersiz regex çıkıyordu.

Birincisini ortak kapı vakaları, ikincisini kendi tasarım incelemem,
üçüncüsünü ortak dedektör vakaları yakaladı.

Swift ilk kez derlendiğinde (elle inceleme, derleyici olmadığı için) beş
tane daha çıktı, hepsi §0's "küçük adım, ayrı doğrulama" ilkesinin aynı
ihlali — tek yerde değişip diğerini güncellemeyi unutmak:

4. **Uzlaştırma gerekçesi bulut adımından sonraki dönüşlerin çoğunda
   kayboluyordu.** En çok görüleni: üretici bir kartı onaya düşürdüğünde
   `.confirmationRequired`'a giden dönüş `reconciliation`'ı taşımıyordu —
   ekran "neden soruluyor" bölümünü oradan okuyor, §19.2'nin yasakladığı
   gerekçesiz onay ekranı ortaya çıkıyordu.
5. **`MarkerConfig.hueRanges` derlenmiyordu.** İç içe iki kapanıştan geçen
   etiketli demet elemanı, etiketsiz demet dizisine dönüşmüyor.
6. **Tam çözünürlük bir sayfa base64'lendiğinde sunucusuz platformun kabul
   ettiği gövde boyutunu aşıyordu** (Vercel ~4,5 MB) — telefon kendi
   uç noktasının mesajını değil, platformun opak reddini görecekti.
   `UploadImageEncoder` yükleme öncesi 2600 px uzun kenara indiriyor.
7. **`GOOGLE_APPLICATION_CREDENTIALS` bir dosya yolu ister, dağıtılan
   sunucuda o dosya yok.** `providers/googleAuth.ts` ikinci bir yol açtı:
   `GOOGLE_CREDENTIALS_JSON` ortam değişkeninde satır içi JSON.
8. **`api/` altındaki her dosyayı Vercel ayrı bir rota sanır** — `_ocr.ts`
   ve `_auth.ts` kendi başlarına bir işleyici dışa vermediği için dağıtım
   derlemesi patlardı. Alt çizgi öneki ve `vercel.json`'daki `rewrites`
   çözdü; ayrıntı `backend/README.md`.

Beşini de gerçek testler yakaladı: 5, 6, 7, 8 birer regresyon testiyle
geldi; 4'ü ise onay ekranını üreten her çıkış yolunu tek tek sınayan yeni
bir testle — mevcut testler yalnız "kabul edilen sayfa" yolunu sınıyordu,
üretim hatası yolunu değil.

## Ölçüm hâlâ eksik

Şu ana kadarki her şey **bir** fotoğrafla doğrulandı. Faz 2 çıkış kapısı için
20 görüntülük etiketli set gerekiyor (`docs/GOLD-SET-GUIDE.md`,
`docs/MAC-ADIMLARI.md`). Özellikle ölçülmemiş olan:

- İşaret tespitinin gerçek sayfalarda tek-dokunuş oranı (§25 Faz 0 kapısı)
- Apple Vision satır kutularının geometrik olarak güvenilir olup olmadığı
  (metni yanlış ama kutuları doğru mu?) — F2-6 buna dayanıyor
- Google'ın Türkçe el yazısındaki başarısı (§10.6)
- Vercel'e dağıtımın gerçekten çalıştığı — yapılandırma yazıldı
  (`backend/vercel.json`, `docs/GOOGLE-CLOUD-KURULUM.md`'ye eklenecek
  adımlar) ama gerçek bir Vercel hesabıyla hiç denenmedi; ilk dağıtım
  hem ilk doğrulama olacak
- `swift test`'in gerçekten geçtiği — Swift ilk kez bir derleyicide
  çalışacak; bu döngüdeki gözden geçirme derleyicisiz yapıldı
