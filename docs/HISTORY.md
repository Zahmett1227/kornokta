# Tarihsel kayıt (HISTORY)

Bu dosya, `CLAUDE.md`'de biriken oturum-tarihi kayıtlarının arşividir.
Güncel durum için `CLAUDE.md`'ye bak; buradaki her şey ya süperseded mimariye
(Faz 6 öncesi deterministik hat — 2026-08-09 tıraşında koddan da silindi) ya da
kapanmış inceleme turlarına aittir. Karar gerekçesi ararken oku; davranış
değiştirmek için okuma.

---

## Faz 6 boyunca merge edilen büyük işler (özet, 2026-08-05 → 2026-08-08)


- **PR #15–#23 — vision akışı + kalite/gecikme.** `/api/cards-vision`, prompt
  v2.3, `imageDetail:"high"`, `reasoning:"low"`, sayfa başına kart limiti 12,
  `maxOutputTokens` 8192; "sıcak-çalışma" UI redesign
  (`App/Theme/CizgiTheme.swift`); `ConfirmationView` ana akıştan çıktı,
  tam-sayfa crop atlandı, `needsReview` bölümleri kaldırıldı. Zaman aşımı
  tavanı yükseltildi: `vercel.json maxDuration` 300, `OPENAI_TIMEOUT_MS`
  290000, iOS timeout 300 + uzun-timeout'lu `URLSession`.
- **Çoklu fotoğrafta zaman aşımı** ([`docs/COKLU-FOTO-TIMEOUT.md`](docs/COKLU-FOTO-TIMEOUT.md)).
  Tavan yükseltmesi tek sayfayı kurtardı, parti hâlâ patlıyordu. Kök neden
  sunucu tavanı değil, telefonun 5–15 dakikalık **seri** bir partiyi ayakta
  tutamamasıydı: ekran varsayılan 30 s'de kilitlenir → iOS uygulamayı askıya
  alır → arka plan oturumu olmayan `URLSession` kopar (`NSURLErrorTimedOut`).
  Çözüm: paralellik + ekran kilidi + arka plan assertion + otomatik retry +
  `waitsForConnectivity`.
- **PR #25/#26 — ADR-006: bekleme telefondan çıktı (Supabase iş kuyruğu)**
  ([`docs/ADR-006-supabase-is-kuyrugu.md`](docs/ADR-006-supabase-is-kuyrugu.md)).
  Yukarıdakiler hatayı azaltıyordu ama garanti etmiyordu; telefon hâlâ uzun bir
  isteği bekliyordu. Cron yok (Hobby'de günde bir kez) — onun yerine telefonun
  yoklamaları hem unutulmuş bir işi başlatıyor hem işleyeni ölmüş bir işi geri
  alıyor; atomik `claim` (PostgREST `?status=eq.queued`) çifte üretimi
  engelliyor, gerçek veritabanında doğrulandı. Telefon Supabase'i hiç görmüyor:
  RLS açık + policy yok, yalnız Vercel'in `service_role` anahtarı geçiyor.
  `/api/cards-vision` dokunulmadan duruyor (geri dönüş istemci tarafında bir yol
  değişikliği). Codex'in bulduğu beş yarış/sızıntı PR #26'da kapatıldı; kural
  artık `JobStoreLike`'ın başında yazılı: **her durum değişikliği onu haklı
  çıkaran duruma koşullu olmak zorunda.** Vercel'de iki env değişkeni şart:
  `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.
- **PR #27 — tekrar döngüsü, kart düzenleme, kaynağa dönme, altı yarım kalmış
  söz.** Ortak tema: kodun bir şey vaat edip tutmadığı yerler.
  - **Tekrar döngüsü onarıldı.** `quickSessionMinutes × 5` **her** oturuma
    uygulanıyordu (varsayılan 5 dk ile günde en fazla 25 kart — §18.3'ün "bugün
    bekleyen tüm kartlar" varsayılanı erişilemezdi); biten oturum yeniden
    kurulamıyordu; kuyruk donmuş bir kimlik listesiydi, "Unuttum" denen kart
    aynı oturumda geri gelmiyordu; geri alma yoktu. Artık normal oturum =
    bekleyen her kart, hızlı oturum ayrı bir seçenek ve **gerçek bir süre
    bütçesi** (`ReviewPace`, `ReviewLog.responseTimeMs` medyanından), unutulan
    kart oturumun sonuna dönüyor (en çok 3 kez), son puanlama geri alınabiliyor,
    yeni kart limiti `DailyNewCardLedger` ile gerçekten günlük. Mantık
    `Scheduling/ReviewSession.swift`'te.
  - **Kart düzenleme ve "Kaynağı göster" bağlandı.** Faz 6 onay adımını "yanlış
    kart sonradan düzeltilir" gerekçesiyle kaldırmıştı ama düzeltme hiç
    yazılmamıştı (tek çare silmekti); "Kaynağı göster" ise `card.sourceQuote`'a
    kapılıydı ve vision akışı onu her kartta boş bırakıyordu. Artık
    `CardEditorView` (Bilgilerim + tekrar ekranı, "Askıya al" ile birlikte) ve
    `CardSourceView` (sayfa fotoğrafı, modelin okuduğu metin, ders, çekim
    tarihi) var. Düzenleme FSRS geçmişine **dokunmuyor**. Kurallar
    `Models/CardEditing.swift`'te.
  - **Altı yarım kalmış söz kapatıldı:** yedekten geri yükleme (biçim v2 —
    etiketler, `createdAt`, `canonicalClaim` ve **tüm `ReviewLog` geçmişi**;
    yalnızca ekler), dHash ile yinelenen sayfa tespiti, kart olan günlere tarihli
    ve gerçek sayıyı taşıyan bildirimler (+ rozet, + dokununca Tekrar sekmesi),
    Ayarlar'da `ModelRun` tabanlı "Kullanım" bölümü (USD yalnız sunucuda fiyat
    ayarlıysa — §0.6), Ayarlar'ın doğru mimariyi raporlaması, ve uçtan uca
    çalışan "sayfa başına kart" ayarı (`maxCardsPerPage`; sunucu kendi tavanına
    kırpar — istemci daha az isteyebilir, fazlasını değil, §21.3).


## Faz 5 / annotation-grounding döneminde bulunan ve düzeltilen sorunlar

Aşağıdaki 1–11 maddeleri Faz 6 ÖNCESİ (süperseded) mimariye aittir;
ayrıntı `docs/FAZ5-DURUM.md`. İlgili kod 2026-08-09 tıraşında silindi.

1. `ProcessingQueue.swift`: orijinal sayfa görüntüsü, `.ready` durumu ve
   kartlar diske kalıcı olarak yazılmadan siliniyordu (kayıt başarısız olursa
   görüntü kurtarılamaz kalıyordu) — iki P1 bulgusu, ikisi de düzeltildi (PR #3).
2. `AppEnvironment.swift`: `init`'te `self.settings` tüm stored property'ler
   atanmadan okunuyordu — Swift derleme hatası. Bu, App hedefinin Xcode'da
   **gerçekten derlendiği ilk an**dı (`swift test` yalnız `CizgiCore`
   paketini derliyor, App hedefini hiç dokunmuyor) — düzeltildi (PR #4).
3. Kullanıcı gerçek bir sütunlu (Nekroz/Apoptoz karşılaştırma) sayfa çekti;
   kart arkası iki konuyu tek cümlede karıştırdı. Kök neden: hem Apple Vision
   hem Google Document AI satırları yalnız "yukarıdan aşağı + soldan sağa"
   sıralıyor, sütun farkında değildi. Sütun tespiti eklendi
   (`ReadingOrder.swift` / `documentAI.ts`), Codex'in ardışık 8 turluk
   incelemesinden 7'si düzeltildi (8.'si — çok dar ama gerçek boşluğu kesen
   bir ayraç senaryosu — kullanıcı kararıyla ertelendi, gerçek kullanımda
   düşük olasılık). `docs/ADR-002-birincil-ocr-secimi.md`'nin "Açık kalanlar"
   listesi güncellendi (PR #5).
4. **(Bu oturum)** Telefon backend'e bağlandıktan sonra ilk gerçek sayfada
   ("Tip 4 hipersensitivite") onay ekranı dört "kritik değer uyuşmazlığı"
   uyarısı gösterdi. İki gerçek hata bulundu: (a) `reconcile.ts`'teki
   "kaynak"/"okuma" etiketleri ters yönlüydü — Türkçe okuyamayan Apple'ın
   okuması "kaynak" (gold), gerçekten güvenilir Google'ın okuması "okuma"
   (hypothesis) gösteriliyordu; (b) ADR-002'den sonra bile Apple'ın Google
   ile kritik-token uyuşmazlığı tek başına onay ekranını tetiklemeye devam
   ediyordu — Apple Türkçe okuyamadığı için bu gerçek bir ikinci görüş değil.
   Ayrıca `hypo_hyper` karşılaştırması tüm kelimeyi kıyaslıyordu, yalnız
   polarite önekini değil (`hipersensitivite`/`hipersenstvite` gibi bir OCR
   yazım hatası bile "kritik uyuşmazlık" sayılıyordu). Üçü de düzeltildi;
   karar ve gerekçe `docs/ADR-003-ocr-uzlastirma-kapisi-daraltildi.md`'de.
   Ayrıca kullanıcının isteğiyle kart üretim promptu (§15.2) v1.1'e
   güncellendi: model artık soruyu kurmadan önce pasajın kazanımını
   yorumluyor, `explanation` alanında kaynak dışı bağlama izin var
   (`enriched=true` ile, §12.2'nin zaten var olan onay zorunluluğu altında).
5. **(Bu oturum, PR #7 incelemesi)** Codex gerçek bir P1 buldu: madde 4'teki
   `hypo_hyper` önek-katlaması paylaşılan `addedCriticalTokens` üzerinden
   `cardGate.ts`'e de sızmıştı — bir kart `sourceQuote: hipokalemi` derken
   `back: hiponatremi` yazsa (tamamen farklı bir tanı) bile ikisi de `hipo`ya
   katlandığı için "uydurulmuş kritik değer yok" çıkıp otomatik kabul
   edilebilirdi. Düzeltme: katlama artık varsayılan **kapalı**
   (`fold_hypo_hyper`/`foldHypoHyper` parametresiyle açık istek gerektiriyor);
   yalnızca `reconcile.ts` (OCR-vs-OCR) açıyor, `cardGate.ts` hiç açmıyor.
   Ayrıntı ADR-003'ün "Düzeltme" bölümünde. Yol boyunca `gate.ts` içinde
   önceden var olan, ilgisiz bir bayt hatası da bulundu: `${token.tokenClass}
   ${token.key}` şablon dizgisinde beş yerde gerçek bir boşluk yerine NUL
   (`\x00`) baytı vardı — sessizce çalışıyordu (yalnız iç anahtar olarak
   kullanılıyor) ama görünmez bir kusurdu, düzeltildi.
6. **(Bu oturum, aynı PR'ın ikinci incelemesi)** Codex bir P1 + bir P2 daha
   buldu. P1: `explanation`'daki uydurma içerik yalnızca modelin kendi
   `enriched` bayrağına güveniyordu — bayrak yanlışlıkla `false` kalırsa hiç
   yakalanmıyordu (ADR-001'in "bayrak taban, tavan değil" kuralının tam
   ihlali). Düzeltme: `explanationIntroducesUnsourcedCriticalToken`
   (`cardGate.ts`) artık `enriched`'ten bağımsız kontrol ediyor. P2:
   `canonical_hypo_hyper`/`canonicalHypoHyper`, Türkçe noktalı büyük `İ`'yi
   `casefold`/`toLowerCase`'den önce katlamıyordu — `İ` varsayılan küçük
   harfte birleşen noktalı bir `i`ye dönüşüp önek eşleşmesini bozuyordu.
   Düzeltme: zaten var olan `fold_diacritics`/`foldDiacritics` önce
   çalıştırılıyor. Ayrıntı: ADR-003'ün "İkinci düzeltme turu" bölümü.
7. **(Bu oturum, aynı PR'ın üçüncü incelemesi)** Codex bir adım daha derine
   indi: madde 6'daki `explanation` kontrolü yalnızca §10.5'in saydığı
   kritik-token sınıflarını yakalayabiliyor — kaynakta hiç geçmeyen ama
   hiçbir sınıfa girmeyen uydurma bir cümle (Codex'in örneği: sahte bir
   mekanizma iddiası) hâlâ `enriched=false` ile sızabilirdi. Bu deterministik
   olarak çözülemeyecek bir problem (serbest metnin kaynaktan çıkarılabilir
   olup olmadığı semantik bir yargı, §0.5) — bu yüzden kural basitleştirildi:
   `explanation` boş değilse, kritik token bulunsun bulunmasın, `enriched`
   ne olursa olsun `quick_confirm`'e yükseliyor. Küçük bir sürtünme kabul
   edildi (tamamen zararsız bir açıklama da onay ister) çünkü serbest metni
   güvenilir biçimde ayıramıyoruz. Ayrıntı: ADR-003'ün "Üçüncü düzeltme"
   bölümü.
8. **(Yeni oturum, PR #7 merge sonrası gerçek cihaz raporu, sonradan
   revize edildi — bkz. madde 9)** Kullanıcı PR #7 dağıtıldıktan sonra
   "Kart oluştur"un hâlâ kart oluşturmadığını bildirdi. `[String]` satır-id
   seçim modeline göre üç kök neden bulunup düzeltilmiş, bir dala push
   edilmişti (commit `25e3fdd`). **Bu dal hiç merge edilmedi** — bkz. madde 9.
9. **(Yeni oturum, aynı şikayet main'de tekrar edince)** Kullanıcı "main'e
   bazı değişiklikler yaptım ama onay ekranı hâlâ hiçbir şeyi onaylamıyor,
   düzeltip merge eder misin" dedi. `main`'i kontrol edince: madde 8'in dalı
   (`25e3fdd`) ile eşzamanlı, **aynı temel commit'ten (`1c1855d`)** başka bir
   oturum (muhtemelen Codex, `codex/annotation-grounding` dalından) çok daha
   büyük bir yeniden tasarım yapmış ve PR #8/#9/#10 ile merge etmiş: "annotation
   grounding" — satır-id yerine görsel kanıt/token tabanlı `AnnotationGroup`,
   sayfa başına tek Google OCR çağrısı, cihazda saklanan `OCRSnapshot`, ve
   fotoğraf üstü kutu onayı (bkz. `docs/ADR-004-annotation-grounding.md`).
   **Bu dal madde 8'in düzeltmelerini hiç içermiyordu** — aynı üç kök neden,
   yeni mimari içinde sessizce yeniden ortaya çıkmıştı:
   - `CapturePipeline.swift`: bir kart `requiresUserApproval` ile
     işaretlendiğinde `finalState` `.confirmationRequired` oluyordu — kart
     zaten kaydedilmiş olsa bile (`ProcessingQueue.apply` `generatedGroups`'u
     `finalState`'ten bağımsız kaydediyor). Bir sonraki "Kart oluştur"
     denemesinde `completedGroupIds` bu zaten-kaydedilmiş grubu
     `selectedGroups`'tan eleyip hiçbir şey üretmiyordu — kalıcı bir tıkanma,
     "Kart oluştur" hiçbir şey yapmıyormuş gibi görünüyordu. §12.2'nin gereği
     olan v1.1 promptu çoğu karta `explanation` eklediği ve `cardGate.ts` bunu
     `quick_confirm`'e yükselttiği için bu neredeyse her gerçek sayfada
     oluyordu. Düzeltme: onay isteyen kart artık `.ready` ile birlikte
     `CardStatus.needsReview` olarak kaydediliyor.
   - `LibraryView.swift`: `.needsReview` kartları hâlâ görünmüyordu — hiçbir
     "Onay bekliyor" bölümü, Onayla/Sil düğmesi yoktu. Madde 8'in dalındaki
     aynı 71 satırlık ekleme yeniden uygulandı.
   - `ConfirmationView.swift`: `submit()` sonucu kontrol etmeden `dismiss()`
     çağırıyordu. Artık `page.processingState`'i kontrol ediyor, hâlâ
     `confirmationRequired`'sa nedeni (`PipelineOutcome.confirmationReason`,
     yeni alan — `.confirmationRequired`'a giden her yol artık bir sebep
     taşıyor) uyarı olarak gösteriyor.
   - Yol boyunca ayrı bir gerçek hata daha bulundu: çok-gruplu bir gönderimde
     bir grup başarıyla üretildikten SONRA aynı gönderimdeki bir sonraki grup
     başarısız olursa (`passage.isEmpty`, `knowledge.cards.isEmpty`,
     `sourceInsufficient`), önceki grubun ürettiği kartlar `PipelineOutcome`a
     hiç taşınmıyordu (`generatedGroups` varsayılan `[]`) — parayla üretilmiş
     kartlar sessizce kayboluyordu. Üç dönüş noktasına da `generatedGroups:
     generated` eklendi.
   - Backend tarafında bu turda **hiçbir değişiklik yok**: `_ocr.ts` ve
     `reconcile.ts` madde 4-7'deki haliyle değişmeden duruyor (ADR-004
     mimarisinde seçim OCR çağrısından SONRA oluştuğu için madde 8 dalındaki
     `selectedLineIds`/`selectedBoxes` sayfa-içi daraltma mekanizması bu
     mimariye hiç uymuyor ve gerekli de değil — asıl tıkanma zaten
     `needsApproval` yönlendirmesindeydi).
   Testler: backend'e dokunulmadı (451/451 hâlâ yeşil, doğrulandı). Swift'e 3
   yeni test eklendi (167 toplam) — **henüz bir Mac'te koşulmadı**. **Bu dal
   kullanıcı isteğiyle PR #11 olarak merge edildi** (`main`'de `e0ee22f`).
10. **(Yeni oturum, gerçek cihaz ekran görüntüsüyle üç ayrı istek)** Kullanıcı
    telefonda bir ekran görüntüsü paylaştı: kök `TabView`'ın yüzen (floating)
    sekme çubuğu, `ConfirmationView`'ın alt kısmındaki "Seçili gruplardan kart
    oluştur" düğmesinin üstüne biniyordu — düğme metni çubuğun camsı
    arkasından görünüyordu, dokunmak güvenilir değildi. Kök neden araştırılmadı
    (App hedefi bu ortamda derlenemiyor); en güvenilir düzeltme uygulandı:
    `ConfirmationView` artık `.toolbar(.hidden, for: .tabBar)` ile açıkken
    sekme çubuğunu tamamen gizliyor — zaten odaklı, engelleyici bir onay adımı
    olduğu için ekranı tam kullanması makul. Ayrıca iki eksik özellik
    eklendi: (a) `ProcessingQueue.delete(_:)` — işleme kuyruğundan bir
    kaydı, SwiftData'nın `regions`/`knowledgeUnits`/`cards` zincirini
    kademeli (`cascade`) silmesine ek olarak orijinal sayfa görüntüsünü ve
    varsa bölge kırpma görüntülerini diskten de temizleyerek tamamen
    kaldırıyor (`QueueView`'da yeni "Sil" kaydırma eylemi; eski "İptal" yalnız
    durumu `.cancelled` yapıp satırı sonsuza dek listede bırakıyordu — o da
    duruyor, artık zaten iptal edilmiş satırlarda gizleniyor). (b) Bilgilerim'e
    kart silme: `LibraryView`'ın üç listesine (`Onay bekliyor`, `En çok
    unutulanlar`, `Son eklenenler`) kaydırarak silme (`onDelete`) eklendi;
    `CardDetailView`'da `.needsReview` olmayan kartlar için de (önceden
    yalnız onay bekleyenlerde vardı) ayrı bir "Sil" bölümü eklendi. Hiçbiri
    kartın bağlı olduğu `TextRegion`/kırpma görüntüsünü temizlemiyor (bir
    `KnowledgeUnit` birden çok kart taşıyabilir; kalan boş bölge zararsız,
    `PageDetailView`'da görünmez bir "Pasaj" girdisi olarak kalır — mevcut
    davranışla tutarlı, kapsam dışı bırakıldı). Bu madde PR #12 (`ab9e0b1`)
    ile main'e merge edildi (bir sonraki oturumun `git pull`ıyla görüldü).
11. **(Yeni oturum, 2026-08-04, üç ayrı istek)** Kullanıcı üç şey istedi: app
    icon, her sayfada bir "geri gelme" butonu, manuel alan ekleme
    stabilizasyonu.
    - **Icon:** `ios/App/Assets.xcassets/AppIcon.appiconset/` sıfırdan
      oluşturuldu (proje hiç asset katalog içermiyordu —
      `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` ayarı vardı ama
      karşılıksızdı, muhtemelen önceki bir `xcodegen generate` çalıştırması
      asset katalog daha eklenmeden önce bu ayarı otomatik yazmıştı).
      Görsel Canva MCP ile üretildi (fosforlu kalem motifi: beyaz zemin,
      tek amber vurgu çizgisi + lacivert metin çizgisi, tam kadraj),
      1024×1024 opak PNG. Yeni Swift dosyalarını (`AppNavigator.swift`,
      `HomeButton.swift`) ve asset katalogu projeye bağlamak için
      `project.pbxproj` elle düzenlenmedi — `ios/project.yml`'in `App`
      klasörünü glob'ladığı fark edilince `cd ios && xcodegen generate`
      çalıştırıldı, proje temiz baştan üretildi (README'nin kendi kuralı:
      `.xcodeproj` bilerek commit edilmiyor).
    - **"Ana sayfaya dön" butonu:** İncelemede görüldü ki push edilen her
      ekran zaten SwiftUI'nin otomatik geri okunu alıyor — kullanıcı
      netleştirmede bunun yerine sekme kök ekranları dahil her sayfada
      doğrudan Yakala'ya dönen tek bir buton istedi. Yeni
      `AppNavigator` (ObservableObject; seçili sekme + `capturePath`/
      `libraryPath` `NavigationPath`'leri) ve `HomeButton`/
      `.homeButtonToolbar()` eklendi; `RootView` artık `TabView(selection:)`
      kullanıyor. Sekiz ekranın hepsine (`CaptureView`, `ReviewView`,
      `LibraryView`, `SettingsView`, `QueueView`, `PageDetailView`,
      `ConfirmationView`, `CardDetailView`) sol üstte ev ikonu eklendi; push
      edilen ekranlarda sistemin geri okunun yanında ikinci bir kontrol
      olarak duruyor.
    - **Manuel alan ekleme stabilizasyonu** (kod okumasıyla bulunan beş
      kırılganlık, hepsi düzeltildi): (a) `PageOverlayTransform.normalizedPoint`
      artık görüntü sınırı dışındaki bir sürükleme noktasında `nil` dönüp
      dikdörtgeni sessizce iptal etmek yerine kenara kenetleniyor; (b) canlı
      önizleme dikdörtgeni de aynı şekilde kenetleniyor (yeni
      `clampedViewPoint`); (c) çizim modundayken alttaki otomatik-bölge
      butonları `.allowsHitTesting(false)` ile devre dışı, artık bir bölgenin
      üzerinden çizime başlamak o bölgenin seçimini de değiştirmiyor; (d) pan
      artık kalıcı bir state'te birikip (`dragStartPan`/`isPanning`) her yeni
      dokunuşta sıfıra zıplamıyor, ayrıca görüntü ekran dışına tamamen
      sürüklenemeyecek şekilde kenetlendi (`maxPanX`/`maxPanY`); (e)
      `AnnotationGrouper.ground`/`groundLocally`'de yalnız `.manual` seçim
      tipi için: örtüşme eşiğini (0.3/0.25) ıskalayan ama merkeze yakın
      (≤0.16 normalize mesafe — `nearbyHandwrittenTokens`'ın kullandığı
      yarıçapla aynı) bir kutu artık boş pasajla onay ekranına sekmek yerine
      en yakın satıra düşüyor; mesafe sınırı bilerek düşük tutuldu çünkü
      `BackendPipelineTests.testCloudReadingThatMissesTheMarkedRegionAsksInsteadOfFallingBack`
      testi, alâkasız bir satıra sessizce düşmenin (kutunun gerçekten
      hiçbir ilgili içerik bulamadığı durumda) kasıtlı olarak yasak
      olduğunu doğruluyor — bu test hâlâ yeşil. (f) Manuel kutuya artık
      "×" ile sil/geri al eklendi (önceden yalnızca seçimi kaldırıp
      göndermemek mümkündü, kutu ekranda kalıyordu).
    - `ios/CizgiCore/Tests/CizgiCoreTests/AnnotationGroundingTests.swift`'e
      3 yeni test eklendi (kenetleme, uzak/yakın satır fallback'i remote ve
      local yollar için).


## PR #30'da kapatılan inceleme bulguları (2026-08-07 akşam turu)

listesi + bağımsız iki incelemenin bulguları; ayrıntılı gerekçeler kod
yorumlarında.

*Veri bütünlüğü / yarışlar:*
- iOS: çakışan iki koşunun kart setini **iki kez** kalıcılaştırması (`apply`'ın
  `.ready` dalına `hasPersistedGroup` süzgeci, `process(pageID:)`'te
  `shouldProcess` yeniden kontrolü, `retry`'de in-flight koruması).
- iOS: iptalin geç gelen sonuçla ezilmesi (`apply` başında `.cancelled` guard'ı).
- Backend: `complete`/`fail` artık `started_at` fence'li — ADR-006 kuralının son
  iki istisnası kapandı. `claim` kazandığı satırı döner; worker o satırın
  parametreleriyle üretir, fence'i kaybederse ne sonuç yazar ne paylaşılan
  nesne yolunu siler.

*Kalıcı kilitler (jobId = sayfa kimliği olduğu için hepsi "sayfa bir daha
üretilemez" demekti):*
- Storage `getImage` 404'ü, OpenAI `incomplete` ve gövde-içi `failed` artık
  retryable.
- **`force` bayrağı:** kullanıcının "Tekrar dene"si kalıcı hatayı da yeniden
  kuruyor (`POST /api/jobs` `force: true` → `requeue(includePermanent)`).
  Otomatik retry'ler bunu **kullanmaz**. Bu olmadan yanlış API anahtarıyla
  üretilen sayfalar, anahtar düzeltildikten sonra bile sonsuza dek kilitliydi.
- Vision uçları artık PDF/TIFF'i kapıda çeviriyor (`VISION_MIME_TYPES`);
  önceden OpenAI'den 400 dönüp kalıcı hataya çevriliyordu.
- iOS: bilinmeyen kart tipi artık yalnız o kartı düşürüyor, tüm yanıtı değil.

*FSRS (§18.1 — resmi algoritmaya sadakat):* `nextStabilityFailure`/
`_next_stability_failure` resmi `min(long_term, S / e^(w17·w18))` clamp'ini
**taşımıyordu**; open-spaced-repetition/py-fsrs `_next_forget_stability` ile
karşılaştırılarak doğrulandı ve iki dilde birden eklendi,
`evals/shared/fsrs-cases.json` yeniden üretildi. Etkisi: çok gecikmiş,
kararlılığı düşük bir kart "Unuttum" sonrası **daha uzun** aralık alabiliyordu.

*Diğer:* `numeric()` artık negatif/sıfır değerleri reddediyor
(`SUPABASE_JOB_STALE_AFTER_MS=0` her canlı işçiyi anında bayat sayıyordu);
elle retry sonrası `scheduleRetryDrain` çağrılıyor; parti sürerken çekilen
sayfalar için `rerunRequested` (önce bir sonraki açılışa kadar bekliyorlardı);
QueueView'da kart taşıyan sayfanın silinmesi artık onay istiyor; `ImageStore`
Swift 6 `Sendable` uyarısı kapatıldı; README/PRIVACY güncel akışa çekildi.

**Bilerek yapılmayan:** sunucu tarafında `attempts` üst sınırı. Telefonun
`RetryPolicy.maxAttempts` = 5'i otomatik denemeleri zaten sınırlıyor ve çağrı
başına maliyet tavanı artık gerçek; sunucuya sabit bir tavan koymak yeni
eklenen `force` kaçışını da kapatırdı.
- Python (`evals/`): **517 test yeşil** — bu ortamda gerçekten koşuldu
  (`pip install pytest jsonschema numpy pillow opencv-python-headless` sonrası).
- Swift (`ios/CizgiCore/`): tam paket **Linux'ta derlenmiyor** (CoreGraphics,
  SwiftData). Foundation'a bağlı mantık (ReviewSession/ReviewPace/
  DailyNewCardLedger, CardEditing, BackupExporter+Restorer, PerceptualHash,
  ReviewReminders, ImportedImage, MultipleChoice, StateMachine) bu ortama
  kurulan gerçek bir Swift araç zinciriyle, yalnız o dosyaları içeren izole bir
  pakette **120 testle koşuldu ve geçti**. **Tam paketin son yeşil koşusu bir
  Mac'te yapılmalı.**
- App hedefi: kullanıcı `main`'i (PR #29 dahil) Xcode'da derledi, uygulama
  sorunsuz açıldı.
- SwiftUI dosyaları burada yalnız `swiftc -parse` ile denetlenebiliyor — bu
  **sözdizimi** kontrolüdür, tip/aşırı-yükleme hatasını yakalamaz. Nitekim
  `SettingsView`'daki geçersiz bir `Section` başlatıcısı ancak kullanıcının
  Xcode derlemesinde çıktı (düzeltildi, `cfcc44c`). Bu sınıftan hatalar için
  **tek gerçek kapı bir Mac derlemesi.**

