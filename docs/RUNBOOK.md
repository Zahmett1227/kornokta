# Runbook

> Taslak — Faz 0 itibarıyla yalnız değerlendirme araçları çalışır durumdadır.

## Geliştirme ortamı

```bash
# Python bağımlılıkları (evals)
pip install -r evals/requirements.txt

# Tüm testler
python -m pytest evals

# Manifest doğrulama
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json

# İşaret algılama spike'ı — sentetik demo
python -m evals.spikes.marker_detection.run --demo

# Sağlayıcı karşılaştırma — kuru çalıştırma (anahtar gerektirmez)
python -m evals.spikes.provider_compare.run --dry-run
```

## Anahtar yönetimi

- Sağlayıcı anahtarları yalnız ortam değişkenlerinden okunur: `GOOGLE_APPLICATION_CREDENTIALS`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`.
- `.env` dosyaları gitignore'ludur; asla commit edilmez.
- iOS uygulamasına hiçbir anahtar gömülmez (Faz 3'te backend token akışı: ANA-PLAN §7.3).

## Sorun giderme

- `pytest` içe aktarma hatası verirse repo kökünden çalıştırıldığından emin olun (`python -m pytest evals`).
- OpenCV kurulumu sorunluysa `opencv-python-headless` kullanın; spike Pillow tabanlı sentetik üreticiyle de çalışır.

Backend ve iOS operasyon bölümleri ilgili fazlarda eklenecek.
