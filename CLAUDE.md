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
6b. **Kartlaşmamış işaretler görünür oldu (kapsama sözleşmesi, 2026-08-19 —
   `docs/PLAN-kapsama-sozlesmesi.md`).** Sistemin göremediği tek kayıp,
   işaretlenip hiç kartlaşmayan içerikti: üretilmemiş kartın `lowConfidence`'ı
   olmaz. İki katman:
   **(A)** Şema v2.3 — model kendi işaret defterini yazıyor (`marks[]`:
   `id`/`kind`/`quote`) ve her kart hangi işaretten doğduğunu söylüyor
   (`markId`). Sunucu farkı deterministik çıkarıyor
   (`providers/coverage.ts`): *kartsız işaret* ve *işaretsiz kart* (= prompt
   kural 1'in ihlali). Ek çağrı yok, `jobs` sütunu yok.
   **(B)** `/api/coverage` — dördüncü kapı, **Gemini**: aynı sayfayı bağımsız
   okuyup "bu işaret kartlaşmış mı?" diyor. A'nın **yapısal olarak**
   göremediği sınıfı yakalar: modelin *hiç görmediği* işaret (kendi defterine
   yazmadığı şey). Elle tetikli ("Kapsama denetle"), maliyeti `ModelRun`
   (`purpose: "coverage_audit"`) ile deftere giriyor.
   Telefonda: sayfa detayında **"Kartlaşmamış işaretler"** bölümü; satıra
   dokunmak `ManualCardSheet`'i işaretin metniyle açıyor, sola kaydırmak
   **"Yoksay"** diyor. Yoksayma kimliği işaretin *metninden* türetiliyor
   (`PageMark.id`), çünkü modelin `m1` etiketi yalnız o yanıt içinde tekil —
   yeniden üretimde başka bir pasajı gösterir ve yoksayma yanlış işareti
   gizlerdi. **Sessizlik temiz kâğıt değildir:** v2.3 öncesi bir sayfa
   "kapsama defteri olmadan üretilmiş" der, "her şey kapsandı" demez.
   Prompt v2.8 kural 13'ün anti-teşvik cümlesi bilinçli: kartsız işaret
   *kusur değil, kullanıcının görmesi gereken bilgi* — yoksa modelin temiz
   görünmek için az işaret yazması işine gelirdi.
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

### Kavram destesi kaldırıldı (2026-09-14)

2026-09-09'da eklenen ikinci deste (dışarıda hazırlanmış JSON kavram paketi,
3.017 kart) sahibinin kararıyla **tamamen** kaldırıldı: "deneme amaçlıydı,
sevmedim; yalnız Çekimlerim kalacak". ADR-010 tarihsel. Geri dönüş = kaldırma
commit'inin revert'i (`git log`'da "Kavram destesini tamamen kaldır").

- **Silinenler:** `CardScope`, `CardScopePicker` (Tekrar/Egzersiz/Bilgilerim
  tepesindeki anahtar), `ConceptPackImporter` + içe aktarma ekranı,
  `ConceptRelease` + "Kuyruk" bölümü, `CardCollection` enum'u,
  **`Card.collectionRaw` sütunu**, **`CardStatus.queued`**, deste başına günlük
  yeni kart sicili (tek sicile döndü, anahtar `cizgi.newCardLedger.v1`
  korundu), `evals/tests/test_card_scope_sites.py`.
- **Cihazdaki veri — `ConceptDeckRemovalMigration`** (tek seferlik,
  `cizgi.migration.conceptDeckRemoval.v1`, göç zincirinin **en başında**):
  kavram unit'lerini, kartlarını, `ReviewLog`'larını **ve** o kartlardan
  yapılmış Egzersiz koşularını/denemelerini siler. Sonuncusu bilinçli:
  `ExerciseAttempt` kartla ilişki değil düz `cardId` taşır, cascade onu
  götürmez — simülatörde 16 yetim deneme kalacaktı.
- **Tanıma etiketle, sütunla değil.** Aynı açılışta `collectionRaw` şemadan
  düştüğü için göç onu okuyamaz; importer'ın her unit'e yazdığı
  `"kavram-paketi"` etiketi tek iz. `ConceptDeckLegacy` (CizgiCore) bu yüzden
  kaldırmadan **sağ çıkan tek kavram izi** — "hiçbir şey bırakma" ile bilinçli
  gerilim, eski veriyi temizleyebilmek için gerekli. Yalnız `queued`'a bakan
  bir göç **hiçbir** kartı bulamazdı: simülatördeki 3.017 kart kuyruk
  özelliğinden önce aktarıldığı için `active`'ti.
- **Şema kanıtı:** sütun düşürme bu projede ilk kezdi. Eski şemalı gerçek depo
  (3.021 kart, 834 unit, 12 log, 7 koşu/19 deneme) üzerine yeni build silmeden
  kuruldu → uygulama açıldı, `ZCOLLECTIONRAW` yok, 4 kart / 3 unit / 3 log /
  2 koşu / 3 deneme, yetim log ve deneme sıfır, ikinci açılışta sayılar aynı.
- **Yedek v8:** `collection` alanı yok. v7 dosyası hatasız okunur;
  `BackupRestorer.plan` kavram kayıtlarını (etiket **veya** `queued`) atlar ve
  sayar, geri yükleme mesajı "N kavram kartı atlandı (bu deste kaldırıldı)"
  der. Eski depodan üretilmiş gerçek bir v7 yedeğiyle arayüzden denendi.

### Tasarım dili — "Kemik & Oxblood" (2026-09-10)

Görsel dilin tek kaynağı `ios/App/Theme/CizgiTheme.swift`. Claude Design'da
hazırlanan tasarım dili buraya birebir uygulandı; **akış, metin, FSRS, kuyruk,
ADR kararları ve `CizgiCore` değişmedi** — değişen yalnız değer katmanı ve
bileşen anatomisi.

Önceki "warm study" (kehribar vurgu / lacivert mürekkep / sıcak kâğıt) gitti.
Yerine:

- **Vurgu sabit bir marka rengi değil, bir konum.** `Cizgi.accent` artık
  `static let` değil hesaplanan bir değer: o an çalışılan **dersin** rengi.
  Kaynağı `CizgiAccentSource` seçer — `subject` (öntanımlı) · `timeOfDay` ·
  `pinned`; Ayarlar → **Görünüm**'den değişir. Ders yoksa saat karar verir
  (06–12 tuğla · 12–18 oxblood · 18–23 erik · 23–06 lacivert).
- **Ders yayı:** on bir ders tek bir renk yayında — aynı açıklık ve
  doygunlukta, yalnız ton açısı kayar. Bağımsız marka renkleri değil, aynı
  ölçeğin komşu durakları.
- **Nötrler:** kemik kâğıt / lacivert gece. **Gölge kalktı, yerine 1px
  hairline.** Köşe yarıçapı bir kademe sıkıldı (baloncuk değil, ciltli kitap).
- **Serif (`Cizgi.serif`) tam üç yerde:** kart sorusu, boş durum başlığı,
  büyük sayı. Başka hiçbir yerde serif yok.
- **Yeni bileşenler:** `NumeralActionRow` (büyük serif sayı + ad; eski
  `FeatureActionCard`'ın yerine), `CardTypeMark` (SF Symbol rozet yerine
  sorunun *biçimini* çizen `Canvas` işareti), `CizgiRule` (soru/cevap
  baklava kesmesi), `CizgiSectionMark` (§, açıklama paragrafının başında),
  `DogEar` (kıvrık köşe — yalnız `lowConfidence` kartta), `SubjectChip`,
  `SubjectDistributionBar` (Bilgilerim'in tepesinde ders dağılımı).
  `HighlighterStrip` kaldırıldı (zaten kullanılmıyordu).
- `Cizgi.highlighter` artık `LinearGradient` değil `Color` — adı, çağrı
  yerleri değişmesin diye korundu.

**Tasarımdan bilinçli üç sapma** (üçü de "sessizce yanlış" olmasın diye):

1. **Yay dokuz durakla geldi, şema on bir ders taşıyor.** Eksik iki ders
   (`Küçük Stajlar`, `Kadın Hastalıkları ve Doğum`) renksiz kalsaydı vurguları
   saate düşer ve `SubjectDistributionBar` o kartları şeritten sessizce
   atardı — kartlar geçerli, ekran sağlıklı, anlattığı deste yanlış. Yay iki
   durak **uzatıldı**: mevcut dokuz renk aynen duruyor, yeni ikisi en geniş
   iki ton boşluğunun ortasına komşularının açıklık/doygunluk ortalamasıyla
   kondu. Ayrıca `cerrahi`'nin görünen adı kanonik **"Genel Cerrahi"**ye
   çekildi — "Cerrahi" `matching()` ile hiçbir zaman eşleşmiyordu.
   Kilit: **`evals/tests/test_subject_arc_sync.py`**.
2. **Tepkisellik `.id()` ile değil yayıncıyla.** UYGULAMA.md kökü
   `.id(Cizgi.accentSubject)` ile yeniden kimliklemeyi öneriyordu; o, alt
   ağacın bütün `@State`'ini sıfırlar — Egzersiz'in yarım kalan oturumu dahil.
   Yerine `CizgiAppearance` (tek `ObservableObject`): `RootView` ve
   `SettingsView` onu gözler, gövde yeniden değerlendirilir, `Cizgi.accent`
   taze okunur, kimlik değişmediği için hiçbir `@State` kaybolmaz.
3. **Serif geri düşüşü gerçekten serif.** `Font.custom` bulunamayan bir aile
   için sistem **sans**'ına düşer, serife değil — tasarımın serif sesi hiç
   duyulmadan kaybolurdu. `Cizgi.isSerifBundled` bir kez bakar ve yoksa
   **Georgia**'ya düşer (iOS'ta hep var, `relativeTo:` korunduğu için Dynamic
   Type de yerinde).

**Font durumu:** `LibreCaslonText-Regular.ttf` pakette (`ios/Resources/`,
OFL lisansıyla, `UIAppFonts` `project.yml`'de). Georgia geri düşüşü yalnız
dosya bir gün eksik kalırsa devreye girer.

**Yan düzeltmeler** (tasarımı uygularken görünür hâle gelen gerçek kusurlar):
Ayarlar / Egzersiz kurulumu / Kullanım dökümü ekranları iOS'un soğuk gri grup
zeminini kullanıyordu — üçü de artık `Cizgi.paper`'a bağlı (diğer kök ekranlar
zaten öyleydi). `TagChip` uzun konu adında ("Kemoterapötikler ve
İmmünomodülatörler") üç satıra şişip kartın başlık satırını dağıtıyordu; artık
tek satır + kırpma, tam ad VoiceOver'da.

#### Tekrar ekranı düzeni (2026-09-12)

Sahibin bildirimi ("font kötü, renkler kötü") simülatörde açık ve karanlık modda
gezilerek somutlaştırıldı; çıkanların bir kısmı zevk değil **kusurdu**. Kart
karakteri (kutu mu, sayfa mı, fiş mi) bilerek **sonraki tura bırakıldı** —
bu tur yalnız düzen, kontrast ve eksik bilgi.

- **Karanlık modda "Kolay" okunmuyordu.** Not düğmelerinin metni `.white`
  sabitti, dördüncü derecenin zemini `Cizgi.ink`'ti ve ink karanlıkta neredeyse
  beyaz. Çözüm dolgulu düğmeyi bırakıp **konturlu** `CizgiChoiceButton`'a
  geçmek: metin her zaman kendi tint'inde, zemin her zaman `surface`, ikisi de
  moda göre dönüyor — böyle bir çift bir daha kurulamaz. Egzersiz'in üç sonucu
  da aynı bileşeni kullanıyor (zaten aynı görünüyorlardı; iki kopya ayrışırdı).
- **FSRS aralıkları artık düğmenin altında** ("Zor · 8 gün"). Scheduler zaten
  hesaplıyordu ve `schedule` saf, yani kart başına dört aritmetik geçiş —
  yazma yok, ağ yok. **"Unuttum" istisnası:** kart hâlâ kuyruğa geri dönecekse
  (`ReviewSession.wouldRequeueOnAgain`) etiket `oturumda` diyor. Scheduler'ın
  tarihi karta yazılıyor ama gerçekte olan şey kartın bu oturumda geri
  gelmesi; oraya gün sayısı basmak iki dakika sonra yalanlanan bir söz olurdu.
  Biçimlendirme `ReviewIntervalLabel` (CizgiCore, testli) — sınırları olan
  aritmetik `Text` içinde `%.0f` ile durmamalı.
- **Oturumda büyük başlık ve alt sekme çubuğu gizli**, "Bitir" tek çıkış
  (Egzersiz'in deseni, `AppNavigator.isTabBarHidden` kuralı). Egzersiz'den
  farkı: **onay diyaloğu yok** — her not verildiği anda karta ve `ReviewLog`'a
  yazılıyor, kapatılacak yarım kayıt yok (Egzersiz'in diyaloğu `finishedAt`'i
  boş `ExerciseRun` yüzünden var).
- **Kart dikeyde ortalanıyor** (`minHeight: geo.size.height`). Önce üste
  yapışıktı ve alt yarı boştu: cevapla not düğmesi telefonun iki ucundaydı.
  Uzun cevap eskisi gibi kayıyor.
- **Tipografi 26 serif / 17 sans / 15 muted.** Önceki 24/20 çifti neredeyse
  aynı ağırlıktaydı, yani soruyla cevabı tipografi değil yalnız araya giren
  kesme çizgisi ayırıyordu.
- **Erişilebilirlik boyutlarında not satırı 2×2'ye kırılıyor.** Dört sütun
  ~86pt bırakıyor ve AX5'te her etiket kırpılıyordu ("Unut…" / "oturu…");
  okunamayan bir not düğmesi, aralığı olmayandan kötüdür.
- **Yan düzeltmeler:** başlangıç ekranındaki büyük sayı artık serif (temanın
  kendi kuralıydı, `.system(.rounded)` tasarım dilinden önce kalmıştı); süre
  tahmini dakikada takılmıyordu — 3.017 kartlık kavram destesi "≈ 603 dk"
  diyordu, artık `ReviewIntervalLabel.sessionEstimate` ile "≈ 10 sa".

Egzersiz'in üç sonuç düğmesi AX boyutlarında hâlâ kırpılıyor (bu turdan önce de
öyleydi); aynı 2×2 çözümü oraya da uygulanabilir.

#### Kart karakteri: kutu değil sayfa (2026-09-12, ikinci tur)

`ReviewCardFace` — Tekrar ve Egzersiz'in **ortak** kart yüzü.

- **Kutu kalktı.** Kart bir `CardSurface`'ti: `surface` dolgulu yuvarlak
  dikdörtgen, hairline kenar, tepede 3px ders şeridi, `paper` üstünde yüzen.
  İki sorun: `surface` zeminden %5 farklı olduğu için kutu zaten *görünmüyordu*
  — kenarlık, yarıçap ve şerit gözün seçemediği bir şeyi çizmeye harcanıyordu;
  ve bir kutu bir *yerde* durmak zorunda, kısa kart onu boş ekranın ortasında
  bırakıyordu. Artık sayfanın kendisi kart: geriye solda **dersin rengini
  taşıyan dikey bir çizgi** (ciltli kitabın kenar rubrikası — okunan şeyin
  yanında durur, tepesini kapatmaz) ve kâğıt üstünde mürekkep kaldı.
- **Neden ortak:** iki ekranda neredeyse birebir iki kopya vardı ve **zaten
  ayrışmışlardı** — konu çipi yalnız Egzersiz'de, FES işareti yalnız
  Egzersiz'de, soru puntosu iki yerde iki türlü (24 ve 26). Gerçekten farklı
  olan iki şey iki slot: `options` (her ekran kendi seçim durumunu tutuyor) ve
  `footer` (kaynak açıcısı, her ekranın kendi image store'u).
- **Üst satır:** ders · konu, harf aralıklı ve `faint`. Kartın **tipi** orada
  yazmıyor — `CardTypeMark` onun biçimini çiziyor, o işaret bunun için var.
  Ders de konu da yoksa tip adı yazıya düşüyor (satır hiç boş kalmıyor).
- **Dikeyde üste yaslandı** (birinci turdaki ortalama geri alındı). Ortalama
  yüzen bir kutu için doğruydu, sayfa için yanlış: cevap açılınca soru yukarı
  kayıyordu, yani okunan satır her kartta gözün altından kaçıyordu.
- **Türkçe büyük harf hatası** (bu turda görüldü): `"Endokrin".uppercased()`
  → "ENDOKRIN". `TurkishText.uppercased` (CizgiCore, testli) eklendi ve
  `ScreenHero`'nun aynı satırı da ona çevrildi — bugünkü eyebrow metinlerinde
  dotted i yok, yani orada görünür bir şey düzelmedi, 'i' içeren bir eyebrow
  yazıldığı gün sessizce bozulması engellendi. docs/ADR-001.
- **`DogEar` artık kullanılmıyor** (katlandığı kutuyla birlikte gitti).
  Silinmedi — "Gözden geçir" çipi hem ikon hem kelime taşıdığı için anlam
  zaten renge dayanmıyordu, ama kıvrık köşe başka bir yerde (Bilgilerim'in
  şüpheli kart listesi) işe yarayabilir. Kullanılmayacaksa silinmeli.

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
- **Yedek biçimi v9 (2026-09-14, docs/ADR-011):** dosya isteğe bağlı
  `pages[]` (JPEG base64 + `captureDate`/`subject`/`readText`/`pageLabel`) ve
  kartta `pageId` taşıyabilir; geri yükleme fotoğraflı kart için üretimin
  zincirini kurar (`CapturedPage(.ready) → tam sayfa .manual TextRegion →
  KnowledgeUnit → Card`), yani "Kaynağı göster" dışarıda (Claude'un sayfa
  fotoğrafını okuyarak) üretilmiş kartta da fotoğrafı gösterir. Karar
  `BackupRestorer.plan`'da (saf, testli: hangi sayfa kurulur, hangi kart hangi
  sayfaya bağlanır), yazma `BackupPageInstaller`'da (CizgiCore, bellek-içi
  SwiftData ile testli). **Sayfa kartı izler:** yalnız eklenecek bir kartın
  işaret ettiği ve cihazda olmayan sayfa kurulur — ikinci yükleme hiçbir şey
  eklemez, yetim sayfa kalmaz. Kopuk `pageId` ya da çözülemeyen/kesik/JPEG
  olmayan görüntü (`JPEGIntegrity`: bölüm yapısı `FF D9`'a kadar yürünür +
  ImageIO JPEG olarak okur — yalnız başlangıç işareti kesik veriyi geçiriyordu,
  Codex PR #50) yalnız o kartın **fotoğrafını** götürür ve özette sayılır. Sayfa
  `.ready` doğar — `ProcessingQueue.shouldProcess` onu hiç seçmez, yani
  `/api/jobs`'a gitmez. Başarısız `save()`'den sonra yazılan JPEG'ler silinir.
  **Okuma/çözme/plan/görüntü yazma ana aktörün dışında** (`plan(fileAt:)` +
  `writeImages`; ana aktörde yalnız `install` + kartlar + `save`), dosya belleğe
  eşlenir ve **256 MB sınırı** var (`BackupRestorer.maxFileBytes`; aşan dosyaya
  "böl" mesajı) — Codex PR #50.
  **"Yedeği hazırla" hâlâ görüntüsüz** (`pages`/`pageId` anahtarı hiç
  yazılmaz) — v9 şimdilik yalnız içe aktarmada. Şema değişmedi, göç yok.
- **Yedek biçimi v8:** v7'nin `collection` alanı kavram destesiyle birlikte
  kalktı. v7 dosyası hatasız okunur; içindeki kavram kayıtları etiketle
  tanınır, atlanır ve geri yükleme mesajında sayılır.
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

| Kapsama sözleşmesi — Katman A (şema v2.3) + Katman B (`/api/coverage`, Gemini) (2026-08-19) | 🟡 PR #47 (beş Codex turu: iki P1 + yedi P2 kapatıldı, biri gerekçeyle reddedildi); tasarım ve gerekçe `docs/PLAN-kapsama-sozlesmesi.md`. Backend 351 test + `tsc`, evals 509 test yeşil. Swift tarafı **indirilen araç zinciriyle dilim paketinde gerçekten koşturuldu** (76 test: `CoverageTests`, `CoverageAuditProviderTests`, `BackendCardProviderTests`, `PipelineTests`) — doğrulanmayan tek şey SwiftUI görünümleri ve SwiftData modeli; onlar için `swift test` + `xcodegen generate` bir Mac'te/CI'da koşmalı. **Açmadan önce:** `GEMINI_USD_PER_MILLION_*` Vercel'e girilmeli (bugün 0; defter Gemini'yi bedava sayıyor). Cihaz doğrulaması aşağıdaki listenin 18-22. maddeleri |
| Sayfa detayında kart ekleme + düzenleme (2026-08-15) | ✅ `main`'de (PR #43, squash `721ed19`). Kuyruktan açılan sayfa ekranı (`PageDetailView`) salt-okunur olmaktan çıktı: karta dokunmak ortak `CardEditorView`'ı açıyor, her pasajın altında **"Kart ekle"** var (`ManualCardSheet`). Gerekçe: modelin tehlikeli hatası yanlış kart değil **eksik** kart, ve üretilmemiş kart `lowConfidence` taşımadığı için onu hiçbir otomatik sinyal görmüyor — tek çare sayfaya bakarken elle eklemek. Ortak editör **kart tipi seçici** kazandı (Bilgilerim/Tekrar/Egzersiz de). Codex'in iki P2'si kapatıldı: elle kartın unit'i boş `canonicalClaim` taşıyor (yukarıdaki 4. madde) ve bu belge de o sözleşmeyi yazıyor. Yerel `swift test` (391), simülatör derlemesi, backend ve evals yeşil. **Cihaz doğrulaması açık:** aşağıdaki listenin 6-10. maddeleri |
| Deste denetimi: kopya kartların askıya alınması (2026-08-18) | ✅ `main`'de (PR #46, squash `deef8dc`) ve **cihazda doğrulandı** (2026-08-18): ilk açılışta askıdaki kart sayısı 11 → **128**, tam beklendiği gibi. Sahibinin 2026-08-18 yedeği (1007 kart) baştan sona okundu: 996 aktif kartın **117'si** (%12) birebir/yakın kopya (74) ya da tutulan başka bir kartın cevabında tamamen kapsanan (43) — ana kaynak aynı sayfanın birden çok kez çekilmesi; en yoğun konu Solunum (142 kartın 49'u). Küme küme gerekçeli rapor + UUID listesi sahibinde (sohbette dosya olarak). Uygulama: `DuplicateSuspendMigration` — kimlik listesi gömülü, tek seferlik, **siler değil askıya alır** (`ReviewLog`/FES korunur, "Askıdan çıkar" ile tek tek geri alınır), yalnız `.active` karta dokunur. Bilinçli olarak `TopicBackfillMigration`'ın seen-set deseni DEĞİL (o desenin sonsuz-tarama açığı "Küçük ve gerçek kalanlar" 2'de kayıtlı): bayrak ilk başarılı kayıtta yazılır; temiz kurulum + sonradan restore boşluğu ise `ApprovalGateMigration`'la aynı biçimde kapalı — `SettingsView.restore`, idempotent `suspend(in:)` adımını restore'un kendi context'inde yeniden koşar (Codex, PR #46 P2). Denetimin yan ürünleri: içeriği şüpheli 3 kart (anjiyomiyolipom-ağrı, miksoma-McCune-Albright, HER2→"Luminal B" — `lowConfidence` olmadıkları için İkinci Görüş düğmesi çıkmaz, elle bakılmalı) ve metni düzeltilmeli ~25 kart (v2.6 öncesi "Pasaja göre…" kalıntıları) rapora yazıldı, koda dahil değil. Kalan mini kontrol (kritik değil, fırsat olunca): bir kartta "Askıdan çıkar" deneyip kartın aktif **kaldığını** görmek — bayrak yazıldığı için migration bir daha dokunmamalı |


| Kavram destesi (ADR-010) | ⛔️ **Kaldırıldı** (2026-09-14). Kod, şema sütunu, `queued` durumu ve cihazdaki veri gitti; eski şemalı depo ve gerçek v7 yedeğiyle simülatörde kanıtlandı. Ayrıntı: yukarıdaki "Kavram destesi kaldırıldı" bölümü. **Gerçek cihazda kalan:** doğrulama listesinin 23-24. maddeleri |
| Tasarım dili "Kemik & Oxblood" uygulandı (Claude Design → `CizgiTheme.swift`) | ✅ Yerelde tamam ve **simülatörde uçtan uca görüldü** (2026-09-10): açık/karanlık mod, Egzersiz başlangıcı, Tekrar kartı, Bilgilerim ders şeridi, Ayarlar → Görünüm. `xcodegen` + simülatör derlemesi hata/uyarısız; evals 517, `swift test` 483, backend 360 yeşil. Ayrıntı ve üç bilinçli sapma: yukarıdaki "Tasarım dili" bölümü. **Gerçek cihaz doğrulaması açık:** aşağıdaki listenin 25-28. maddeleri |
| Yedek biçimi v9 — geri yüklemede sayfa fotoğrafı (ADR-011) | ✅ `main`'de (PR #50, squash; 2026-09-14). Dört Codex turu: iki P2 düzeltildi (kesik JPEG'in fotoğraf sayılması → `JPEGIntegrity`; büyük yedeğin ana iş parçacığında açılması → ayrık görev + 256 MB sınırı), iki P2 gerekçeyle bırakıldı (ADR-011 "Bilinçli ayrıntılar"). `swift test`, `xcodegen` + simülatör derlemesi uyarısız. **Simülatörde uçtan uca görüldü:** görevdeki örnek v9 dosyası ("1 kart, 1 sayfa fotoğrafıyla geri yüklendi"), görünür fotoğraflı ikinci dosya (2 bağlı kart + 1 kopuk `pageId` → "3 kart, 1 sayfa fotoğrafıyla geri yüklendi. 1 kartın sayfa fotoğrafı bulunamadı."), kart detayında fotoğraf + tam ekran zoom, Kuyruk'ta "Hazır" sayfa ve sayfa detayında kartlar; aynı dosyanın ikinci yüklemesi "hepsi zaten burada" dedi ve depo sayıları + görüntü dizini değişmedi; kuyruk ekranı açıldıktan sonra sayfalar `ready`, `ModelRun` sıfır. **Gerçek cihazda kalan:** doğrulama listesinin 41. maddesi |
| Karanlık Harita kaldırıldı (ADR-009 geri alındı) | ✅ `main`'de (2026-09-09, `f50a936`). Arka uç ve arayüzden tamamen silindi (31 dosya, −5.640 satır): `/api/dark-map`, `DarkMapConfig` + `DARK_MAP_*`, `CallPurpose`'un `dark_map` değeri, `DarkMapView`/`DarkMapCoverage`/`DarkMapProvider` ve Bilgi Haritası'ndaki giriş kartı. Kardeşi olan **kapsama sözleşmesi (#47) duruyor** — o *tek sayfada* işaret↔kart ölçer. Geri dönüş = `f50a936`'nın revert'i; gerekçe `docs/ADR-009`'da tarihsel olarak duruyor. Canlıda `DARK_MAP_*` hiç girilmemişti, temizlenecek değişken yok; dağıtımdan sonra `/api/dark-map` 404 döner |

**Dal durumu (2026-09-14):** "Sadeleştirme ve Bilgilerim" turu
(`sadelestirme-ve-bilgilerim`: kavram destesinin kaldırılması, Egzersiz'de
askıya alma, kaynak fotoğrafı zoom, günlük bildirim, Bilgilerim + istatistik,
arka plan gravürleri — altı commit) `main`'e fast-forward merge edildi, çalışma
dalı silindi. Yedek v9 işi (ADR-011) `yedek-v9-sayfa` dalında yapılıp PR #50
ile `main`'e squash merge edildi, dal silindi; `main` `origin/main` ile aynı.
Yeni iş `main`'in ucundan yeni bir dalla başlar.

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

**Bu ortamın kalıcı sınırı:** Linux'ta `CizgiCore` **bütün olarak** derlenmiyor
(CoreGraphics, SwiftData); SwiftUI dosyaları ve App hedefi yalnız
`swiftc -parse` ile denetlenebiliyor — bu sözdizimi kontrolüdür, tip hatası
yakalamaz. App hedefi ve tam paket için tek gerçek kapı CI'daki macOS işi ya da
bir Mac derlemesi.

**Ama sınır sanıldığından dar (2026-08-19'da ölçüldü).** İndirilen bir Swift
araç zinciriyle (`swift-6.0.3-RELEASE-ubuntu24.04`, ~450 MB) **dilim paketi**
kurulup gerçek `swift test` koşturulabiliyor: CizgiCore'un Foundation-only
dosyalarını `/tmp` altında bir SwiftPM paketine kopyala, CoreGraphics/SwiftData
gerektiren birkaç dosyayı dışarıda bırak (`Models.swift`, `UploadImage.swift`,
`ImageStore.swift`, `PixelBuffer/PerceptualHash`, `Bundle.module` okuyan
`FSRSWeights`/`SubjectTopicSchema`), `URLSession` kullanan dosyaların başına
`#if canImport(FoundationNetworking) import FoundationNetworking #endif` ekle
ve eksik tipler için küçük shim yaz (`PreparedUpload`/`UploadImageEncoder`).
Kapsama sözleşmesi işinde bu yolla **76 test** gerçekten koşturuldu
(`CoverageTests`, `CoverageAuditProviderTests`, `BackendCardProviderTests`,
`PipelineTests`, `MultipleChoiceTests`…) — yani sağlayıcı/kuyruk/model mantığı
Mac beklemeden **tip düzeyinde** doğrulanabiliyor. Doğrulanamayan tek şey
SwiftUI görünümleri ve SwiftData modelleri.

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
- **`docs/ADR-011`** — GÜNCEL YÖN: yedek biçimi v9, geri yüklemede sayfa
  fotoğrafı. `BackupExporter.swift`/`BackupPageInstaller.swift`/
  `SettingsView.restore`'a dokunmadan önce oku — özellikle sayfanın neden
  kartı izlediği ve dışa aktarmanın neden hâlâ görüntüsüz olduğu.
- **`docs/ADR-010`** — tarihsel: kavram destesi (2026-09-14'te kaldırıldı).
  Kalan tek iz `ConceptDeckLegacy`; ona dokunmadan önce ADR'nin kaldırma notunu
  oku.
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
- **İşaret kademesi (şema v2.3):** şema `marks.items.kind` ↔ `MARK_KINDS` (TS)
  ↔ `MarkKind` (Swift) — `test_ts_contract_sync.py` + `test_swift_contract_sync.py`.
  Burada **sıra da sözleşmedir**: prompt kural 3'ün öncelik merdiveni (el yazısı
  → sembol → altı çizili → fosforlu) hem sunucunun hem telefonun sıralamasını
  belirler, testler sırayı da kilitler.

- **Ders renk yayı (tasarım dili):** `CizgiSubject` ↔
  `backend/schemas/subject_topics.json` — `evals/tests/test_subject_arc_sync.py`.
  Yayda karşılığı olmayan bir ders **hata vermez**: vurgusu saate düşer ve
  dağılım şeridinden kaybolur. Test dört şeyi tutar: her kanonik dersin bir
  durağı var, yayda şemada olmayan ad yok, iki ders aynı rengi paylaşmıyor,
  iki `switch`'in sırası aynı (o sıra ekrandaki sıradır).

- **Tekrar ↔ Egzersiz'in kart yüzü (2026-09-12):** artık tek bir
  `ReviewCardFace`, çünkü iki kopya **zaten ayrışmıştı** — konu çipi yalnız
  birinde, FES işareti yalnız birinde, soru puntosu 24'e karşı 26. Buranın
  testi yok ve olamaz (SwiftUI görünümü); koruma testte değil **yapıda**:
  ekrana özgü olan iki şey (`options`, `footer`) slot, geri kalanı ortak.
  Not düğmeleri de aynı sebeple ortak (`CizgiChoiceButton`).

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

Güncel yön: `docs/ARCHITECTURE.md` (akış + bileşenler),
`docs/ADR-005/006/007/008/010/011`,
`docs/FAZ6-PLAN.md`, `docs/FAZ7-PLAN-coktan-secmeli.md`,
`docs/PLAN-egzersiz-bilgi-haritasi.md`, `docs/PLAN-galeriden-foto.md`,
`docs/PLAN-model-karsilastirma.md` (Sol/Terra/Luna deneyi + kademe
yönlendirmesi tasarımı), `docs/PLAN-kapsama-sozlesmesi.md` (öneri, karar
bekliyor: sessiz kapsama kaybını ölçülebilir yapan iki katman + Sentez
Egzersizi ve Deste Doktoru adayları), `docs/ORNEK-algi-taramasi.md` (Tur A nasıl doldurulur),
`docs/PRIVACY.md`, `docs/RUNBOOK.md`, `docs/MALIYET-OLCUMU.md` (çağrı başına
maliyet defteri, teşhis yordamı, model karşılaştırması), `backend/README.md`,
`ios/README.md`.

Tarihsel (davranış için değil, karar gerekçesi için): `docs/HISTORY.md`
(oturum kayıtları arşivi), `docs/ADR-001..004`, **`docs/ADR-009`** (Karanlık
Harita — 2026-09-09'da koddan tamamen kaldırıldı; geri dönüş = kaldırma
commit'inin revert'i), `docs/FAZ0-*` – `FAZ5-*`,
`docs/COKLU-FOTO-TIMEOUT.md`, `docs/MAC-ADIMLARI*.md`, `docs/GOLD-SET-GUIDE.md`,
`docs/GOOGLE-CLOUD-KURULUM.md`, `docs/OPENAI-GEMINI-KURULUM.md`,
`docs/MODEL-CARD.md`.

## Sıradaki iş

**Elle yapılacak somut işler:** kavram destesi kaldırmasının gerçek cihazda
doğrulanması (aşağıda 23-24), FES sicili ve Egzersiz'in altı boyutlu filtresinin
cihaz doğrulaması (ADR-008, aşağıda 1-5) ve A6 (§2 aşağıda).
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
18. **Kapsama defteri gerçekten doluyor mu (Katman A, 2026-08-19).** Yeni bir
    sayfa çek: sayfa detayının altındaki **"Kartlaşmamış işaretler"** bölümü ya
    işaret listeliyor ya "bildirilen her işaret bir karta dönüşmüş" diyor
    olmalı. **"kapsama defteri olmadan üretilmiş"** diyorsa model `marks`
    alanını doldurmamıştır — o zaman sorun prompt'ta, ve bu belge bir kez daha
    "kural yazmak yetmiyor"un kaydı olur.
19. **İşaretten kart yazma.** Bir işarete dokun: `ManualCardSheet` "İşaretlenen"
    bölümü + cevap alanı doldurulmuş olarak açılmalı. Soruyu yaz, kaydet →
    kart Tekrar'da ve Bilgilerim'de **hemen** görünmeli.
20. **"Yoksay" kalıcı mı.** Bir işareti sola kaydırıp Yoksay de → listeden
    düşmeli. Sonra "Kapsama denetle"yi çalıştır: **yoksayılan işaret geri
    gelmemeli** (kimlik işaretin metninden türetiliyor, modelin `m1` etiketinden
    değil — asıl sınanan bu).
21. **"Kapsama denetle" (Katman B, Gemini).** Düğme çalışıyor mu; özet satırı
    ("N işaret gördü, k tanesine kart bulamadı") makul mü; Ayarlar → Kullanım'da
    **"kapsama denetimi"** satırı gerçek USD ile görünüyor mu. **Ön koşul:**
    `GEMINI_USD_PER_MILLION_*` Vercel'de doldurulmuş olmalı, yoksa satır $0.00
    gösterir ve defter sessizce eksik okur.
22. **Eski sayfa + göç.** v2.3 öncesi çekilmiş bir sayfayı aç: uygulama
    açılmalı (SwiftData'ya `coverageJSON` eklendi — `ModelRun.attempt` dersi:
    isteğe bağlı alan, varsayılan `nil`) ve o sayfa "kapsama defteri olmadan
    üretilmiş" demeli — "temiz" değil.

23. **Kavram destesi kaldırma göçü (2026-09-14).** **Önce Ayarlar → "Yedeği
    hazırla" ile yedek al** (sütun düşürme bu projede ilk; simülatörde
    kanıtlandı ama sigorta ucuz). Sonra kur ve aç: uygulama açılmalı,
    Bilgilerim'in Toplam'ı yalnız çekim kartları olmalı, Tekrar/Egzersiz/
    Bilgilerim'in hiçbirinde Çekimlerim/Kavramlar anahtarı olmamalı, Ayarlar'da
    "Kart" tek satır. İkinci açılışta sayılar aynı kalmalı.
24. **Eski v7 yedeği geri yükle.** Kavram destesi varken alınmış bir yedeği
    seç: "… kavram kartı atlandı (bu deste kaldırıldı)" satırı çıkmalı ve
    Toplam büyümemeli.

25. **Vurgu rengi gerçekten kayıyor mu (tasarım dili).** Yakala'daki ders
    şeridinden ders değiştir: bütün uygulamanın vurgusu (butonlar, seçili
    sekme diski, bağlantılar) o dersin rengine kaymalı — ve bunu yaparken
    **açık bir Egzersiz oturumu kaybolmamalı** (`.id()` yerine yayıncı
    kullanılmasının tek sebebi bu). Ayarlar → Görünüm → "Zamana göre" ve
    "Sabit"i de dene; "Sabit"te ders değişimi rengi **değiştirmemeli**.
26. **Dokuz değil on bir ders.** Ayarlar → Görünüm'deki önizleme şeridi on bir
    durak göstermeli. Bilgilerim'de Çekimlerim destesinin ders şeridi, kart
    dökümüyle aynı oranları anlatmalı; **gri bir dilim görürsen** yaya
    oturmayan kart var demektir (beklenen: yok).
27. **Serif üç yerde, fazlasında değil.** Kart sorusu, boş durum başlığı ve
    büyük sayılar serif olmalı; gövde metni, etiketler ve butonlar **olmamalı**.
    Font pakete konmadıysa serif = Georgia (kırılma değil, tasarlanmış geri
    düşüş). `LibreCaslonText-Regular.ttf` `ios/Resources/`'a konduktan sonra
    aynı üç yer Caslon'a dönmeli — dördüncü bir yer serif olduysa bir çağrı
    fazladan `Cizgi.serif` kullanıyordur.
28. **Dynamic Type'ın en büyük iki kademesi.** Sekme çubuğu etiketleri düşüp
    yalnız ikonlar kalmalı; `NumeralActionRow`'un büyük rakamı satırı
    taşırmamalı; `CardTypeMark` işaretleri okunur kalmalı.

29. **Tekrar'ın aralık etiketleri doğru mu (2026-09-12).** Bir kartta "Bildim"e
    bastıktan sonra kart detayındaki vade, düğmenin altında yazan süreyle
    tutmalı. **Asıl sınanan "Unuttum":** `oturumda` diyorsa kart gerçekten bu
    oturumda geri gelmeli; **aynı kartı üst üste üç kez** Unuttum'la geçince
    dördüncüde etiket bir gün sayısına dönmeli (`maxRelearningRepeats`).
30. **"Bitir" ve sekme çubuğu.** Oturum başlayınca alt çubuk kaybolmalı ve
    "Bitir" çıkmalı; Bitir'e basınca onay sorulmadan başlangıç ekranına
    dönmeli, çubuk geri gelmeli ve **verdiğin notlar korunmuş olmalı** (sayaç
    o kadar azalmış olmalı). Yarıda bırakılan kartlar hâlâ vadesinde görünmeli.
31. **Karanlık mod not düğmeleri.** Dördü de okunur olmalı — özellikle
    "Kolay". Simülatörde doğrulandı, gerçek cihazda bir kez görülmeli.
32. **Beş şıklı kart yeni yüzde (`ReviewCardFace`).** Şık listesi artık bir
    slot; şıklar soru ile kesme çizgisi arasında, kutulu satırlar hâlinde
    durmalı. Yanlış şık seçilince "Devam", doğruda üç derece çıkmalı — bu yol
    simülatördeki destede beş şıklı kart olmadığı için **denenmedi**.
33. **`lowConfidence` kartı.** "Gözden geçir" çipi artık sorunun *üstünde*
    değil, metnin altında. Kıvrık köşe (`DogEar`) kutuyla birlikte kalktı;
    kartın şüpheli olduğu hâlâ anlaşılıyor mu, yoksa çip yetersiz mi — bu bir
    zevk kararı, gerçek kullanımda bakılmalı.
34. **Egzersiz'de askıya alma (2026-09-14).** Bir koşuda ⋯ → "Askıya al":
    sayaç bir azalmalı ("3 / 12" → "3 / 11"), kart Bilgilerim'de Askıda
    görünmeli, koşu bitince özet "N kart yanıtlandı"yı askıya alınan kartı
    saymadan göstermeli. Simülatörde görüldü; ADR-007 gereği kayıt yazmadığı
    (deneme/log sayısı değişmedi) sqlite ile doğrulandı.
35. **Kaynak fotoğrafı tam ekran (2026-09-14).** Tekrar/Egzersiz'de "Kaynağı
    göster" → fotoğrafa dokun → tam ekran. **İki parmakla büyüt, parmakları
    kaldır: büyük kalmalı** (sahibinin asıl şartı); kaydır; aşağı çek → kapanmalı
    (yalnız sığdırılmışken); kapat düğmesi. Simülatörde dördü de görüldü.
    **Görülmeyen tek şey çift dokunuş** (1× ↔ 2,5×): simülatör aracı iki
    dokunuşu çift dokunuş eşiğinden yavaş gönderiyor — gerçek cihazda denenmeli.
    Aynı görüntüleyici kart detayında ve sayfa detayında da var.
36. **Günlük bildirim (2026-09-14).** Yükselttikten sonraki ilk açılışta sistem
    bildirim izni sormalı (Ayarlar'da kapalı duruyordu; tek seferlik göç açıyor).
    **İzin ver** → Ayarlar'da "Günlük hatırlatıcı" açık kalmalı ve o akşam
    seçili saatte "Günlük tekrarlarını tamamla — N kart bekliyor" gelmeli.
    **O günün tekrarlarını bitirdiğin gün gelmemeli.** Simülatörde izin istemi,
    izin ver (ayar açık kaldı) ve izin verme (ayar dürüstçe kapandı, bir daha
    zorla açılmadı) üçü de görüldü; **bildirimin gerçekten düştüğü görülmedi**
    (saat yalnız tam saat alıyor) — cihazda ilk akşam bakılmalı.
37. **Bilgilerim — ders → konu → kart (2026-09-14).** Arama ve filtre boşken
    "Son eklenenler · 7 gün" yalnız son haftanın kartlarını (en fazla 50),
    altında "Dersler"i göstermeli; bir derse dokun → konular (kanonik sıra, sonra
    Konusuz ve varsa Tanınmayan konu) → kartlar. Satırlardaki sayıların toplamı
    ders satırındakine eşit olmalı. Arama ya da filtre açıkken liste "Sonuçlar ·
    N" olarak tamamını göstermeli.
38. **Satırda vade + kaydırma.** Her kart satırında "yeni" / "vadesi geldi" /
    "4 gün" etiketi; sola kaydır → tam kaydırma **askıya alır** (eskiden tam
    kaydırma silerdi), "Sil" ayrı dokunuş. Askıdaki kartta aynı hareket
    "Askıdan çıkar".
39. **İstatistik.** Bilgilerim → İstatistik: Tümü/30 gün/7 gün değişince
    sayılar değişmeli; toplam kart Bilgilerim'in Toplam'ına eşit; bir kartı
    Tekrar'da "Unuttum" ile geç, dön → o dersin "unutma"sı +1. "%0" hepsi yanlış
    demek, "—" hiç veri yok demek. Simülatörde 325 kart / 719 log ile her sayı
    (toplam, ders, 7 gün penceresi) SQL'e karşı birebir doğrulandı; gerçek
    destede (binlerce log) açılış süresi hissedilir mi, ona bakılmalı.
40. **Arka plan gravürleri (2026-09-14).** Tekrar/Egzersiz'de soru hâlindeyken
    sağ altta dersin silik gravürü görünmeli (Anatomi kafatası, Farmakoloji
    yüksükotu, Mikrobiyoloji mikroskop…); **cevap açılınca kaybolmalı**; beş
    şıklı kartta, en büyük yazı boyutlarında ve dersi tanınmayan kartta hiç
    çıkmamalı. Simülatörde açık/karanlık mod, iki ders, cevap açma ve AX5
    görüldü. Opaklık **%7** — sahibi %5/%7/%9 karşılaştırmasından seçti
    (`SubjectFigure.opacity`); gerçek telefon ekranında da aynı eşikte mi, bakılmalı.
    Kaynaklar ve lisanslar: `docs/FIGURES-SOURCES.md`.
41. **Yedek v9 — sayfa fotoğraflı geri yükleme (2026-09-14, ADR-011).**
    Claude'un ürettiği v9 dosyasını Dosyalar'dan geri yükle: özet "N kart, M
    sayfa fotoğrafıyla" demeli; bir karta gir → "Kaynağı göster" → fotoğraf ve
    tam ekran zoom çalışmalı; Kuyruk ekranında sayfalar Hazır olarak
    listelenmeli; aynı dosyayı ikinci kez yükle → hiçbir şey eklenmemeli.
    Ayarlar → Yedeği hazırla ile alınan yeni yedek hâlâ görüntüsüz olmalı
    (dosya boyutu şişmemeli). Simülatörde ilk dördü görüldü; **dışa aktarmanın
    boyutu** yalnız birim testiyle (anahtarlar yazılmıyor) kilitli, gerçek bir
    yedekte bakılmalı. Büyük dosya simülatörde denendi (91 MB / 25 sayfa, birkaç
    saniye); **gerçek telefonda bellek** farklıdır — onlarca sayfalık gerçek bir
    dosyada uygulama kapanmadan bitiyor mu, bakılmalı. 256 MB'ı aşan dosya
    "böl" mesajıyla reddedilmeli.

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

- ~~**Kapsama sözleşmesi**~~ — **yazıldı** (2026-08-19, yukarıdaki durum
  tablosuna ve ana akışın 6b maddesine bakın). Aynı belgedeki (`docs/PLAN-
  kapsama-sozlesmesi.md`) iki büyük alternatif hâlâ aday:
  **Sentez Egzersizi** (kendi kartlarından TUS tipi vinyet, Gemini
  doğrulamalı; yalnız FES'i besler, `EarlyPractice`'e asla dokunmaz — beş
  kartlık bir vinyetteki yanlışı beş kartın vadesine dağıtmanın doğru yolu
  yok) ve **Deste Doktoru** (2026-08-18 denetiminin tekrarlanabilir hâli:
  kopya/kapsanan/**çelişen** kart taraması, tam deste ≈$0.015).
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
