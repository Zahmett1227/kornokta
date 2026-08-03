# Mimari

> Ayrıntılar için ana kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §7 (teknik mimari), §16 (veri modeli), §17 (iş kuyruğu ve durum makinesi).

## Bileşenler

- **iOS istemci** (`ios/`): Swift 6+, SwiftUI, SwiftData, Vision/VisionKit, Core Image. Yakalama, yerel OCR önizleme (satır kutuları için — metin için değil, bkz. aşağı), cihaz üstü işaret tespiti, kuyruk, gerçek kart üretimi istemcisi (Faz 3), gerçek FSRS-6 tekrarı (Faz 4). Faz 1'de başladı, Faz 2-4'te tamamlandı; hepsi bir Mac'te `swift test` ile doğrulandı.
- **Backend** (`backend/`): Vercel Functions. Google kimlik bilgisini saklar, Document AI çağrısını yapar, iki motorun okumasını uzlaştırır, kritik token karşılaştırması yapar, OpenAI/Gemini ile kart üretir (Faz 3). Dağıtık ve uçtan uca doğrulandı. Kalıcı veri kaynağı değildir; ana veri iPhone'daki SwiftData'dadır.
- **Evals** (`evals/`): Altın test seti, OCR/işaret metrikleri, model karşılaştırma araçları, FSRS-6 referans algoritması (Faz 4). Faz 0'da kuruldu; sonraki fazlarda regresyon kapısı olarak kalıyor (503 Python testi).

## Apple Vision yalnız önizleme ve geometri için — metin için değil

`docs/ADR-002-birincil-ocr-secimi.md`: Apple Vision Türkçe metin tanımayı
**desteklemiyor** (`ı ş ğ İ` sıfır kez üretiyor, ölçüldü). Bu yüzden:

- Vision'ın **metni** hiçbir zaman karta gitmiyor — yalnız canlı önizleme ve
  işaret tespitinin çalıştığı satır kutuları için kullanılıyor.
- Google Document AI **birincil ve tek metin kaynağı**.
- İki motorun satırları farklı numaralandığı için (`line_00` her ikisinde de
  farklı fiziksel satırı gösterebilir) eşleştirme id ile değil, **geometrik
  örtüşmeyle (IoU)** yapılıyor — hem backend'de hem iOS'ta aynı eşik (0.3).

## İşlem hattı (özet)

```text
kamera/fotoğraf → yerel sayfa düzeltme → Apple Vision (önizleme + satır geometrisi)
  → cihaz üstü işaret tespiti → Google Document AI OCR (backend) → uzlaştırma
  → [onay | kart üretimi (OpenAI/Gemini, Faz 3)] → kalite doğrulama → [onay | hazır] → SwiftData + FSRS-6 (Faz 4)
```

Durum makinesi ve hata dalları: ANA-PLAN §17. Tüm adımlar idempotent; tekrar planlama LLM'siz, deterministik kodda (§0.8, P6).

## Aynı davranış iki yerde — anti-drift disiplini

Kritik token motoru hem Python'da (referans, `evals/ocr_eval/critical_tokens.py`)
hem TypeScript'te (backend, üretimde çalışan) var. İşaret tespiti hem Python'da
(`evals/spikes/marker_detection/`) hem Swift'te (`ios/CizgiCore/Sources/CizgiCore/MarkerDetection/`)
var. İkisinin ayrışmaması için:

- Regex kalıpları Python'dan üretilip `backend/providers/criticalTokenPatterns.json`'a yazılıyor.
- Davranış, Python'dan üretilen paylaşılan vaka dosyalarıyla (`evals/shared/*.json`) her iki dilde de sabitleniyor.
- Eşikler (`evals/spikes/marker_detection/config.json`) byte-birebir aynı kopya olarak `ios/CizgiCore/Sources/CizgiCore/Resources/`'a taşınıyor; bir Python testi ayrışırsa kırılıyor.
- Her üretici `--check` modunda çalışıp CI'da doğrulanıyor.

## Kanonik sözleşmeler

- LLM çıktı sözleşmesi: [`backend/schemas/llm_output.schema.json`](../backend/schemas/llm_output.schema.json) (ANA-PLAN §14)
- Altın set manifesti: [`evals/gold-manifest.schema.json`](../evals/gold-manifest.schema.json) (ANA-PLAN §23.1)
- Model kimlikleri ve eşikler merkezi config'te tutulur, koda gömülmez (§0.6, §11.3). Faz 0 spike eşikleri: [`evals/spikes/marker_detection/config.json`](../evals/spikes/marker_detection/config.json)
