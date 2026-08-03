# Çizgi backend

Sağlayıcı proxy'si (ANA-PLAN §7). Üç sağlayıcı var: **Google Document AI**
(Türkçe metnin birincil OCR'ı, `docs/ADR-002-birincil-ocr-secimi.md`),
**OpenAI** (kaynağa sadık kart üretimi, §11.2) ve **Gemini** (el yazısı ikinci
görüşü, §10.4 — yalnız gerçek uyuşmazlıkta çağrılır). OpenAI/Gemini tarafı Faz
3'te eklendi; kod ve testler hazır ama **gerçek bir anahtarla hiç
çağrılmadı** — ayrıntı ve kurulum: `docs/FAZ3-PLAN.md`,
`docs/OPENAI-GEMINI-KURULUM.md`.

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

## OpenAI/Gemini'yi tek bir gerçek çağrıyla sınamak (Faz 3)

Anahtarları `.env`'e koyduktan sonra (`docs/OPENAI-GEMINI-KURULUM.md`), gold
set ölçümüne geçmeden önce Document AI için yapılan aynı alışkanlık: tek bir
gerçek çağrı, gerçek bir sayfa olmadan yalnızca istek/yanıt şeklini sınamak
için.

```bash
npm run cards         # tek bir gerçek OpenAI kart üretimi çağrısı
npm run handwriting    # tek bir gerçek Gemini ikinci görüş çağrısı
```

İkisi de terminale yalnız metrik yazar (kart/span sayısı, token, maliyet,
hata durumunda sağlayıcının status kodu ve mesajı) — anahtarı veya tam
içeriği asla basmaz; tam yanıt `evals/reports/*-smoke-test.json`'a yazılır
(gitignore'lu). Bu araçlarla sahte bir anahtar denendiğinde Gemini'nin
`responseSchema`'sının `additionalProperties` anahtar kelimesini kabul
etmediği bulundu ve düzeltildi — ayrıntı `docs/FAZ3-PLAN.md`.

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
| `api/_auth.ts` | Cihaz tokenı doğrulaması (§7.3) |
| `api/_ocr.ts` | `POST /api/ocr` — saf handler, sunucudan bağımsız, testte doğrudan çağrılıyor |
| `api/_cards.ts` | `POST /api/cards` — kart üretimi uç noktası; zaten uzlaştırılmış `cleanText` bekler, OCR yapmaz |
| `api/index.ts` | Bileşim kökü; `DEVICE_TOKEN` ve `OPENAI_API_KEY`'e dokunan tek dosya; Vercel'in çalıştırdığı tek fonksiyon |
| `providers/ocrTypes.ts` | Motorlar arası ortak OCR sonucu biçimi |
| `providers/documentAI.ts` | Document AI sağlayıcısı |
| `providers/googleAuth.ts` | Google kimlik bilgisi kaynağı — yerelde dosya, dağıtımda satır içi JSON |
| `providers/openai.ts` | OpenAI Responses API sağlayıcısı — kaynağa sadık kart üretimi (§11.2, §14) |
| `providers/gemini.ts` | Gemini el yazısı ikinci görüşü — dar sözleşme, kart üretmez (§10.4, §15.3) |
| `providers/cardGate.ts` | Kart üretimi sonrası deterministik kalite kapısı (§19) |
| `prompts/*.ts` | Versiyonlanmış sistem promptları (§15.1–15.3), ANA-PLAN'dan birebir |
| `schemas/llmOutputTypes.ts` | §14 şemasının TypeScript karşılığı; `RiskFlag`/`CardType` Swift'le senkron tutuluyor |
| `schemas/validateLlmOutput.ts` | §14 şemasının ajv ile çalışma zamanı doğrulayıcısı |
| `vercel.json` | Tüm yollar `api/index.ts`'e yönlendirilir; diğer `api/` dosyaları rota olarak taranmaz |
| `scripts/serve.ts` | Yerel geliştirme sunucusu |
| `scripts/ocr.ts` | Yerel Document AI ölçüm aracı (üretim yolu değil) |
| `scripts/cards.ts` | `npm run cards` — tek bir gerçek OpenAI çağrısıyla istek/yanıt şeklini doğrular |
| `scripts/handwriting.ts` | `npm run handwriting` — tek bir gerçek Gemini çağrısıyla istek/yanıt şeklini doğrular |
| `scripts/token.ts` | Cihaz tokenı üretici |

`api/_auth.ts` ve `api/_ocr.ts` alt çizgiyle başlıyor: Vercel `api/` altındaki
her dosyayı ayrı bir uç nokta sanır, ama bu ikisi `index.ts`'in içeri aktardığı
sıradan modüller — kendi başlarına bir `Request`/`Response` işleyicisi
dışa vermiyorlar. Alt çizgi, Vercel'e "bu bir rota değil" demenin standart
yolu. `vercel.json`'daki `rewrites` de aynı nedenle var: telefon
`/api/ocr`'a, `/health`'e ayrı ayrı gidiyor gibi konuşuyor, ama gerçekte
hepsi `api/index.ts` içindeki tek işleyiciye düşüyor — kendi yol ayrımını o
yapıyor.

## Vercel'e dağıtım

Yerelde çalışan aynı `handler`, bir sunucusuz platformda da çalışır (§7.2).
Fark, kimlik bilgisinin nereden geldiği: laptopta bir dosya yolu var,
dağıtılan sunucuda o dosya yok — o yüzden orada anahtar bir ortam
değişkenine JSON olarak gömülür.

1. **Proje kökü.** Vercel projesinin "Root Directory" ayarını `backend`
   yap — depo `ios/` ve `backend/`'i birlikte tutuyor, Vercel yalnız
   ikincisini görmeli.
2. **Ortam değişkenleri.** Vercel proje ayarlarında (`.env` dosyası olarak
   değil — o depo dışında kalıyor):
   - `GOOGLE_PROJECT_ID`, `DOCUMENTAI_LOCATION`, `DOCUMENTAI_PROCESSOR_ID`,
     `DOCUMENTAI_LANGUAGE_HINTS` — `.env.example`'daki değerlerin aynısı, gizli değil.
   - `DOCUMENTAI_COMPUTE_STYLE_INFO` — Enterprise OCR'nin stil eklentisini
     (el yazısı/alt çizgi/arka plan rengi) kullanmak için ancak işlemci sürümü
     ve maliyet doğrulandıktan sonra `true`; varsayılan `false`.
   - `DEVICE_TOKEN` — `npm run token` çıktısı.
   - `GOOGLE_CREDENTIALS_JSON` — indirdiğin servis hesabı dosyasının **tüm
     içeriği**, tek satır JSON olarak. `GOOGLE_APPLICATION_CREDENTIALS`
     burada **kullanılmaz**: o bir dosya yolu ister, dağıtılan sunucuda o
     dosya yok.
     ```bash
     # Dosyayı tek satıra çevirip panoya kopyalar (macOS):
     cat ~/Desktop/kornokta-xxxxx.json | jq -c . | pbcopy
     ```
     `jq` yoksa: `python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))" dosya.json`
3. **Üretim dalı.** Settings → Git → "Production Branch", dağıtmak
   istediğin dal olmalı. Değilse push'lar **Preview** olarak dağıtılır ve
   `<proje>.vercel.app` eski sürümü servis etmeye devam eder — dağıtım
   "Ready" göründüğü hâlde. Tek dağıtımı yayına almak için: Deployments →
   ilgili satır → `...` → "Promote to Production".
4. **Dağıt.** `backend/` içinden `vercel deploy` (veya Vercel'in GitHub
   entegrasyonu, push'ta otomatik dağıtır).
5. **Doğrula.** Yayındaki adresle:
   ```bash
   curl https://<proje>.vercel.app/health          # {"ok":true}
   curl https://<proje>.vercel.app/api/ocr         # 405, "Yalnızca POST."
   curl -X POST https://<proje>.vercel.app/api/ocr # 401, "Yetkisiz."
   ```
   Bu üçü birlikte anlamlı: `/api/ocr`'ın 405 vermesi bağımlılıkların
   kurulabildiğini, yani ortam değişkenlerinin eksiksiz ve
   `GOOGLE_CREDENTIALS_JSON`'ın ayrıştırılabilir olduğunu gösterir.
   Token'sız POST'un **401** (500 değil) dönmesi `DEVICE_TOKEN`'ın
   tanımlı ve yeterince uzun olduğunu gösterir — `api/_auth.ts` tanımsız
   token'ı sunucu hatası sayar.

   Uçtan uca son sınama, gerçek token ve gerçek bir sayfayla:
   ```bash
   curl -X POST https://<proje>.vercel.app/api/ocr \
     -H "Authorization: Bearer $DEVICE_TOKEN" \
     -H 'Content-Type: application/json' \
     -d "{\"jobId\":\"deneme\",\"mimeType\":\"image/jpeg\",\"imageBase64\":\"$(base64 -i bir-sayfa.jpg)\"}"
   ```
   Yalnız bu adım Google kimlik doğrulamasının gerçekten çalıştığını
   gösterir; yukarıdakiler JSON'ın ayrıştığını gösterir, jetonun
   alınabildiğini değil.

### İlk dağıtımda çıkan tuzaklar

Hepsi gerçek bir dağıtımda yaşandı ve düzeltildi:

- **`vercel.json` → `functions`** altındaki girdi boş obje olamaz
  (`"api/index.ts": {}` → "Function must contain at least one property").
  `maxDuration` verilmiş durumda.
- **Dışa aktarım biçimi.** `export default handler` **çalışmaz**: Vercel
  bunu eski `(req, res) => void` imzası sanar ve döndürülen `Response`'u
  yok sayar; istek yanıtsız kalıp zaman aşımına düşer. Doğrusu
  `export default { fetch: handler }`. Aynı yanlış biçim, ayrı bir hata
  gibi görünen `ERR_INVALID_URL`'e de yol açıyordu: eski imzada ilk
  argüman Node `IncomingMessage`'dır ve `.url`'i mutlak değil, çıplak
  yoldur. `tests/router.test.ts` bu biçimi sabitliyor.
- **Production Branch** (yukarıda 3. madde) — en çok zaman kaybettiren
  madde, çünkü hata mesajı vermez.

## Henüz yok

- Transkripsiyon uzlaştırmasının Gemini'ye yükselmesi (§5.2 adım 5) — bugün
  `providers/reconcile.ts` tamamen deterministik, Gemini sağlayıcısı yazıldı
  ama hiçbir akışa bağlı değil
- Fotoğrafların işlem biter bitmez silinmesi (§7.3) — şu an istek belleği
  ötesinde hiçbir yerde tutulmuyor zaten (görüntü asla diske yazılmıyor),
  ama bu davranış henüz ayrı bir testle güvence altına alınmadı
- Gerçek OpenAI/Gemini token maliyeti — `OPENAI_USD_PER_MILLION_*`/
  `GEMINI_USD_PER_MILLION_*` hâlâ 0 (`docs/FAZ3-PLAN.md`)
- Başarısız kart üretimi çağrıları için iOS tarafında bir `ModelRun` kaydı
  (yalnız başarılı çağrılar kaydediliyor, `docs/FAZ3-PLAN.md`'de F3-8 altında)

Tamamlananlar (artık burada değil): gerçek bir OpenAI/Gemini anahtarıyla
canlı doğrulama, gold pasajlarla kart kalite rubriği ölçümü, iOS
istemcisinin `/api/cards`'ı çağırması ve `ModelRun` kaydı — bkz.
`docs/FAZ3-PLAN.md`.
