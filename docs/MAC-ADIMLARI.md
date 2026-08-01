# Mac'te ilk 20 görsel ve Apple Vision denemesi

Bu belge Faz 0'ın kalan kısmı için **senin** uygulayacağın adımları içerir. Test altyapısı yeterli; buradan sonrası gerçek veri.

Hedef: 20 görselle Apple Vision'ın gerçek performansını ölçmek ve eşikleri kalibre etmek. 100'lük tam set bu 20'den sonra, ölçüm mantıklı çıkarsa toplanır.

---

## Adım 0 — Depoyu al (5 dk)

```bash
git clone https://github.com/Zahmett1227/kornokta.git
cd kornokta
git checkout claude/tibbi-hafiza-app-04elp1
python3 -m venv .venv && source .venv/bin/activate
pip install -r evals/requirements.txt
python -m pytest evals -q
```

Beklenen: tüm testler geçer. Geçmezse buradan devam etme, bana yaz.

---

## Adım 1 — 20 görsel çek (30–45 dk)

Kendi kitaplarından, kendi işaretleme tarzınla. Dağılım:

| Adet | Kategori | Klasör |
|---:|---|---|
| 8 | Basılı + fosforlu kalem | `evals/fixtures/highlight/` |
| 4 | Basılı + tükenmez alt çizgi | `evals/fixtures/underline/` |
| 3 | Kurşun kalem alt çizgisi | `evals/fixtures/pencil/` |
| 3 | Basılı + kenar el yazısı notu | `evals/fixtures/margin/` |
| 2 | Kötü açı / gölge / düşük ışık | `evals/fixtures/poor/` |

Kurallar:
- **Doz, birim, yön (sağ/sol), olumsuzluk veya uygulama yolu içeren pasajlar seç.** Ölçmek istediğimiz şey tam olarak bunlar; düz tanım cümleleri az bilgi verir.
- Hasta bilgisi içeren hiçbir şey çekme.
- Aynı sayfayı iki kez çekme.
- Dosya adları sade olsun: `highlight_01.jpg`, `pencil_03.jpg` gibi.

Görseller `.gitignore` ile korunuyor; repoya gitmez.

---

## Adım 2 — Etiketle (60–90 dk, en yorucu kısım)

Her görsel için `evals/gold-manifest.json` içindeki `entries` dizisine bir girdi ekle. Şablon:

```json
{
  "id": "gold_003",
  "category": "printed_highlight",
  "imagePath": "fixtures/highlight/highlight_01.jpg",
  "status": "annotated",
  "expectedOutcome": "auto_accept",
  "sourceMeta": { "subject": "Farmakoloji", "topic": "Anafilaksi", "bookAlias": "kitap-a" },
  "captureConditions": { "lighting": "good", "angle": "flat" },
  "goldSelectedLines": [
    {
      "lineId": "line_04",
      "text": "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
      "selectionType": "highlight",
      "markerType": "highlighter",
      "markerColor": "yellow"
    }
  ],
  "exactTranscription": "Anafilakside ilk seçenek 0,3–0,5 mg IM adrenalindir.",
  "criticalTokens": [
    { "token": "0,3–0,5", "tokenClass": "number_decimal" },
    { "token": "mg", "tokenClass": "unit" },
    { "token": "IM", "tokenClass": "route" },
    { "token": "adrenalin", "tokenClass": "drug_name" }
  ],
  "handwriting": [],
  "acceptableCards": [
    { "type": "direct_recall", "front": "Anafilakside ilk seçenek tedavi nedir?", "back": "0,3–0,5 mg IM adrenalin.", "sourceLineIds": ["line_04"] },
    { "type": "cloze", "front": "Anafilakside ilk seçenek ___ mg IM adrenalindir.", "back": "0,3–0,5", "sourceLineIds": ["line_04"] }
  ],
  "rejectCardExamples": [
    { "front": "Adrenalin hangi reseptörlere etki eder?", "back": "α1, β1, β2", "rejectReason": "not_answerable_from_source" }
  ]
}
```

**En kritik iki alan:**

1. `exactTranscription` — **birebir** yaz. Kitapta ne yazıyorsa o: virgül ondalık ayracı, uzun tire, `İ`/`ı` farkı, `IM`/`IV` büyük harfi. Buradaki her sapma ölçümü bozar.
2. `criticalTokens` — anlamı değiştirecek her şey. Aday üretmek için:

```bash
python -c "
from evals.ocr_eval.critical_tokens import detect_critical_tokens as d
print([(t.text, t.token_class) for t in d('BURAYA TRANSKRİPSİYONU YAPIŞTIR')])
"
```

Çıkanları gözden geçir, eksik olanı (özellikle ilaç/mikroorganizma adları) elle ekle.

Doğrula:

```bash
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json --check-files
```

`ERROR` kalmamalı. `WARN` satırları kota eksikliğidir, 20 görselde normal.

---

## Adım 3 — Apple Vision denemesini çalıştır (10 dk)

```bash
cd ios/spikes/AppleVisionSpike
swift build -c release
mkdir -p ../../../evals/reports

.build/release/AppleVisionSpike \
  --input ../../../evals/fixtures \
  --output ../../../evals/reports/vision.json
cd ../../..
```

Xcode'da açmak istersen `Package.swift` dosyasını `File > Open…` ile aç.

---

## Adım 4 — Puanla (5 dk)

```bash
python -m evals.ocr_eval.vision_report evals/reports/vision.json
python -m evals.ocr_eval.vision_report evals/reports/vision.json --verbose
```

Çıktı her görsel için CER, WER ve kritik token kapısı sonucu verir.

---

## Adım 5 — Sonuca bak, birlikte karar verelim

Bana şu üç şeyi ilet:

1. **Özet satırı** — kaç görsel kapıyı geçti, ortalama CER/WER
2. **`--verbose` çıktısındaki kritik uyuşmazlıklar** — hangi tür hatalar çıkmış
3. **Gecikme** — medyan ve en yüksek ms

Kabaca ne beklediğimiz:

| Durum | Anlamı | Sonraki adım |
|---|---|---|
| Kapıyı geçen ≥ %80, CER < 0,05 | Apple Vision basılı metinde yeterli | 100'lük sete geç |
| Kapıyı geçen %50–80 | Sınırda; hataların türüne bakalım | Eşik kalibrasyonu veya Google OCR karşılaştırması |
| Kapıyı geçen < %50 | Tek başına Vision yetmiyor | Google Document AI'yı öne al (§10.2) |

**Not:** Kapıda kalmak her zaman OCR hatası demek değil. Etiketlemede birebir olmayan bir transkripsiyon da kapıda kalır. `--verbose` çıktısındaki uyuşmazlık gerçekten OCR hatası mı, yoksa senin etiketin mi — ilk 20'de ikisini de göreceğiz, bu normal.

---

## Yapmayacağın şeyler

- iOS uygulaması yazmaya başlama. Faz 0 çıkış kapıları geçilmeden ekran yok (ANA-PLAN §0.9, §25).
- 100 görseli tek seferde etiketleme. Önce 20, sonra ölçüm, sonra karar.
- API anahtarı gerektiren hiçbir şey çalıştırma; bu adımların hepsi cihaz üstünde ve ücretsiz.
