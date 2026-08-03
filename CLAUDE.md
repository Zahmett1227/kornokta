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
| Faz 5 — Sertleştirme | Başlamadı |

**Dal durumu:** `main` Faz 2 sonrasıyla (`ccf5985`) aynı. Faz 3/4'ün kodu
`claude/proje-analizi-planlama-r7lxw4` dalında, henüz `main`'e alınmadı.
Önceki oturumlar `claude/faz1-ios-iskelet` ve `claude/tibbi-hafiza-app-04elp1`
dallarında çalıştı, bunlar zaten `main`'e ileri sarılmıştı.

**Test durumu:**
- Python (`evals/`): 503 test, yeşil — `python -m pytest evals -q`
- Swift (`ios/CizgiCore/`): 136 test, **kullanıcı tarafından gerçek bir Mac'te
  doğrulandı (2026-08-03), hepsi yeşil** — `swift test`
- Backend (`backend/`): 419 test, yeşil — `npm test`

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`), uçtan uca
doğrulandı — gerçek bir kitap sayfası fotoğrafı Google Document AI'dan doğru
Türkçe metinle döndü (`ı ş ğ İ ü ö ç` dahil).

## Kararlar (değiştirmeden önce oku)

- **`docs/ADR-002-birincil-ocr-secimi.md`** — Apple Vision Türkçe metin
  tanımayı desteklemiyor (ölçüldü, `docs/FAZ0-BULGULAR.md`). Google Document
  AI birincil ve tek metin kaynağı; Vision yalnız önizleme + satır geometrisi
  için kullanılıyor. Bunu tersine çevirecek bir değişiklik yapmadan önce bu
  ADR'yi oku.
- **`docs/ADR-001-hibrit-turkce-morfoloji.md`** — Türkçe normalizasyon
  (İ/ı büyük-küçük harf, NFC, diyakritik katlama) kararı.
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
cd ios/CizgiCore && swift test                # 136 test (hepsi Mac'te doğrulandı)
cd backend && npm test                        # 419 test
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

Eskiden tek gerçek engelleyici olan `swift test` doğrulaması **2026-08-03'te
kullanıcı tarafından bir Mac'te yapıldı: 136/136 test yeşil.** Faz 3 ve Faz 4
artık ikisi de kod + test + Mac doğrulaması tamam. Kalan hiçbir kalem Faz
3/4'ün çıkış kapılarını engellemiyor — hepsi ne zaman istenirse ele alınabilir:

1. Gerçek maliyet takibi: `OPENAI_USD_PER_MILLION_*`/`GEMINI_USD_PER_MILLION_*`
   hâlâ 0 (uydurma rakam yok, §0.6) — sağlayıcının kendi fiyatlandırma
   sayfasından doldurulmalı.
2. Başarısız kart üretimi çağrıları için de bir `ModelRun` kaydı (şu an
   yalnız başarılı çağrılar kaydediliyor — `docs/FAZ3-PLAN.md`'de F3-8
   altında not edildi).
3. Faz 4'ün küçük kalanları: bildirimler (`AppSettings.notificationHour`
   var ama hiç `UNUserNotification` çağrısı yok), süre-bütçeli hızlı mod,
   ayrı bir "yeni kart limiti" ayarı (`docs/FAZ4-PLAN.md`).
4. Faz 5 — Sertleştirme (retry/idempotency, background recovery, maliyet
   sert limitleri, veri dışa aktarma) henüz başlamadı.
5. `main` dalı hâlâ Faz 2 sonrasıyla aynı — Faz 3/4'ün kodu
   `claude/proje-analizi-planlama-r7lxw4`'te. `main`'e alma (merge/PR) henüz
   kullanıcıdan istenmedi.
