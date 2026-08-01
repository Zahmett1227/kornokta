# Çizgi — Kişisel Tıbbi Hafıza Uygulaması

Kitapta işaretlenen (altı çizili / fosforlu) tıbbi bilgiyi fotoğraftan güvenli biçimde yakalayan, el yazısını gerektiğinde çoklu doğrulamadan geçiren, kaynak-sadık öğrenme kartlarına dönüştüren ve bilgiyi FSRS ile unutmadan önce yeniden soran **kişisel** iOS uygulaması.

Ana şartname: [`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) — tüm ürün, mimari ve kalite kararlarının kaynağıdır.

## Mevcut durum: Faz 0 — Risk azaltma

Ana plan §25 ve §32 uyarınca önce alt çizgi / OCR / el yazısı riski çözülür; ürün ekranlarına henüz yatırım yapılmaz. Bu repoda şu an:

- **Altın test seti manifest şeması** ve doğrulayıcısı (`evals/`)
- **OCR/işaret değerlendirme metrikleri** (CER, WER, kritik token hata oranı, seçim P/R/F1)
- **Kritik token detektörü** (ana plan §10.5 sınıfları)
- **İşaret algılama spike'ı** (fosforlu/alt çizgi, OpenCV; sentetik görüntülerle test edilebilir)
- **Sağlayıcı karşılaştırma iskeleti** (ana plan §27; anahtarlar yalnız env üzerinden)
- **Apple Vision spike'ı** (`ios/spikes/AppleVisionSpike/`) ve çıktısını puanlayan `vision_report`
- **Faz 0 çalışma planı**: [`docs/FAZ0-PLAN.md`](docs/FAZ0-PLAN.md)
- **Durum özeti**: [`docs/FAZ0-STATUS.md`](docs/FAZ0-STATUS.md)
- **Mac'te sıradaki adımlar**: [`docs/MAC-ADIMLARI.md`](docs/MAC-ADIMLARI.md)
- **Altın set çekim/etiketleme rehberi**: [`docs/GOLD-SET-GUIDE.md`](docs/GOLD-SET-GUIDE.md)
- **Türkçe morfoloji kararı**: [`docs/ADR-001-hibrit-turkce-morfoloji.md`](docs/ADR-001-hibrit-turkce-morfoloji.md)

iOS (`ios/`) ve backend (`backend/`) dizinleri şimdilik iskelettir; Faz 0 çıkış kapıları geçilmeden doldurulmayacaktır.

## Repo yapısı

Ana plan §26'daki yapı izlenir:

```text
├── ios/          # SwiftUI uygulaması (Faz 1+)
├── backend/      # Vercel Functions, sağlayıcı orkestrasyonu (Faz 3+)
│   └── schemas/  # Kanonik LLM çıktı sözleşmesi (§14) — şimdiden tanımlı
├── evals/        # Altın test seti, metrikler, spike'lar (Faz 0 — aktif)
│   ├── gold-manifest.json         # Altın set manifesti (başlangıç)
│   ├── gold-manifest.schema.json  # Manifest JSON şeması
│   ├── fixtures/                  # Gerçek sayfa görselleri — YEREL, commit edilmez
│   ├── ocr_eval/                  # Metrikler, normalizasyon, kritik token, doğrulayıcı
│   ├── card-quality/              # Kart kalite rubriği (§23.3)
│   ├── spikes/                    # Faz 0 risk azaltma prototipleri
│   └── tests/                     # pytest birim testleri
└── docs/         # Mimari, gizlilik, Faz 0 planı, rehberler
```

## Değerlendirme araçlarını çalıştırma

Gereksinimler: Python 3.11+

```bash
pip install -r evals/requirements.txt

# Tüm birim testleri
python -m pytest evals

# Manifesti şemaya ve tutarlılık kurallarına karşı doğrula
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json

# İşaret algılama spike'ını sentetik görüntüyle dene
python -m evals.spikes.marker_detection.run --demo
```

## Güvenlik kuralları (bağlayıcı — ana plan §0, §7.3, §24.6)

- **API anahtarı repoya veya iOS uygulamasına asla konmaz.** Anahtarlar yalnız backend ortam değişkenlerinde yaşar; spike betikleri anahtarları sadece env'den okur.
- `evals/fixtures/` içine **telifli kitap sayfası commit edilmez**; gerçek görseller yerelde tutulur (`.gitignore` ile korunur).
- Loglarda görüntü içeriği veya tam OCR metni saklanmaz.
- Hasta verisi hiçbir akışta işlenmez; içerik yalnız kişisel eğitim içindir.
