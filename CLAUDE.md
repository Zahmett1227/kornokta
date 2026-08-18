# Çizgi — proje durumu (yeni oturum için)

Bu dosya her yeni Claude Code oturumunun başında otomatik okunur. Amacı: bir
önceki oturumun hafızasını taşımadan, buradan devam edilebilmesi. **Yalnız
güncel durumu taşır** — oturum-tarihi kayıtları ve süperseded mimarinin
ayrıntıları [`docs/HISTORY.md`](docs/HISTORY.md)'de.

## Proje ne

Tek kullanıcılık (sahibi için) iOS uygulaması: kitapta işaretlenen (altı
çizili/fosforlu/dairelenmiş/yanına not alınmış) tıbbi bilgiyi fotoğraftan
yakalar, OpenAI vision modeline okutup zenginleştirilmiş öğrenme kartlarına
dönüştürür, FSRS-6 ile tekrar ettirir. Kullanıcı Türkçe konuşan bir TUS
öğrencisi/hekim.

**Tüm ürün/mimari/kalite kararlarının kaynağı:**
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md).
Bölüm numaralarına (§0.5, §19.3 gibi) kod yorumlarında sürekli atıf yapılır.
Ancak ANA-PLAN'ın tıbbi-güvenlik omurgası Faz 6 pivotuyla kişisel kullanım
için bilinçle gevşetildi — güncel kararlar ADR-005/006/007'dedir ve ANA-PLAN'ın
üstündedir.

Dokümantasyon ve kullanıcıyla iletişim **Türkçe**; kod tanımlayıcıları ve
yorumları **İngilizce**.

## Güncel yön — Faz 6 / vision-öncelikli (pivot: 2026-08-05)

Ana akış: *işaretli sayfa fotoğrafını doğrudan OpenAI vision modeline gönder →
model kullanıcının önemsediği kısmı kendisi okuyup zenginleştirilmiş kartları
üretsin → kartlar onaysız doğrudan desteye girsin → FSRS ile tekrar edilsin.*

- **Neden ve hangi ilkeler gevşedi:** [`docs/ADR-005`](docs/ADR-005-kisisel-vision-yeniden-tasarim.md)
- **Asenkron iş kuyruğu:** [`docs/ADR-006`](docs/ADR-006-supabase-is-kuyrugu.md)
- **Egzersiz→FSRS köprüsü:** [`docs/ADR-007`](docs/ADR-007-egzersiz-fsrs-koprusu.md)
- **Kullanıcı kararları:** hata riski kabul edildi (uygulama tek çalışma
  kaynağı değil), yayınlanma yok (tamamen kişisel), OpenAI'de kalınıyor.

**Önemli (2026-08-09):** Faz 6 öncesi deterministik hat (Apple Vision OCR,
cihaz üstü işaret tespiti, Google Document AI, uzlaştırma, grounding, onay
ekranı) uzun süre "geri dönüş için diskte" durduktan sonra kullanıcı kararıyla
**koddan silindi**. Geri dönüş = tıraş commit'inin (`git log`'da "Ölü kodu
tıraşla") revert'i. O mimarinin kaydı ADR-002/003/004 + `docs/HISTORY.md`'de.

### Ana akış bugün nasıl işliyor

1. **Yakala:** işaretli sayfa fotoğrafı — kameradan ya da galeriden (galeriden
   gelen her fotoğraf tek noktada JPEG'e ve düz yöne normalize edilir,
   `ImportedImage`) → **çift sayfa mı?** (`PageSplit`, en/boy oranı; evetse tek
   dokunuşluk "Sol/Sağ/Tümü" adımı) → dHash ile "bu sayfayı daha önce çektin
   mi?" sorusu (reddetmez, **sorar**) → bayt diske yazıldıktan sonra kuyruğa
   girer.
2. **Kuyruk:** `ProcessingQueue` sayfaları 3'lü paralel işler; işlem sürerken
   ekran kilidini ve bir arka plan assertion'ını tutar, geçici hataları
   `nextAttemptAt`'e uyarak kendiliğinden tekrar dener.
3. **Üretim (asenkron, ADR-006):** `POST /api/jobs` sayfayı Supabase Storage'a
   yazar, satırı `queued` yapar ve saniyeler içinde 202 döner; üretim yanıttan
   sonra `waitUntil` altında sürer. Telefon `GET /api/jobs?ids=` ile yoklar.
   **İş kimliği = sayfa kimliği** — uygulama beklerken öldürülse bile bir
   sonraki açılış biten işi bulup alır (ikinci üretim ücreti yok). Görüntü iş
   bitince, sonuç metni **60 gün** sonra silinir (docs/PRIVACY.md).
4. **Kartlar onaysız** `.active` olarak SwiftData'ya girer ve FSRS-6 ile
   tekrar edilir. "Kaynağı göster" sayfa fotoğrafını ve modelin okuduğu metni
   gösterir; kart düzenleme FSRS geçmişine dokunmaz.
   **Sayfa detayı (2026-08-15):** kuyruktan bitmiş bir sayfaya dokununca açılan
   ekran artık salt-okunur değil — üretilen karta dokunmak ortak
   `CardEditorView`'ı açar (soru/cevap, açıklama, **kart tipi**, ders/konu,
   şıklar), her pasajın altındaki **"Kart ekle"** ise `ManualCardSheet`'i.
   Kartı **sola kaydırmak siler** (2026-08-15): Bilgilerim'deki
   `LibraryView.deleteCards` deseninin aynısı ve aynı sebeple **onaysız** —
   sahibin baktığı tek kart. Kuyruk *listesindeki* diyalog başka bir şeyi
   koruyor: orada tek kaydırma sayfanın bütün kartlarını ve tekrar geçmişini
   birden alır. Kartsız kalan `KnowledgeUnit` bilerek duruyor (modelin
   okumasını taşır; budanması ayrı bir karar).
   Elle eklenen kart üretilenle aynı yoldan girer (aynı region/unit zinciri,
   `status: .active`, sıfır FSRS durumu) — tek farkı unit'inin
   **`canonicalClaim`'inin boş olması**. `canonicalClaim` "Kaynağı göster"de
   *Modelin okuduğu* başlığı altında basılır, yani bir provenans iddiasıdır;
   model bu kartı hiç okumadığı için orada söylenecek bir şey yoktur ve boş
   claim bu yokluğu **yapısal** olarak temsil eder (`nonEmpty` onu düşürür).
   Oraya kartın sorusunu yazmak yanlıştır: `CardSourceResolver` okumayı yalnız
   karta *eşit olduğu sürece* gizler, soru düzenlenince eski soru "Modelin
   okuduğu" olarak geri çıkar (Codex, PR #43). Aynı sebeple
   `KnowledgeUnitBinding` eşleşmesine claim de girer — elle kart modelin
   unit'ine yapışıp onun okumasını kendi kaynağı gibi gösteremesin diye.
   Kart tipi değişikliği ve ders/konu bağlama kuralları çekirdekte ve testli
   (`CardTypeChange`, `ManualCardDraft`, `KnowledgeUnitBinding`).
5. **Kartların bir kısmı beş şıklı** olabilir (§13.3, Ayarlar'daki mod). FSRS
   eşlemesi asimetrik: yanlış şık = Unuttum; doğru şıkta Zor/İyi/Kolay.
6. **Şüpheli kartlar bloklanmaz, işaretlenir:** `lowConfidence` kartlar
   Bilgilerim'de "Gözden geçir" bölümünde listelenir. Böyle bir kartın
   detayında **"İkinci görüş iste"** düğmesi var (2026-08-11): telefondaki
   orijinal sayfa + kart `/api/second-opinion`'a gider, **Gemini** (bilinçli
   olarak kartı üreten OpenAI'den bağımsız aile; §10.4'ün pivotu sağ çıkan
   fikri) bölgeyi yeniden okuyup `supports|contradicts|unclear` verdikti döner.
   Yalnız istek üzerine harcar; cevabın metni kaydedilmez (ekrandan çıkınca
   gider) ama maliyeti kaydedilir (`ModelRun`, `purpose: "second_opinion"` —
   Kullanım ekranı Gemini'yi de sayar),
   `GEMINI_API_KEY` yoksa/Gemini çökse yalnız bu düğme etkilenir. Kota/kredi
   biterse hata mesajı bunu **adıyla** söyler; OpenAI 429 `insufficient_quota`
   da öyle (sahibinin şartı — "sorunu arayıp arayıp durmayalım").
7. **Egzersiz** (varsayılan açılış sekmesi) FSRS'ten ayrı puanlanır
   (`ExerciseRun`/`ExerciseAttempt`, 90 gün saklanır, yedeğe girmez) ama
   FSRS'i **korumalı köprüyle** besler (ADR-007): erken doğru → kısmi
   stabilite kredisi (vade asla ileri itilmez); erken yanlış → soft lapse
   (`Card.softLapseCount`, en fazla 1 gün öne çekme); vadeye yakın yanlış →
   gerçek FSRS "Unuttum"; vadesi gelmiş kart ve "Kararsızdım" hiç dokunmaz;
   `ReviewLog` Egzersiz'den asla yazılmaz.
8. **FES** (ADR-008, 2026-08-14): Tekrar'ın dört derecesi (Unuttum +2 · Zor +1 ·
   Bildim/Kolay −2) ve Egzersiz'in üç sonucu (Bilemedim +2 · Kararsızdım +1 ·
   Biliyordum −2) ortak, **kalıcı** bir ağırlıklı skoru besler (`Card.fesScore`,
   `[0,12]` kırpılı, eşik 3 — `FesScore.swift`). ADR-007'nin köprüsünden
   bağımsız: FES saf muhasebe, hiçbir zamanlama kararını etkilemez ve
   `EarlyPractice`'in due/frozen kapılarına tabi değildir. Eşiği aşan kart
   Egzersiz'in "FES kartlar" hızlı başlangıcında (üyelik FES, sıra
   `WeakPointRanking.rank`), Bilgilerim'de ayrı bir bölümde ve kart
   detayında görünür; öncesi değil **cevap açıldıktan sonra** (ölçümü
   bozmasın diye). Geçmiş kartlar `FesBackfillMigration` ile karta özel
   `fesInitializedAt` alanına bakılarak (bir UserDefaults bayrağı değil —
   yeni kart da pre-v6 yedekten gelen kart da `nil` ile başlar ve
   kendiliğinden işlenir) bir kerelik geriye oynatılır.
9. **Egzersiz kurulumu altı boyutlu** (ADR-008): ders, konu (mevcut
   `TopicFilter`), kart tipi, kart durumu (`unstudied`/`due`/`needsReview`),
   eklenme tarihi, FES — `ExerciseFilter.swift`, ayrı bir "Egzersizi kur"
   sheet'inde (`ExerciseSetupSheet`, taslak + Uygula deseni, canlı sayaç).
   Bütçe kart sayısı kademeleri **ya da süre** olabilir (`ExerciseBudget`);
   süre, Tekrar'ın `ReviewPace`'i (varsayılmayan, ölçülen kart-başı süre)
   Egzersiz'in kendi `ExerciseAttempt.responseTimeMs` örnekleriyle beslenerek
   kart sayısına çevrilir — çekirdekte hiçbir değişiklik gerekmedi.

### Ders/konu sınıflandırması, Egzersiz ve Bilgi Haritası (kalıcı sözleşmeler)

- **Konu şablonu tek kaynak:** `backend/schemas/subject_topics.json` (11 ders,
  143 konu; tusoskop'tan elle portlandı, senkron tarihi `_comment`'te).
  `ios/CizgiCore/.../Resources/subject_topics.json` byte-birebir kopyası;
  `backend/tests/subjectTopics.test.ts` ayrışırsa kırılır. **Konu adları
  yalnız ders içinde tekil** → her kontrol `(ders, konu)` çifti üzerinden.
  Uygulamada tek erişim noktası **`SubjectTopicSchema.shared`**.
- **Prompt v2.6 (2026-08-12, Tur A ölçümünden):** dört kural, dördü de sayarak
  gerekçelendi. **Kural 3(b) — yıldız:** el yazısından sonra en değerli, altı
  çizili ve fosforludan önce; gerekçesi prompt'ta yazılı (fosforlu hızlı ve
  geniş sürülür, yıldız ayrı ve bilinçli bir harekettir). Yıldız/ok bir şeyi
  *işaret eder, üstünü örtmez* — kart, gösterilen hedefe göre kurulur. Sıra
  testle kilitli ve kilit **konum tabanlı**: madde taşınırsa ya da silinirse
  test düşer (metin araması kural 3'ün kendi bloğuna sabitli — prompt'ta
  "EL YAZISI notlar" iki yerde geçtiği için tüm prompt'ta arama yapan bir
  kontrol hiçbir şey korumuyordu). **Kural 8 — kart tek başına anlaşılmalı:** kartın metni sayfaya
  atıf yapamaz ("sayfadaki kutuya göre…" kitap kapalıyken cevaplanamaz); tek
  istisna okunamayan el yazısının `explanation`'da anılması, `front`/`back`
  asla. **Kural 5 — tek fikir**, artık bölünebilir ve sınanabilir ("cevabın
  yarısını bilen dürüst not verebilmeli"). **Kural 2 — tarama**, sayfanın alt
  yarısı/kenar boşlukları için sertleşti ve bitiş kontrolü kazandı; bu sonuncusu
  ucuz kademenin *sessiz kapsama boşluğuna* karşı tek savunma (üretilmemiş kart
  `lowConfidence` taşımaz). Sürüm sabiti `CARD_PROMPT_VERSION`, kurallar
  `tests/prompts.test.ts` ile kilitli.
- **Prompt v2.7 (2026-08-15, sahibin gerçek sayfada bildirdiği kusur):** model
  yıldızlı/daireli pasajı `readText`'e yazıyor — yani **görüyor** — ama kartları
  aynı sayfanın işaretsiz yerlerinden kuruyor. Eksik olan kural değildi (3(b)
  yıldızı zaten fosforlunun üstüne koyuyordu, kural 2 zaten kapsama kontrolü
  istiyordu); eksik olan, v2.6'nın kendi ölçümünün gösterdiği **bağlayıcı
  biçimdi** — hatayı adlandıran + yanlış/doğru çifti veren kural 8 82/360→0/239
  gitti, yalnız tercih bildiren kural 5 hiç kımıldamadı. İki mevcut kural o
  biçime çevrildi: **3(b)** hatayı adıyla anıyor ("okudum ama karta çevirmedim")
  ve onu üreten readText-vs-kartlar çiftini gösteriyor; **kural 2'nin bitiş
  kontrolü** artık sayfa sırasına değil **öncelik sırasına** göre yürüyor ve bir
  işareti elemek onu *hangi daha değerli işaret için* elediğini söylemeyi
  gerektiriyor — gerekçelendirilemeyen bir eleme, eleme değil **atlamadır**.
  Sayfa-sıralı kontrolün göremediği ayrım tam buydu: kart üretilmişti, yalnız
  yanlış işaretlerden. **Kademe adlandırıldı (Codex'in iki turunun ürünü):**
  yıldız/artı/ünlem/ok ve daire/kutu/çerçeve artık tek bir adın altında —
  **`SEMBOL İŞARETLERİ`** — ve hem bitiş kontrolü hem bağlayıcı kural kademeyi
  *adıyla* anıyor. Sebebi: küme üç yerde tekrar edilince kayıyordu (öncelik
  listesi oku sayıyordu, iki uygulama noktası yalnız "yıldız/daire" diyordu —
  yani ok işaretli pasaj listenin içinde, korumanın dışındaydı). Yeni işaret
  tipi eklemek artık tek düzenleme. Sahibin kullandığı **kutu/çerçeve** bu
  turda eklendi: prompt onu üç yerin hiçbirinde, tarama listesinde bile
  anmıyordu. Kademenin üyeleri ve tarandığı testle kilitli; sıra kilidi
  üyelere değil **kademe adına** bakıyor (üye eklemek "sıra bozuldu" demek
  değil). **Değişmez (üçüncü turda kilitlendi):** üye listesi tam **iki**
  yerde yaşar — tarama listesi (ne aranacak) ve 3(b) (nasıl sıralanır).
  *Uygulama* noktalarının (1. kuralın kapısı, bitiş kontrolü, bağlayıcı kural)
  hiçbiri üye saymaz, kademeye adıyla atıf yapar. Üçüncü tur tam buradan
  geldi: 1. kural bir **kapı** ("cevap hayırsa VAZGEÇ") ve yeniden
  adlandırmadan sağ çıkmış kısmi listesi yüzünden yalnız artı/ünlemle
  işaretlenmiş bir pasajı, öncelik kuralı onu hiç görmeden eleyebiliyordu.
  Kilit `not.toContain` değil harf-sınırlı regex kullanır — Türkçe'de "kartı"
  içinde "artı" geçer. İki kural da testle kilitli ve kilitler **kural 3'ün /
  kontrolün kendi bloğuna sabitli** (aynı blok-dilimleme gerekçesi).
- **Şema v2.2 / prompt v2.5:** karta opsiyonel `topic`. Kanonik şemada enum
  yok; enum yalnız model-yüzlü dinamik şemada (`buildModelResponseSchema` →
  `anyOf: [enum-string, null]`). Üç katman: şema enum'u + prompt + sunucu
  sanitizasyonu (`sanitizeTopics`). **Geçersiz konu işi asla düşürmez, null'a
  çevrilir.** `subject` istekle gelir, `jobs.subject` kolonunda taşınır;
  bilinmeyen ders 400 değil null.
- **Kart başına kesin konu:** `persist`, kartları konuya bölüp konu başına bir
  `KnowledgeUnit` üretir (`TopicGrouping`); hepsi aynı `TextRegion`'ı paylaşır.
- **Migration'lar:** `SubjectBackfillMigration` (tanınmayan/boş ders →
  "Patoloji") ve `TopicBackfillMigration` (PR #34/#35: mevcut 204 Patoloji
  kartına konu atadı) idempotent, bayrakla tek seferlik.
- **Alt navigasyon** yerli `TabView` çubuğu değil, `CizgiRootTabBar`; her
  sekmenin `NavigationStack`'i içindeki kök içeriğe `rootTabBarInset()` ile
  bağlı — push edilen ekran barı doğal olarak almaz. **Tüm push'lar değer
  tabanlı** (2026-08-09 refaktörü): `NavigationLink(value:)` +
  `navigationDestination` yığın köklerinde; `goHome()` path sıfırlaması
  gerçekten pop eder.
- **Alt navigasyonu gizleyen her ekran görünür bir çıkış borçlu** (kural
  `AppNavigator.isTabBarHidden`'ın başında; Egzersiz'in "Bitir"i bunun için).
- **Bilgi Haritası:** kanonik ders/konu kapsamı; tanınmayan ad asla kanonik
  düğüm üretmez ama sayılır ("Konusuz" / "tanınmayan konu" /
  "sınıflandırılmamış" kovaları) — ekrandaki satırların toplamı desteye eşit.
- **Yedek biçimi v6:** `CardRecord` = kart + FSRS durumu + tüm `ReviewLog`
  geçmişi + şıklar + `lowConfidence` + `topic` (v4) + `softLapseCount` (v5) +
  FES sicili (v6: `fesScore`/`fesNegativeCount`/`fesInitializedAt`). Eski
  dosyalar `decodeIfPresent` ile okunur; geri yükleme yalnızca ekler ve eski
  ders adlarını normalize eder. **FES üçlüsü zaten-sonuçlanmış yazılır**,
  alıcı cihazda yeniden hesaplanmaz — `ExerciseRun`/`ExerciseAttempt` hiçbir
  sürümde yedeğe girmediği için bir replay yalnız `ReviewLog` yarısını görür.
- **FES sicili ve altı boyutlu Egzersiz filtresi:** ADR-008. Ana akışın 8-9.
  maddelerine bakın.

## Şu an neredeyiz (2026-08-11)

| İş | Durum |
|---|---|
| Faz 0–5 (iskelet → sertleştirme) | ✅ Tamam (tarih: `docs/HISTORY.md`, faz planları). Faz 2'nin OCR hattı önce ana akıştan çıktı, sonra 2026-08-09'da koddan silindi. |
| Faz 6 — vision-öncelikli yeniden tasarım + ADR-006 kuyruğu | ✅ Tamam ve cihazda doğrulandı (PR #15–#27) |
| Galeriden fotoğraf ekleme | ✅ Tamam ve cihazda doğrulandı (PR #28) |
| Faz 7 — beş şıklı TUS kartı | 🟡 A1–A5 `main`'de (PR #29); **A6 (distraktör kalitesi, gerçek sayfa) açık** |
| Ders/konu sınıflandırması + Egzersiz modu | ✅ Tamam (PR #32); `jobs.subject` kolonu canlıda |
| Egzersiz merkeze + Bilgi Haritası | ✅ `main`'de (PR #33); üç P0 cihazda doğrulandı |
| Konu backfill (204 Patoloji kartı) | ✅ `main`'de (PR #34/#35) |
| `jobs.result` 60 günlük saklama süpürmesi | ✅ `main`'de (PR #36); karar: docs/PRIVACY.md |
| Ölü kod tıraşı (deterministik hat silindi) | ✅ `main`'de (PR #36); ADR-005'e not düşüldü |
| Değer tabanlı navigasyon refaktörü | ✅ `main`'de (PR #36); cihazda doğrulandı (2026-08-13) |
| Egzersiz→FSRS köprüsü (ADR-007) | ✅ `main`'de (PR #36); cihazda doğrulandı (2026-08-13) |
| Çift sayfa kadraj düzeltmesi (`PageSplit` + "Sol/Sağ/Tümü") | ✅ `main`'de (PR #37); kamera **ve galeri** yolunda cihazda doğrulandı (2026-08-13) — PhotosPicker artık riski gerçekleşmedi |
| Gemini ikinci görüş (`/api/second-opinion` + "İkinci görüş iste") | ✅ `main`'de ve **cihazda doğrulandı** (2026-08-13). Gemini `responseSchema`'yı kabul ediyor — OpenAI'de yaşadığımız şema riskinin buradaki eşi de kapandı |
| Çağrı başına maliyet defteri (cached/reasoning token, başarısız çağrılar, Kullanım dökümü) | ✅ `main`'de; `jobs.usage` migration'ı canlıda; Kullanım ekranı cihazda doğrulandı (2026-08-13) |
| Teşhis mesajı (sunucunun gerçek hatası ekrana) | ✅ `main`'de ve cihazda (2026-08-13) |
| Model karşılaştırması — Tur A koşuldu ve kör değerlendirme yapıldı (2026-08-12, 6 sayfa × 3 model × 20 kart) | ✅ Bulgular `docs/PLAN-model-karsilastirma.md` → "Tur A sonucu". Özet: tek bayraksız hata Terra'dan ve iki koşuda tekrarladı; Luna 120 kartta sıfır bayraksız hata; Sol el yazısında en iyi. Tur B gereksiz. **Model kararı sahibinde açık** (Luna güçlü aday) |
| Prompt v2.6 (Tur A'nın ikinci ürünü) | ✅ `main`'de; Sol'un üstünlüğünün prompt'la alınabilen kısmı kurala çevrildi |
| Tur A2 — `luna@low` vs `luna@high` (2026-08-12 akşamı, prompt v2.6) | ✅ Koşuldu ve kör değerlendirildi. **`@high` 4 sayfada üstün, 1 eşit, 1 geride**; üstünlük el yazısı ve kapsamada. Bedeli: reasoning 685→72 017 token (105×), $0.005→$0.020/sayfa, 21→112 sn. İkisinde de "yanlış ama emin" sıfır. Ayrıntı `docs/PLAN-model-karsilastirma.md` → "Tur A2 sonucu". **Model kararı sahibinde açık** (`luna@high` önerilen) |
| Prompt v2.6 doğrulaması | ✅ İki bağımsız koşudan: sayfaya atıf yapan soru **82/360 → 0/239** (kural 8 tuttu, pahalı kademede de); çok-fikirli kart değişmedi (kural 5 bağlamadı, sonraki turda yeniden yazılacak) |
| Tur A3 — `luna@medium` vs `luna@high` vs `sol@low` (aynı prompt sürümünde ilk dürüst kıyas) | ✅ Koşuldu ve kör değerlendirildi. **`medium` elendi** (turun tek sessiz hatası + tek uydurma kartı ondan; el yazısında 3 sayfada sonuncu). `sol@low` ↔ `luna@high` kalitede yakın, maliyette **7,5 kat** uzak ($0.1394 vs $0.0186/sayfa). **Karar: `luna@high`** — sahibinin ölçeğinde ~$240 yerine ~$32 |
| FES sicili + Egzersiz'in altı boyutlu filtresi/bütçesi (ADR-008, 2026-08-14) | 🟡 `main`'de (PR #41, squash `e934cb7`); Codex turları kapandı. Yerel `swift test` + `xcodegen`/`xcodebuild`, backend ve evals yeşildi; simülatörde kurulup açıldı — kritik risk olan "yeni migration açılışta çökertir mi" orada elendi. **Cihaz doğrulaması açık:** aşağıdaki doğrulama listesinin 1-5. maddeleri |
| Sayfa başına kart tavanı 12→18 (2026-08-14) | ✅ `main`'de (PR #42). Sunucu tavanı (`config.ts`/`.env.example`), iOS varsayılanı + Stepper aralığı (`AppEnvironment`/`SettingsView`) ve çıktı token tavanı (aynı 1,5× oranla 8192→12288) **birlikte** değişti — istemci sunucu tavanını aşamadığı için (§21.3) yalnız birini değiştirmek hiçbir şey yapmazdı. Canlıda `OPENAI_MAX_OUTPUT_TOKENS` elle 48000'e çekilip redeploy edildi; `OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT` Vercel'e hiç girilmemiş, tavan kod varsayılanından geliyor. Codex'in iki gerçek iOS bulgusu düzeltildi: mevcut kurulumlarda UserDefaults'taki 12 için bayraklı tek seferlik göç, ve temiz kurulumda bayrağın hemen yazılması (yoksa kullanıcının sonradan bilerek seçtiği 12 sessizce 18'e çevrilirdi). **Cihaz doğrulaması açık:** yoğun işaretli bir sayfa gerçekten 12'den fazla kart üretiyor mu, ve Ayarlar'daki Stepper 18'e kadar çıkıyor mu |

| Sayfa detayında kart ekleme + düzenleme (2026-08-15) | ✅ `main`'de (PR #43, squash `721ed19`). Kuyruktan açılan sayfa ekranı (`PageDetailView`) salt-okunur olmaktan çıktı: karta dokunmak ortak `CardEditorView`'ı açıyor, her pasajın altında **"Kart ekle"** var (`ManualCardSheet`). Gerekçe: modelin tehlikeli hatası yanlış kart değil **eksik** kart, ve üretilmemiş kart `lowConfidence` taşımadığı için onu hiçbir otomatik sinyal görmüyor — tek çare sayfaya bakarken elle eklemek. Ortak editör **kart tipi seçici** kazandı (Bilgilerim/Tekrar/Egzersiz de). Codex'in iki P2'si kapatıldı: elle kartın unit'i boş `canonicalClaim` taşıyor (yukarıdaki 4. madde) ve bu belge de o sözleşmeyi yazıyor. Yerel `swift test` (391), simülatör derlemesi, backend ve evals yeşil. **Cihaz doğrulaması açık:** aşağıdaki listenin 6-10. maddeleri |
| Deste denetimi: kopya kartların askıya alınması (2026-08-18) | 🟡 Dalda. Sahibinin 2026-08-18 yedeği (1007 kart) baştan sona okundu: 996 aktif kartın **117'si** (%12) birebir/yakın kopya (74) ya da tutulan başka bir kartın cevabında tamamen kapsanan (43) — ana kaynak aynı sayfanın birden çok kez çekilmesi; en yoğun konu Solunum (142 kartın 49'u). Küme küme gerekçeli rapor + UUID listesi sahibinde (sohbette dosya olarak). Uygulama: `DuplicateSuspendMigration` — kimlik listesi gömülü, tek seferlik, **siler değil askıya alır** (`ReviewLog`/FES korunur, "Askıdan çıkar" ile tek tek geri alınır), yalnız `.active` karta dokunur. Bilinçli olarak `TopicBackfillMigration`'ın seen-set deseni DEĞİL (o desenin sonsuz-tarama açığı "Küçük ve gerçek kalanlar" 2'de kayıtlı): bayrak ilk başarılı kayıtta yazılır; temiz kurulum + sonradan restore boşluğu ise `ApprovalGateMigration`'la aynı biçimde kapalı — `SettingsView.restore`, idempotent `suspend(in:)` adımını restore'un kendi context'inde yeniden koşar (Codex, PR #46 P2). Denetimin yan ürünleri: içeriği şüpheli 3 kart (anjiyomiyolipom-ağrı, miksoma-McCune-Albright, HER2→"Luminal B" — `lowConfidence` olmadıkları için İkinci Görüş düğmesi çıkmaz, elle bakılmalı) ve metni düzeltilmeli ~25 kart (v2.6 öncesi "Pasaja göre…" kalıntıları) rapora yazıldı, koda dahil değil. **Cihaz doğrulaması açık:** ilk açılışta Bilgilerim'deki askıdaki kart sayısı 11'den **128'e** çıkmalı; Tekrar/Egzersiz sayaçları düşmeli; bir kartta "Askıdan çıkar" denenip migration'ın geri askılamadığı görülmeli |

**Dal durumu:** çalışma dalları merge sonrası siliniyor; yeni iş `main`'in
ucundan yeni bir dalla başlar.

**Test durumu:** sayıların tek kaynağı CI (`.github/workflows/`): backend
(vitest + tsc), evals (pytest + üretici `--check`'ler), iOS (macOS runner'da
`swift test` + `xcodegen generate` + simülatör derlemesi). Üçü de yeşilse
durum sağlıklıdır. Bu belgeye test sayısı yazmıyoruz — üç yerde üç farklı
sayı tutmayı iki kez denedik, ikisinde de ayrıştı.

**⚠️ CI şu an kullanılamıyor — GitHub Actions kotası doldu (2026-08-14):** üç
workflow da (backend, evals, ios) artık bir runner'a **hiç atanmadan** saniyeler
içinde kırmızı dönüyor — imzası belirgin: `runner_id: 0`, boş `runner_name`,
2-4 saniyede "failure". Bu bir **kod sinyali değil**; checkout adımına bile
ulaşılmıyor, dolayısıyla log da yok (log indirme 404 veriyor). PR #42'de altı
koşunun altısı böyleydi ve aynı imza `main`'in kendi HEAD'inde de var (`ios`
en az 2026-08-12'den beri). **Sonuç:** yukarıdaki "üçü de yeşilse sağlıklıdır"
ölçütü kota yenilenene kadar geçersiz, ve bu dönemde kırmızı CI'ya bakıp "bu
değişiklik bir şeyi bozdu" diye okumak yanlış olur. Kota dönene kadar tek
gerçek kapı yerelde `npm test` + `npm run typecheck` ve bir Mac'te
`swift test`. Kota yenilendiğinde ilk iş `main`'i bir kez yeşile koşturup bu
notu silmek.

**Bu ortamın kalıcı sınırı:** Linux'ta `CizgiCore` derlenmiyor (CoreGraphics,
SwiftData); SwiftUI dosyaları yalnız `swiftc -parse` ile denetlenebiliyor — bu
sözdizimi kontrolüdür, tip hatası yakalamaz. Foundation-only mantık, indirilen
bir Swift araç zinciriyle izole bir pakette gerçekten koşturulabilir (ADR-007'nin
12 testi böyle doğrulandı). App hedefi ve tam paket için tek gerçek kapı
CI'daki macOS işi ya da bir Mac derlemesi.

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`), Root Directory
`backend`. Gerekli env değişkenleri `.env.example`'da; iş kuyruğu için
`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` şart. İkinci görüş düğmesi için
`GEMINI_API_KEY` (anahtar: aistudio.google.com, `docs/OPENAI-GEMINI-KURULUM.md`)
Vercel'e girilmeli — girilmezse yalnız o düğme "eksik ortam değişkeni" der,
başka hiçbir şey etkilenmez. Supabase'de `jobs` tablosu +
`page-uploads` özel kovası; ikisinde de RLS açık ve **policy yok** (yalnız
`service_role` geçer).

**Model (2026-08-13'ten beri canlı, `OPENAI_MAX_OUTPUT_TOKENS` 2026-08-14'te
48000'e çekildi):** `OPENAI_MODEL=gpt-5.6-luna`,
`OPENAI_REASONING_EFFORT=high`, `OPENAI_MAX_OUTPUT_TOKENS=48000`, fiyatlar
`0.2 / 0.02 / 1.2`. Gerekçesi üç turluk ölçüm:
`docs/PLAN-model-karsilastirma.md` → "Tur A3 sonucu". Özet: `sol@low` ile
kalitede yakın (ikisi de sıfır sessiz hata), maliyette 7,5 kat uzak —
sahibinin ölçeğinde ~$240 yerine ~$32. `MAX_USD_PER_CARD_GENERATION=0.30`
ayarlı; Ayarlar → Kullanım gerçek USD gösteriyor ve cihazda doğrulandı.

**Model değiştirirken kural:** `OPENAI_MODEL` tek başına değiştirilmez —
fiyat değişkenleri de aynı anda değişmeli (`..._INPUT_TOKENS`,
`..._CACHED_INPUT_TOKENS`, `..._OUTPUT_TOKENS`). Yoksa defter yeni modelin
tokenlarını eski modelin fiyatından çarpar ve Kullanım ekranı sessizce yanlış
okur — kaçırılması en kolay hata, çünkü hiçbir şey patlamaz. Kademe fiyatları
(2026-08 doğrulaması): Sol 5/0.5/30, Terra 2/0.2/12, Luna 0.2/0.02/1.2.

**`OPENAI_REASONING_EFFORT` yükseltilirken kural:** `OPENAI_MAX_OUTPUT_TOKENS`
da yükselmeli. Reasoning tokenları çıktı bütçesinden düşülür ve `high`'ta
sayfa başına ~12 000 token yiyor — 12288'lik varsayılan yalnız düşünmeye bile
yetmez. Tur A2'nin ilk denemesi tam bu yüzden 6/6 düştü; her düşen çağrı **tam
ücret** faturalanıp sıfır kart üretti. `high` için 32000 önerilir. Karşılaştırma
betiğinde `--max-output-tokens`, ve effort yükseltilip tavan yükseltilmediğinde
çağrılardan önce uyarı basılıyor.

**`OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT` yükseltilirken kural:**
`OPENAI_MAX_OUTPUT_TOKENS` da aynı oranda yükselmeli — daha çok kart, daha çok
görünür çıktı token'ı ister; reasoning'den bağımsız bir eksen ama aynı hata
sınıfı (yukarıdaki reasoning-effort kuralıyla aynı: tavanı büyütmeden ceza
büyütmek, düşen çağrı tam ücret faturalanır). 2026-08-14: kart tavanı 12→18
olunca kod varsayılanı aynı oranda (1,5×) 8192→12288'e çekildi (`config.ts`,
`.env.example`); sahibi canlıdaki `OPENAI_MAX_OUTPUT_TOKENS`'ı da elle 48000'e
çekip redeploy etti (yukarıdaki "Model" notu güncel).

**Kapanan risk (Codex, PR #42 P1 — 2026-08-14):** kart tavanı canlıda elle
girilmiş olsaydı `numeric()` onu kod varsayılanına tercih eder,
`OpenAICardGenerator` her isteği yine eski sayıya kırpar (§21.3) ve bu
değişiklik canlıda hiçbir şeyi değiştirmemiş olurdu. Sahibi Vercel'in ortam
değişkeni listesini kontrol etti: **`OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT`
girilmemiş** — yani tavan hep kod varsayılanından geliyor ve 18 dağıtımla
birlikte geçerli oluyor. Bu değişkeni ileride Vercel'e eklemek, `config.ts`'i
sessizce devre dışı bırakmak demektir; ekleneceği gün iki yer birlikte
güncellenmeli.

**Ortam değişkeni notu (2026-08-14 envanteri):** canlıda `DOCUMENTAI_*`,
`GOOGLE_PROJECT_ID` ve `GOOGLE_CREDENTIALS_JSON` hâlâ duruyor. Bunlar
deterministik hattın (ADR-005 tıraşı, 2026-08-09) kalıntısı; kod artık
hiçbirini okumuyor. Zararsız ama `GOOGLE_CREDENTIALS_JSON` gerçek bir
kimlik bilgisi — bir gün temizlik yapılacaksa oradan başlanmalı.

**Migration sırası (kural):** `jobs` tablosuna sütun ekleyen bir değişiklik
**dağıtımdan önce** canlıya uygulanmalı. Yeni kod sütunu yazar; sütun yoksa
PostgREST `insert`'i reddeder ve her çekim patlar. Dört sütun (`max_cards`,
`mc_mode`, `subject`, `usage`) canlıda mevcut — `usage` 2026-08-12'de uygulandı
(`jsonb not null default '[]'`, `jobs_usage_is_array` kısıtıyla; mevcut 28 iş
boş defterle geçti).

## Kararlar (değiştirmeden önce oku)

- **`docs/ADR-005`** — GÜNCEL YÖN: kişisel vision-öncelikli pivot;
  §0.5/§10/§12.1/§19'un gevşetilmesi. 2026-08-09 notu: deterministik hat
  koddan silindi, geri dönüş = tıraş commit'inin revert'i.
- **`docs/ADR-006`** — GÜNCEL YÖN: kart üretimi asenkron; iş kimliği = sayfa
  kimliği; cron yok, kurtarma + saklama süpürmeleri telefonun yoklamalarına
  biner. `_jobs.ts`/`supabaseJobs.ts`'e dokunmadan önce oku — kural: **her
  durum değişikliği onu haklı çıkaran duruma koşullu olmak zorunda.**
- **`docs/ADR-007`** — GÜNCEL YÖN: Egzersiz FSRS'i yalnız `EarlyPractice`
  köprüsünden besler. `ExerciseView.recordAndAdvance`/`EarlyPractice.swift`'e
  dokunmadan önce oku.
- **`docs/ADR-008`** — GÜNCEL YÖN: FES sicili (kalıcı, iki kaynaklı) ve
  Egzersiz'in altı boyutlu filtresi/bütçesi. `FesScore.swift`,
  `ExerciseFilter.swift`, `ExerciseBudget.swift`, `FesBackfillMigration.swift`'e
  dokunmadan önce oku — özellikle FES'in **neden saklanan, hesaplanan
  olmadığı** (`ExerciseAttempt` 90 günde siliniyor) ve neden
  `ExercisePracticeWeight`'in yerine değil yanına girdiği.
- **`docs/ADR-001`** — Türkçe normalizasyon (İ/ı, NFC, diyakritik katlama);
  `providers/turkish.ts` ↔ `MultipleChoice.comparisonKey` hâlâ buna dayanır.
- **`docs/ADR-002/003/004`** — tarihsel: OCR seçimi, uzlaştırma kapısı,
  annotation-grounding. Kod silindi; yalnız karar arkeolojisi için oku.
- **§0.6** — model adı, eşik, maliyet sınırı asla koda gömülmez; hep merkezi
  config'te (backend `config.ts`).
- **§0.8** — hesaplama ve zamanlama deterministik kodda; LLM yalnız
  görüntü/metin yorumlama ve içerik üretimi için.

## Anti-drift disiplini (bu projede iki kez ısırdı, yapısal önlemli)

Canlı çiftler ve kilitleri:

- **FSRS-6:** Python referansı (`evals/fsrs/`) ↔ Swift portu —
  `evals/shared/fsrs-cases.json` + `test_fsrs_config_sync.py`.
- **Kart tipi enum'u:** şema ↔ TS ↔ Swift — `test_ts_contract_sync.py`,
  `test_swift_contract_sync.py`.
- **Ders/konu şeması:** backend JSON ↔ iOS Resources kopyası —
  `subjectTopics.test.ts`.
- **Şık karşılaştırma anahtarı:** `optionKey` (TS) ↔ `comparisonKey` (Swift) —
  aynı vaka çiftleri iki tarafta test edilir.

Yeni bir "aynı davranış iki yerde" durumu çıkarsa aynı deseni uygula — elle
senkron tutma, üret ve testle kilitle.

## Güvenlik (bağlayıcı)

- API anahtarı **hiçbir zaman** repoda veya iOS uygulamasında olmaz; yalnız
  backend ortam değişkenlerinde (`.env` gitignore'lu / Vercel).
- `DEVICE_TOKEN` yalnız iki yerde: backend ortam değişkeni + telefonun
  Keychain'i. Üçüncü kopya yok.
- `SUPABASE_SERVICE_ROLE_KEY` RLS'i tamamen atlar: yalnız yerel `.env` ve
  Vercel proje ayarları. Repoda, `config.ts`'te ve iOS uygulamasında asla —
  telefon Supabase'i hiç görmez, her şeye backend üzerinden erişir.
- `evals/fixtures/` içine telifli kitap sayfası commit edilmez (gitignore'lu).
- Sunucu loglarında görüntü içeriği, kart metni veya tam sayfa metni saklanmaz.

## Nasıl çalıştırılır

Ayrıntı: `docs/RUNBOOK.md`. Özet:

```bash
python -m pytest evals -q                      # eval + sözleşme testleri
cd ios/CizgiCore && swift test                 # yalnız bir Mac'te / CI
cd backend && npm test                         # vitest
cd backend && npm run typecheck                # tsc --noEmit
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
cd ios && xcodegen generate                    # App'e dosya eklendiyse ŞART
```

## Doküman haritası

Güncel yön: `docs/ARCHITECTURE.md` (akış + bileşenler), `docs/ADR-005/006/007/008`,
`docs/FAZ6-PLAN.md`, `docs/FAZ7-PLAN-coktan-secmeli.md`,
`docs/PLAN-egzersiz-bilgi-haritasi.md`, `docs/PLAN-galeriden-foto.md`,
`docs/PLAN-model-karsilastirma.md` (Sol/Terra/Luna deneyi + kademe
yönlendirmesi tasarımı), `docs/ORNEK-algi-taramasi.md` (Tur A nasıl doldurulur),
`docs/PRIVACY.md`, `docs/RUNBOOK.md`, `docs/MALIYET-OLCUMU.md` (çağrı başına
maliyet defteri, teşhis yordamı, model karşılaştırması), `backend/README.md`,
`ios/README.md`.

Tarihsel (davranış için değil, karar gerekçesi için): `docs/HISTORY.md`
(oturum kayıtları arşivi), `docs/ADR-001..004`, `docs/FAZ0-*` – `FAZ5-*`,
`docs/COKLU-FOTO-TIMEOUT.md`, `docs/MAC-ADIMLARI*.md`, `docs/GOLD-SET-GUIDE.md`,
`docs/GOOGLE-CLOUD-KURULUM.md`, `docs/OPENAI-GEMINI-KURULUM.md`,
`docs/MODEL-CARD.md`.

## Sıradaki iş

**Elle yapılacak somut işler:** FES sicili ve Egzersiz'in altı boyutlu
filtresinin cihaz doğrulaması (ADR-008, aşağıda 1-5) ve A6 (§2 aşağıda).
Cihaz doğrulama listesinin geri kalanı 2026-08-13'te büyük ölçüde kapandı;
kalan iki madde (6-7) haftalara yayılan gerçek-kullanım gözlemi, oturup
yapılacak bir şey değil.

### 1. Cihaz doğrulama listesi

**Bu bölüm kullanıcıya sorulacak soruların listesidir.** Kod ve CI yeşil;
buradaki maddeler yalnız gerçek cihazda görülerek kapanır. Doğrulanan madde
buradan silinip "doğrulananlar"a taşınır.

**✅ Cihazda doğrulanmış (2026-08-08):** alt navigasyon kök ekranlarda doğru;
Bilgi Haritası'nın "Konusuz" kovası dolu; Egzersiz'in "Bitir"i çalışıyor ve
biten koşu "Son Egzersizler"e düşüyor.

**✅ Cihazda doğrulanmış (2026-08-13, `luna@high` canlıyken):** uygulama
açılıyor (SwiftData göç düzeltmesi tuttu, veri kayıpsız); kameradan yakalama;
galeriden seçme; kart üretimi uçtan uca. **Bununla şemanın en büyük riski
kapandı:** OpenAI `anyOf: [enum-string, null]` konu alanını kabul ediyor —
etmeseydi her iş düşerdi, B planına (enum'u şemadan çıkarmak) gerek kalmadı.

**✅ Cihazda doğrulanmış (2026-08-13, ikinci tur):** konu ataması gerçekten
doluyor (kart detayında "Sınıflandırma" makul ders/konu gösteriyor — şemanın
kabul edilmesi bunu garanti etmiyordu, `sanitizeTopics` tanımadığı konuyu
sessizce null'a çevirir ve iş yine biter); Ayarlar → Kullanım "Çağrı dökümü"
gerçek USD ve token kırılımı veriyor; çift sayfa kadraj adımı **hem kamerada
hem galeride** çalışıyor (galerideki bilinen `PhotosPicker` artık riski
gerçekleşmedi — "N sayfa kadraj seçimi bekliyor" kartı çıkmadı, yapısal
düzeltme gerekmiyor); değer tabanlı navigasyon (derin ekranda alt bar
kayboluyor, ev düğmesi köke dönüyor); Egzersiz→FSRS köprüsü (vadesi gelmemiş
kart en fazla yarına çekiliyor); yedek al → geri yükle `softLapseCount` dahil
durumu koruyor (**v5'e kadar** — v6'nın FES alanları aşağıda hâlâ açık);
Bilgi Haritası "Konusuz" satırı, "Hızlı 10"un tekrarında farklı kart, aktif
oturum diyaloğu, erişilebilirlik yazı boyutunda ikon-only alt bar; **"İkinci
görüş iste" (Gemini)** — düğme çalışıyor ve Gemini `responseSchema`'yı kabul
ediyor. Bu düğme aynı zamanda "başka bir model ailesi denemeli miyiz?"
sorusunun ucuz ölçüm aracı: gerçek kullanımda biriken verdiktler, Gemini'nin
OpenAI'nin kaçırdığını sistematik yakalayıp yakalamadığını adaptör yazmadan
gösterir (2026-08-13 tartışması).

**🔲 Henüz doğrulanmamış:**

1. **FES sicili ve geçmiş replay'i (ADR-008, en kritik — uygulama hiç
   açılmama riski).** Uygulamayı aç: `Card`'a eklenen üç alan
   declaration-time default'lu olduğu için açılmalı, ama bu tam olarak bir
   kez yaşanmış bir hata sınıfı (`ModelRun.attempt`, §"Migration sırası"
   kuralının ruhu) — kontrol şart. Birkaç kez yanlış/kararsız işaretlenmiş
   eski bir kart ilk açılışta Bilgilerim → "FES kartlar" bölümünde ve kart
   detayında görünmeli.
2. **Egzersiz kurulum sheet'i.** "Filtrele" ikonuna dokun; ders, konu, kart
   tipi, kart durumu, eklenme tarihi, FES'i tek tek dene — sheet'teki canlı
   "N kart hazır" sayacı her dokunuşta değişmeli. "Uygula"dan sonra ana
   ekrandaki chip'ler tutmalı, her chip'in "x"i yalnız kendi boyutunu
   silmeli. "Sıfırla" hepsini temizlemeli.
3. **Egzersiz bütçesi — Kart / Süre.** "Süre" segmentini seç, bir kademe
   dene; altındaki "≈ N kart" tahmini makul mü (ilk kullanımda 12 sn/kart
   varsayımıyla; birkaç Egzersiz'den sonra ölçülen hızla değişmeli). "Tümü"yü
   Süre sekmesindeyken seç — sekme Kart'a atlamamalı (Codex, PR #41).
4. **"FES kartlar" hızlı başlangıcı.** Birkaç kartı bilerek yanlış/kararsız
   yanıtla → eşiği aşınca Egzersiz'in "FES kartlar" kutucuğunda, Bilgilerim'de
   ve kart detayında görünmeli; ardından birkaç kez doğru yanıtla → listeden
   kendiliğinden çıkmalı. Egzersiz sonuç ekranındaki "N kart FES'e girdi/çıktı"
   satırı doğru mu.
5. **Yedek al → geri yükle (v6):** FES sicili (`fesScore`/`fesNegativeCount`)
   de korunuyor mu — üstteki 2026-08-13 doğrulaması yalnız v5'i (`softLapseCount`)
   kapsıyor, v6'nın FES alanları henüz denenmedi.
6. **Sayfa detayında kart düzenleme.** Kuyruk → bitmiş sayfa → üretilmiş bir
   karta dokun: editör açılmalı. Tipini "Beş şık"a çevir, dört şıkkı doldur,
   kaydet → Tekrar'da kart gerçekten şıklarla soruluyor mu. Sonra tipi düz bir
   tipe geri al: **cevap, işaretlediğin doğru şık olarak kalmalı** (bu tam
   olarak PR #29'da iki kez kırılan yer).
7. **"Kart ekle" — dersli sayfa.** Çekimde ders seçilmiş bir sayfada Kart ekle:
   ders kilitli görünmeli (seçici yok) ve konu listesi **yalnız o dersin**
   konularını göstermeli. Ders seçilmemiş bir sayfada ders seçici çıkmalı.
   Konu seçilmeden "Kaydet" aktifleşmemeli.
8. **Elle beş şıklı kart.** Cevap alanına yazdığın metin doğru şık olmalı;
   boş bırakılan bir yanlış şık ya da cevabı tekrarlayan bir şık Kaydet'i
   kilitlemeli. "Neden yanlış" boş bırakılabilmeli (kart bayraklanmamalı).
   Kaydedilen kart Tekrar'da ve Bilgilerim'de **hemen** görünmeli — görünmüyorsa
   `status` `.draft` kalmıştır.
9. **0 kartlı sayfa.** Model hiç kart üretmemiş (ya da kalıcı hata almış) bir
   sayfada "Bu sayfadan kart üretilmedi." satırı ve Kart ekle görünmeli;
   eklenen kartın "Kaynağı göster"i sayfa fotoğrafını gösterebilmeli.
10. **Yedek al → geri yükle:** elle eklenen kart ders/konu/şıklarıyla
    korunuyor mu (biçim değişmedi, ama elle kart bu yoldan ilk kez geçiyor).
11. **Prompt v2.7 — yıldızlı yer atlanıyor mu (2026-08-15, bildirilen kusur).**
    Yıldız/daire koyduğun bir sayfayı çek: o işaret karta dönüşmeli, ve
    işaretsiz metinden kart **çıkmamalı**. Kontrol yolu: "Kaynağı göster" →
    *Modelin okuduğu* içinde yıldızlı pasaj görünüyor ama kartlarda yoksa kural
    hâlâ bağlamamıştır. Bağlamazsa sıradaki adım prompt değil **şema**: çıktıya
    `marks[]` + kart başına `markIndex` (şema v2.3) — o zaman kartsız kalan
    yıldız sunucuda deterministik olarak görülebilir, ki bugün onu gören
    hiçbir sinyal yok.
12. **Sayfa detayında kaydırarak silme (2026-08-15).** Kuyruk → bitmiş sayfa →
    modelin ürettiği bir kartı sola kaydır → "Sil": kart hem oradan hem
    Bilgilerim'den ve Tekrar'dan düşmeli. Sonra kuyruk listesinde o sayfayı
    silmeye kalk — diyalogdaki kart sayısı bir eksilmiş olmalı.
13. **Prompt v2.6 üretimde.** Deneyde 239 kartta sayfaya atıf yapan soru
    sıfırdı; gerçek kullanımda da tutuyor mu ("sayfada / işaretlenen" diyen
    kart var mı) birkaç hafta içinde bakılmalı. Çok-fikirli kart ise deneyde
    **düzelmedi** — kural 5 yeniden yazılacak.
14. **Zayıf nokta sönümlemesi** — haftalar sürer, bilinçle sona bırakıldı.
15. **Arama (2026-08-15).** Bilgilerim'de bir kelime yaz: üç sayı kutusu ve
    "Gözden geçir" / "FES kartlar" / "En çok unutulanlar" bölümleri artık
    **birlikte** daralmalı — bildirilen kusur tam olarak bunların daralmamasıydı
    (yalnız "Son eklenenler" daralıyordu, o da ekranın altında). Büyük I ile
    yaz ("Inflamasyon"): İ'li kartlar gelmeli. Yalnız açıklamada ya da bir şıkta
    geçen bir terimi ara ("Glomus"): kart çıkmalı. Bulunmayan bir kelimede
    "… için kart yok." satırı görünmeli.
16. **"Gözden geçir"den çıkarma (2026-08-15).** Listedeki bir kartı sağa kaydır
    → "Doğru": kart listeden hemen düşmeli, Egzersiz'in "Gözden geçir" sayacı
    bir azalmalı, ama kart **Tekrar'da kalmalı** (askıya alınmış olmamalı).
    Aynısı kart detayındaki "Kontrol ettim, doğru" düğmesiyle de olmalı. Yedek
    al → geri yükle: temizlenen bayrak geri dönmemeli.
17. **Approval gate göçü (2026-08-15).** İlk açılışta Bilgilerim'in üç sayısı
    birbirini tutmalı: Toplam = Aktif + Askıda. Bugün tutmuyor (631 = 606 + 0
    değil); farkı yaratan, 2026-08-04'ten kalma 25 `needsReview` kart. Göçten
    sonra bunlar Tekrar'a girmeli — vadeleri geçmiş olduğu için **hepsi bir
    anda** gelir, beklenen davranış budur. Açılışta tek seferlik
    (`cizgi.migration.approvalGate.v1`), **ayrıca her geri yüklemede**: yedek
    kartın saklı durumunu aynen getirdiği için, bayrak harcandıktan sonra geri
    yüklenen bir `.needsReview` kart aksi hâlde kalıcı olarak Tekrar'ın dışında
    kalırdı (Codex, PR #44). Ayrı bir madde olarak da denenmeli: **eski bir
    yedeği geri yükle** → geri gelen kartlar Tekrar'a girmeli, Toplam = Aktif +
    Askıda yine tutmalı.

### 2. A6 — beş şıklı kartın gerçek sayfayla denenmesi

Kod bitti, kalite bitmedi — ancak gerçek sayfalarla oturur.

- İlk denemede **Ayarlar → Beş şıklı kart: Hepsi** (`Karışık` bilerek seçici;
  yolu doğrulamak için "Hepsi" net).
- **Makine zaten neyi tutuyor** (bunlara bakmaya gerek yok):
  `sanitizeMultipleChoice`, şık sayısı beş değilse / doğru şık bir taneden az
  ya da fazlaysa / `correctOption` uyuşmuyorsa / iki şık aynı anlama geliyorsa
  (Türkçe normalizasyonlu) / `back` doğru şıkla eşleşmiyorsa kartı **düz karta
  indiriyor**; bir şık diğerini kapsıyorsa ya da "neden yanlış" boşsa
  `lowConfidence` **işaretliyor**. Yani sayılabilir ihlaller kapıda duruyor.
- **Yalnız insanın görebileceği beş soru:** distraktörler gerçekten
  karıştırılabilir mi (yakınlık tıbbi bir yargı — biçimsel olarak kusursuz bir
  şık takımı soruyu bedavaya çevirebilir); şıklar aynı semantik sınıftan mı;
  kurguda **ikinci bir doğru** var mı (kapı yalnız metin kapsamasını görür,
  "klinik olarak da doğru sayılır"ı göremez); "neden yanlış" gerçekten
  öğretiyor mu (kapı boş olmadığına bakar, doğru olduğuna bakamaz); şıklar
  telefonda okunacak kadar kısa mı.
- **İki somut tahmin** (2026-08-13, prompt okunarak): en olası kusur **şık
  uzunluğu** — prompt "kısa olsun" diyor ama ölçüt vermiyor, ve v2.6'nın kural
  5 deneyimi ölçütsüz kuralın bağlamadığını gösterdi. İkincisi: `Karışık`
  modda modelin "bu kart ayırt etme mi?" kararını fazla cömert verip düz
  tanımları da beş şıklı yapması.
- Bulgular prompt'un `multipleChoiceInstruction` bloğuna işlenir — kural 8'de
  işe yarayan biçimle: yanlış örnek + doğru örnek çifti.
- İlk turda ölç: Ayarlar → Kullanım'daki çıktı token artışı (tahmin: kart
  başına +80–150). **Not:** bu tahmin Sol dönemindeydi; `luna@high`'ta çıktı
  $1.20/M olduğu için sayfa başına ~+$0.002 — beş şıklı kart artık bir maliyet
  kararı değil, yalnız kalite kararı.

### 3. Küçük ve gerçek kalanlar

1. **`Models` alan sadeleşmesi + SwiftData göçü** (`sourceQuote`, TextRegion'ın
   OCR-dönemi alanları vb.). Bilerek ertelendi: §10.4 "mevcut kartlar
   korunmalı" — SwiftData şemasına dokunmak ayrı, dikkatli bir iş.
2. **`TopicBackfillMigration` sonlanma koşulu** (PR #36 incelemesinin bulgusu,
   kod `main`'den geliyor): bayrak ancak 203 eşlenmiş kimliğin **hepsi**
   görülünce yazılıyor; v2'den önce silinmiş tek bir kart, migration'ın her
   açılışta tüm desteyi taramasına yol açar. Maliyet bugün küçük (tek fetch)
   ama sınırsız; bir tamamlanma/yaş koşulu eklenmeli.
3. **Kilitli telefon "cihaz anahtarı yok" gibi görünüyor** (2026-08-15, canlı
   olay; sahibin kararıyla şimdilik bırakıldı). Anahtar
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` ile yazılıyor
   (`DeviceTokenStore.swift:72`), ama `read()` her `OSStatus`'u sessizce `nil`'e
   çeviriyor (`:53`) — `errSecInteractionNotAllowed` (-25308, telefon kilitli)
   ile `errSecItemNotFound` (-25300, anahtar hiç yok) ayırt edilemiyor.
   `AppEnvironment.swift:106` her istekte taze okuduğundan, kuyruk arka planda
   ilerlerken ekran kilitlenirse `BackendCardProvider.swift:54` "Cihaz anahtarı
   ayarlanmamış." diyor ve sahibi hatalı biçimde Ayarlar'a yönlendiriyor; kilit
   açılıp "Tekrar dene" denince aynı iş sorunsuz üretiyor. Düzeltme: `read()`
   `OSStatus`'u korusun, kilit hâli kendi mesajını taşısın.
4. **Anahtarın erişilebilirlik sınıfı arka plan işine uymuyor** (3'ün kökü,
   **sahibin kararı bekliyor** — bu yüzden koda dokunulmadı). Yerindeki yorum
   iki ayrı korumayı birbirine karıştırıyor: yedekten çıkarılmayı engelleyen
   `ThisDeviceOnly`, kilitliyken okunmayı engelleyen ise `WhenUnlocked`. Kuyruk
   arka planda çalıştığı için olağan seçim
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` olurdu: yedek koruması
   aynen kalır, kilitliyken üretim sürer. Güvenlik farkı küçük ama sıfır değil.
5. **Backend 401'i kalıcı sayıyor.** `supabaseJobs.ts:251` `isTransientStatus`
   yalnız ≥500, 408 ve 429'u geçici kabul ediyor. 2026-08-15'te tek seferlik bir
   `PGRST303 "JWT issued at future"` sahibe hata olarak göründü ve elle tekrar
   denemede kendiliğinden düzeldi — servis anahtarı statik bir JWT olduğundan
   `iat` kayamaz, dolayısıyla oynayan taraf Supabase'in saati (doğrulanamadı;
   Supabase kayıtlarına bu oturumdan erişilemedi). Tek otomatik yeniden deneme
   bunu tamamen görünmez kılardı. Asimetri yalnız backend'de: iOS zaten geçici
   sayıyor (`StateMachine.swift:126`).

6. **`try? context.save()` hatayı yutuyor — 24 çağrı, tek karar gerekiyor.**
   Codex bulgusu (P2, PR #44 üçüncü tur). Depo geçici olarak yazılamazsa
   kaydetme hatası düşüyor, ama bellekteki değişiklik duruyor: ekran işlemi
   başarılı göstermiş oluyor ve uygulama sonraki otomatik kaydetmeden önce
   sonlanırsa işlem kayboluyor. Bulgu "Gözden geçir"deki "Doğru" için
   yazıldı ama orada özel bir şey yok — aynı desen "Askıya al", "Sil",
   "Etkinleştir", `deleteCards` ve diğerlerinde, uygulama genelinde **24
   yerde** var. Bu yüzden PR #44'te bilerek düzeltilmedi: yalnız iki çağrıyı
   hata gösterir yapmak, yan yana duran düğmelerin biri hata verip diğeri
   yutan tutarsız bir ekran bırakırdı. Sonuç veri kaybı değil — en kötü
   hâlde işlem geri alınır ve kullanıcı tekrarlar — ama doğru düzeltme
   hepsi için ortak bir hata yüzeyi kurmak, tek tek yamamak değil.

### Aday sonraki özellikler

Öneri, taahhüt değil; sırayı kullanıcı seçer.

- **Tekrar (FSRS) oturumuna ders/konu filtresi** ("bugün yalnız Farmakoloji").
- **Kart kalitesi geri bildirimi:** tekrar sırasında "bu kart kötü" işareti →
  prompt iterasyonuna girdi.
- **Sayfayı yeniden üret — artık model kademesiyle birlikte** (Tur A bunu öne
  aldı): aynı fotoğraftan ikinci takım, ama asıl değeri "bu sayfayı Sol'la
  yeniden üret" düğmesi olmasında. Ucuz kademenin tehlikeli başarısızlığı
  sessiz kapsama boşluğu ve onu hiçbir otomatik sinyal göremiyor; elle tetik
  yanlış-pozitifsizdir, kullanılmadığında bedavadır ve otomatik tetiğin ne
  sıklıkta haklı çıkacağını ölçmenin en ucuz yoludur
  (`docs/PLAN-model-karsilastirma.md` → Kademeli akış).
- **FSRS ağırlık optimizasyonu:** yedeğe giren `ReviewLog` geçmişinden
  kullanıcıya özel ağırlıklar (`evals/fsrs/` referansı hazır).
- **PDF / Dosyalar'dan içe aktarma ve Share Sheet** (ANA-PLAN §4.3).
- **Tusoskop'tan analitik katman:** güven-küçültmeli konu ustalığı + bileşik
  zayıflık skoru (Bilgi Haritası'na "% biliyorum"), günlük istatistik kaydı
  (ısı haritası/seri), "bugün ne çalışayım" planlayıcısı (LLM + deterministik
  ikiz deseni). 2026-08-09 inceleme raporunda ayrıntılı.
