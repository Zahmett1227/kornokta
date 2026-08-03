# Çizgi — proje durumu (yeni oturum için)

Bu dosya her yeni Claude Code oturumunun başında otomatik okunur. Amacı: bir
önceki oturumun hafızasını taşımadan, buradan devam edilebilmesi.

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
| Faz 2 — Bulut OCR + işaret tespiti | ✅ Kod ve dağıtım tamam. **Çıkış kapısı (20 görüntülük altın set ölçümü) kullanıcı tarafından bilinçli olarak atlandı** — sebep ve araçlar `docs/FAZ2-PLAN.md`'de. Eşikler hâlâ "ilk kalibrasyon". |
| Faz 3 — AI kart üretimi | ✅ Backend yazıldı, test edildi, gerçek anahtarla uçtan uca doğrulandı. iOS istemci entegrasyonu (`BackendCardProvider`, `ModelRun` kaydı) yazıldı ve **kullanıcı tarafından bir Mac'te `swift test` ile doğrulandı (2026-08-03, 136/136 yeşil)**. **Çıkış kapısı (gold pasaj kart kalite rubriği) kullanıcıyla birlikte ölçüldü ve kullanıcı tarafından yeterli görüldü**: 2 gerçek pasaj, 8 gerçek kart, %100 kabul — küçük bir örneklem, istatistiksel kanıt değil, ama kullanıcının kendi kararı (ANA-PLAN bir örneklem büyüklüğü şart koşmuyor). Ayrıntı ve gözlemler: `docs/FAZ3-PLAN.md`'nin "F3-10 — asıl ölçüm yapıldı" bölümü. Kalan: yalnız gerçek maliyet rakamları. |
| Faz 4 — FSRS tekrar motoru | ✅ Gerçek FSRS-6 algoritması yazıldı (`evals/fsrs/` Python referansı + Swift portu), Faz 1'in zaten hazır olan offline review akışına (`ReviewView`, `ReviewSessionPlanner`, askıya alma) `ReviewScheduling` seam'i üzerinden bağlandı — **`ReviewView.swift`'te hiçbir değişiklik gerekmedi**. Python tarafı bu ortamda gerçekten çalıştırıldı (51 yeni test, hepsi geçiyor); Swift portu (`FSRSScheduler.swift`, 6 yeni test) **kullanıcı tarafından bir Mac'te `swift test` ile doğrulandı (2026-08-03, yeşil)**. Kalan (çıkış kapısını engellemiyor): bildirimler, süre-bütçeli hızlı mod, ayrı bir "yeni kart limiti". Ayrıntı: `docs/FAZ4-PLAN.md`. |
| Faz 5 — Sertleştirme | 🟡 Kod tamam; **gerçek iPhone testi 2026-08-03'te fiilen başladı** (kullanıcı kendi telefonunda çalıştırdı, gerçek bir sayfa çekti). **Bu oturumda telefon backend'e bağlandı** (Vercel cihaz tokenı girildi) ve **153/153 Swift testi kullanıcı tarafından doğrulandı** — önceki oturumun açık kalan en öncelikli maddesi kapandı. Kabul listesindeki 10 maddenin tamamı henüz koşulmadı ama süreçte dört gerçek hata bulunup düzeltildi — ayrıntı `docs/FAZ5-DURUM.md`. |

**Dal durumu:** `claude/project-review-issue-j0ycif` (bu oturumun dalı,
`main`'in `598b93c`'i üzerine). Önceki `main` durumu: `15e68b0`+PR #3/#4/#5,
2026-08-03.

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

**Test durumu:**
- Python (`evals/`): 503 test, yeşil — `python -m pytest evals -q` (bu
  oturumda gerçekten çalıştırıldı)
- Backend (`backend/`): **439 test**, yeşil — `npm test` (bu oturumda
  gerçekten çalıştırıldı; +2 bu oturumun prompt testleri, mevcut
  reconcile/ocrEndpoint testleri yeni davranışa göre güncellendi)
- Swift (`ios/CizgiCore/`): 153 test. **Kullanıcı bu oturumda `swift test`
  çalıştırdı, 153/153 yeşil** — önceki oturumun açık kalan riski (sütun
  tespitinin son 8 düzeltmesi hiç derlenmemişti) kapandı. **Dikkat:** bu
  doğrulamadan *sonra*, bu oturumda `BackendPipelineTests.swift`'teki bir
  örnek etiket metni (kaynak/okuma yön düzeltmesi için) değiştirildi —
  testin kendisi `reconcile.ts`'i çalıştırmıyor (sentetik veriyle kuruluyor),
  yani mantıken kırılması beklenmez, ama bu haliyle bir Mac'te henüz
  **kimse çalıştırmadı**. Sıradaki oturumda önce bu koşulmalı.

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`), uçtan uca
doğrulandı. **Telefon bu oturumda backend'e bağlandı** (Vercel cihaz tokenı
Ayarlar'a girildi) — kart üretimi artık Mock'tan gerçek yapay zekaya geçmiş
olmalı; bu oturumda yalnız reconcile.ts/prompt kod tarafı değişti, telefonun
güncellenmiş kodu henüz çalıştırmadığı unutulmamalı (yeni build gerekiyor).

## Kararlar (değiştirmeden önce oku)

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
python -m pytest evals -q                    # 503 test
cd ios/CizgiCore && swift test                # 153 test (153/153 Mac'te doğrulandı; bu oturumun etiket-metni değişikliği sonrası henüz yeniden koşulmadı, yukarı bak)
cd backend && npm test                        # 439 test
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
```

## Doküman haritası

- `docs/RUNBOOK.md` — nasıl çalıştırılır, sorun giderme
- `docs/ARCHITECTURE.md` — bileşenler, işlem hattı, anti-drift mekanizması
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

**En öncelikli:** bu oturumun değişikliklerini (ADR-003 + prompt v1.1)
Vercel'e dağıtıp telefonda aynı sayfayı yeniden çekmek — onay ekranının
artık Apple-Google gürültüsüyle tetiklenmediğini ve gerçek yapay zeka
kartlarının yeni prompt'la nasıl çıktığını gerçek kullanımda görmek.

1. Bu dal (`claude/project-review-issue-j0ycif`) merge edilip Vercel'in
   Production dağıtımı güncellenmeli (Production Branch ayarına dikkat —
   `backend/README.md`'deki tuzak). Sonra telefonda aynı "Tip 4
   hipersensitivite" sayfası yeniden çekilip davranış doğrulanmalı.
2. Bir Mac'te `cd ios/CizgiCore && swift test` — 153/153 bu oturumda
   doğrulandı ama sonrasında `BackendPipelineTests.swift`'te küçük bir örnek
   metin değişikliği yapıldı (kaynak/okuma yönü); yeniden koşulması ucuz ve
   kesinleştirir.
3. `docs/FAZ5-DURUM.md`'deki 10 maddelik iPhone kabul listesinin geri
   kalanını (bildirim, yedek, sınırlar, uçak modu) koş.
4. Gerçek maliyet takibi: `OPENAI_USD_PER_MILLION_*`/`GEMINI_USD_PER_MILLION_*`
   hâlâ 0 (uydurma rakam yok, §0.6) — sağlayıcının kendi fiyatlandırma
   sayfasından doldurulmalı.
5. Başarısız kart üretimi çağrıları için de bir `ModelRun` kaydı (şu an
   yalnız başarılı çağrılar kaydediliyor — `docs/FAZ3-PLAN.md`'de F3-8
   altında not edildi).
6. Faz 4'ün küçük kalanları: bildirimler (`AppSettings.notificationHour`
   var ama hiç `UNUserNotification` çağrısı yok), süre-bütçeli hızlı mod,
   ayrı bir "yeni kart limiti" ayarı (`docs/FAZ4-PLAN.md`).
7. (Düşük öncelik) Codex'in PR #5'te bulduğu 8. bulgu ertelendi: yarım sayfa
   genişliğinden dar ama yine de gerçek sütun boşluğunu kesen ortalanmış bir
   ayraç/başlık, boşluğu hâlâ gizleyebilir (`documentAI.ts`/`ReadingOrder.swift`
   içindeki `MAX_COLUMN_ITEM_WIDTH` sabitiyle ilgili — ayrıntı PR #5'in
   yorumlarında). Gerçek kullanımda düşük olasılık, kullanıcı kararıyla
   ertelendi.
8. (Düşük öncelik, ADR-003 "Açık kalan") `evals/ocr_eval/metrics.py`'deki
   manifest-tabanlı `critical_token_error_rate` ölçümü `hypo_hyper` için
   hâlâ tüm kelimeyi kıyaslıyor — altın-set ölçümünde aynı yanlış-pozitif
   görülürse `canonical_hypo_hyper` oraya da taşınmalı.
