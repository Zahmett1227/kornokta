# Faz 3 — AI kart üretimi

**Dal:** `claude/proje-analizi-planlama-r7lxw4` (Faz 2'nin üstüne)
**ANA-PLAN:** §25 Faz 3
**Çıkış kapısı:** Gold pasajlardan üretilen kartların kalite rubriği (§23.3) kabul sınırını geçmelidir.

---

## Neden bölünüyor

Faz 2'nin aynı gerekçesi burada da geçerli: §25 Faz 3'ü tek seferde yazmak
hiçbirini ayrı ayrı doğrulanamaz hale getirir (§0 "işi küçük ve doğrulanabilir
adımlara böl"). Sıra, sonraki adımın üstüne inşa edebileceği katmandan başlıyor.

| Adım | İş | Durum |
|---|---|---|
| **F3-1** | Merkezi config: OpenAI/Gemini model, eşik, maliyet alanları (§0.6, §11.3) | ✅ |
| **F3-2** | Versiyonlanmış prompt modülleri (§15.1–15.3, metin ANA-PLAN'dan birebir) | ✅ |
| **F3-3** | §14 şemasının çalışma zamanı doğrulayıcısı (ajv) + paylaşılan TS tipleri + anti-drift senkron testi | ✅ |
| **F3-4** | Kart üretimi sonrası deterministik kalite kapısı (§19) | ✅ |
| **F3-5** | OpenAI Responses API sağlayıcısı (kart üretimi) | ✅ kod + test; sahte anahtarla canlı istek şekli sınandı, **gerçek anahtarla hiç çağrılmadı** |
| **F3-6** | Gemini el yazısı ikinci görüş sağlayıcısı | ✅ kod + test; sahte anahtarla canlı denemede gerçek bir şema hatası bulundu ve düzeltildi (aşağıya bakın). **Hiçbir uç noktaya bağlı değil** (transkripsiyon uzlaştırması hâlâ tamamen deterministik) |
| **F3-7** | `POST /api/cards` uç noktası, router'a bağlı | ✅ |
| **F3-7.5** | Yerel canlı-doğrulama araçları (`npm run cards`, `npm run handwriting`) | ✅ — tek gerçek çağrı yapar, sahte anahtarla test edildi |
| **F3-8** | iOS istemci entegrasyonu (`/api/cards` çağrısı, `ModelRun` kaydı, onay ekranına bağlama) | ❌ başlamadı |
| **F3-9** | Gerçek bir OpenAI/Gemini anahtarıyla canlı doğrulama | 🔶 Anahtarlar kullanıcının yerelinde/Vercel'de; bu ortamda değil — sıradaki adım kullanıcının `npm run cards`/`npm run handwriting` çalıştırması |
| **F3-10** | Gold pasajlarla kart kalite rubriği ölçümü (§25 Faz 3 çıkış kapısı) | ❌ F3-9'a bağımlı |

---

## Ne yapıldı

### Config, prompt, şema (F3-1..F3-3)

- `backend/config.ts`: `OpenAIConfig`, `GeminiConfig`, ve maliyet alanları eklendi.
  Google Document AI provider'ıyla aynı disiplin: model kimliği, `reasoningEffort`,
  `maxOutputTokens`, `maxCardsPerKnowledgeUnit` hepsi ortam değişkeninden okunuyor,
  hiçbiri kodda gömülü değil (§0.6). Per-token fiyat alanları **varsayılan 0** —
  ANA-PLAN'ın yazıldığı tarihte (1 Ağustos 2026) doğrulanmış bir OpenAI/Gemini
  fiyatı yok; uydurma bir rakam koymaktansa maliyeti dürüstçe sıfır göstermek
  tercih edildi (Google'ın kendi `usdPer1000Pages` alanı için zaten kullanılan
  "referans, sözleşme değil" ilkesiyle aynı).
- `backend/prompts/{transcriptionVerification,cardGeneration,handwritingSecondOpinion}.ts`:
  §15.1/§15.2/§15.3 metinleri birebir kopyalandı (parafraze değil — "sessizce
  düzeltme yapma" gibi ifadeler ürünün güvenlik sözleşmesinin parçası). Her
  modül kendi `*_PROMPT_VERSION`'ını taşıyor (§15 "Prompt metinleri
  versiyonlanmalıdır"), config'te değil — metni değiştirip versiyonu unutmak
  iki ayrı düzenleme olamasın diye.
- `backend/schemas/llmOutputTypes.ts`: §14 şemasının TypeScript karşılığı.
  `RiskFlag`/`CardType` birer `as const` dizi olarak tutuluyor (bir literal
  union değil) çünkü çalışma zamanında gerçekten var olan bir liste gerekiyor —
  Swift tarafındaki ham değerli enum'larla aynı sebep.
- `backend/schemas/validateLlmOutput.ts`: `llm_output.schema.json`'ı ajv ile
  derleyip bağımsız doğrulama yapıyor. OpenAI'ın Structured Outputs "strict"
  modu zaten uyumlu çıktı garantisi veriyor, ama bu garanti HTTP çağrısının
  karşı tarafında yaşıyor; bu modül aynı kontrolü bizim tarafımızda da
  tekrarlıyor (§14 "Şema doğrulanmayan cevap kaydedilmemelidir").

### Anti-drift: üçüncü bir kopya, üçüncü bir kilit

`RiskFlag`/`CardType` artık üç yerde var: şema JSON'ı, Swift enum'ları, ve şimdi
TypeScript. Proje bu deseni iki kez tecrübe etti (docs/ADR-001) — üçüncü kopyayı
savunmasız bırakmak aynı hatayı tekrarlamak olurdu. `evals/tests/test_ts_contract_sync.py`,
`test_swift_contract_sync.py`'nin ikizi: TypeScript kaynağını metin olarak okuyup
her iki listeyi de şemayla karşılaştırıyor, Node araç zinciri gerekmeden mevcut
Python CI'ında çalışıyor.

### Kart kalite kapısı (F3-4)

`backend/providers/cardGate.ts`, şema-geçerli bir §14 çıktısı üzerinde §19'un
kabul/onay/ret kurallarını uyguluyor. İki tasarım kararı öne çıkıyor:

1. **ADR-001'in kuralı buraya da taşındı:** modelin kendi `requiresUserApproval`
   alanı bir taban, tavan değil. Kapı bunu `false`'tan `quick_confirm`/`reject`'e
   yükseltebilir, ama modelin işaretlediği `true`'yu asla aşağı çekmez.
2. **Kartın kendi `sourceQuote`'una karşı bağımsız bir kritik-token kontrolü.**
   OCR uzlaştırma kapısının kullandığı aynı dedektör (`providers/gate.ts`'teki
   `addedCriticalTokens`) burada da çalıştırılıyor — kartın `front`/`back`'i,
   kendi alıntıladığı kaynakta olmayan bir doz/birim/yol içeriyorsa (§0.5,
   §19.3'ün tam olarak yakalamak istediği hata), bu ikinci bir dedektör
   yazılarak değil, var olanı yeniden kullanarak tespit ediliyor.

### OpenAI sağlayıcısı (F3-5) — bir tasarım kararı: `usage` ve `requestId` modelden istenmiyor

`backend/providers/openai.ts`, Responses API'ye Structured Outputs (strict mod)
ile çağrı yapıyor. Modelden istenen JSON şeması, §14'ün **bir alt kümesi**:
`usage` ve `requestId` alanları çıkarılmış. Sebep: model, kendi ürettiği yanıtın
gerçek token maliyetini üretim sırasında bilemez (bu sayı ancak API çağrısı
bittikten sonra var olur), ve bir istek kimliği modelin icat edeceği değil,
bizim atadığımız bir şeydir. Backend, gerçek `usage` verisini (HTTP yanıtındaki
token sayıları + config'teki fiyat) ve çağıranın verdiği `requestId`'yi çağrı
bittikten sonra ekliyor, sonra tam nesneyi `validateLlmOutput`'tan geçiriyor.

Üç bağımsız katman aynı kuralı (§13.2 pasaj başına en fazla 4 kart) uyguluyor:
prompt metni nazikçe rica ediyor, modele gönderilen şemanın `cards.maxItems`'ı
yapısal olarak sınırlıyor, ve `cardGate.ts` son çare olarak fazlasını reddediyor.

### Gemini sağlayıcısı (F3-6) — dar bir sözleşme, bilerek

`backend/providers/gemini.ts`, §15.3'ün istediği gibi yalnız transkripsiyon +
belirsizlik döndürüyor; kart üretmiyor ve §14'ün tam şemasını hiç görmüyor.
`HandwritingSecondOpinion.uncertainSpans`, §14'teki `UncertainSpan` tipini
yeniden kullanıyor — aynı kavram için ikinci bir şekil icat edilmedi.

**Bu sağlayıcı şu an hiçbir uç noktaya bağlı değil.** §5.2 adım 5'teki akış
("Sol + Gemini uyuşmazsa ikinci görüş") bir *transkripsiyon uzlaştırma* kararı;
bugünkü `providers/reconcile.ts` tamamen deterministik ve hiçbir LLM'e
yükselmiyor (Faz 2'nin bilinçli kapsamı). Gemini'yi gerçekten tetikleyecek olan
akış — "kritik uyuşmazlık + el yazısı → önce Sol'a, o da çözemezse Gemini'ye"
— henüz yazılmadı. Sağlayıcı kodu ve testleri hazır kalıyor; orkestrasyon bir
sonraki adım.

### `POST /api/cards` (F3-7)

`backend/api/_cards.ts`, `backend/api/_ocr.ts` ile aynı disiplini paylaşıyor:
veritabanı yok, günlükte içerik yok, bayt yalnız çağrı süresince bellekte.
Kasıtlı bir tasarım: bu uç nokta **ham görüntüden OCR yapmıyor** —
`cleanText` alanını zorunlu tutuyor, çünkü kart üretimi §17'nin
`transcription_reconciliation`'dan **sonraki** adımı; zaten uzlaştırılmış/onaylanmış
metni bekliyor. `MAX_USD_PER_CARD_GENERATION` sınırı, sıfırdan büyükse, yalnız
çıktı-token üst sınırıyla (girdi maliyeti çağrı öncesi bilinemez) **çağrı
yapılmadan önce** kontrol ediliyor (§21.3).

---

## Ölçüm hâlâ eksik — Faz 2'yle aynı kalıp

Faz 2'nin çıkış kapısı "20 görüntülük altın set etiketlemesi" adımında
bilinçli olarak atlanmıştı; Faz 3'ün eksiği daha temel: **bu geliştirme
ortamında OPENAI_API_KEY/GEMINI_API_KEY hiç yok** (kullanıcı bunları yalnız
kendi yerel `.env`'ine ve Vercel'e girdi — ayrıntı aşağıda). Dolayısıyla:

1. §25 Faz 3 çıkış kapısı ("gold pasajlardan üretilen kartların kalite
   rubriği kabul sınırını geçmesi") bir gold set + gerçek, kimliği doğrulanmış
   bir API çağrısı gerektirir; anahtar bu ortamda hiç olmadı.
2. ANA-PLAN'ın adlandırdığı modeller (`gpt-5.6-sol`, `gemini-3.5-flash`) bu
   belgenin yazıldığı tarihte gerçek API'lerde var olup olmadığı
   doğrulanmamış isimler — kullanıcının hesabında erişilebilir gerçek bir
   model kimliğiyle eşleşip eşleşmediği yalnızca gerçek bir anahtarla
   anlaşılabilir.

**Yapılabilen kısmı yapıldı — sahte anahtarla iki gerçek çağrı:** Bu ortamdan
`api.openai.com` ve `generativelanguage.googleapis.com`'a ağ erişimi var
(proxy üzerinden), ama gerçek bir anahtar yok. Bilerek **geçersiz** bir
anahtarla her iki sağlayıcıya da gerçek birer istek gönderildi — amaç
kimlik doğrulamayı geçmek değil, **istek gövdesinin şeklini** canlı API'ye
karşı sınamaktı:

- **OpenAI:** `401 Incorrect API key provided` döndü — yani istek OpenAI'ın
  kimlik doğrulama katmanına düzgün ulaştı. Model adının (`gpt-5.6-sol`)
  geçerli olup olmadığı bundan **anlaşılamadı**: OpenAI kimlik doğrulamayı
  gövde/model kontrolünden önce yapıyor.
- **Gemini gerçek bir hata buldu ve düzeltildi:** İlk deneme
  `400 Invalid JSON payload ... Unknown name "additionalProperties" ...
  Cannot find field.` döndürdü. Gemini'nin `responseSchema`'sı JSON
  Schema'nın kısıtlı bir alt kümesi ve `additionalProperties` anahtar
  kelimesini **desteklemiyor** — `providers/gemini.ts`'teki `RESPONSE_SCHEMA`
  bunu içeriyordu. Düzeltme: API'ye gönderilen şema artık bu anahtar
  kelimeyi taşımıyor; kendi bağımsız doğrulamamızın ihtiyaç duyduğu
  "beklenmeyen alan sızmasın" garantisi (§15.3: kart üretmemeli) ayrı bir
  yerel şemada (`localValidationSchema()`) korunuyor — API'ye giden ve bizim
  ajv ile doğruladığımız artık iki farklı nesne, kasıtlı olarak. Düzeltmeden
  sonra aynı sahte anahtarla tekrar denendiğinde istek şema doğrulamasını
  geçti ve beklendiği gibi `400 API key not valid` ile durdu — yani Gemini'nin
  geçersiz anahtar hatası **400** kodunda geliyor, OpenAI'ın 401'inden farklı;
  `scripts/handwriting.ts`'in hata ipucu mesaj içeriğine bakıyor, yalnız
  status koduna değil.

Bu, canlı bir anahtarla ilk denemede çıkması muhtemel hatalardan birini
(ve yalnızca birini) önceden temizledi. **Model adının kendisinin
geçerliliği ve OpenAI'ın istek gövdesinin geri kalanının kabul edilip
edilmediği hâlâ bilinmiyor** — bunlar için gerçek bir anahtar şart.

**Sıradaki adım — kullanıcı kendi `.env`'i üzerinden çalıştırmalı:**

```bash
cd backend
npm run cards         # tek bir gerçek OpenAI kart üretimi çağrısı
npm run handwriting    # tek bir gerçek Gemini ikinci görüş çağrısı
```

İkisi de tek bir gerçek çağrı yapar, sahte bir görüntüyle (gerçek bir sayfa
değil — amaç yalnızca istek/yanıt şeklini sınamak), ve terminale yalnız
metrik yazar (kart sayısı, kalite kapısı kararları, token/maliyet, hata
durumunda sağlayıcının kendi hata mesajı ve status kodu) — hiçbir zaman
anahtarı veya tam kart/transkripsiyon metnini basmaz; tam yanıt yerel,
gitignore'lu bir JSON'a yazılır. Model adı geçersizse hata mesajı bunu
söyleyecek; `.env`'deki `OPENAI_MODEL`/`GEMINI_MODEL` değeri kodda gömülü
olmadığı için (§0.6) yeniden denemek yalnızca bir `.env` düzenlemesi.

**Vercel tarafı:** Bu dal (`claude/proje-analizi-planlama-r7lxw4`) Vercel'de
zaten bir Preview dağıtımına derlendi (build başarılı — kodun Vercel'in
gerçek derleme hattında da çalıştığının ayrı bir kanıtı), ama proje SSO
korumasını "custom domain dışındaki her yer"de açık tutuyor, yani Preview
URL'i doğrudan `curl` ile test edilemiyor. Bu yüzden ilk doğrulama için
yerel `.env` yolu öneriliyor; Vercel üzerinden uçtan uca test, bu kod
`main`'e alınıp prod'a çıktıktan sonra (Faz 2'de `/api/ocr` için yapıldığı
gibi) mantıklı.

**Ayrıca gözden geçirilecek:** `backend/vercel.json`'daki `maxDuration: 60`,
`/api/ocr` ile paylaşılıyor. Görüntü + reasoning içeren bir kart üretimi
çağrısı Document AI'dan daha uzun sürebilir; canlı ölçümde ilk bakılacak yer.

## Test durumu

```
$ npm test   (backend/)
416 passed
$ python -m pytest evals -q
435 passed
```

Yeni testlerin hepsi (config, prompt, şema doğrulayıcı, kart kapısı, OpenAI/Gemini
sağlayıcıları, `/api/cards` uç noktası) sahte taşıyıcı (`Transport`) üzerinden
çalışıyor — ağ ve gerçek anahtar gerekmiyor, Google Document AI sağlayıcısının
test deseniyle aynı.
