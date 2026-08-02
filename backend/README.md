# Çizgi backend

Sağlayıcı proxy'si (ANA-PLAN §7). Şu an tek sağlayıcı var: **Google Document AI**,
Türkçe metnin birincil OCR'ı (`docs/ADR-002-birincil-ocr-secimi.md`).

## Neden var

Apple Vision Türkçe'yi desteklemiyor — 148 satırlık gerçek bir sayfada `ı ş ğ İ`
harflerini sıfır kez üretti (`docs/FAZ0-BULGULAR.md`). Metnin kaynağı artık
Google Document AI.

Backend'in ikinci sebebi: API anahtarı uygulamanın içine konulamaz (§0.7, §7.3).
Telefon backend'e konuşur, anahtar yalnızca burada durur.

## Kurulum

Google Cloud tarafı için önce `docs/GOOGLE-CLOUD-KURULUM.md`.

```bash
cd backend
npm install
cp .env.example .env
```

`.env` içinde doldurulacak tek satır:

```
GOOGLE_APPLICATION_CREDENTIALS=/indirdiğin/anahtarın/tam/yolu.json
```

Diğer değerler (proje, işlemci, bölge) hazır geliyor ve gizli değil.

> Anahtar dosyasını depo klasörünün **dışında** tut. `.gitignore` yaygın
> desenleri engelliyor ama en güvenlisi dosyanın orada hiç bulunmaması.

## Test

Ağ ve anahtar gerektirmez — sağlayıcı, sahte bir taşıyıcı üzerinden sürülüyor.

```bash
npm run typecheck
npm test
```

## Gerçek bir sayfayı okutmak

```bash
npm run ocr -- --input ../evals/fixtures/deneme --output ../evals/reports/google.json
```

İlk denemede `--limit 1` koy: kurulumun doğru olduğunu tek sayfa maliyetine
öğrenirsin.

Çıktı, Apple Vision spike'ının yazdığı JSON ile **aynı biçimde**, yani mevcut
puanlayıcı ikisini de okur:

```bash
cd ..
python -m evals.ocr_eval.vision_report evals/reports/google.json
```

### HEIC uyarısı

iPhone varsayılan olarak HEIC çekiyor ve Document AI bunu kabul etmiyor. Araç
bunu fark edip söylüyor. macOS'ta çevirmek için:

```bash
mkdir -p evals/fixtures/deneme-jpg
sips -s format jpeg evals/fixtures/deneme/*.HEIC --out evals/fixtures/deneme-jpg
```

## Yapı

| Dosya | İş |
|---|---|
| `config.ts` | Tüm ayarlar tek yerde, ortamdan okunur (§0.6). Kimlik bilgisi buraya girmez. |
| `providers/ocrTypes.ts` | Motorlar arası ortak OCR sonucu biçimi |
| `providers/documentAI.ts` | Document AI sağlayıcısı |
| `scripts/ocr.ts` | Yerel ölçüm aracı (üretim yolu değil) |

## Henüz yok

- HTTP uç noktası ve cihaz tokenı (§7.3) — telefon şu an backend'e bağlanmıyor
- Maliyet kaydı ve bütçe sınırı uygulaması (§11) — sadece çalıştırma öncesi tahmin var
- Kart üretimi sağlayıcısı (§13) — Faz 3
