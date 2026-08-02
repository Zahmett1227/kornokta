# Mac'te 20 görsel — Faz 2 çıkış kapısı ölçümü

Bu belge Faz 2'nin kalan tek kalemi için **senin** uygulayacağın adımları içerir
(`docs/FAZ2-PLAN.md`, "Ölçüm hâlâ eksik"). Kod ve dağıtım tarafı zaten
doğrulandı — bu ölçüm, gerçek sayfalarla üç şeyi kanıtlayacak:

1. İşaret tespitinin gerçek sayfalarda **tek-dokunuş oranı** (§25 Faz 2 kapısı)
2. Apple Vision satır kutularının **geometrik olarak güvenilir** olup olmadığı
   — metni Türkçe okumuyor, ama kutuları doğru yere mi oturuyor? F2-6 buna
   dayanıyor
3. Google Document AI'ın gerçek sayfalarda, özellikle el yazısında, ne kadar
   iyi okuduğu

> **Önceki sürümden fark:** Bu belge daha önce "Apple Vision'a mı Google'a mı
> geçelim" kararını sormak için yazılmıştı. O karar verildi
> (`docs/ADR-002-birincil-ocr-secimi.md`) — Google birincil. Adımlar artık
> ona göre ve doğru sırada: **önce** Vision çalıştırılıyor (satır kimlikleri
> üretmesi için), **sonra** etiketleme yapılıyor — tersi mümkün değil, çünkü
> etiketlerken referans aldığın `line_XX` kimlikleri Vision'ın kendi çıktısı.

---

## Adım 0 — Depoyu güncelle (2 dk)

```bash
cd ~/Desktop/kornokta
git pull origin claude/tibbi-hafiza-app-04elp1
source .venv/bin/activate   # yoksa: python3 -m venv .venv && source .venv/bin/activate && pip install -r evals/requirements.txt
python -m pytest evals -q
```

Beklenen: tüm testler geçer. Geçmezse buradan devam etme, bana yaz.

---

## Adım 1 — 20 görsel çek, GERÇEK işaretle (30–45 dk)

Kendi kitaplarından, kendi işaretleme tarzınla. **Fosforlu kalem, tükenmez alt
çizgi, kurşun kalem alt çizgisi gerçekten çekilmiş sayfalar olmalı** — işaret
tespiti ölçülüyor, işaretsiz bir sayfa hiçbir şey ölçmez.

| Adet | Kategori | Klasör |
|---:|---|---|
| 8 | Basılı + fosforlu kalem | `evals/fixtures/highlight/` |
| 4 | Basılı + tükenmez alt çizgi | `evals/fixtures/underline/` |
| 3 | Kurşun kalem alt çizgisi | `evals/fixtures/pencil/` |
| 3 | Basılı + kenar el yazısı notu | `evals/fixtures/margin/` |
| 2 | Kötü açı / gölge / düşük ışık | `evals/fixtures/poor/` |

Kurallar:
- **Doz, birim, yön (sağ/sol), olumsuzluk veya uygulama yolu içeren pasajlar
  seç.** Ölçmek istediğimiz tam olarak bunlar; düz tanım cümleleri az bilgi
  verir.
- Hasta bilgisi içeren hiçbir şey çekme.
- Aynı sayfayı iki kez çekme.
- Dosya adları sade olsun: `highlight_01.jpg`, `pencil_03.jpg` gibi.
- HEIC çekiyorsan sorun değil — Adım 2'deki araçlar ikisini de okuyor.

Görseller `.gitignore` ile korunuyor; repoya gitmez.

---

## Adım 2 — Apple Vision'ı çalıştır (10 dk)

Bunu **etiketlemeden önce** yapıyoruz: gold veriye gireceğin `line_XX`
kimlikleri, aşağıdaki komutun ürettiği kimlikler olacak.

```bash
cd ~/Desktop/kornokta/ios/spikes/AppleVisionSpike
swift build -c release
mkdir -p ../../../evals/reports

.build/release/AppleVisionSpike \
  --input ../../../evals/fixtures \
  --output ../../../evals/reports/vision.json
cd ../../..
```

---

## Adım 3 — Google Document AI'ı çalıştır (5–10 dk)

Aynı 20 görsel, bu sefer gerçek OCR kaynağından.

```bash
cd ~/Desktop/kornokta/backend
source .env
npm run ocr -- --input ../evals/fixtures --output ../evals/reports/google.json
cd ..
```

Her sayfa için `OK   dosya.jpg  satır=N  NNNN ms` satırı basmalı. Hata
verirse (`DEVICE_TOKEN` ya da `GOOGLE_APPLICATION_CREDENTIALS` ile ilgili
olabilir) bana yapıştır.

---

## Adım 4 — Etiketle (60–90 dk, en yorucu kısım)

Her görsel için `evals/gold-manifest.json`'daki `entries` dizisine bir girdi
ekle. Önce Vision'ın o görsel için ne bulduğuna bak — `line_XX` kimliklerini
oradan alacaksın:

```bash
python3 -c "
import json
run = json.load(open('evals/reports/vision.json'))
for page in run['pages']:
    if 'highlight_01.jpg' in page['imagePath']:   # kendi dosya adını yaz
        for l in page['lines']:
            print(l['lineId'], repr(l['text']))
"
```

Vision'ın metni muhtemelen yanlış olacak (Türkçe okumuyor) — önemli değil,
yalnız hangi `line_XX`'in fiziksel olarak işaretlediğin satıra denk geldiğini
bulmak için bakıyorsun (konum ve sıraya göre anlaşılır).

Şablon:

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

1. `exactTranscription` — **birebir** yaz. Kitapta ne yazıyorsa o: virgül
   ondalık ayracı, uzun tire, `İ`/`ı` farkı, `IM`/`IV` büyük harfi. Bunu
   Vision'ın çıktısından değil, kitabın kendisinden yaz — Vision Türkçe
   okumuyor.
2. `criticalTokens` — anlamı değiştirecek her şey. Aday üretmek için:

```bash
python -c "
from evals.ocr_eval.critical_tokens import detect_critical_tokens as d
print([(t.text, t.token_class) for t in d('BURAYA TRANSKRİPSİYONU YAPIŞTIR')])
"
```

Çıkanları gözden geçir, eksik olanı (özellikle ilaç/mikroorganizma adları)
elle ekle.

`poor_capture` kategorisindeki 2 görsel için `expectedOutcome` muhtemelen
`needs_confirmation` ya da `reject` olacak — kötü çekim zaten öyle
tasarlandı.

Doğrula:

```bash
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json --check-files
```

`ERROR` kalmamalı. `WARN` satırları 100'lük hedef kotaya göredir, 20 görselde
normal.

---

## Adım 5 — Puanla (5 dk)

İki ayrı ölçüm, iki ayrı soruyu cevaplıyor.

**İşaret tespiti — tek-dokunuş oranı ve Vision'ın satır kutusu güvenilirliği:**

```bash
python -m evals.ocr_eval.gold_marker_report --vision evals/reports/vision.json
```

**OCR/el yazısı kalitesi — Google'ın gerçek sayfalarda ne kadar doğru
okuduğu:**

```bash
python -m evals.ocr_eval.vision_report evals/reports/google.json --verbose
```

(Bu araç adından "vision" görünse de motor bağımsızdır — yalnız
`pages[].lines[].text` şeklini okur, hangi motorun ürettiğine bakmaz. Aynı
komutu `vision.json`'a karşı da çalıştırıp iki motoru karşılaştırabilirsin.)

---

## Adım 6 — Sonucu bana ilet

Üç şeyi yapıştır:

1. `gold_marker_report`'un özet satırları (tek-dokunuş %, ulaşılabilir %,
   yanlış-pozitif sayısı)
2. `vision_report --verbose` çıktısındaki kritik uyuşmazlıklar — hangi tür
   hatalar çıkmış
3. Google OCR çalıştırırken görünen gecikmeler (`npm run ocr` çıktısındaki
   `ms` değerleri)

**Not:** Düşük bir tek-dokunuş oranı her zaman kod hatası demek değil —
`config.json`'daki eşikler "ilk kalibrasyon başlangıcı" (§9.3), gerçek
veriyle güncellenmesi bekleniyor. `gold_marker_report`'un ayırdığı
yanlış-pozitif/yanlış-negatif ayrımı burada önemli: yanlış-pozitif
(işaretlenmemiş bir satırın onaysız seçilmesi) ciddi bir sorun, yanlış-negatif
(işaretli bir satırın tek dokunuşta yakalanamaması) yalnızca eşiklerin sıkı
olduğunu gösterir.

---

## Yapmayacağın şeyler

- iOS uygulamasına yeni ekran ekleme. Faz 2 çıkış kapısı geçilmeden yeni
  kapsam yok (ANA-PLAN §0.9, §25).
- 100 görseli tek seferde etiketleme. Önce 20, sonra ölçüm, sonra karar.
- Gerçek hasta bilgisi içeren hiçbir görsel çekme veya etiketleme.
