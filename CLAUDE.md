# Çizgi — proje durumu (yeni oturum için)

Bu dosya her yeni Claude Code oturumunun başında otomatik okunur. Amacı: bir
önceki oturumun hafızasını taşımadan, buradan devam edilebilmesi.

## ⚠️ Yön değişikliği — Faz 6 / "B" (2026-08-05)

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
- **Durum (2026-08-06):** **Faz 6 esasen kod-tamam ve `main`'de** (PR #15–#23
  merge edildi). Vision akışı uçtan uca: `CapturePipeline` tam sayfayı doğrudan
  `/api/cards-vision`'a gönderiyor, kartlar onaysız `.active`; UI "sıcak-çalışma"
  redesign'ı (`App/Theme/CizgiTheme.swift`); `ConfirmationView` ana akıştan
  çıktı, tam-sayfa crop atlandı, `needsReview` bölümleri kaldırıldı. **B3
  kalite/gecikme:** `imageDetail:"high"`, `reasoning:"low"`, kart limiti 12,
  `maxOutputTokens` 8192, prompt v2.3. **Zaman aşımı kökten çözüldü** (PR #22):
  `vercel.json maxDuration` 300, `OPENAI_TIMEOUT_MS` 290000, iOS timeout 300 +
  uzun-timeout'lu `URLSession`. **Codex P1** (PR #23): `.env.example` tüm B3
  değerlerinde ayrışmıştı, config varsayılanlarına hizalandı + bir test şablonu
  varsayılanlara kilitledi. **B4:** FSRS bildirimleri (`ReviewNotificationManager`
  + Settings) ve hata/retry kuyruğu (`ProcessingQueue.retry` + "Tekrar dene")
  **zaten bağlı**. Backend **428** test yeşil. **Gerçek kalan (hepsi ya riskli-
  düşük-değer ya da bloke):** (a) `Models` alan sadeleşmesi + SwiftData göçü —
  §10.4 "mevcut kartlar korunmalı", cihazsız doğrulanamaz, kullanıcıya görünür
  değeri yok; (b) gerçek maliyet USD rakamları — §0.6 gereği uydurulmaz, gerçek
  fiyat yok; (c) **§11 kabul kriterleri = gerçek cihaz doğrulaması** (kullanıcı
  retest + Vercel env kontrolü).
- **2026-08-06 — çoklu fotoğrafta zaman aşımı:** PR #22'nin tavan yükseltmesi
  tek sayfayı kurtardı ama parti hâlâ patlıyordu. Kök neden sunucu tavanı değil,
  telefonun 5–15 dakikalık **seri** bir partiyi ayakta tutamamasıydı (ekran
  varsayılan 30 s'de kilitleniyor → iOS uygulamayı askıya alıyor → arka plan
  oturumu olmayan `URLSession` kopuyor → `NSURLErrorTimedOut`). `ProcessingQueue`
  artık sayfaları 3'lü paralel işliyor, işlem sürerken ekran kilidini ve bir arka
  plan assertion'ını tutuyor, geçici hataları `nextAttemptAt`'e uyarak
  kendiliğinden tekrar deniyor; `waitsForConnectivity` açıldı. Teşhis:
  [`docs/COKLU-FOTO-TIMEOUT.md`](docs/COKLU-FOTO-TIMEOUT.md).
- **2026-08-06 — ADR-006: bekleme telefondan çıktı (Supabase iş kuyruğu).**
  Yukarıdakiler hatayı azaltıyor ama garanti etmiyordu: telefon hâlâ uzun bir
  isteği bekliyordu. Kart üretimi artık asenkron — `POST /api/jobs` sayfayı
  Supabase Storage'a yazıp saniyeler içinde 202 dönüyor, üretim `waitUntil`
  altında yanıttan sonra sürüyor, `GET /api/jobs?ids=` sonucu topluyor.
  **İş kimliği = sayfa kimliği**, yani uygulama beklerken öldürülse bile bir
  sonraki açılış biten işi bulup alıyor (ikinci üretim ücreti yok). Cron yok —
  Hobby'de günde bir kez — onun yerine telefonun yoklamaları hem unutulmuş bir
  işi başlatıyor hem de işleyeni ölmüş bir işi geri alıyor; atomik `claim`
  (PostgREST `?status=eq.queued`) çifte üretimi engelliyor, gerçek veritabanında
  doğrulandı. Telefon Supabase'i hiç görmüyor: RLS açık + policy yok, yalnız
  Vercel'in `service_role` anahtarı geçiyor. `/api/cards-vision` dokunulmadan
  duruyor (geri dönüş istemci tarafında bir yol değişikliği).
  Karar/gerekçe/§7.3 tavizi: [`docs/ADR-006-supabase-is-kuyrugu.md`](docs/ADR-006-supabase-is-kuyrugu.md).
  Backend **469** test yeşil, `tsc --noEmit` temiz; merge sonrası Codex'in
  bulduğu üç yarış (koşulsuz `enqueue` → çifte ödemeli üretim; kurtarmanın
  denemeye kilitli olmaması; kuyruğa alma düşerse sızan görüntü) PR #26'da
  kapatıldı; Codex aynı PR'ı da inceleyip nesne temizliğinde iki delik
  daha buldu (kaybeden gönderimin kendi yüklemesi; `expire` sonrası düşen
  yükleme), onlar da kapatıldı — kural artık `JobStoreLike`'ın başında yazılı: **her durum
  değişikliği onu haklı çıkaran duruma koşullu olmak zorunda**; CizgiCore'a 9 test eklendi
  ama **Swift bu ortamda derlenmedi** — bir Mac'te `swift test` +
  `xcodebuild -scheme Cizgi … build` gerekiyor. Vercel'de iki yeni env
  değişkeni şart: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.

- **2026-08-06 — tekrar döngüsü onarıldı.** Üç kusur üst üste binip gerçek bir
  desteyi kullanılamaz kılıyordu: (a) `quickSessionMinutes × 5` **her** oturuma
  uygulanıyordu, yani varsayılan 5 dk ile günde en fazla 25 kart —
  §18.3'ün "bugün bekleyen tüm kartlar" varsayılanı erişilemezdi; (b) oturum
  bitince `startSessionIfNeeded` boş olmayan kuyruğu yeniden kurmayı reddediyordu,
  yani uygulamayı kapatmadan devam edilemiyordu; (c) kuyruk donmuş bir kimlik
  listesiydi, "Unuttum" denen kart aynı oturumda geri gelmiyordu (öğrenme adımı
  yok). Ayrıca geri alma yoktu — "Kolay"a yanlış basmak kalıcıydı.
  Artık: normal oturum = bekleyen her kart, hızlı oturum ayrı bir seçenek ve
  **gerçek bir süre bütçesi** (`ReviewPace`, her `ReviewLog`'un yıllardır kaydedip
  kimsenin okumadığı `responseTimeMs` medyanından); unutulan kart oturumun sonuna
  geri konuyor (en çok 3 kez); son puanlama geri alınabiliyor (kart alanları +
  `ReviewLog` + günlük hak); yeni kart limiti `DailyNewCardLedger` ile **gerçekten
  günlük** (önce her oturumda sıfırlanıyordu). Mantık `Scheduling/ReviewSession.swift`
  içinde, App hedefinde değil — **28 yeni test bu ortamda gerçek `swift test` ile
  koşuldu ve geçti** (Linux'ta bir Swift araç zinciri kurulup CizgiCore'un
  Foundation-only alt kümesi izole bir pakette derlendi; tam paket CoreGraphics/
  SwiftData yüzünden Linux'ta derlenmiyor). `ReviewView.swift` yalnız `swiftc -parse`
  ile doğrulandı — tip denetimi hâlâ bir Mac gerektiriyor.

- **2026-08-06 — kart düzenleme ve "Kaynağı göster" bağlandı.** İkisi de
  verilmiş ama tutulmamış sözlerdi. (a) Faz 6 onay adımını "yanlış kart sonradan
  Bilgilerim'de düzeltilir" gerekçesiyle kaldırmıştı (ADR-005, FAZ6-PLAN §9) ama
  düzeltme hiç yazılmamıştı — tek çare kartı silmekti. Artık `CardEditorView`
  var, hem Bilgilerim'den hem **tekrar ekranından** (kötü kart orada fark edilir)
  açılıyor; §6.5'in istediği "askıya al" da aynı menüde ve askıya alınan kart
  oturumdan çıkarılıyor. Düzenleme FSRS geçmişine **dokunmuyor** — gerekçe
  `CardEditorView.save`'de. (b) "Kaynağı göster" `card.sourceQuote`'a kapılıydı
  ve vision akışı onu her kartta boş bırakıyor, yani uygulamanın ürettiği hiçbir
  kartta görünmüyordu — oysa sayfa fotoğrafı diskte ve ilişki zinciri
  (`Card → KnowledgeUnit → TextRegion → CapturedPage`) sağlamdı. Artık
  `CardSourceView` sayfayı, modelin okuduğu metni, dersi ve çekim tarihini
  gösteriyor; "Orijinal sayfayı sakla" kapalıysa bunu **söylüyor** (Ayarlar'a da
  uyarı eklendi). §5.5'in istediği kırpıntı ve kitap/sayfa bilgisi bu akışta
  gerçekten yok, o yüzden uydurulmadı. Kurallar `Models/CardEditing.swift`'te
  (modelin "okuduğu metin" aslında kendi yedek metniyse ya da sorunun kendisiyse
  kaynak sayılmıyor) — **14 yeni test, gerçek `swift test` ile geçti** (toplam 42).
  **Not:** iki yeni App dosyası var; `cd ios && xcodegen generate` çalıştırmadan
  Xcode onları hedefe almaz.

- **2026-08-06 — kalan altı "yarım kalmış söz" kapatıldı.** Hepsi kodun bir şey
  vaat edip tutmadığı yerlerdi:
  1. **Yedek geri yüklenebiliyor.** `BackupExporter`'ın yalnız `encode`'u vardı;
     artık `decode` + `BackupRestorer` var ve Ayarlar'da "Yedekten geri yükle".
     Biçim v2: etiketler, `createdAt`, `canonicalClaim` ve **tüm `ReviewLog`
     geçmişi** de yedeğe girdi (FSRS ağırlık optimizasyonunun ihtiyacı olan veri
     cihazdan hiç çıkmıyordu). v1 dosyalar hâlâ okunuyor. Geri yükleme
     **yalnızca ekler** — mevcut kart olduğu gibi bırakılır, gerekçe
     `BackupRestorer.plan`'da.
  2. **Yinelenen sayfa tespiti.** `perceptualHash` alanı hiç yazılmıyordu; artık
     her çekimde dHash hesaplanıyor (`PerceptualHash`/`PerceptualHasher`,
     Foundation-only ve test edilir; görüntüden gri örnek çıkarma
     `PageImageHasher`'da). Aynı sayfa ikinci kez çekilirse Yakala ekranı
     **soruyor**, reddetmiyor — eşik ilk kalibrasyon ve sayfayı bilerek yeniden
     çekmek normal.
  3. **Bildirim artık yalan söylemiyor.** Tek tekrarlı tetikleyici yerine, önümüzdeki
     7 gün için **kart olan günlere** tarihli tek seferlik bildirimler kuruluyor,
     her biri gerçek sayıyı taşıyor (`ReviewReminderPlanner`); rozet "şu an
     bekleyen" sayısı; bildirime dokununca **Tekrar** sekmesi açılıyor (eskiden
     Yakala açılıyordu).
  4. **Maliyet görünür.** `ModelRun` yazılıp hiç okunmuyordu; Ayarlar'da
     "Kullanım" bölümü çağrı ve token sayılarını gösteriyor. USD yalnız sunucuda
     fiyat ayarlıysa gösteriliyor — §0.6 uydurma fiyatı yasaklıyor ve "0,00 USD"
     bedava gibi okunurdu.
  5. **Ayarlar doğru mimariyi raporluyor.** "Faz 3 / Google Document AI" diyordu;
     Faz 6 hiç OCR yapmıyor.
  6. **"Sayfa başına kart" ayarı gerçekten çalışıyor.** `maxCards` istek
     gövdesine hiç yazılmıyordu. Artık uçtan uca bağlı; sunucu **kendi tavanına
     kırpıyor**, yani istemci daha az isteyebilir, fazlasını değil (§21.3).
     Yeni bir ayar anahtarı (`maxCardsPerPage`, varsayılan 12) — eskisini
     bağlamak, kayıtlı 2 değeri yüzünden B3'ün 12'ye çıkarma kararını sessizce
     geri alırdı. Supabase'e `max_cards` sütunu eklendi (migration repoda).

  Backend **476** test yeşil, `tsc --noEmit` temiz; CizgiCore'da **63 test gerçek
  `swift test` ile geçti**. SwiftUI dosyaları yalnız `swiftc -parse` ile
  denetlendi. **Not:** `ios/App` altında iki yeni dosya
  (`CardEditorView`/`CardSourceView` ile birlikte dört); `cd ios && xcodegen generate`
  şart.

Aşağıdaki "Şu an neredeyiz" tablosu ve 1–11
  maddeleri Faz 6 ÖNCESİ (süperseded) mimariyi anlatır; **güncel yön yukarıdadır**.

## Proje ne

Tek kullanıcılık (sahibi için) iOS uygulaması: kitapta işaretlenen (altı
çizili/fosforlu) tıbbi bilgiyi fotoğraftan yakalar, kaynak-sadık öğrenme
kartlarına dönüştürür, FSRS ile tekrar ettirir. Kullanıcı Türkçe konuşan bir
TUS öğrencisi/hekim.

**Tüm ürün/mimari/kalite kararlarının kaynağı:**
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md).
Bölüm numaralarına (§0.5, §19.3 gibi) bu dosyada ve tüm kod yorumlarında
sürekli atıf yapılır — bir davranış tuhaf görünüyorsa önce oraya bak.

Dokümantasyon ve kullanıcıyla iletişim **Türkçe**; kod tanımlayıcıları ve
yorumları **İngilizce**.

## Şu an neredeyiz (2026-08-03)

| Faz | Durum |
|---|---|
| Faz 0 — Risk azaltma | ✅ Tamam |
| Faz 1 — Yerel uygulama iskeleti | ✅ Tamam |
| Faz 2 — Bulut OCR + işaret tespiti | ✅ Kod ve dağıtım tamam. 2026-08-04'te Faz 3 öncesi annotation-grounding katmanı eklendi: token/bbox kanıtı, grup sözleşmesi, tek-çağrılık OCR snapshot ve fotoğraf üstü onay. **Çıkış kapısı (20 görüntülük altın set ölçümü) kullanıcı tarafından bilinçli olarak atlandı** — sebep ve araçlar `docs/FAZ2-PLAN.md`'de. Eşikler hâlâ "ilk kalibrasyon". |
| Faz 3 — AI kart üretimi | ✅ Backend yazıldı, test edildi, gerçek anahtarla uçtan uca doğrulandı. iOS istemci entegrasyonu (`BackendCardProvider`, `ModelRun` kaydı) yazıldı ve **kullanıcı tarafından bir Mac'te `swift test` ile doğrulandı (2026-08-03, 136/136 yeşil)**. **Çıkış kapısı (gold pasaj kart kalite rubriği) kullanıcıyla birlikte ölçüldü ve kullanıcı tarafından yeterli görüldü**: 2 gerçek pasaj, 8 gerçek kart, %100 kabul — küçük bir örneklem, istatistiksel kanıt değil, ama kullanıcının kendi kararı (ANA-PLAN bir örneklem büyüklüğü şart koşmuyor). Ayrıntı ve gözlemler: `docs/FAZ3-PLAN.md`'nin "F3-10 — asıl ölçüm yapıldı" bölümü. Kalan: yalnız gerçek maliyet rakamları. |
| Faz 4 — FSRS tekrar motoru | ✅ Gerçek FSRS-6 algoritması yazıldı (`evals/fsrs/` Python referansı + Swift portu), Faz 1'in zaten hazır olan offline review akışına (`ReviewView`, `ReviewSessionPlanner`, askıya alma) `ReviewScheduling` seam'i üzerinden bağlandı — **`ReviewView.swift`'te hiçbir değişiklik gerekmedi**. Python tarafı bu ortamda gerçekten çalıştırıldı (51 yeni test, hepsi geçiyor); Swift portu (`FSRSScheduler.swift`, 6 yeni test) **kullanıcı tarafından bir Mac'te `swift test` ile doğrulandı (2026-08-03, yeşil)**. Kalanların hepsi kapandı: bildirimler (`ReviewNotificationManager`), günlük yeni kart limiti ve süre bütçeli hızlı oturum — sonuncu ikisi 2026-08-06'da gerçek anlamlarına kavuştu (aşağıdaki tekrar döngüsü maddesi). Ayrıntı: `docs/FAZ4-PLAN.md`. |
| Faz 5 — Sertleştirme | 🟡 Kod tamam; **gerçek iPhone testi 2026-08-03'te fiilen başladı**. Telefon backend'e bağlandı, 153/153 Swift testi bir Mac'te doğrulandı — ama sonrasında main annotation-grounding'e geçti (madde 9) ve o doğrulama artık eski bir kod tabanına ait. Kabul listesindeki 10 maddenin tamamı henüz koşulmadı; süreçte gerçek hatalar bulunup düzeltildi (dördü madde 1-4, üçü madde 9) — ayrıntı `docs/FAZ5-DURUM.md`. |
| Faz 6 — Vision-öncelikli kişisel yeniden tasarım (B) | 🟡 **B1 tam + B2 (çekirdek + App cilası) + B3 başlangıç + UI redesign (2026-08-05).** `faz6-quality-ui` dalında: prompt v2.1 (kalite), `OPENAI_REASONING_EFFORT` medium, "sıcak-çalışma" UI redesign (`App/Theme/CizgiTheme.swift` + Yakala/Tekrar/Bilgilerim/Kuyruk), `ConfirmationView` navigasyondan çıktı, tam-sayfa crop atlandı — **App hedefi `xcodebuild` ile BUILD SUCCEEDED**, CizgiCore 185 test, backend 425, Python 513 yeşil. Kalan: Models göçü + B4.<br>**Önceki (`faz6-vision`, merge edildi PR #15):** Backend kart yolu yerinde v2'ye revize edildi: prompt v2.0, `/api/cards-vision`, `cleanText` kalktı, `cardGate` auto_accept'e sadeleşti, çıktı şeması v2 (`schemaVersion "2.0"`; transcription/knowledgeUnits/source-fidelity alanları çıktı, kart `tags`+`lowConfidence`). iOS: `BackendCardProvider` `/api/cards-vision`'a bağlandı; **`CapturePipeline.run()` vision akışına çevrildi** (tam sayfa → vision → tek sentetik grupla `.ready`; yerel OCR/işaret-tespiti/onay ana akıştan çıktı), kartlar `.active`. OCR-akış pipeline testleri §8 gereği arşivlendi. Backend 425 + Python 513 + Swift **185** test yeşil. Geri dönüş için OCR/reconcile/detection modülleri (backend+iOS) dokunulmadan diskte. **Kalan (App hedefi, gerçek cihaz):** `ConfirmationView` navigasyondan çıkarma, `persist` tam-sayfa crop atlama, `needsReview` arayüz bölümleri, `Models` alan sadeleşmesi + SwiftData göçü. Bkz. `docs/FAZ6-PLAN.md` §9 iki "Uygulama notu" ve `docs/ADR-005`. |

**Dal durumu:** `claude/project-review-issue-j0ycif`, `main`'in `0bca0d0`'i
(PR #7/#8/#9/#10 dahil güncel uç) üzerine **sıfırdan kuruldu** — önceki bir
oturumun aynı isimli dalı (`598b93c` üzerine kurulmuştu, commit `25e3fdd`)
main'in `1c1855d`'ten sonra annotation-grounding'e gittiğini fark etmeden
push edilmişti; o dal madde 9'da anlatıldığı gibi geçersiz kaldı ve terk
edildi (obje veritabanında hâlâ erişilebilir ama branch ref'i artık ona
işaret etmiyor).

**Bugünkü gerçek cihaz oturumunda bulunan ve düzeltilen sorunlar** (ayrıntı
`docs/FAZ5-DURUM.md`, madde 4 bu oturuma ait):
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

**Test durumu:**
- Python (`evals/`): 511 test — bu oturumda dokunulmadı/koşulmadı.
- Backend (`backend/`): **451 test**, yeşil — bu oturumda backend'e hiç
  dokunulmadı.
- Swift (`ios/CizgiCore/`): **171 test, yeşil** (168 mevcut + 3 yeni),
  bu ortamda `swift test` ile gerçekten koşuldu (2026-08-04). App hedefi
  de bu ortamda ilk kez gerçekten derlendi
  (`xcodebuild -scheme Cizgi -destination 'generic/platform=iOS Simulator'
  build`, **BUILD SUCCEEDED**, uyarısız) — ama gerçek cihaz/simülatör
  çalıştırması hâlâ yapılmadı; `AppNavigator`/`HomeButton`/gesture
  değişiklikleri yalnız derleme ile doğrulandı, davranışı değil.

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`). Yerel
`main`, `ab9e0b1`'i (PR #12, madde 10) içeriyor — bu oturumun madde 11
değişiklikleri **henüz commit edilmedi**, çalışma dizininde duruyor.

## Kararlar (değiştirmeden önce oku)

> **Faz 6 / B (2026-08-05):** Aşağıdaki kararların çoğu tıbbi-güvenlik
> omurgasına aittir ve Faz 6'da **bilinçle gevşetiliyor**. Güncel karar
> `docs/ADR-005-kisisel-vision-yeniden-tasarim.md` + `docs/FAZ6-PLAN.md`.
> Aşağıdakiler Faz 6 öncesi (süperseded) mimarinin kararlarıdır; kod hâlâ o
> haldeyken geçerlidir.

- **`docs/ADR-005-kisisel-vision-yeniden-tasarim.md`** — **GÜNCEL YÖN:**
  kişisel kullanım için vision-öncelikli pivot; §0.5/§10/§12.1/§19'un
  gevşetilmesi. Ana akışa dokunmadan önce bunu oku.
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
- `evals/fixtures/` içine telifli kitap sayfası **commit edilmez** (gitignore'lu).
- Sunucu loglarında görüntü içeriği veya tam OCR metni saklanmaz.

## Nasıl çalıştırılır

Ayrıntı: `docs/RUNBOOK.md`. Özet:

```bash
python -m pytest evals -q                    # 511 test
cd ios/CizgiCore && swift test                # 167 test (bu oturumdan sonra hiç Mac'te koşulmadı, yukarı bak)
cd backend && npm test                        # 451 test
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
```

## Doküman haritası

- `docs/RUNBOOK.md` — nasıl çalıştırılır, sorun giderme
- `docs/ARCHITECTURE.md` — bileşenler, işlem hattı, anti-drift mekanizması
- `docs/ADR-005-kisisel-vision-yeniden-tasarim.md` — **GÜNCEL YÖN:** kişisel
  vision-öncelikli pivot kararı (Faz 6 / B)
- `docs/FAZ6-PLAN.md` — **GÜNCEL YÖN:** Faz 6'nın detaylı, dosya bazlı uygulama
  planı, sadeleşmiş sözleşme ve aşamalı süre tahmini
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

**En öncelikli (Faz 6 / B — YENİ YÖN, bkz. `docs/FAZ6-PLAN.md` §9):**
B1 (backend) ve B2'nin çekirdeği (iOS `BackendCardProvider` + `CapturePipeline`
vision akışı) `faz6-vision` dalında uygulandı ve testlerle doğrulandı (henüz
commit edilmedi, çalışma dizininde; backend 425 / Python 513 / Swift 185 yeşil).

**Sıradaki: B2 App-hedefi cilası (bu ortamda derlenemez — gerçek cihaz gerekir):**
- `ConfirmationView`'ı navigasyondan çıkar (artık ulaşılmaz, ölü kod).
- `ProcessingQueue.persist`: vision grupları için tam-sayfa crop kaydetmeyi atla
  (şu an her sayfayı gereksizce crop olarak da saklıyor).
- `LibraryView`'daki `needsReview`/"Onay bekliyor" bölümlerini kaldır (vision
  akışında kart üretilmiyor).
- (İsteğe bağlı) `ProcessingState.confirmationRequired`/`CardStatus.needsReview`
  enum vakalarını kaldır — App hedefindeki exhaustive switch'lere dikkat.
- `Models.swift`: `sourceQuote` vb. kaldırılan alanlar için SwiftData göçü
  (tek cihaz, düşük risk).
- Gerçek iPhone'da uçtan uca: işaretli sayfa → onaysız aktif kart → FSRS tekrar.
Sonra B3 (prompt kalite döngüsü) + B4 (cila).

Ayrıca: gerçek maliyet rakamları hâlâ 0 (`OPENAI_USD_PER_MILLION_*`, §7); tam
sayfa girdi crop'tan pahalı, ilk çağrılarda `ModelRun.usage`'dan okunup
doldurulmalı.

---

**Aşağıdakiler Faz 6 ÖNCESİ (süperseded) önceliklerdir; B'ye geçilince çoğu
geçersiz olacak, tarihsel bağlam için duruyor:**

**Eski en öncelikli:** madde 11'in üç değişikliğini gerçek cihazda doğrulamak
(hiçbiri henüz commit edilmedi): (a) yeni app icon'un ana ekranda beklendiği
gibi göründüğü, (b) her sayfadaki ev ikonunun gerçekten Yakala'ya dönüp tüm
yığınları sıfırladığı (özellikle Onay ekranından ortadayken), (c) manuel
alan çizerken kenar kenetlemesinin/pan düzeltmesinin/sil butonunun gerçek
parmak hareketiyle beklenen gibi çalıştığı ve bir kutunun artık boş pasajla
geri sekmediği. Bu oturumda yalnız `swift test` (171 yeşil) ve
`xcodebuild … build` (BUILD SUCCEEDED) çalıştırılabildi — gerçek
cihaz/simülatör çalıştırması hiç yapılmadı.

Madde 10'un üç değişikliği (PR #12, `ab9e0b1`) main'e merge edildi ama
kendi gerçek cihaz doğrulaması da hâlâ bekliyor: (a) `ConfirmationView`
açıkken sekme çubuğunun gizlendiği ve "Seçili gruplardan kart oluştur"un
tam görünüp dokunulabilir olduğu, (b) İşleme Kuyruğu'nda "Sil"in satırı
(ve diskteki görüntülerini) gerçekten kaldırdığı, (c) Bilgilerim'de bir
kartın silinebildiği.

Madde 9'un doğrulaması (needsApproval→ready, Bilgilerim'de Onay bekliyor,
confirmationReason) hâlâ bekliyor — main'e merge edildi ama gerçek cihazda
hiç denenmedi. Bir Mac'te `swift test` (167 test, hiçbiri bu oturumdan sonra
koşulmadı) her iki maddeyle birlikte yapılabilir.

**Bir önceki oturumdan devralınan, hâlâ geçerli öncelik:** gerçek karmaşık
bir sayfa fotoğrafını `evals/fixtures/complex-annotations/` altına
yerleştirip fotoğraf-tabanlı grounding/onay akışını telefonda denemek.
Beklenenler: kısa alt çizgi yalnız tokenı seçmeli, aynı metin farklı
yerlerde ayrı kalmalı, tek OCR çağrısından sonra onay ekranı tekrar OCR
yapmamalı. Ayrıntı: ADR-004. Üçü aynı anda, aynı gerçek cihaz oturumunda
doğrulanabilir.

1. Bu dal (`claude/project-review-issue-j0ycif`) merge edilip Vercel'in
   Production dağıtımı güncellenmeli (Production Branch ayarına dikkat —
   `backend/README.md`'deki tuzak).
2. `docs/FAZ5-DURUM.md`'deki 10 maddelik iPhone kabul listesinin geri
   kalanını (bildirim, yedek, sınırlar, uçak modu) koş.
3. Gerçek maliyet takibi: `OPENAI_USD_PER_MILLION_*`/`GEMINI_USD_PER_MILLION_*`
   hâlâ 0 (uydurma rakam yok, §0.6) — sağlayıcının kendi fiyatlandırma
   sayfasından doldurulmalı.
4. Başarısız kart üretimi çağrıları için de bir `ModelRun` kaydı (şu an
   yalnız başarılı çağrılar kaydediliyor — `docs/FAZ3-PLAN.md`'de F3-8
   altında not edildi).
5. Faz 4'ün küçük kalanları: ~~bildirimler~~ (ARTIK BAĞLI —
   `ios/App/ReviewNotificationManager.swift` + SettingsView, günlük tekrar
   hatırlatması `UNCalendarNotificationTrigger` ile kuruluyor); ~~süre-bütçeli
   hızlı mod~~ ve ~~ayrı bir "yeni kart limiti" ayarı~~ da bağlı — ikisi de
   2026-08-06'da gerçek anlamlarına kavuşturuldu (tekrar döngüsü maddesi).
6. (Düşük öncelik) Codex'in PR #5'te bulduğu 8. bulgu ertelendi: yarım sayfa
   genişliğinden dar ama yine de gerçek sütun boşluğunu kesen ortalanmış bir
   ayraç/başlık, boşluğu hâlâ gizleyebilir (`documentAI.ts`/`ReadingOrder.swift`
   içindeki `MAX_COLUMN_ITEM_WIDTH` sabitiyle ilgili — ayrıntı PR #5'in
   yorumlarında). Gerçek kullanımda düşük olasılık, kullanıcı kararıyla
   ertelendi.
7. (Düşük öncelik, ADR-003 "Açık kalan") `evals/ocr_eval/metrics.py`'deki
   manifest-tabanlı `critical_token_error_rate` ölçümü `hypo_hyper` için
   hâlâ tüm kelimeyi kıyaslıyor — altın-set ölçümünde aynı yanlış-pozitif
   görülürse `canonical_hypo_hyper` oraya da taşınmalı.
8. (Bu oturumdan) `ProcessingQueue.completedGroupIds`/`CapturePipeline`'ın
   çok-gruplu kısmi seçim modeli tam doğrulanmadı: bir kullanıcı bir
   sayfadaki 5 gruptan 2'sini onaylayıp gönderirse, snapshot'ın
   `autoSelectedGroupIds`'i yalnız o 2 grupla daralıyor — kalan 3 gruba aynı
   sayfadan daha sonra dönmek şu an desteklenmiyor gibi görünüyor (kod
   okumasıyla tespit edildi, cihazda doğrulanmadı). Gerçek kullanımda bir
   sorun çıkarsa `CapturePipeline.swift`'teki `selection`/`groundedSelection`
   inşasına bak.
