# ADR-011 — Yedek biçimi v9: geri yüklemede sayfa fotoğrafı

**Tarih:** 2026-09-14 · **Durum:** ✅ Kabul edildi · **Dal:** `yedek-v9-sayfa`

## Bağlam

Kartların uygulamaya ikinci bir giriş kapısı oluştu: sahibinin sayfa
fotoğraflarını Claude doğrudan okuyup kartları dışarıda yazıyor. Böyle bir
kartın uygulamaya girebildiği tek yol **"Yedekten geri yükle"**.

O yol v8'e kadar yalnız `Card + KnowledgeUnit + ReviewLog` kuruyordu;
`CapturedPage` ve `TextRegion` yaratmıyordu. "Kaynağı göster"
(`CardSourceView`) fotoğrafı `card.knowledgeUnit.region.page.originalImagePath`
zincirinden bulduğu için geri yüklenen kart yalnız *Modelin okuduğu* metni
gösteriyor, fotoğrafı göstermiyordu. Oysa bu kartların kaynağı tam olarak bir
sayfa fotoğrafı — ve bu projede fotoğraf, kartı kaynağıyla karşılaştırmanın
tek yolu (§5.5).

## Karar

1. **Biçim v9.** Dosyaya iki isteğe bağlı şey eklendi: üst düzeyde
   `pages[]` (`id`, `jpegBase64`, `captureDate`, isteğe bağlı `subject`,
   `readText`, `pageLabel`) ve kartta `pageId`. İkisi de yoksa dosya v8'in
   anahtarlarıyla birebir aynıdır; v8/v7/…/v1 dosyaları değişmeden okunur,
   `formatVersion > 9` reddedilmeye devam eder.

2. **Geri yükleme üretimin kurduğu zinciri kurar:**
   `CapturedPage(.ready) → TextRegion (tam sayfa, .manual) → KnowledgeUnit → Card`.
   `ProcessingQueue.persist`'in bıraktığı şeklin aynısı olduğu için "Kaynağı
   göster", tam ekran görüntüleyici ve sayfa detayı **hiç değişmeden** çalışır.
   SwiftData şeması değişmedi — yalnız var olan modellere yeni satır; göç yok.

3. **Kararlar planda, yazma kurucuda.** `BackupRestorer.plan` (saf, testli)
   hangi sayfaların kurulacağına ve hangi kartın hangi sayfaya bağlanacağına
   (`pageLinks`) karar verir; `BackupPageInstaller` (CizgiCore, bellek-içi
   SwiftData ile testli) yalnız yazar. `SettingsView.restore` ikisini bağlar ve
   tek `save()` + `rollback()`'i elinde tutar.

4. **Sayfa kartı izler, tersi değil.** Sayfa yalnız *eklenecek* bir kart ona
   işaret ediyorsa kurulur: aynı dosya ikinci kez yüklendiğinde hiçbir şey
   kurulmaz, bütün kartları zaten cihazda olan sayfa yetim `CapturedPage` olarak
   geri gelmez. Cihazda zaten olan sayfa yeniden kurulmaz ve görüntüsü yeniden
   yazılmaz; yeni kartlar ona bağlanır.

5. **Dosya güvenilmezdir — içerik affedilir, biçim affedilmez.** Karşılığı
   olmayan bir `pageId`, boş ya da çözülemeyen `jpegBase64` (ya da JPEG
   başlangıç işareti `FF D8 FF` taşımayan bayt) o kartın **fotoğrafını**
   götürür, geri yüklemeyi değil: kart v8'deki gibi fotoğrafsız girer ve özet
   "N kartın sayfa fotoğrafı bulunamadı" der. Tip hatası (geçersiz UUID/tarih)
   ise bugünkü bütün alanlarda olduğu gibi dosyayı okunamaz yapar.
   JPEG işareti kontrolünün sebebi: görüntü `-original.jpg` olarak saklanır ve
   "İkinci görüş"/"Kapsama denetle" onu `image/jpeg` diye gönderir; base64'ün
   çözülmesi içeriğin JPEG olduğunu söylemez.

6. **Sayfa `.ready` doğar ve kuyruk ona dokunmaz.** `ProcessingQueue.shouldProcess`
   `.ready`'yi hiçbir zaman seçmez; geri yüklenen sayfa `POST /api/jobs`'a
   gitmez (para harcanmaz, ikinci kart takımı üretilmez). Simülatörde kuyruk
   ekranı açılıp yenilendikten sonra sayfalar `ready` kaldı, `ModelRun` sıfır.

7. **Yarım geri yükleme diskte iz bırakmaz.** Görüntü yazımı yarıda patlarsa
   kurucu o ana kadar yazdıklarını siler; `save()` patlarsa `rollback()`'ten
   sonra `BackupPageInstaller.discard` yazılan bütün JPEG'leri siler.

8. **Görüntüye dokunulmaz.** Yükleme bütçesine göre küçültme/yeniden sıkıştırma
   yok — bu görüntü modele gitmek için değil ekranda gösterilmek için orada.

## Bilinçli ayrıntılar

- **Birim paylaşımı tam yük üzerinden.** Aynı sayfanın kartları, `persist`'teki
  gibi ders/konu başına birim paylaşır — ama eşleşme `(ders, konu, claim,
  etiketler)` üzerinden. `KnowledgeUnitBinding.findOrCreate` etiketleri
  eşleşmede yok sayar; tek bir kartı sınıflandırmalar arasında taşırken doğru
  olan bu, geri yüklemede yanlış: farklı etiketli iki kayıttan birinin
  etiketleri sessizce kaybolurdu.
- **`Source` paylaşılır.** Sayfanın dersi şablonda tanınırsa kanonik adla
  (`"mikrobiyoloji"` → `"Mikrobiyoloji"`), yoksa kırpılmış hâliyle; aynı derse
  tek `Source` — `ProcessingQueue.enqueue` ile aynı fonksiyon (`SourceBinding`,
  bu işte kuyruktan çekirdeğe taşındı).
- **Algısal hash yazılır.** Geri yüklenen sayfanın `perceptualHash`'i kaydedilir;
  aynı sayfa sonradan kamerayla çekilirse "bu sayfayı daha önce çektin mi?"
  sorusu çıkar. 2026-08-18 deste denetiminde kopyaların ana kaynağı aynı
  sayfanın tekrar çekilmesiydi.
- **`coverageJSON` `nil`.** Sayfa detayı "kapsama defteri olmadan üretilmiş"
  der — model bu sayfanın işaret defterini yazmadı, doğru cümle bu.
- **"Orijinal sayfayı sakla" kapalıyken de fotoğraf yazılır.** O ayar üretim
  hattının görüntüyü kart hazır olunca silip silmeyeceğini yönetir; fotoğraf
  taşıyan bir dosyayı geri yüklemek, fotoğrafı istemenin açık hâlidir.

## Dışa aktarma neden görüntü yazmıyor

"Yedeği hazırla" bugünkü gibi görüntüsüz: `pages` yazılmaz, `pageId` yazılmaz
(boş olduklarında anahtar hiç çıkmaz). Mevcut yedekler şişmesin diye bilinçli —
bir sayfa JPEG'i bütün kart metinlerinden büyüktür ve yedek paylaşım sayfasından
geçen tek bir JSON dosyası. v9 şimdilik yalnız içe aktarma tarafında öğrenildi;
dışa aktarmaya görüntü eklemek ayrı bir karar.

## Geri dönüş

Bu işin commit'inin revert'i. Şema değişmediği için cihazda göç gerekmez:
geri yüklenmiş sayfalar sıradan `.ready` sayfalar olarak kalır. Revert'ten sonra
v9 dosyası "daha yeni bir sürümle alınmış" diye reddedilir.
