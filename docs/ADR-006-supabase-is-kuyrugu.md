# ADR-006 — Kart üretimi asenkron bir iş kuyruğuna taşındı (Supabase)

**Tarih:** 2026-08-06 · **Durum:** kabul edildi, uygulandı · **Kapsam:** Faz 6 (B)

## Bağlam

Faz 6'nın vision çağrısı doğası gereği yavaş: tam sayfa `imageDetail:"high"`
ile okunuyor ve sayfa başına 12'ye kadar kart üretiliyor. Gerçek gecikme bir
dakikanın altından birkaç dakikaya kadar değişiyor.

PR #22 bunu bir tavan sorunu sanıp bütün tavanları yükseltti (Vercel
`maxDuration` 300, `OPENAI_TIMEOUT_MS` 290000, iOS timeout 300). Tek sayfa
düzeldi, parti düzelmedi. Sonraki teşhis
([`COKLU-FOTO-TIMEOUT.md`](COKLU-FOTO-TIMEOUT.md)) sorunun tavanda hiç
olmadığını gösterdi:

1. iPhone ekranı varsayılan olarak 30 saniyede kilitleniyor.
2. Ekran kilitlenince iOS uygulamayı askıya alıyor.
3. Arka plan oturumu olmayan bir `URLSession` bunu atlatamıyor; uçuştaki istek
   kopuyor.
4. iOS bunu `NSURLErrorTimedOut` diye bildiriyor → `providerUnavailable` →
   kullanıcıya **zaman aşımı**.

Tek fotoğrafta kullanıcı ~1 dakika ekrana bakıp bekliyor, o yüzden
tetiklenmiyor. Beş fotoğrafta kimse 10 dakika bakmıyor.

Vercel'in kendi limit tablosu Hobby için 300 s'i **azami** değer olarak veriyor,
yani yükseltilecek başka tavan da yok. Ayrıca Vercel'in dokümanı uzun süren
isteklerde HTTP/1.1 istemcilerinin ve ara ağ katmanlarının boşta bağlantıyı
kapatabileceğini söyleyip "çalışırken ilerleme ya da heartbeat verisi akıt"
diyor — mobil şebekedeki NAT zaman aşımlarında bu ayrıca bir risk.

Kısacası: **bir telefonun dakikalarca tek bir HTTP bağlantısını açık tutmasına
güvenilemez.** Tavanları büyütmek bu gerçeği değiştirmiyor.

## Karar

Beklemeyi telefondan çıkar. Kart üretimi artık yazılı bir **iş** (`job`):

```
telefon  POST /api/jobs   → sayfa Storage'a yazılır, satır 'queued' olur, 202 döner (saniyeler)
Vercel   arka planda      → OpenAI çağrısı yapılır, sonuç satıra yazılır
telefon  GET  /api/jobs   → sonucu, ne zaman uyanıksa alır
```

Durum Supabase'de duruyor: `public.jobs` tablosu ve `page-uploads` özel kovası.

### Neden Supabase

Kalıcı bir duruma ihtiyaç vardı (Vercel fonksiyonları durumsuz) ve seçenekler
Postgres + nesne deposu + ücretsiz katman üçlüsünü aynı anda veren bir şeydi.
Zaten hesap vardı ve maliyet aylık 0 USD. Alternatif olarak Vercel KV/Blob de
işi görürdü; Supabase seçildi çünkü ileride kart verisinin kendisi de senkron
edilmek istenirse aynı yerde durabilir.

### Neden cron yok

Boşa düşen bir işi kimin başlatacağı sorusu normalde bir zamanlayıcıyla
çözülür. Vercel'in Hobby planında cron **günde bir kez**; bu iş için işe
yaramaz. Onun yerine iki süpürme, telefonun zaten yaptığı yoklamaların içinde
çalışıyor:

- **Kurtarma:** `processing` durumunda `SUPABASE_JOB_STALE_AFTER_MS`'ten (330 s,
  Vercel'in 300 s tavanının hemen üstünde) uzun süredir duran bir iş, işleyeni
  süre tavanında öldürülmüş sayılıp tekrar denenebilir hataya çevriliyor.
- **Kaçırılan gönderim:** `queued` görülen bir işi yoklama da başlatıyor.

İkincisi ancak `claim` **atomik** olduğu için güvenli: PostgREST'in
`?id=eq.X&status=eq.queued` filtresi UPDATE'in WHERE'ine giriyor, yani iki
çağrı aynı işe el atsa bile yalnız biri kazanıyor ve model bir kez çağrılıyor.
Bu davranış gerçek veritabanında doğrulandı (ilk UPDATE 1 satır, ikincisi 0).

### Güvenlik modeli değişmedi

Telefon Supabase'i **hiç görmüyor**. Eskiden olduğu gibi yalnız Vercel'e,
yalnız `DEVICE_TOKEN` ile konuşuyor. `jobs` tablosunda RLS açık ve **hiçbir
policy yok** — yani anon/publishable anahtar için tam kapalı; yalnız Vercel'in
elindeki `service_role` anahtarı geçebiliyor. Kova da özel ve aynı şekilde
politikasız. Gerçek anahtarlarla doğrulandı: publishable anahtarla `SELECT` boş
dönüyor, `INSERT` 42501 ile, Storage yüklemesi `AccessDenied` ile reddediliyor.

`SUPABASE_SERVICE_ROLE_KEY` `config.ts`'ten geçmiyor; her kimlik bilgisi gibi
composition root'ta okunuyor (§0.7) ve bir test bunu kilitliyor.

## §7.3'ten verilen taviz (bilinçli)

Eskiden sayfa baytları yalnızca çağrı süresince bellekteydi ve hiçbir yere
yazılmıyordu. Artık iş bitene kadar **Storage'da duruyor**. Bu, §7.3'ün
lafzından bir sapma ve bilerek yapılıyor: tek kullanıcılık, tamamen kişisel bir
uygulamada, sayfanın birkaç dakika özel bir kovada durmasının maliyeti,
kartların hiç üretilememesinin maliyetinden düşük (ADR-005'in aynı gerekçesi).

Sapmayı sınırlayan şeyler:

- Kova özel ve politikasız; yalnız servis anahtarı erişebiliyor.
- **Her** sonlanma yolu — başarı, hata, süre dolması — nesneyi siliyor ve
  `image_path`'i boşaltıyor. Dört test bunu ayrı ayrı kontrol ediyor.
- Log satırları eskisi gibi yalnız kimlik, sayı ve süre taşıyor; bir test hiçbir
  logda görüntünün, kart metninin veya kullanıcı ipucunun geçmediğini
  doğruluyor.

Kalan açık: işlem sunucusu, satırı yazdıktan **sonra** ama nesneyi silmeden
önce ölürse nesne kovada kalır. Kişisel ölçekte kabul edildi (sayfa ~3 MB,
ücretsiz katman 1 GB); gerekirse ileride bir temizlik süpürmesi eklenir.

## iOS tarafı: ne değişti, ne değişmedi

`BackendCardProvider.generate()` **hâlâ kartlar hazır olunca dönüyor** —
`CapturePipeline` ve `ProcessingQueue` bunun üzerine kurulu ve onları değiştirmek
bir SwiftData göçü gerektirirdi. Değişen şey, kesilmenin artık işi yok
etmemesi:

- Her HTTP çağrısı saniyeler sürüyor (bir yükleme ya da küçük bir yoklama), bir
  kesinti tek bir yoklamaya mal oluyor.
- **İş kimliği sayfanın kimliği.** Uygulama beklerken öldürülse bile, bir
  sonraki açılışta aynı sayfa yeniden denendiğinde ilk iş önce *soruluyor*;
  sunucuda çoktan bitmiş olan iş oradan alınıyor. İkinci bir üretim için para
  ödenmiyor, 3 MB yeniden yüklenmiyor.
- Yedi dakikalık `jobDeadline` aşılırsa bu bir kayıp değil: iş sunucuda sürüyor,
  geçici hata bildiriliyor ve bir sonraki deneme sonucu topluyor.

Yani "uygulama açık kalmalı" gerekliliği tamamen kalkmadı — ama artık uygulama
yalnızca **sonucu görmek** için açık olmak zorunda, işin *yapılması* için değil.
Bu ayrım, kullanıcının gördüğü hatanın tamamını açıklıyor.

Bunu tamamlamak için kuyruk da paralel hale getirildi (aynı anda 6 sayfa):
ADR-006 altında bir "slot" neredeyse bedava — sayfa çoğu zaman iki yoklama
arasında uyuyor — ve sıralı bir kuyruk, sunucudaki paralelliği kullanmadan işi
damla damla göndermiş olurdu.

## Geri dönüş

`/api/cards-vision` **olduğu gibi duruyor** ve çalışıyor. `/api/jobs` ikinci bir
kapı, yerine geçen bir şey değil. Geri dönüş, `BackendCardProvider`'ın hangi
yolu çağırdığını değiştirmekten ibaret — sunucuda yeniden dağıtım gerekmiyor.
`SUPABASE_URL` boş bırakılırsa `/api/ocr` ve `/api/cards-vision` hiçbir şey fark
etmeden çalışmaya devam eder, yalnız `/api/jobs` hangi değişkenin eksik olduğunu
söyleyerek reddeder.

## Merge sonrası düzeltilen üç yarış (Codex, PR #25)

İlk uygulamada durum değişikliklerinin hepsi koşullu değildi ve Codex üç
gerçek boşluk buldu. Üçü de PR #26'da kapatıldı; hepsi için, düzeltmeden önceki
davranışa karşı düşen bir test var (mutasyonla doğrulandı).

1. **P1 — `enqueue` koşulsuzdu.** Aynı sayfa için çakışan iki gönderim: ikisi
   de satırı okuyup uygun bulur, sonra ikincisinin merge-upsert'i, birincinin
   işçisi işi *aldıktan sonra* satırı `queued`a geri çeker. İkinci bir işçi de
   onu alır — aynı sayfa için **iki ödemeli üretim** ve tek görüntü/sonuç
   üzerinde yarış. Uç durum değil: `ProcessingQueue`, aynı sayfa için elle
   "Tekrar dene" ile aşağı-çekmenin çakışmasına açıkça izin veriyor.
   Düzeltme: `enqueue` ikiye ayrıldı — `insertQueued` (upsert değil, düz insert;
   birincil anahtar çakışması `false` döner) ve `requeue`
   (`?status=eq.failed&retryable=is.true` koşullu). Kaybeden hiçbir şey yazmaz,
   sadece güncel durumu bildirir.
2. **P2 — kurtarma denemeye kilitli değildi.** `expire` yalnız `status`'e
   bakıyordu; bir yoklama eski satırı okurken iş yeniden kuyruğa alınıp taze
   bir işçi tarafından alınmışsa, süpürme **yeni** denemeyi öldürüyordu. Ayrıca
   görüntü, `expire` `false` dönse bile siliniyordu — yani yeni yüklenmiş
   sayfayı silip yerine geçen işçiyi düşürüyordu. Düzeltme: `expire` artık
   gözlenen `started_at`'e de kilitli (`started_at=eq.<encoded>`; zaman damgası
   `+00:00` taşıdığı için URL kodlaması şart, yoksa filtre hiçbir şeyle
   eşleşmez) ve görüntü yalnız fence'li yazma başarılıysa siliniyor.
   Gidiş-dönüşün birebir eşleştiği gerçek veritabanında doğrulandı.
3. **P2 — kuyruğa alma başarısız olursa görüntü sızıyordu.** `putImage`
   başarılı, ardından PostgREST çağrısı başarısız: satır yok, dolayısıyla
   hiçbir yoklama ve hiçbir kurtarma süpürmesi o yüklemeyi bir daha bulamaz.
   Düzeltme: telafi silmesi — ama **yalnız nesnenin sahipsiz olduğu
   doğrulandıktan sonra**. Belirsiz bir hatada yarışı kazanan başka bir
   gönderim tam o baytlara güveniyor olabilir; sızan nesne birkaç megabayt,
   kırılan canlı iş ise sayfanın kendisi.

Ortak ders, artık `JobStoreLike`'ın başında yazılı: **her durum değişikliği,
onu haklı çıkaran duruma koşullu olmak zorunda.** Buradaki koşulsuz tek bir
yazma, bu dosyanın önlemek için var olduğu hatayı geri getiriyor.

Codex bu düzeltmeleri de inceleyip nesne temizliğinde iki delik daha buldu;
ikisi de aynı PR'da kapatıldı:

4. **Yarışı kaybeden gönderim kendi yüklemesini bırakabiliyordu.** "Kazanan
   zaten bu nesneyi işaret ediyor" varsayımı yalnız kazanan *hâlâ çalışıyorsa*
   doğru. Kazanan bitmişse sonlanma yolu nesneyi çoktan silmiş olur ve
   kaybedenin yüklemesi hiçbir satırın işaret etmediği taze bir nesne bırakır.
   Kaybeden yol da artık sahiplik-farkında temizliği çalıştırıyor.
5. **Eskimiş bir işin yeniden gönderiminde yükleme düşerse eski nesne
   sahipsiz kalıyordu.** `expire` başarılı olduğu anda satırın `image_path`'i
   boşalıyor ama nesne hâlâ kovada; "yalnız yükledimse temizle" kuralı o aralığı
   kaçırıyordu. Bayrak artık `expire` başarısından itibaren de kalkıyor.

Sonuç olarak sızıntı penceresi tek bir yere indi ve o da §7.3 bölümünde
"kalan açık" olarak zaten yazılı: işçi, satırı yazdıktan sonra ama nesneyi
silmeden önce ölürse.

## Doğrulama

- Backend: **469 test yeşil** (38'i bu ADR'nin `tests/jobsEndpoint.test.ts`
  dosyasından), `tsc --noEmit` temiz.
- Gerçek Supabase projesine karşı doğrulanan: tablo ve kova yolları, `in.(uuid)`
  filtresi, RLS'in yazmayı gerçekten engellediği, atomik `claim`'in ikinci
  çağrıda 0 satır döndürdüğü.
- **Doğrulanmayan:** servis anahtarıyla yapılan gerçek yazma/okuma/silme turu
  (bu ortamda servis anahtarı yok) ve iOS derlemesi (Swift araç zinciri yok).
  İkisi de kullanıcının elinde: ayrıntı `COKLU-FOTO-TIMEOUT.md` §5.

**Güncelleme (2026-08-07):** kuyruk `main`'de (PR #25/#26). Kullanıcı Vercel'e
`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` değişkenlerini ekledi ve iOS
tarafını bir Mac'te derledi. PR #27 şemaya nullable bir `max_cards` sütunu
ekledi (ayrı bir migration; istemcinin "sayfa başına kart" ayarı işçiye ancak
satır üzerinden ulaşabiliyor, çünkü işçi isteği çok sonra çalışıyor) — backend
test sayısı **476**. **Gerçek cihazda uçtan uca parti testi hâlâ yapılmadı**;
bu ADR'nin asıl gerekçesini doğrulayacak tek şey odur.

## İkinci inceleme turu (2026-08-07 akşamı)

Yukarıdaki "her durum değişikliği koşullu olmak zorunda" kuralının **iki
istisnası kalmıştı** ve inceleme onları buldu:

6. **`complete` ve `fail` yalnız `id` ile yazıyordu.** Üretim sürerken deneme
   bayatlarsa (bir yoklama `expire` eder, yeni bir gönderim işi yeniden kurar),
   emekli işçinin geç gelen cevabı canlı denemenin üstüne yazılabiliyordu.
   Düzeltme: ikisi de artık `?status=eq.processing&started_at=eq.<encoded>`
   koşullu, yani `expire` ile aynı fence. Fence kaybedilirse sonuç düşürülür
   (`jobs.result_dropped`) ve **paylaşılan nesne yoluna dokunulmaz** — yol
   deterministik (`pages/<jobId>`) olduğu için silmek, yeni denemenin taze
   baytlarını götürürdü. Bunu mümkün kılmak için `claim` artık boolean yerine
   kazandığı satırı döner; işçi de üretimini o satırın parametreleriyle yapar
   (önceden claim'den *önce* okunan anlık görüntüyü kullanıyordu).

7. **Kalıcı hata kaçışsızdı.** İş kimliği = sayfa kimliği olduğundan
   `failed` + `retryable=false` bir satır, o sayfayı `/api/jobs` üzerinden
   sonsuza dek üretilemez yapıyordu; `requeue` filtresi `retryable=is.true`
   istiyor, `submit` de satırı olduğu gibi geri döndürüyordu. En kötü hâli:
   yanlış bir API anahtarıyla üretilen her sayfa, anahtar düzeltildikten sonra
   bile kilitli kalıyordu — tek çare sayfayı silip yeniden çekmekti.
   Düzeltme iki koldan:
   - Bazı hatalar zaten kalıcı sayılmamalıydı: Storage `getImage` 404'ü
     (eşzamanlı temizlik silmiş olabilir), OpenAI `status:"incomplete"` (token
     harcaması stokastik) ve gövde-içi `status:"failed"` artık **retryable**.
   - Gerçekten kalıcı olanlar için `POST /api/jobs` bir `force: true` bayrağı
     kabul ediyor (`requeue(..., { includePermanent: true })`). Bu bayrağı
     **yalnız kullanıcının "Tekrar dene" dokunuşu** taşır, kuyruğun otomatik
     denemeleri asla — tekrarlamanın tek başına çözmeyeceği bir hatayı
     tekrarlamak anlamsız, ama bir *insanın* yeniden sorması sunucunun
     bilmediği bir şeyi taşıyabilir. `force` yalnız `retryable` koşulunu
     düşürür; `status=eq.failed` koşulu yerinde kalır, yani canlı bir işçi
     (`processing`) ya da biten bir iş (`ready`) asla geri çekilemez.

Ayrıca vision uçları artık PDF/TIFF'i **kapıda** çeviriyor (`VISION_MIME_TYPES`,
Document AI'ın listesinin bir alt kümesi): OpenAI ikisini de kabul etmiyor,
dolayısıyla eskiden kapıdan geçip sağlayıcıdan 400 alıyor ve yukarıdaki kalıcı
kilide dönüşüyorlardı.
