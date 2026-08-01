# Mimari

> Taslak — ayrıntılar için ana kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §7 (teknik mimari), §16 (veri modeli), §17 (iş kuyruğu ve durum makinesi).

## Bileşenler

- **iOS istemci** (`ios/`): Swift 6+, SwiftUI, SwiftData, Vision/VisionKit, Core Image. Yakalama, yerel OCR önizleme, işaret tespiti, kuyruk, FSRS tekrar. Faz 1'de başlar.
- **Backend** (`backend/`): Vercel Functions. Sağlayıcı anahtarlarını saklar, Google Document AI / OpenAI / Gemini çağrılarını orkestre eder, §14 kanonik şemasını doğrular, maliyet kaydeder. Faz 3'te başlar. Kalıcı veri kaynağı değildir; ana veri iPhone'daki SwiftData'dadır.
- **Evals** (`evals/`): Altın test seti, OCR/işaret metrikleri, model karşılaştırma araçları. Faz 0'ın merkezi; sonraki fazlarda regresyon kapısı olarak kalır.

## İşlem hattı (özet)

```text
kamera/fotoğraf → yerel sayfa düzeltme → Apple Vision OCR → işaret tespiti
  → Google Document AI OCR → uzlaştırma → [onay | kart üretimi (GPT-5.6 Sol)]
  → kalite doğrulama → [onay | hazır] → SwiftData + FSRS
```

Durum makinesi ve hata dalları: ANA-PLAN §17. Tüm adımlar idempotent; tekrar planlama LLM'siz, deterministik kodda (§0.8, P6).

## Kanonik sözleşmeler

- LLM çıktı sözleşmesi: [`backend/schemas/llm_output.schema.json`](../backend/schemas/llm_output.schema.json) (ANA-PLAN §14)
- Altın set manifesti: [`evals/gold-manifest.schema.json`](../evals/gold-manifest.schema.json) (ANA-PLAN §23.1)
- Model kimlikleri ve eşikler merkezi config'te tutulur, koda gömülmez (§0.6, §11.3). Faz 0 spike eşikleri: [`evals/spikes/marker_detection/config.json`](../evals/spikes/marker_detection/config.json)
