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

## Şu an neredeyiz (2026-08-02)

| Faz | Durum |
|---|---|
| Faz 0 — Risk azaltma | ✅ Tamam |
| Faz 1 — Yerel uygulama iskeleti | ✅ Tamam |
| Faz 2 — Bulut OCR + işaret tespiti | ✅ Kod ve dağıtım tamam. **Çıkış kapısı (20 görüntülük altın set ölçümü) kullanıcı tarafından bilinçli olarak atlandı** — sebep ve araçlar `docs/FAZ2-PLAN.md`'de. Eşikler hâlâ "ilk kalibrasyon". |
| Faz 3 — AI kart üretimi | 🔶 Backend tarafı yazıldı, test edildi, **ve gerçek bir OpenAI/Gemini anahtarıyla uçtan uca doğrulandı** (gerçek kart, gerçek transkripsiyon). İki gerçek hata bu sırada bulundu ve düzeltildi (OpenAI şema `type` zorunluluğu, model reasoning token'larının `max_output_tokens`'tan düşmesi). iOS istemci entegrasyonu (`BackendCardProvider`, `ModelRun` kaydı) da yazıldı — **ama bu ortamda Swift derleyicisi olmadığı için bir Mac'te `swift test` ile henüz doğrulanmadı**. Kalan: o doğrulama, gold pasaj kart kalite rubriği ölçümü (çıkış kapısı). Ayrıntı: `docs/FAZ3-PLAN.md`. |
| Faz 4 — FSRS tekrar motoru | Başlamadı |
| Faz 5 — Sertleştirme | Başlamadı |

**Dal durumu:** `main` Faz 2 sonrasıyla (`ccf5985`) aynı. Faz 3'ün backend
kodu `claude/proje-analizi-planlama-r7lxw4` dalında, henüz `main`'e
alınmadı. Önceki oturumlar `claude/faz1-ios-iskelet` ve
`claude/tibbi-hafiza-app-04elp1` dallarında çalıştı, bunlar zaten `main`'e
ileri sarılmıştı.

**Test durumu:**
- Python (`evals/`): 435 test, yeşil — `python -m pytest evals -q`
- Swift (`ios/CizgiCore/`): 114 test **gerçek bir Mac'te doğrulandı** (2026-08-02);
  Faz 3 istemci entegrasyonuyla birlikte **+16 yeni test yazıldı (130 toplam),
  bu ortamda derleyici olmadığı için henüz Mac'te çalıştırılmadı** — `swift test`
- Backend (`backend/`): 418 test, yeşil — `npm test`

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
python -m pytest evals -q                    # 435 test
cd ios/CizgiCore && swift test                # 130 test (114'ü Mac'te doğrulandı, +16'sı henüz değil)
cd backend && npm test                        # 418 test
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
```

## Doküman haritası

- `docs/RUNBOOK.md` — nasıl çalıştırılır, sorun giderme
- `docs/ARCHITECTURE.md` — bileşenler, işlem hattı, anti-drift mekanizması
- `docs/FAZ2-PLAN.md` — Faz 2'nin tam kaydı: ne yapıldı, hangi hatalar
  bulundu/düzeltildi, çıkış kapısının neden atlandığı
- `docs/FAZ3-PLAN.md` — Faz 3'ün tam kaydı: backend'de ne yazıldı, hangi
  tasarım kararları alındı, çıkış kapısının neden henüz ölçülemediği
- `docs/OPENAI-GEMINI-KURULUM.md` — OpenAI/Gemini anahtarlarını edinme adımları
- `docs/MAC-ADIMLARI.md` — altın set ölçümü istenirse adım adım rehber
  (araçlar hazır, hiç çalıştırılmadı)
- `backend/README.md` — backend yapısı, Vercel dağıtımında çıkan gerçek
  tuzaklar ve çözümleri
- `ios/README.md` — iOS yapısı, cihazda elle kontrol listesi
- `docs/PRIVACY.md`, `docs/MODEL-CARD.md` — gizlilik kuralları, model stratejisi
- `docs/FAZ0-*.md`, `docs/FAZ1-DURUM.md` — tarihsel kayıtlar (güncel durum
  için değil, o anki karar gerekçelerini görmek için)

## Sıradaki iş: Faz 3 — AI kart üretimi devamı

Backend tarafı yazıldı VE gerçek anahtarla uçtan uca doğrulandı
(`docs/FAZ3-PLAN.md`): config, promptlar, §14 şema doğrulayıcı, kart kalite
kapısı, OpenAI/Gemini sağlayıcıları, `POST /api/cards`, `npm run
cards`/`npm run handwriting`. iOS istemcisi de yazıldı (`BackendCardProvider`,
`ModelRun` kaydı §16.8, `CapturePipeline`/`ProcessingQueue`/`AppEnvironment`
bağlaması) — ayrıntı ve nelerin eklendiği `docs/FAZ3-PLAN.md`'nin "F3-8"
bölümünde. Sırada:

1. **`cd ios/CizgiCore && swift test` bir Mac'te.** Bu ortamda Swift
   derleyicisi yok; F3-8'in kodu ve +16 yeni testi hiç çalıştırılmadı. Önce bu
   — hata çıkarsa bir sonraki oturuma o hatayla gelinmeli, "çalışıyor"
   varsayılmamalı.
2. Gold pasajlarla kart kalite rubriği ölçümü — çıkış kapısı (§25): "Gold
   pasajlardan üretilen kartların kalite rubriği kabul sınırını geçmelidir."
3. Gerçek maliyet takibi: `OPENAI_USD_PER_MILLION_*`/`GEMINI_USD_PER_MILLION_*`
   hâlâ 0 (uydurma rakam yok, §0.6) — sağlayıcının kendi fiyatlandırma
   sayfasından doldurulmalı.
4. Başarısız kart üretimi çağrıları için de bir `ModelRun` kaydı (şu an
   yalnız başarılı çağrılar kaydediliyor — `docs/FAZ3-PLAN.md`'de F3-8
   altında not edildi).
