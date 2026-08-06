# Çoklu fotoğrafta zaman aşımı — teşhis ve çözüm

**Tarih:** 2026-08-06 · **Durum:** çözüldü — palyatif düzeltmeler + beklemenin
tamamen telefondan çıkarılması ([`ADR-006`](ADR-006-supabase-is-kuyrugu.md)).
Gerçek cihaz doğrulaması bekliyor (§5).

Şikâyet: *tek fotoğraf çoğu zaman çalışıyor, birden fazla fotoğraf yükleyince
zaman aşımı alıyorum.*

## 1. Neden tek fotoğrafta değil de çoklu fotoğrafta?

Faz 6'nın vision çağrısı doğası gereği yavaş: tam sayfa `imageDetail:"high"`
ile okunuyor ve sayfa başına 12'ye kadar kart üretiliyor. Gerçek gecikme bir
dakikanın altından birkaç dakikaya kadar değişiyor. Tek başına bu bir hata
değil — PR #22 tavanları buna göre yükseltti (Vercel `maxDuration` 300,
`OPENAI_TIMEOUT_MS` 290000, iOS `timeout` 300). Vercel'in kendi limit tablosu
Hobby için 300 s'i (fluid compute varsayılan açık) **azami** değer olarak
veriyor, yani sunucu tarafında yükseltilecek başka bir tavan yok.

Sorun tek çağrıda değil, **partide**. `ProcessingQueue.processPending()`
sayfaları sırayla işliyordu:

```swift
for page in pages { await process(page) }   // eski hâli
```

Beş fotoğraf = arka arkaya beş çağrı = telefonun **5–15 dakika** boyunca
uyanık, ön planda ve bağlantısını tutuyor olması gerekiyor. Pratikte olan şu:

1. iPhone ekranı varsayılan olarak **30 saniyede** kilitleniyor.
2. Ekran kilitlenince iOS uygulamayı askıya alıyor.
3. `URLSessionConfiguration.default` (arka plan oturumu değil) askıya alınmayı
   atlatamıyor; uçuştaki istek kopuyor.
4. iOS bunu `NSURLErrorTimedOut` olarak bildiriyor → `providerUnavailable` →
   ekranda **zaman aşımı**.

Tek fotoğrafta kullanıcı genelde ~1 dakika ekrana bakıp bekliyor, o yüzden
tetiklenmiyor. Beş fotoğrafta kimse 10 dakika ekrana bakmıyor. Kök neden
buydu: **sunucunun tavanı değil, telefonun partiyi ayakta tutamaması.**

İkincil bir risk daha var: istek dakikalarca **boşta** duruyor (bayt akmıyor).
Vercel'in kendi dokümanı uzun süren isteklerde HTTP/1.1 istemcilerinin ve ara
katmanların boşta bağlantıyı kapatabileceğini söyleyip "çalışırken ilerleme ya
da heartbeat verisi akıt" diyor. Mobil şebekedeki NAT zaman aşımlarında bu
gerçek bir olasılık ve her ek fotoğraf bir zar atışı daha demek.

## 2. Bu turda yapılan kod düzeltmeleri

### 2.1 Parti artık paralel (`ProcessingQueue`)

Sayfalar aynı anda en fazla `maxConcurrentPages` (§3'ten sonra 6) olacak şekilde işleniyor
ve bir slot boşalır boşalmaz sıradaki başlıyor (bariyer yok — 40 saniyede
biten bir sayfa 4 dakika süren birinin arkasında beklemiyor). İş telefonda
I/O-bağımlı, sunucuda ise her sayfa bağımsız bir serverless çağrısı olduğu
için yatay ölçekleniyor; limit yalnızca sağlayıcı hız sınırlarına karşı
nezaketten var.

Etki: beş fotoğrafın duvar saati ~5×'ten tek çağrı süresine iniyor. Telefonun ayakta
kalması gereken süre kısaldıkça kesilme olasılığı düşüyor.

Görev sınırını `CapturedPage` değil `UUID` geçiyor: model `Sendable` değil,
ayrıca her çocuk görev sayfayı ana bağlamdan yeniden çekiyor — parti sürerken
silinen bir sayfa "bulunamadı" olup sessizce düşüyor.

### 2.2 Telefon partiyi kendi altından çekmiyor

`process` içindeki mevcut uçuş sayacına bağlandı:

- `isIdleTimerDisabled = true` — sayfa işlenirken ekran kilitlenmiyor. (1)'deki
  zincirin ilk halkasını kesiyor.
- `beginBackgroundTask` — kullanıcı başka uygulamaya geçerse iOS'un verdiği
  ~30 saniyeyi alıyor; cevaplamak üzere olan bir çağrı kaybolmak yerine
  yetişiyor. Süre dolarsa assertion bırakılıyor (uygulamanın öldürülmemesi
  için), uçuştaki sayfalar geçici hata olup kuyruktan tekrar deneniyor.

İkisi de **uzun** bir arka plana alınmayı atlatmaz; onun için arka plan
`URLSession`'ı ya da beklemeyi telefondan çıkarmak gerekir (§3).

### 2.3 Geçici hatalar artık gerçekten tekrar deneniyor

`nextAttemptAt` yazılıyordu ama onu **onurlandıran hiçbir şey yoktu**: kuyruk
yalnızca kullanıcı uygulamayı yeniden açtığında veya aşağı çektiğinde
koşuyordu. Çok sayfalı bir partide tek bir kopan bağlantı, kullanıcı bakmayı
akıl edene kadar o kartları üretilmemiş bırakıyordu. Artık her geçişin sonunda
en erken vadeye bir takip geçişi planlanıyor. Zinciri mevcut deneme tavanı
(`RetryPolicy.maxAttempts = 5`) bitiriyor — hakkı tükenen sayfa
`.permanentFailure` oluyor ve `shouldProcess` onu seçmiyor.

### 2.4 Bağlantı dalgalanması bir denemeyi yakmıyor

`waitsForConnectivity = true`. Wi-Fi/hücresel arasında geçen telefon isteği
anında başarısız saymak yerine bekliyor; bekleme zaten `timeoutIntervalForResource`
ile sınırlı, dolayısıyla mevcut tavanın ötesine geçemiyor.

## 3. Asıl çözüm: bekleme telefondan çıktı (uygulandı)

Yukarıdakiler hatayı büyük ölçüde azaltır ama **garanti etmez**: telefon hâlâ
uzun bir HTTP isteğini bekliyor, yalnız artık daha kısa süre ve daha az
kesilerek. Garanti eden tek şey, telefonun o isteği hiç beklememesi.

Bu yüzden kart üretimi asenkron bir iş kuyruğuna taşındı — karar, gerekçe,
güvenlik modeli ve §7.3'ten verilen bilinçli taviz:
[`ADR-006-supabase-is-kuyrugu.md`](ADR-006-supabase-is-kuyrugu.md).

Özet:

```
telefon  POST /api/jobs   → sayfa Storage'a yazılır, satır 'queued', 202 (saniyeler)
Vercel   arka planda      → OpenAI çağrısı, sonuç satıra yazılır (waitUntil)
telefon  GET  /api/jobs   → sonucu, ne zaman uyanıksa alır
```

Kritik nokta: **iş kimliği sayfanın kimliğidir.** Uygulama beklerken öldürülse
bile, bir sonraki açılışta aynı sayfa yeniden denendiğinde iş önce *sorulur* ve
sunucuda çoktan bitmiş olan sonuç oradan alınır — ikinci bir üretim için para
ödenmez, 3 MB yeniden yüklenmez. "Uygulama açık kalmalı" gerekliliği tamamen
kalkmıyor, ama artık uygulama yalnızca **sonucu görmek** için açık olmak
zorunda, işin *yapılması* için değil.

`/api/cards-vision` olduğu gibi duruyor; geri dönüş istemci tarafında bir yol
değişikliğinden ibaret (ADR-006 "Geri dönüş").

## 4. Hâlâ açık olan, ama artık küçük

- **Kart sayısı / gecikme.** Gecikmenin baskın bileşeni üretilen çıktı token'ı.
  Vercel'de `OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT` 12'den 8'e indirilirse sayfa
  başına süre kabaca üçte bir azalır. Artık bir zorunluluk değil (kimse
  beklemiyor), yalnız bir tercih. Tamamen ortam değişkeni.
- **Ayarlar'daki "pasaj başına kart" ölü.** `CapturePipeline` `maxCards`'ı
  `CardGenerationRequest`'e koyuyor, ama `BackendCardProvider` onu istek
  gövdesine hiç yazmıyor ve sunucu her zaman kendi `maxCardsPerKnowledgeUnit`
  değerini kullanıyor. Bilerek düzeltilmedi: ayarın kayıtlı varsayılanı 2 ve
  kablolamak, B3'te kart kapsamını bilinçli olarak 12'ye yükselten kararı
  sessizce geri alırdı. İstenirse ayrı bir iş.
- **Deneme hakkı.** Her kesinti `RetryPolicy`'nin beş hakkından birini yakıyor;
  beşi de biterse sayfa `.permanentFailure` olur ve kullanıcının "Tekrar dene"
  demesi gerekir (o da sayacı sıfırlıyor). Gerçek kullanımda beş kesinti
  beklenmiyor, ama olursa iş kaybolmuyor — sunucudaki sonuç duruyor.
- **Sızan nesne.** İşleyen sunucu, satırı yazdıktan sonra ama görüntüyü
  silmeden önce ölürse nesne kovada kalır. Kişisel ölçekte kabul edildi
  (sayfa ~3 MB, ücretsiz katman 1 GB).
- **Fonksiyon bölgesi.** Dağıtım `iad1` (ABD-Doğu), Supabase ise `eu-central-1`
  (Frankfurt). Vercel'i de `fra1`'e almak hem Türkiye'den yüklemeyi hem de
  Vercel↔Supabase turunu kısaltır. Hobby'de tek bölge seçilebiliyor: panelde
  Project Settings → Functions → Function Region. Kod değişikliği yok.

## 5. Doğrulama durumu

Yapılan:

- Backend **467 test yeşil** (36'sı yeni `tests/jobsEndpoint.test.ts`),
  `tsc --noEmit` temiz.
- Gerçek Supabase projesine karşı: tablo ve kova yollarının doğruluğu,
  `in.(uuid)` filtresi, RLS'in publishable anahtarla yazmayı gerçekten
  engellediği (42501 / `AccessDenied`), ve atomik `claim`'in ikinci çağrıda 0
  satır döndürdüğü.

Yapılamayan (bu ortamın sınırı, kullanıcının elinde):

- Servis anahtarıyla gerçek bir yazma/okuma/silme turu — bu ortamda servis
  anahtarı yok, MCP yalnız publishable anahtarı veriyor.
- **iOS derlemesi.** Swift araç zinciri yok. Değişen dosyaların ikisi
  (`ProcessingQueue.swift`, `AppEnvironment.swift`) App hedefinde — `swift test`
  zaten kapsamaz, `xcodebuild -scheme Cizgi … build` gerekir. `BackendCardProvider`
  ve `BackendClient` CizgiCore'da, onlar `swift test` ile derlenir ve yeni 9
  test oradadır.
- Gerçek cihazda uçtan uca: 5 işaretli sayfa arka arkaya → hepsinin saniyeler
  içinde kuyruğa girmesi → uygulama kapatılıp açıldığında kartların gelmiş
  olması.
