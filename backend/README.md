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

## HTTP ucu (telefonun konuştuğu yer)

Önce bir cihaz tokenı üret — telefonun "bu benim" demesini sağlayan uzun
rastgele değer (§7.3):

```bash
npm run token
```

Çıkan değeri `.env` içinde `DEVICE_TOKEN=` satırına yapıştır. Aynı değer sonra
iPhone'un Keychain'ine de girecek. **Üçüncü bir kopya bırakma.**

Sunucuyu başlat:

```bash
npm run serve
```

Yalnız `127.0.0.1`'e bağlanır — süreç bir Google anahtarı tutuyor, her arayüze
açmak onu bulunduğun ağa açardı.

Denemek için:

```bash
curl http://127.0.0.1:8787/health

curl -X POST http://127.0.0.1:8787/api/ocr \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"jobId\":\"deneme\",\"mimeType\":\"image/jpeg\",\"imageBase64\":\"$(base64 -i bir-sayfa.jpg)\"}"
```

Cevaplar her zaman `retryable` alanı taşır: telefon geçici bir arızayı kuyruğa
alıp tekrar denemeli, kalıcı olanı denememeli (§17).

## Yapı

| Dosya | İş |
|---|---|
| `config.ts` | Tüm ayarlar tek yerde, ortamdan okunur (§0.6). Kimlik bilgisi buraya girmez. |
| `api/auth.ts` | Cihaz tokenı doğrulaması (§7.3) |
| `api/ocr.ts` | `POST /api/ocr` — saf handler, sunucudan bağımsız, testte doğrudan çağrılıyor |
| `api/index.ts` | Bileşim kökü; `DEVICE_TOKEN`'a dokunan tek dosya |
| `providers/ocrTypes.ts` | Motorlar arası ortak OCR sonucu biçimi |
| `providers/documentAI.ts` | Document AI sağlayıcısı |
| `scripts/serve.ts` | Yerel geliştirme sunucusu |
| `scripts/ocr.ts` | Yerel ölçüm aracı (üretim yolu değil) |
| `scripts/token.ts` | Cihaz tokenı üretici |

## Henüz yok

- Vercel'e dağıtım (§7.2) — şu an yalnız yerelde çalışıyor
- Kritik token motoru ve OCR uzlaştırma (§10.3, §10.5) — Faz 2'nin sonraki adımı
- Maliyet kaydı ve bütçe sınırı uygulaması (§11) — sadece çalıştırma öncesi tahmin var
- Kart üretimi sağlayıcısı (§13) — Faz 3
