# Çizgi — Kişisel Tıbbi Hafıza Uygulaması

Kitapta işaretlenen (altı çizili / fosforlu) tıbbi bilgiyi fotoğraftan güvenli
biçimde yakalayan, kaynak-sadık öğrenme kartlarına dönüştüren ve bilgiyi FSRS
ile unutmadan önce yeniden soran **kişisel** iOS uygulaması.

> **⚠️ Yön değişikliği (2026-08-05, kod 2026-08-07'de tamamlandı) — Faz 6 / B:**
> Uygulama, kişisel kullanım için **vision-öncelikli** bir mimariye geçti:
> işaretli sayfa fotoğrafı doğrudan OpenAI vision modeline gider, model
> önemsenen kısmı okuyup zenginleştirilmiş kartları onaysız üretir. Bu,
> "kaynağa-sadık + onaylı" omurgayı kişisel kullanım için bilinçle gevşetir.
> Neden ve plan:
> [`docs/ADR-005-kisisel-vision-yeniden-tasarim.md`](docs/ADR-005-kisisel-vision-yeniden-tasarim.md),
> [`docs/FAZ6-PLAN.md`](docs/FAZ6-PLAN.md). Güncel akışın şeması:
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

Ana şartname:
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md)
— tüm ürün, mimari ve kalite kararlarının kaynağıdır.

**Yeni bir oturuma (Claude Code veya başka biri) başlıyorsan önce
[`CLAUDE.md`](CLAUDE.md)'yi oku** — güncel durum, açık kararlar ve sıradaki
adım oranın tek kaynağıdır; buradaki tablo yalnız kaba bir özettir.

## Mevcut durum (2026-08-07)

| Faz | Kapsam | Durum |
|---|---|---|
| **Faz 0** | Risk azaltma — OCR/işaret ölçüm altyapısı, Apple Vision'ın Türkçe desteklemediğinin kanıtlanması | ✅ Tamam |
| **Faz 1** | Yerel uygulama iskeleti — SwiftData, kuyruk, durum makinesi, sahte kart üretimi | ✅ Tamam |
| **Faz 2** | Bulut OCR (Google Document AI), işaret tespiti, uzlaştırma, onay ekranı | ✅ Kod tamam — ama **Faz 6'da ana akıştan çıktı**; kod geri dönüş için duruyor, çağrılmıyor. Bkz. `docs/FAZ2-PLAN.md` |
| **Faz 3** | AI kart üretimi (OpenAI Structured Outputs) | ✅ Tamam; kart yolu Faz 6'da v2'ye (vision) revize edildi. Bkz. `docs/FAZ3-PLAN.md` |
| **Faz 4** | FSRS tekrar motoru | ✅ Gerçek FSRS-6 (Python referansı + Swift portu). Bildirimler, günlük yeni kart limiti ve süre bütçeli hızlı oturum dahil. Bkz. `docs/FAZ4-PLAN.md` |
| **Faz 5** | Sertleştirme | ✅ Tamam; kabul listesi kullanıcının iPhone'unda 2026-08-07'de koşuldu. Bkz. `docs/FAZ5-DURUM.md` |
| **Faz 6** | Vision-öncelikli kişisel yeniden tasarım (B) | ✅ **Tamam ve cihazda doğrulandı.** Tek vision çağrısı + Supabase asenkron iş kuyruğu (ADR-006). Bkz. `docs/FAZ6-PLAN.md`, `docs/ADR-005`, `docs/ADR-006` |
| Galeriden fotoğraf ekleme | İçe aktarılan fotoğrafın JPEG + düz yöne normalize edilmesi | ✅ Tamam ve cihazda doğrulandı. Bkz. `docs/PLAN-galeriden-foto.md` |
| **Faz 7** | Beş şıklı (TUS tipi) kart | 🟡 Kod `main`'de; kalan iş distraktör kalitesinin gerçek sayfayla denenmesi (A6). Bkz. `docs/FAZ7-PLAN-coktan-secmeli.md` |

Backend gerçek bir Vercel dağıtımında canlı; kart üretimi `POST /api/jobs` →
Supabase iş kuyruğu → OpenAI vision üzerinden asenkron çalışıyor ve gerçek
cihazla uçtan uca doğrulandı. Test durumunun güncel sayıları ve hangi ortamda
koşulduğu [`CLAUDE.md`](CLAUDE.md) "Test durumu" bölümünde.

## Repo yapısı

Ana plan §26'daki yapı izlenir:

```text
├── ios/          # SwiftUI uygulaması — CizgiCore (mantık) + App (arayüz)
├── backend/      # Vercel Functions — Google Document AI proxy'si, dağıtık
├── evals/        # Altın test seti, OCR/işaret metrikleri, spike'lar
│   ├── gold-manifest.json         # Altın set manifesti
│   ├── gold-manifest.schema.json  # Manifest JSON şeması
│   ├── fixtures/                  # Gerçek sayfa görselleri — YEREL, commit edilmez
│   ├── ocr_eval/                  # Metrikler, kritik token, doğrulayıcı, raporlar
│   ├── card_quality/               # §23.3 kart kalite rubriği + toplama aracı (Faz 3 çıkış kapısı)
│   ├── fsrs/                       # FSRS-6 referans algoritması (Faz 4)
│   ├── spikes/                    # marker_detection (işaret tespiti referansı)
│   └── tests/                     # pytest birim testleri (503 test)
└── docs/         # Mimari, gizlilik, faz planları, kurulum rehberleri
```

## Değerlendirme araçlarını çalıştırma

```bash
pip install -r evals/requirements.txt
python -m pytest evals                                    # 503 test
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json
```

## iOS mantığını test etme

```bash
cd ios/CizgiCore && swift test                             # 136 test (hepsi Mac'te doğrulandı)
```

## Backend'i çalıştırma

```bash
cd backend && npm install && npm test                      # 419 test
npm run serve                                               # yerel sunucu, 127.0.0.1:8787
```

Ayrıntı ve Vercel'e dağıtım: [`backend/README.md`](backend/README.md).

## Güvenlik kuralları (bağlayıcı — ana plan §0, §7.3, §24.6)

- **API anahtarı repoya veya iOS uygulamasına asla konmaz.** Anahtarlar
  yalnız backend ortam değişkenlerinde (Vercel env / yerel `.env`, gitignore'lu)
  yaşar.
- `evals/fixtures/` içine **telifli kitap sayfası commit edilmez**; gerçek
  görseller yerelde tutulur (`.gitignore` ile korunur).
- Sunucu loglarında görüntü içeriği veya tam OCR metni saklanmaz.
- Hasta verisi hiçbir akışta işlenmez; içerik yalnız kişisel eğitim içindir.
- Cihaz tokenı (`DEVICE_TOKEN`) yalnız iki yerde durur: backend ortam
  değişkeni ve telefonun Keychain'i. Üçüncü kopya yok.
