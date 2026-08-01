# AppleVisionSpike

Faz 0 Apple Vision denemesi (ANA-PLAN §10.1, §25). Altın set görüntülerini cihaz üzerinde OCR'dan geçirir ve Python değerlendirme araçlarının puanlayacağı JSON üretir.

Bu bir uygulama değil, **ölçüm aracı**. Faz 0'ın amacı ekran yapmak değil, OCR kalitesini ölçmek.

## Gereksinim

- macOS 13+
- Xcode 15+ (veya yalnız komut satırı araçları)

## Çalıştırma

Xcode gerekmez:

```bash
cd ios/spikes/AppleVisionSpike
swift build -c release
.build/release/AppleVisionSpike \
  --input ../../../evals/fixtures/highlight \
  --output ../../../evals/reports/vision.json
```

Xcode'da açmak istersen: `File > Open…` ile `Package.swift` dosyasını seç. Şema otomatik oluşur; `Product > Run` için argümanları `Product > Scheme > Edit Scheme… > Arguments` altına gir.

## Seçenekler

| Seçenek | Varsayılan | Açıklama |
|---|---|---|
| `--input` | — | Görüntü dosyası veya klasör |
| `--output` | — | Yazılacak JSON |
| `--languages` | `tr-TR,en-US` | Tanıma dilleri |
| `--language-correction` | kapalı | Dil düzeltmesini açar |

**Dil düzeltmesi neden kapalı:** Vision'ın dil düzeltmesi metni sıradan sözcüklere doğru yeniden yazar. Bu tam olarak ANA-PLAN §0.5'in yasakladığı sessiz düzeltme — ilaç adını veya dozu, biz kaynakla karşılaştırmadan önce yaygın bir sözcüğe çevirebilir. Kalibrasyon sırasında etkisini görmek istersen `--language-correction` ile aç ve iki çıktıyı karşılaştır.

## Çıktı

`OCRRun` → sayfa listesi, her sayfada satırlar:

```json
{
  "lineId": "line_04",
  "text": "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
  "confidence": 0.94,
  "x": 0.08, "y": 0.31, "width": 0.84, "height": 0.03
}
```

Kutu koordinatları görüntüye göre normalize (0–1) ve **sol üst köşe** başlangıçlı — Vision'ın sol alt konvansiyonundan çevrildi ki işaret tespiti spike'ındaki `LineBox` ile aynı çerçevede olsun.

## Puanlama

```bash
python -m evals.ocr_eval.vision_report evals/reports/vision.json
python -m evals.ocr_eval.vision_report evals/reports/vision.json --verbose
```

Manifestteki `annotated` girdilerle eşleştirir (dosya adına göre) ve CER, WER ile üç ölçümlü kritik token kapısını raporlar. Çıkış kodu: kapıyı geçemeyen görüntü varsa `2`.
