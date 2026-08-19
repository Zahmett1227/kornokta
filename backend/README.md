# Çizgi backend

Sağlayıcı proxy'si (ANA-PLAN §7). Ana sağlayıcı **OpenAI** — işaretli
sayfa fotoğrafını vision modeliyle okuyup kartları üretir (Faz 6, ADR-005).
Kart üretimi normalde asenkron bir iş kuyruğu üzerinden yürür (`/api/jobs`,
ADR-006); `/api/cards-vision` senkron ikinci kapı olarak duruyor. Üçüncü,
küçük ve isteğe bağlı kapı **Gemini**: `/api/second-opinion`, `lowConfidence`
bir kart için kullanıcının istediği bağımsız ikinci okuma (aşağıda).

> Google Document AI / OCR-uzlaştırma katmanı **2026-08-09 tıraşında silindi**
> (ADR-005'in "kod diskte duruyor" notu artık geçerli değil; geri dönüş = o
> commit'in revert'i). Eski kurulum belgesi `docs/GOOGLE-CLOUD-KURULUM.md`
> yalnız tarihsel kayıttır. Gemini ise 2026-08-11'de çok daha dar bir rolle
> geri döndü — anahtar edinme adımları için `docs/OPENAI-GEMINI-KURULUM.md`
> hâlâ geçerli.

## Neden var

API anahtarı uygulamanın içine konulamaz (§0.7, §7.3). Telefon backend'e
konuşur; `OPENAI_API_KEY` ve Supabase servis anahtarı yalnızca burada durur.

## Kurulum

```bash
cd backend
npm install
cp .env.example .env
```

`.env` içinde doldurulacaklar: `OPENAI_API_KEY`, `DEVICE_TOKEN`
(`npm run token` üretir), iş kuyruğu için `SUPABASE_URL` +
`SUPABASE_SERVICE_ROLE_KEY`, ikinci görüş için (isteğe bağlı)
`GEMINI_API_KEY`. Diğer değerler hazır geliyor ve gizli değil.

## Test

Ağ ve anahtar gerektirmez — sağlayıcılar sahte taşıyıcılar üzerinden sürülür.

```bash
npm run typecheck
npm test
```

## OpenAI'yi tek bir gerçek çağrıyla sınamak

```bash
npm run cards         # tek bir gerçek OpenAI kart üretimi çağrısı
```

Terminale yalnız metrik yazar (kart sayısı, token, maliyet; hata durumunda
sağlayıcının status kodu) — anahtarı veya tam içeriği asla basmaz; tam yanıt
`evals/reports/*-smoke-test.json`'a yazılır (gitignore'lu).

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

Yalnız `127.0.0.1`'e bağlanır — süreç gerçek anahtarlar tutuyor, her arayüze
açmak onları bulunduğun ağa açardı.

Cevaplar her zaman `retryable` alanı taşır: telefon geçici bir arızayı kuyruğa
alıp tekrar denemeli, kalıcı olanı denememeli (§17).

## Asenkron iş kuyruğu — `/api/jobs` (docs/ADR-006)

Telefonun kullandığı ana yol. `/api/cards-vision` telefondan, modelin sürdüğü
1–5 dakika boyunca tek bir bağlantıyı açık tutmasını istiyordu; hiçbir telefon
bunu güvenilir biçimde yapamıyor (ekran kilitleniyor → iOS uygulamayı askıya
alıyor → yükleme zaman aşımıyla ölüyor). Burada bekleme telefondan çıkıyor:

```
POST /api/jobs   → sayfa Storage'a yazılır, satır 'queued', 202 döner (saniyeler)
                   üretim yanıttan SONRA, waitUntil altında devam eder
GET  /api/jobs?ids=<uuid>[,<uuid>…]
                 → { "jobs": [ { jobId, status, result?, error?, retryable? } ] }
```

`status`: `queued` | `processing` | `ready` | `failed`. `result`, biten bir işte
`/api/cards-vision`'ın gövdesinin aynısıdır — telefon aynı çözücüyü kullanır.

`jobId` **UUID olmak zorunda** (Postgres birincil anahtarı) ve telefonun sayfa
kimliğidir; aynı sayfa ikinci kez gönderilirse yeni bir iş açılmaz, biten iş
varsa sonucu doğrudan döner. İşi tekrar başlatan bir cron yok — Hobby planında
cron günde bir kez — onun yerine telefonun zaten yaptığı yoklamalar hem
kuyrukta unutulmuş bir işi başlatıyor hem de işleyeni ölmüş bir işi geri
alıyor. Aynı yoklamalara binen üçüncü bir süpürme, biten (`ready`/`failed`)
satırların sonuç metnini **60 gün** sonra siliyor
(`SUPABASE_RESULT_RETENTION_MS`, docs/PRIVACY.md).

Gereken ortam değişkenleri (`.env.example`'daki Supabase bloğu):
`SUPABASE_URL` ve `SUPABASE_SERVICE_ROLE_KEY`. İkincisi RLS'i tamamen atlar —
depoya girmez, yalnız yerel `.env` ve Vercel proje ayarları. `SUPABASE_URL`
boşsa diğer uçlar hiç etkilenmez, yalnız `/api/jobs` hangi değişkenin eksik
olduğunu söyleyerek reddeder.

## İkinci görüş — `POST /api/second-opinion` (2026-08-11)

"Gözden geçir"deki `lowConfidence` bir kart için telefonun **istek üzerine**
çağırdığı uç: kartın kaynak sayfası (telefonda saklanan orijinal; sunucunun
kopyası çoktan silinmiş olur) + kartın kendisi gönderilir, **Gemini** —
bilinçli olarak kartı üreten sağlayıcıdan farklı bir model ailesi, çünkü
ikinci görüşün değeri bağımsızlığında — ilgili bölgeyi yeniden okur ve
`supports | contradicts | unclear` verdiktiyle bağımsız transkripsiyonu
döndürür. Kart üretmez (prompt v2.0 yasaklar, şemada yeri yok); cevap hiçbir
yere kaydedilmez, telefon o an gösterir.

Gövde: `{ requestId, mimeType, imageBase64, card: { front, back,
explanation? } }`. Cevap: `{ requestId, verdict, reading, note?, usage,
promptVersion }`.

Gereken tek ortam değişkeni `GEMINI_API_KEY`; boşsa yalnız bu uç hangi
değişkenin eksik olduğunu söyleyerek reddeder, kart üretimi hiç etkilenmez
(`SUPABASE_URL`/`/api/jobs` ilişkisinin aynısı). **Kota/kredi biterse hata
mesajı bunu açıkça söyler** ("kota/kredi tükenmiş görünüyor …
aistudio.google.com'dan kontrol et") — OpenAI tarafında da `insufficient_quota`
aynı netlikte raporlanır; ikisi de sahibinin şartı (2026-08-11): bir 429'un
"model meşgul" mü "bakiye bitti" mi olduğu asla aranarak bulunmasın.

## Karanlık Harita — `POST /api/dark-map` (2026-08-19, docs/ADR-009)

Telefonun **istek üzerine** çağırdığı dördüncü kapı, ve diğerlerinin tersi bir
soru sorar: *hangi kanonik konuda hiç kartım yok, ve hangileri TUS'ta pahalıya
mal oluyor?*

Gövde: `{ requestId, coverage: [{ subject, topic, cardCount, weakCardCount?,
sampleFronts? }], subjects?, maxZones? }` — telefon yalnız **kartı olan**
çiftleri gönderir. Cevap iki cinsten oluşur ve bu ayrım bilerektir:

- `untouched` — hiç kartı olmayan kanonik konuların **tam** listesi. Sunucu
  kendi kanonik listesinden sıfır doldurur, yani telefonun anmadığı konu boş
  sayılır; eksik rapor eden bir istemci bir konuyu ancak *daha karanlık*
  gösterebilir. Model çağrısından **önce** üretilir.
- `zones` — ince konular arasında öncelik sıralaması. **İki model ailesi** (aynı
  prompt, iki ayrı çağrı, birbirini görmeden) sıralar; ikisinin de işaretlediği
  konu `confirmed`, tekinin `disputed`. Ayrıca `raters[]`, `singleRater` ve iki
  satırlık `usage` defteri (`purpose: "dark_map"`).

**Model konu icat edemez:** `topicKey` (= `Ders|Konu`) her iki ailenin yanıt
şemasında 143 değerli bir **enum**'dur — kartın `topic` alanındaki üç katmanın
aynısı (şema enum'u + prompt Kural 1 + `sanitizeRatings`). Kimlik daima çifttir,
çünkü altı konu adı iki ders altında birden geçer.

`GEMINI_API_KEY` yoksa uç **tek sıralayıcıyla** çalışır (`singleRater: true`,
her bölge `disputed`) — reddetmez. İki aile de düşerse **5xx** döner, boş
`zones` ile 200 değil: boş sıralama "karanlık yer yok" diye okunur.

Veritabanına dokunmaz, hiçbir şey yazmaz, görüntü taşımaz — bu yüzden kuyruğa
(ADR-006) binmez ve `jobs` tablosuna sütun eklemez. Bütün ayarları kod
varsayılanlı (`DARK_MAP_*`), yani canlıya hiçbir değişken girmeden çalışır.

**Migration sırası (kural):** `jobs` tablosuna sütun ekleyen bir değişiklik
**dağıtımdan önce** canlıya uygulanmalı. Yeni kod sütunu yazar; sütun yoksa
PostgREST `insert`'i reddeder ve her çekim patlar. Migration'lar sırayla
çalışır ve **hiçbiri geçmiş bir dosyayı düzenleyerek** eklenmez (Codex, PR #27
P1): bugüne kadar `max_cards`, `mc_mode` ve `subject` böyle eklendi.

Şema migration'larda: `jobs` tablosu + `page-uploads` özel kovası, ikisinde
de RLS açık ve **policy yok** (yani yalnız servis anahtarı geçer). Sayfa
baytları iş bitince siliniyor — §7.3'ten verilen bilinçli tavizin sınırı,
ADR-006'da yazılı.

## Yapı

| Dosya | İş |
|---|---|
| `config.ts` | Tüm ayarlar tek yerde, ortamdan okunur (§0.6). Kimlik bilgisi buraya girmez. |
| `api/_auth.ts` | Cihaz tokenı doğrulaması (§7.3) |
| `api/_image.ts` | Görüntü alım yardımcıları (boyut sınırı, katı base64 çözümü) |
| `api/_cards.ts` | `POST /api/cards-vision` — senkron kart üretimi; saf handler, testte doğrudan çağrılıyor |
| `api/_jobs.ts` | `POST/GET /api/jobs` — asenkron iş kuyruğu (ADR-006) + saklama süpürmesi |
| `api/_secondOpinion.ts` | `POST /api/second-opinion` — lowConfidence kart için istek üzerine Gemini ikinci okuması |
| `api/_darkMap.ts` | `POST /api/dark-map` — kapsama boşluğu; deterministik `untouched` + çift aileli `zones` (ADR-009) |
| `providers/coverage.ts` | Karanlık Harita'nın sayılabilir yarısı: kanonik listeden sıfır doldurma, `topicKey` kodlaması, prompt tablosu |
| `providers/darkMap.ts` | İki sıralayıcı (OpenAI + Gemini, aynı prompt) + `sanitizeRatings` + `mergeRankings` mutabakat kapısı |
| `api/index.ts` | Bileşim kökü; `DEVICE_TOKEN`, `OPENAI_API_KEY`, `GEMINI_API_KEY` ve Supabase anahtarına dokunan tek dosya; Vercel'in çalıştırdığı tek fonksiyon |
| `providers/openai.ts` | OpenAI Responses API sağlayıcısı — vision kart üretimi (§11.2, §14) |
| `providers/gemini.ts` | Gemini generateContent sağlayıcısı — ikinci görüş (§10.4'ün Faz 6 hali); kota/kredi bitişini adıyla raporlar |
| `providers/cardGate.ts` | Kart üretimi sonrası deterministik sağlık kapısı (Faz 6'da auto-accept + `lowConfidence` işaretleme) |
| `providers/multipleChoice.ts` | Beş şıklı kartın yapısal doğrulaması (§13.3) |
| `providers/subjectTopics.ts` | Ders/konu şeması + konu sanitizasyonu (şema v2.2) |
| `providers/turkish.ts` | Türkçe normalizasyon yardımcıları (ADR-001) |
| `providers/supabaseJobs.ts` | PostgREST/Storage üzerinden iş deposu; tüm yazmalar koşullu (ADR-006) |
| `prompts/*.ts` | Versiyonlanmış sistem promptları (§15.1), ANA-PLAN'dan birebir |
| `schemas/llmOutputTypes.ts` | §14 şemasının TypeScript karşılığı; `RiskFlag`/`CardType` Swift'le senkron tutuluyor |
| `schemas/validateLlmOutput.ts` | §14 şemasının ajv ile çalışma zamanı doğrulayıcısı |
| `vercel.json` | Tüm yollar `api/index.ts`'e yönlendirilir; diğer `api/` dosyaları rota olarak taranmaz |
| `scripts/serve.ts` | Yerel geliştirme sunucusu |
| `scripts/cards.ts` | `npm run cards` — tek bir gerçek OpenAI çağrısıyla istek/yanıt şeklini doğrular |
| `scripts/token.ts` | Cihaz tokenı üretici |

`api/_auth.ts` gibi alt çizgiyle başlayan dosyalar: Vercel `api/` altındaki
her dosyayı ayrı bir uç nokta sanır, ama bunlar `index.ts`'in içeri aktardığı
sıradan modüller. Alt çizgi, Vercel'e "bu bir rota değil" demenin standart
yolu. `vercel.json`'daki `rewrites` de aynı nedenle var: telefon
`/api/jobs`'a, `/health`'e ayrı ayrı gidiyor gibi konuşuyor, ama gerçekte
hepsi `api/index.ts` içindeki tek işleyiciye düşüyor — kendi yol ayrımını o
yapıyor.

## Vercel'e dağıtım

1. **Proje kökü.** Vercel projesinin "Root Directory" ayarını `backend`
   yap — depo `ios/` ve `backend/`'i birlikte tutuyor, Vercel yalnız
   ikincisini görmeli.
2. **Ortam değişkenleri.** Vercel proje ayarlarında (`.env` dosyası olarak
   değil — o depo dışında kalıyor): `OPENAI_API_KEY`, `DEVICE_TOKEN`,
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` ve `.env.example`'daki
   isteğe bağlı ayarlar. (Eski dağıtımlarda duran `GOOGLE_*`/`DOCUMENTAI_*`/
   `GEMINI_*` değişkenleri zararsızdır; kod artık okumaz.)
3. **Üretim dalı.** Settings → Git → "Production Branch", dağıtmak
   istediğin dal olmalı. Değilse push'lar **Preview** olarak dağıtılır ve
   `<proje>.vercel.app` eski sürümü servis etmeye devam eder — dağıtım
   "Ready" göründüğü hâlde. Tek dağıtımı yayına almak için: Deployments →
   ilgili satır → `...` → "Promote to Production".
4. **Dağıt.** `backend/` içinden `vercel deploy` (veya Vercel'in GitHub
   entegrasyonu, push'ta otomatik dağıtır).
5. **Doğrula.** Yayındaki adresle:
   ```bash
   curl https://<proje>.vercel.app/health              # {"ok":true}
   curl https://<proje>.vercel.app/api/jobs            # 401, "Yetkisiz."
   ```
   Token'sız isteğin **401** (500 değil) dönmesi `DEVICE_TOKEN`'ın tanımlı ve
   yeterince uzun olduğunu gösterir — `api/_auth.ts` tanımsız token'ı sunucu
   hatası sayar.

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

- Başarısız kart üretimi çağrıları için iOS tarafında bir `ModelRun` kaydı
  (yalnız başarılı çağrılar kaydediliyor, `docs/FAZ3-PLAN.md`'de F3-8 altında)
