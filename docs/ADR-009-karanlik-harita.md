# ADR-009 — Karanlık Harita: kapalı şablon üzerinde çift aileli kapsama boşluğu

**Tarih:** 2026-08-19 · **Durum:** kabul edildi, uygulandı (cihaz doğrulaması açık)

## Bağlam

> **Adlandırma notu (2026-08-19):** aynı gün `main`'e giren **Kapsama
> sözleşmesi** (#47, `docs/PLAN-kapsama-sozlesmesi.md`) da "kapsama" diyor ama
> başka bir şeyi ölçüyor: **tek sayfa** içinde işaret ↔ kart eşleşmesini. Bu ADR
> **tüm deste** ölçeğinde konu ↔ kart kapsamasından bahsediyor. İkisi kardeş —
> aynı kör noktanın (üretilmemiş kart hiçbir sinyal taşımaz) sayfa ve müfredat
> ölçekleri. Modüller bu yüzden ayrı adlarda: `providers/coverage.ts` onların,
> `providers/topicCoverage.ts` bunun.


Uygulama bugüne kadar tek bir soruyu cevapladı: **"elimdeki kartlar hakkında ne
biliyorum?"** Bilgi Haritası kapsamı sayıyor, FES takıldığın kartları biriktiriyor,
Egzersiz zayıf noktaları öne çekiyor. Hepsi *var olan* kartların üzerinde çalışır.

Oysa CLAUDE.md iki ayrı yerde, iki ayrı vesileyle aynı teşhisi koyuyor: modelin
tehlikeli hatası yanlış kart değil **eksik** kart, ve üretilmemiş bir kart
`lowConfidence` taşımadığı için **onu hiçbir otomatik sinyal görmüyor**. Bu teşhis
hep *sayfa ölçeğinde* konuldu — "bu fotoğrafta yıldızladığın yer karta dönmedi".

Ama aynı boşluğun bir de **müfredat ölçeği** var, ve orası tamamen kör: hiç
fotoğrafını çekmediğin, belki hiç okumadığın, belki kitabında hiç olmayan bir
konu tanım gereği hiçbir sayfada yok. Sayfa detayındaki "Kart ekle" düğmesi bunu
çözemez — hangi sayfaya bakarak ekleyeceksin?

2026-08-18 deste denetimi bunu sayıyla gösterdi: 996 aktif kartın 142'si tek bir
konuda (Solunum) toplanmış. Kapsama, çalışılan kitapların ve o dönemki ilginin
şekliyle **çarpık**. TUS ise kitabından değil müfredattan sorar.

## Karar

`POST /api/dark-map`: telefon her kanonik (ders, konu) çifti altında kaç aktif
kartı olduğunu gönderir, sunucu iki şey döndürür — **cinsleri bilerek farklı**:

1. **`untouched`** — hiç kartı olmayan kanonik konuların tam listesi. Saf
   aritmetik, model çağrısından **önce** üretilir, iki çağrı da düşse bile döner.
2. **`zones`** — ince konular arasında bir **öncelik sıralaması**. Hiçbir sayacın
   üretemeyeceği kısım budur, çünkü TUS'un o konudan ne sorduğuna bağlıdır. İki
   model ailesi bunu **birbirinden habersiz** cevaplar; sunucu anlaştıklarını
   işaretler.

Ekranda da ayrı dururlar. Tek listede birleştirmek cazip ve yanlış olurdu: bir
modelin kanısına bir sayımla aynı görsel yetkiyi verirdi.

### Trick: konular yalnız şablondan seçilir

Bu özelliğin çalışmasının **tek sebebi** `schemas/subject_topics.json`'un kapalı
olması: 11 ders, 143 konu. Deste bu 143'ün bir alt kümesini kapsar, dolayısıyla
**tümleyeni bilinebilir** — "neyi çalışmıyorum?" bir kanı değil, bir sorgu olur.
Tasarımdaki her şey bu özelliği korumak için:

- **Kanonik liste, istemcinin listesi değil, başlangıç noktasıdır.** Telefonun
  anmadığı konu sunucuda sıfırla doldurulur. Eksik rapor eden bir istemci bir
  konuyu ancak **daha karanlık** gösterebilir — dikkat israfı, gizleme değil.
- **Model konu icat edemez.** `topicKey` (= `Ders|Konu`) her iki ailenin yanıt
  şemasında **enum**'dur; 143 değerin dışı temsil edilemez. Bu, kartın `topic`
  alanının zaten yaşadığı üç katmanlı korumanın aynısıdır: şema enum'u + prompt
  Kural 1 + sunucu sanitizasyonu (`sanitizeRatings`). Üçünden ikisi düşse bile
  ekrana uydurulmuş konu adı çıkmaz.
- **Kimlik daima çifttir.** Altı konu adı iki ders altında birden geçiyor
  (`Deri Hastalıkları` → Patoloji + Genel Cerrahi; ayrıca `İmmünoloji`,
  `Meme Hastalıkları`, `Pankreas Hastalıkları`, `Onkoloji`, `Beslenme`). İki
  alanı bağımsız doğrulayan bir kapı, Patoloji'ye bir Farmakoloji konusu
  bağlanmasına izin verirdi — `topicKey` tek enum değeri olduğu için bu kombinasyon
  **temsil edilemez**. Hem backend hem iOS testleri bunu ayrı ayrı kilitler.
- **Kart sayısı asla modelden okunmaz.** `mergeRankings` sayıyı destenin kendi
  kapsama tablosundan alır; modelin yankısını geçirmek gerçek bir konu adının
  yanına uydurma bir rakam basardı.

### Neden iki aile

Kart üretiminin zemini kullanıcının kendi işaretlediği fotoğraftır. Bu çağrının
**hiçbir zemini yok**: "TUS bu konudan çok sorar" iddiasını doğrulayacak bir
sayfa yok, yalnız modelin eğitim verisi var. Elimizdeki tek denetim, aileler
arası mutabakat — ve bu, `/api/second-opinion`'ın cihazda zaten kanıtladığı alet
(2026-08-13): bağımsız bir aile, ilk okuyucunun körlüğünü görür.

**Tek prompt, iki aile.** Aynı sistem prompt'u ve aynı kullanıcı mesajı ikisine
de gider. Her aileye ayrı bir metin yazsaydık, bir anlaşmazlık "bu iki okuyucu
deste hakkında ayrıldı" olmaktan çıkıp "bu iki okuyucuya farklı şeyler soruldu"
hâline gelirdi; kapı kendi prompt kaymamızı ölçmeye başlardı. Bağımsızlık
prompt'ta değil, **iki ayrı çağrıda** yaşar.

**Kapının satın aldığı ve almadığı:** tek bir ailenin idiyosenkrazisini yakalar;
**ortak hatayı yakalamaz** — iki aile de örtüşen kaynaklardan öğrendi, yaygın bir
yanlış inanış mutabakattan sağ çıkar. Bu yüzden onaylanmış bölge bile "bakılacak
öneri" olarak sunulur, "gerçek" olarak değil; ve bu yüzden deterministik yarı
(`untouched`) ayrı ve önde durur.

**Anlaşmazlık saklanmaz.** Tek ailenin işaretlediği konu `disputed` etiketiyle
döner. Düşürmek, 50/50 bir yargıyı "ikisi de işaretlemedi" sessizliğinden
ayırt edilemez hâle getirirdi.

### Bozulma: Gemini yoksa harita kaybolmaz

`GEMINI_API_KEY` yoksa uç **tek sıralayıcıyla** çalışır: `singleRater: true`,
her bölge `disputed`, ekranda turuncu uyarı. Reddetmek, tek bir eksik ortam
değişkeninin azaltılmış güvenle çalışan bir özelliği tamamen düşürmesi olurdu —
`/api/second-opinion`'a verilen izolasyonun tersi. Ama tek-aileli bir koşu asla
mutabakat gibi görünmemeli; ekran bunu adıyla söyler.

**İki aile de düşerse 5xx döner**, boş `zones` ile 200 değil: boş sıralama
"karanlık yer yok" diye okunur — bu özelliğin kazara veremeyeceği tek cevap.

## Neyi gevşetiyoruz

**Hiçbir şeyi.** İlk tasarımda bu ADR kaynaksız "hayalet kart" üretmeyi de
kapsıyordu ve provenans kuralını (her kartın bir sayfa fotoğrafına dayanması)
gevşetmeyi gerektiriyordu. Bu turda **bilerek uygulanmadı**: harita, kart
üretmeden de tam bir üründür ve provenansı gevşetmek, sahibinin haritayı gerçek
destesinde çalışırken görmesinden **sonra** verilecek ayrı bir karardır.

Güvenlik omurgası da olduğu gibi duruyor: anahtarlar yalnız backend'de, telefon
Supabase'i hiç görmüyor, log'a içerik yazılmıyor (§7.3 — test, konu adının,
gerekçenin ve kart sorusunun log'a düşmediğini ayrıca kilitliyor).

## Sonuçlar

- **Yeni kalıcı veri yok.** Uç veritabanına dokunmaz, `jobs` tablosuna sütun
  eklemez, SwiftData şemasını değiştirmez — yani bu değişikliğin göç riski yok
  (ADR-006'nın "migration sırası" kuralı burada devreye girmiyor).
- **Senkron, kuyruk değil.** Görüntü taşımaz, kalıcı bir şey üretmez, saniyeler
  sürer. ADR-006 kuyruğu isteği aşan işler için var; bu onlardan değil.
- **Maliyet:** iki metin çağrısı, sayfa başına üretimden ucuz. İkisi de
  `ModelRun`'a `purpose: "dark_map"` ile yazılır, Kullanım ekranı ikisini de
  sayar. Başarısız çağrı da yazılır (`billing` üç değerli: kapıda reddedilen
  bedava, yolda kesilen ölçülemedi).
- **Kendi bütçe bloğu** (`DARK_MAP_*`), OpenAI'ninkini ödünç almaz: kart üretimi
  tam çözünürlüklü bir görüntü + 18 karta kadar yazar, bu çağrı ~143 satır metin
  + en fazla bir düzine kısa yargı. Ortak değişken kullansaydı yakalama hattının
  her ayarı sessizce burayı da ayarlardı. **Effort/tavan çifti kuralı burada da
  geçerli** — `.env.example` bunu uyarıyla yazıyor.
- **Askıya alınmış kart kapsama sayılmaz.** `DuplicateSuspendMigration`'ın
  kaldırdığı 117 kopya, bir konuyu "çalışılmış" göstermemeli.

## Riskler

1. **Ortak halüsinasyon.** İki aile aynı yaygın yanlışta anlaşabilir. Azaltma:
   onaylanmış bölge bile öneridir; deterministik yarı ayrı sunulur; gerekçeler
   aile aile basılır, ortalanmaz.
2. **TUS ağırlığı tahmini kayabilir** — modelin bilgisi eğitim verisinden gelir,
   güncel ÖSYM dağılımını birebir tutmayabilir. Azaltma: skorla değil **sırayla**
   sunulur, ve `maxZones` varsayılanı 12 (envanter değil, çalışma sırası).
3. **Prompt kuralı bağlamayabilir.** v2.6/v2.7 deneyimi net: yalnız tercih
   bildiren kural kımıldamıyor, hatayı adlandırıp yanlış/doğru çifti veren kural
   82/360→0/239 gidiyor. Kural 1–4 bu biçimde yazıldı ve `darkMapPrompt.test.ts`
   biçimi blok blok kilitliyor. Yine de gerçek ölçüm cihazda.

## Codex incelemesi (PR #49) — üç tur, yedi P2, hepsi düzeltildi

### Tur 1 — dört bulgu

1. **Şema kanonik listeye değil, isteğin kendi tablosuna bağlanmalı.** `subjects`
   daraltıldığında enum yine 143 konu sunuyordu; model dışarıda bırakılmış bir
   dersin konusunu **geçerli biçimde** döndürebilirdi ve `mergeRankings` onu
   kapsama tablosunda bulamayıp **uydurma 0 kart** basardı. Bu, bu özelliğin
   kendi değişmezinin ("kart sayısı daima desteden, asla modelden") ihlaliydi.
   Artık üç katman da (`allowedTopicKeys`) isteğin tablosundan türüyor, ve
   `mergeRankings` satırı olmayan bölgeyi **basmak yerine düşürüyor** —
   uydurma sayı yapısal olarak imkânsız.
2. **Gemini'nin kesilme yolunda `usageMetadata` kayboluyordu.** `MAX_TOKENS`
   ile biten bir üretim tam ücret faturalanır *ve* Gemini tam rakamı verir; ama
   `GeminiError`'ın usage alanı yoktu, defter sıfır token yazıyordu. Sistemin en
   pahalı hatası, ölçümün mevcut olduğu yerde eksik raporlanıyordu — yani
   `tokenUsage.ts`'in var olma sebebinin aynısı. `GeminiError` artık `usage`
   taşıyor (OpenAIError'ın eşi), usage HTTP katmanından hemen sonra bir kez
   okunuyor ve her hata yoluna veriliyor.
3. **Gemini taşıma hatası sarılmamıştı.** Zaman aşımı ham bir `AbortError`
   olarak kaçıyordu; ne `OpenAIError` ne `GeminiError` olduğu için iki-aile-de-
   düştü yolu onu geçici sayamıyor, kalıcı bir OpenAI hatasıyla birleşince
   `retryable: false` üretiyor ve **telefon "Tekrar dene" sunmuyordu.** OpenAI
   sıralayıcısındaki sarmalayıcının aynısı eklendi.
4. **Birleşmiş sonucun tavanı yoktu.** Her aile ayrı ayrı `maxZones`'a
   kırpılıyordu ama birleşim değil: ayrık seçimlerde 12 isteyen 24 alıyordu.
   `mergeRankings` artık sıralamadan **sonra** kırpıyor, yani hayatta kalanlar
   onaylanmış ve en karanlık olanlar.

Yan ürün: filtreli istekte prompt modele "Kanonik şablonda N konu var" diyordu —
N daraltılmış sayı olduğu için bu yanlıştı, ve kapalı-küme çerçevesi bütün
prompt'un dayandığı şey olduğu için yanlış olması önemliydi. "Aşağıdaki tabloda
N konu var" oldu.

### Tur 2 — bir bulgu

5. **Giriş kartı ile ekran aynı desteyi farklı sayıyordu.** Bilgi Haritası'ndaki
   giriş kartı `coveredTopicCount`'u (tüm kartlar), açtığı ekran ise
   `DarkMapCoverage`'ı (yalnız aktif kartlar) kullanıyordu; kartlarının hepsi
   askıya alınmış bir konu birine göre kapsanmış, diğerine göre boştu — **sayı
   dokununca değişiyordu.** Bu destede somut: `DuplicateSuspendMigration` 117
   kartı askıya aldı. Tanımlardan biri yanlış değildi (tile *desteyi*, harita
   *çalışılanı* anlatır); yanlış olan giriş kartının birini hesaplayıp
   diğerinin ekranına götürmesiydi. Tek tanım `KnowledgeMapSummary.
   activeCoveredTopicCount`'a çekildi ve `DarkMapCoverageAgreementTests` ile
   kilitlendi.

### Tur 3 — iki bulgu

6. **Boş/tamamen askıda deste engelleniyordu, üstelik yanlış sebeple.** Ekran
   "önce kartlara ders/konu atanmalı" diyerek çağrıyı reddediyordu; oysa satırlar
   deste boşken ya da her kart askıdayken de boştur ve o cümle o hâllerde
   **yanlıştır**. Reddetmek kendi içinde de hatalıydı: sunucu boş `coverage`'ı
   143 konuya sıfır doldurup yalnız TUS ağırlığına göre sıralar, ki bu yeni
   başlayan biri için bu özelliğin verebileceği en yararlı cevaptır. Engel
   kaldırıldı; kişiselleşmemiş durum düğmeden **önce** açıklanıyor.
7. **Hata yolu deterministik yarıyı düşürüyordu.** Bu modülün kendi başlığı
   `untouched` için "model çağrısından önce üretilir ve iki çağrı da düşse bile
   döner" diyor; hata yolu bu sözü sessizce çiğniyordu. Telefon bunu ıskalamaz
   (aynı listeyi cihazda üretir — ekranın uçak modunda çalışmasının sebebi de
   bu), ama yalnız başarı yolunda tutan bir sözleşme yazılan sözleşme değildir.
   `untouched` + `totals` artık hata gövdesinde de var, ve iki yol aynı
   projeksiyon fonksiyonlarını paylaşıyor.

## Değerlendirilen alternatifler

- **Tek model.** Ucuz ve basit; ama zemini olmayan bir iddiada tek okuyucunun
  idiyosenkrazisini görecek hiçbir şey kalmıyor. §10.4'ün sağ çıkan fikri tam
  buydu.
- **Serbest konu adı (şablonsuz).** Modelden "eksik olduğunu düşündüğün konuları
  yaz" istemek. Reddedildi: çıktı desteye **join edilemez**, "Egzersiz'de çalış"
  gibi hiçbir eylem bağlanamaz, ve uydurulmuş konu adı ile gerçek boşluk ayırt
  edilemez hâle gelir. Kapalı şablon bu özelliği mümkün kılan şeydir, kısıtı
  değil.
- **Kuyruğa (ADR-006) bindirmek.** Gereksiz: görüntü yok, kalıcı çıktı yok,
  saniyeler sürüyor. İş satırı, bir isteği aşan işler içindir.
- **Hayalet kart üretimi (ilk tasarım).** Ertelendi, yukarıya bakın.

## Sonraki adım (karar sahibinde)

Harita gerçek destede çalıştıktan sonra: onaylanmış karanlık bölgeler için
**hayalet kart** üretimi (OpenAI üretir, Gemini bağımsız doğrular, yalnız
mutabakattan geçen kart `.active` girer, görünür 👻 rozetiyle ve boş
`canonicalClaim` ile — elle kartın sözleşmesinin aynısı; o konudaki gerçek sayfa
çekildiğinde kart **terfi eder**). Bu, provenans kuralını gevşetmeyi gerektirir
ve bu yüzden ayrı bir ADR'nin konusudur.
