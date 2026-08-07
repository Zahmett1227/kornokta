# Çizgi — proje durumu (yeni oturum için)

Bu dosya her yeni Claude Code oturumunun başında otomatik okunur. Amacı: bir
önceki oturumun hafızasını taşımadan, buradan devam edilebilmesi.

## Güncel yön — Faz 6 / vision-öncelikli (pivot: 2026-08-05)

Uygulama sahibi bilinçli bir ürün pivotu kararı verdi: uygulama **tıbbi-güvenlik
/ kaynağa-sadakat omurgasından**, **kişisel kullanım için vision-öncelikli** bir
mimariye geçiyor. Yeni ana akış: *işaretli sayfa fotoğrafını doğrudan OpenAI
vision modeline gönder → model kullanıcının önemsediği (fosforlu/altı çizili/
dairelenmiş/yanına not alınmış) kısmı kendisi okuyup zenginleştirilmiş kartları
üretsin → kartlar onaysız doğrudan desteye girsin → FSRS ile tekrar edilsin*.

- **Neden ve hangi ilkeler gevşedi:** [`docs/ADR-005-kisisel-vision-yeniden-tasarim.md`](docs/ADR-005-kisisel-vision-yeniden-tasarim.md)
- **Uygulama planı (detaylı, dosya bazlı, aşamalı):** [`docs/FAZ6-PLAN.md`](docs/FAZ6-PLAN.md)
- **Kullanıcı kararları:** hata riski kabul edildi (uygulama tek çalışma kaynağı
  değil), yayınlanma yok (tamamen kişisel), OpenAI'de kalınıyor.
- **Durum (2026-08-07):** **Faz 6 kod olarak tamam ve `main`'de** (PR #15–#27,
  son merge `0679edc`). Vision akışı uçtan uca çalışıyor, kart üretimi asenkron
  bir iş kuyruğuna taşındı, tekrar döngüsü onarıldı, kartlar düzenlenebiliyor ve
  kaynağına dönülebiliyor. **Kalan iş kod değil, gerçek cihaz doğrulaması** —
  "Sıradaki iş" bölümüne bak.

### Ana akış bugün nasıl işliyor

1. **Yakala:** işaretli sayfa fotoğrafı → dHash ile "bu sayfayı daha önce
   çektin mi?" sorusu (reddetmez, **sorar**) → bayt diske yazıldıktan sonra
   kuyruğa girer.
2. **Kuyruk:** `ProcessingQueue` sayfaları 3'lü paralel işler; işlem sürerken
   ekran kilidini ve bir arka plan assertion'ını tutar, geçici hataları
   `nextAttemptAt`'e uyarak kendiliğinden tekrar dener.
3. **Üretim (asenkron):** `POST /api/jobs` sayfayı Supabase Storage'a yazar,
   satırı `queued` yapar ve **saniyeler içinde 202** döner; üretim yanıttan
   sonra `waitUntil` altında sürer. Telefon `GET /api/jobs?ids=` ile yoklar.
   **İş kimliği = sayfa kimliği**, yani uygulama beklerken öldürülse bile bir
   sonraki açılış biten işi bulup alır (ikinci üretim ücreti yok).
4. **Kartlar onaysız** `.active` olarak SwiftData'ya girer ve FSRS-6 ile tekrar
   edilir. Yanlış kart tekrar ekranından ya da Bilgilerim'den düzenlenir/askıya
   alınır; "Kaynağı göster" sayfa fotoğrafını ve modelin okuduğu metni gösterir.

### Faz 6 boyunca merge edilen büyük işler

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

**Kullanıcı kararları:** hata riski kabul edildi (uygulama tek çalışma kaynağı
değil), yayınlanma yok (tamamen kişisel), OpenAI'de kalınıyor.

Aşağıdaki 1–11 maddeleri ve "Kararlar" bölümünün bir kısmı Faz 6 ÖNCESİ
(süperseded) mimariyi anlatır; **güncel yön yukarıdadır**.

## Proje ne

Tek kullanıcılık (sahibi için) iOS uygulaması: kitapta işaretlenen (altı
çizili/fosforlu/dairelenmiş/yanına not alınmış) tıbbi bilgiyi fotoğraftan
yakalar, bir vision modeline okutup zenginleştirilmiş öğrenme kartlarına
dönüştürür, FSRS ile tekrar ettirir. Kullanıcı Türkçe konuşan bir TUS
öğrencisi/hekim.

> Faz 6 öncesinde ürünün omurgası **kaynağa sadakat + onay kapıları**ydı; pivot
> bunu kişisel kullanım için bilinçle gevşetti (ADR-005). ANA-PLAN'ın ilgili
> maddeleri hâlâ okunur, ama bu iki belge onların üstündedir.

**Tüm ürün/mimari/kalite kararlarının kaynağı:**
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md).
Bölüm numaralarına (§0.5, §19.3 gibi) bu dosyada ve tüm kod yorumlarında
sürekli atıf yapılır — bir davranış tuhaf görünüyorsa önce oraya bak.

Dokümantasyon ve kullanıcıyla iletişim **Türkçe**; kod tanımlayıcıları ve
yorumları **İngilizce**.

## Şu an neredeyiz (2026-08-07)

| Faz | Durum |
|---|---|
| Faz 0 — Risk azaltma | ✅ Tamam |
| Faz 1 — Yerel uygulama iskeleti | ✅ Tamam |
| Faz 2 — Bulut OCR + işaret tespiti | ✅ Kod tamam, ama **Faz 6'da ana akıştan çıktı** (kod geri dönüş için diskte, çağrılmıyor). Çıkış kapısı (20 görüntülük altın set ölçümü) kullanıcı kararıyla atlanmıştı — `docs/FAZ2-PLAN.md`. |
| Faz 3 — AI kart üretimi | ✅ Backend + iOS istemcisi tamam, gerçek anahtarla uçtan uca doğrulandı; gold pasaj kalite ölçümü kullanıcıyla birlikte yapıldı (`docs/FAZ3-PLAN.md`). Kart yolu Faz 6'da v2'ye (vision) revize edildi. Kalan: gerçek maliyet rakamları (§7). |
| Faz 4 — FSRS tekrar motoru | ✅ Gerçek FSRS-6 (`evals/fsrs/` Python referansı + Swift portu), `ReviewScheduling` seam'i üzerinden bağlı. Bildirimler, günlük yeni kart limiti ve süre bütçeli hızlı oturum 2026-08-06/07'de **gerçek anlamlarına kavuştu** (PR #27). Ayrıntı: `docs/FAZ4-PLAN.md`. |
| Faz 5 — Sertleştirme | 🟡 Kod tamam; **gerçek iPhone kabul listesi hâlâ açık.** `docs/FAZ5-DURUM.md`'deki 10 maddeden 1–5 denendi (ve o sırada bulunan gerçek hatalar düzeltildi), 6–10 (uçak modu, bildirim, sınırlar, yedek, "orijinali sakla") hiç koşulmadı. |
| Faz 6 — Vision-öncelikli kişisel yeniden tasarım (B) | ✅ **Kod tamam, `main`'de** (PR #15–#27). B1 (backend v2 sözleşme + `/api/cards-vision`), B2 (iOS vision akışı + App cilası), B3 (prompt v2.3 + gecikme/kalite), UI redesign, B4 (bildirimler, hata/retry kuyruğu, maliyet görünürlüğü) bitti; üstüne asenkron iş kuyruğu (ADR-006) ve PR #27'nin onarımları geldi. **Kalan:** §11 kabul kriterleri = gerçek cihaz doğrulaması; `Models` alan sadeleşmesi + SwiftData göçü (bilerek ertelendi, §10.4 "mevcut kartlar korunmalı"); gerçek maliyet USD rakamları. Bkz. `docs/FAZ6-PLAN.md`, `docs/ADR-005`. |

**Dal durumu:** `main` güncel uç (`0679edc`, PR #27 squash merge). Çalışma
dalları merge sonrası bırakılıyor; yeni iş `main`'in ucundan yeni bir dalla
başlar.

**Tarihsel kayıt — Faz 5/annotation-grounding döneminde bulunan ve düzeltilen
sorunlar** (Faz 6 öncesi mimariye ait; ayrıntı `docs/FAZ5-DURUM.md`):
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

**Test durumu (2026-08-07):**
- Backend (`backend/`): **476 test yeşil**, `tsc --noEmit` temiz — bu ortamda
  gerçekten koşuldu.
- Swift (`ios/CizgiCore/`): tam paket **Linux'ta derlenmiyor** (CoreGraphics,
  SwiftData). PR #27'nin eklediği mantık (ReviewSession/ReviewPace/
  DailyNewCardLedger, CardEditing, BackupExporter+Restorer, PerceptualHash,
  ReviewReminders) bu ortama kurulan gerçek bir Swift araç zinciriyle, yalnız
  Foundation'a bağlı dosyaları içeren izole bir pakette **63 testle koşuldu ve
  geçti**. **Tam paketin ve App hedefinin son yeşil koşusu bir Mac'te
  yapılmalı.**
- SwiftUI dosyaları yalnız `swiftc -parse` ile denetlendi — bu **sözdizimi**
  kontrolüdür, tip/aşırı-yükleme hatasını yakalamaz. Nitekim `SettingsView`'daki
  geçersiz bir `Section` başlatıcısı ancak kullanıcının Xcode derlemesinde
  çıktı (düzeltildi, `cfcc44c`). Bu sınıftan hatalar için **tek gerçek kapı bir
  Mac derlemesi.**
- Python (`evals/`): son bilinen 513 test yeşil — bu ortamda `pytest` kurulu
  değil, bu oturumda koşulmadı.

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`), Root Directory
`backend`. Gerekli env değişkenleri `.env.example`'da; iş kuyruğu için
**`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`** şart (kullanıcı ekledi).
Supabase tarafında `jobs` tablosu + `page-uploads` özel kovası var; ikisinde de
RLS açık ve **policy yok** (yalnız `service_role` geçer). Proje kimliği ve
anahtar yalnız Vercel env'inde durur, repoda değil.

## Kararlar (değiştirmeden önce oku)

> **Faz 6 (2026-08-05 pivotu, kod 2026-08-07'de tamam):** Aşağıdaki kararların
> bir kısmı tıbbi-güvenlik omurgasına aittir ve Faz 6'da **bilinçle
> gevşetilmiştir**; ilgili kod artık ana akışta çağrılmıyor (silinmedi, geri
> dönüş için duruyor). Güncel kararlar ADR-005 + ADR-006 + `docs/FAZ6-PLAN.md`.
> Aşağıdakileri o kodu diriltmeden önce oku.

- **`docs/ADR-005-kisisel-vision-yeniden-tasarim.md`** — **GÜNCEL YÖN:**
  kişisel kullanım için vision-öncelikli pivot; §0.5/§10/§12.1/§19'un
  gevşetilmesi. Ana akışa dokunmadan önce bunu oku.
- **`docs/ADR-006-supabase-is-kuyrugu.md`** — **GÜNCEL YÖN:** kart üretimi
  asenkron; `POST /api/jobs` 202 döner, üretim `waitUntil` altında sürer,
  telefon `GET /api/jobs?ids=` ile yoklar. İş kimliği = sayfa kimliği. Cron
  yok; kurtarma telefonun yoklamalarıyla ve atomik `claim` ile yapılır.
  §7.3'ten verilen taviz orada yazılı. `_jobs.ts`/`supabaseJobs.ts`'e
  dokunmadan önce oku — kural: **her durum değişikliği onu haklı çıkaran
  duruma koşullu olmak zorunda.**
- **`docs/ADR-002-birincil-ocr-secimi.md`** — Apple Vision Türkçe metin
  tanımayı desteklemiyor (ölçüldü, `docs/FAZ0-BULGULAR.md`). Google Document
  AI birincil ve tek metin kaynağı; Vision yalnız önizleme + satır geometrisi
  için kullanılıyor. Bunu tersine çevirecek bir değişiklik yapmadan önce bu
  ADR'yi oku. "Açık kalanlar" #1'deki çok sütunlu sayfa okuma sırası artık
  büyük ölçüde çözüldü (`ReadingOrder.swift` / `documentAI.ts`) — satır
  sıralama mantığını değiştirmeden önce bu ADR'nin güncellenmiş halini oku.
- **`docs/ADR-001-hibrit-turkce-morfoloji.md`** — Türkçe normalizasyon
  (İ/ı büyük-küçük harf, NFC, diyakritik katlama) kararı.
- **`docs/ADR-003-ocr-uzlastirma-kapisi-daraltildi.md`** — Apple Vision'ın
  Google ile kritik-token uyuşmazlığı artık `reconcile.ts`'te onay ekranını
  tetiklemiyor (kayda geçiyor, gatelemiyor); "kaynak"/"okuma" etiket yönü
  düzeltildi. Bu dosyayı okumadan `reconcile.ts`'in `decide()` fonksiyonuna
  dokunma.
- **§0.5** — hiçbir sayı/birim/yön/olumsuzlama/sembol sessizce
  "düzeltilmez". OCR farklı okuduğunda kullanıcıya sorulur, otomatik
  seçilmez.
- **§0.6** — model adı, eşik, maliyet sınırı asla koda gömülmez; hep merkezi
  config'te (`evals/spikes/marker_detection/config.json`, backend `config.ts`).
- **§0.8** — hesaplama ve zamanlama deterministik kodda; LLM yalnız
  görüntü/metin yorumlama ve içerik üretimi için.

## Anti-drift disiplini (bu projede iki kez ısırdı, artık yapısal önlemli)

Kritik token motoru ve işaret tespiti mantığı **iki dilde** var (Python
referans + TypeScript/Swift üretim). Ayrışmayı önleyen mekanizma:
- Regex kalıpları Python'dan üretilip JSON'a yazılıyor
  (`backend/providers/criticalTokenPatterns.json`), elle yazılmıyor.
- Davranış paylaşılan vaka dosyalarıyla sabitleniyor (`evals/shared/*.json`).
- Eşik config'leri byte-birebir kopya (`ios/CizgiCore/Sources/CizgiCore/Resources/`),
  bir Python testi ayrışırsa kırılıyor.
- Her üretici `--check` modunda CI'da çalışıyor.

Yeni bir "aynı davranış iki yerde" durumu çıkarsa aynı deseni uygula —
elle senkron tutma, üret ve kilitle.

## Güvenlik (bağlayıcı)

- API anahtarı **hiçbir zaman** repoda veya iOS uygulamasında olmaz.
- Google kimlik bilgisi iki biçimde: yerelde dosya yolu
  (`GOOGLE_APPLICATION_CREDENTIALS`), Vercel'de dosya içeriği tek satır JSON
  (`GOOGLE_CREDENTIALS_JSON`). İkisi de `.env`/Vercel env'de, asla kodda.
- `DEVICE_TOKEN` yalnız iki yerde: backend ortam değişkeni + telefonun
  Keychain'i. Üçüncü kopya yok.
- `SUPABASE_SERVICE_ROLE_KEY` RLS'i tamamen atlar: yalnız yerel `.env` ve Vercel
  proje ayarları. Repoda, `config.ts`'te ve **iOS uygulamasında asla** olmaz —
  telefon Supabase'i hiç görmez, her şeye backend üzerinden erişir. `jobs`
  tablosunda ve `page-uploads` kovasında RLS açık ve **hiç policy yok**, yani
  anonim/publishable anahtarla hiçbir satır okunamaz (gerçek projede
  doğrulandı).
- `evals/fixtures/` içine telifli kitap sayfası **commit edilmez** (gitignore'lu).
- Sunucu loglarında görüntü içeriği veya tam OCR metni saklanmaz.

## Nasıl çalıştırılır

Ayrıntı: `docs/RUNBOOK.md`. Özet:

```bash
python -m pytest evals -q                     # 513 test (bu ortamda pytest kurulu değil)
cd ios/CizgiCore && swift test                 # yalnız bir Mac'te — Linux'ta derlenmiyor
cd backend && npm test                         # 476 test, yeşil
cd backend && npm run typecheck                # tsc --noEmit
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
cd ios && xcodegen generate                    # App'e dosya eklendiyse ŞART
```

**Linux'ta Swift:** tam `CizgiCore` paketi burada derlenmez (CoreGraphics,
SwiftData). Yeni yazılan mantık Foundation-only tutulursa, bir Swift araç
zinciri kurup yalnız o dosyaları ve testlerini içeren izole bir pakette
gerçekten koşturmak mümkün — PR #27'nin 63 testi böyle doğrulandı. SwiftUI
dosyaları için elde yalnız `swiftc -parse` var ve o **tip hatalarını
yakalamaz**; App hedefinin tek gerçek kapısı bir Mac derlemesidir.

## Doküman haritası

- `docs/RUNBOOK.md` — nasıl çalıştırılır, sorun giderme
- `docs/ARCHITECTURE.md` — bileşenler, işlem hattı, anti-drift mekanizması
- `docs/ADR-005-kisisel-vision-yeniden-tasarim.md` — **GÜNCEL YÖN:** kişisel
  vision-öncelikli pivot kararı (Faz 6 / B)
- `docs/ADR-006-supabase-is-kuyrugu.md` — **GÜNCEL YÖN:** asenkron iş kuyruğu
  kararı, kurtarma modeli, yarış koşulları ve gizlilik tavizi
- `docs/FAZ6-PLAN.md` — **GÜNCEL YÖN:** Faz 6'nın detaylı, dosya bazlı uygulama
  planı, sadeleşmiş sözleşme ve aşamalı durum tablosu
- `docs/COKLU-FOTO-TIMEOUT.md` — çoklu fotoğraf zaman aşımının teşhisi: neden
  sunucu tavanı değil telefonun askıya alınması, hangi azaltmalar yapıldı
- `docs/FAZ5-DURUM.md` — 10 maddelik iPhone kabul listesi (6–10 hâlâ açık) ve
  gerçek cihaz oturumlarında bulunan hatalar
- `docs/FAZ2-PLAN.md` — Faz 2'nin tam kaydı: ne yapıldı, hangi hatalar
  bulundu/düzeltildi, çıkış kapısının neden atlandığı
- `docs/FAZ3-PLAN.md` — Faz 3'ün tam kaydı: backend'de ne yazıldı, hangi
  tasarım kararları alındı, gold pasaj ölçümünün nasıl kapatıldığı
- `docs/FAZ4-PLAN.md` — Faz 4'ün tam kaydı: FSRS-6 formülleri nereden
  geldi (ve ilk fetch'in nasıl yanlış çıktığı), Python referansı, Swift
  portu, saat dilimi güvenliği kararı
- `docs/ADR-003-ocr-uzlastirma-kapisi-daraltildi.md` — Apple-Google kritik
  token uyuşmazlığının artık gatelemediği kararı, "kaynak"/"okuma" etiket
  düzeltmesi, `hypo_hyper` yanlış-pozitif düzeltmesi
- `docs/OPENAI-GEMINI-KURULUM.md` — OpenAI/Gemini anahtarlarını edinme adımları
- `docs/MAC-ADIMLARI.md` — Faz 2 altın set ölçümü istenirse adım adım rehber
  (araçlar hazır, hiç çalıştırılmadı)
- `docs/MAC-ADIMLARI-FAZ3.md` — Faz 3 gold pasaj kart kalite ölçümü rehberi
  (kullanıcıyla birlikte yapıldı, sonuç `docs/FAZ3-PLAN.md`'de)
- `backend/README.md` — backend yapısı, Vercel dağıtımında çıkan gerçek
  tuzaklar ve çözümleri
- `ios/README.md` — iOS yapısı, cihazda elle kontrol listesi
- `docs/PRIVACY.md`, `docs/MODEL-CARD.md` — gizlilik kuralları, model stratejisi
- `docs/FAZ0-*.md`, `docs/FAZ1-DURUM.md` — tarihsel kayıtlar (güncel durum
  için değil, o anki karar gerekçelerini görmek için)

## Sıradaki iş

Kod tarafında bilinen bir eksik yok; **sıradaki iş gerçek cihazda doğrulama.**
Aşağıdakiler öncelik sırasıyla.

### 1. Gerçek cihaz doğrulaması (en öncelikli — hepsi tek bir oturumda yapılabilir)

Önce `git pull && cd ios && xcodegen generate` (PR #27 `ios/App` altına dört
yeni dosya ekledi: `CardEditorView`, `CardSourceView`, `PageImageHasher` ve
tema/yardımcılar; XcodeGen çalıştırılmadan Xcode onları hedefe almaz).

- **Faz 6 §11 kabul kriterleri:** işaretli sayfa → onaysız aktif kart → FSRS
  tekrarı; kartlar ağırlıklı olarak *işaretlenen* içeriğe karşılık geliyor mu;
  en az bir kısmı zenginleştirilmiş mi.
- **Asıl şikayetin doğrulaması:** 5–10 fotoğrafı **tek partide** yükle. Beklenen:
  `POST /api/jobs` saniyeler içinde döner, ekran kilitlense/uygulama kapatılsa
  bile iş sunucuda sürer, bir sonraki açılışta kartlar gelir, **hiçbir sayfa iki
  kez üretilmez**.
- **PR #27'nin yeni davranışları:** normal vs hızlı oturum, "Unuttum" kartının
  oturum sonunda geri gelmesi, "Geri al", günlük yeni kart limitinin ekran
  yeniden açılınca sıfırlanmaması, kart düzenleme/askıya alma, "Kaynağı göster",
  aynı sayfayı ikinci kez çekince çıkan soru, bildirimin doğru sayıyı söylemesi
  ve dokununca Tekrar sekmesini açması, "Yedeği hazırla → geri yükle" turu.
- **`docs/FAZ5-DURUM.md` kabul listesinin 6–10. maddeleri** (uçak modu +
  "Tekrar dene", bildirim izni, sınırlar, yedeğin içinde görüntü olmaması,
  "Orijinal sayfayı sakla" kapalıyken davranış).

### 2. Küçük ve gerçek kalanlar

1. **Gerçek maliyet rakamları.** `OPENAI_USD_PER_MILLION_*` hâlâ 0. Artık
   Ayarlar → Kullanım bunu gösterdiği için doldurmanın görünür değeri var;
   §0.6 gereği rakam **sağlayıcının kendi fiyatlandırma sayfasından** gelmeli,
   uydurulmaz.
2. **Başarısız üretim çağrıları için de `ModelRun` kaydı** — şu an yalnız
   başarılı çağrılar kaydediliyor, yani "Kullanım" başarısız denemelerin
   maliyetini göstermiyor (`docs/FAZ3-PLAN.md`, F3-8).
3. **`Models` alan sadeleşmesi + SwiftData göçü** (`sourceQuote` vb. Faz 6'da
   anlamsızlaşan alanlar). Bilerek ertelendi: §10.4 "mevcut kartlar korunmalı"
   diyor, cihazsız doğrulanamaz ve kullanıcıya görünür bir değeri yok.

### 3. Düşük öncelikli, kullanıcı kararıyla ertelenmiş

4. Codex'in PR #5'te bulduğu 8. bulgu: yarım sayfa genişliğinden dar ama gerçek
   sütun boşluğunu kesen ortalanmış bir ayraç/başlık boşluğu hâlâ gizleyebilir
   (`MAX_COLUMN_ITEM_WIDTH`, `documentAI.ts`/`ReadingOrder.swift`). Faz 6 ana
   akışı OCR yapmadığı için pratikte ölü kod.
5. `evals/ocr_eval/metrics.py`'deki `critical_token_error_rate` `hypo_hyper`
   için hâlâ tüm kelimeyi kıyaslıyor (ADR-003 "Açık kalan").
6. `ProcessingQueue.completedGroupIds` / çok-gruplu kısmi seçim modeli — Faz 6
   tek sentetik grup ürettiği için artık tetiklenmiyor, ama kod duruyor.

### Aday sonraki özellikler (karar verilmedi)

Bunlar öneri, taahhüt değil; sırayı kullanıcı seçer.

- **Etiket/ders bazlı filtreli tekrar** ("bugün yalnız Farmakoloji").
- **Kart kalitesi geri bildirimi:** tekrar sırasında "bu kart kötü" işareti ve
  bunların prompt iterasyonuna girdi olması.
- **Sayfayı yeniden üret:** aynı fotoğraftan farklı bir `hint` ile ikinci bir
  kart takımı (maliyeti açıkça söyleyerek).
- **FSRS ağırlık optimizasyonu:** yedeğe artık giren gerçek `ReviewLog`
  geçmişinden kullanıcıya özel ağırlık hesaplama (`evals/fsrs/` referansı var).