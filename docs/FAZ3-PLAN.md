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
| **F3-5** | OpenAI Responses API sağlayıcısı (kart üretimi) | ✅ **gerçek anahtarla uçtan uca doğrulandı** — gerçek kart, gerçek token sayıları (aşağıya bakın) |
| **F3-6** | Gemini el yazısı ikinci görüş sağlayıcısı | ✅ **gerçek anahtarla uçtan uca doğrulandı** — gerçek transkripsiyon, gerçek token sayıları. Hâlâ hiçbir uç noktaya/akışa bağlı değil (transkripsiyon uzlaştırması hâlâ tamamen deterministik) |
| **F3-7** | `POST /api/cards` uç noktası, router'a bağlı | ✅ kod + test; sağlayıcı gerçek anahtarla doğrulandı ama bu HTTP uç noktası üzerinden (yalnız `scripts/cards.ts` üzerinden) henüz canlı denenmedi |
| **F3-7.5** | Yerel canlı-doğrulama araçları (`npm run cards`, `npm run handwriting`) | ✅ — üç gerçek hata buldurdu (OpenAI şema, Gemini token bütçesi, OpenAI token bütçesi), sonunda ikisi de başarıyla tamamlandı |
| **F3-8** | iOS istemci entegrasyonu (`/api/cards` çağrısı, `ModelRun` kaydı, onay ekranına bağlama) | 🔶 kod + yeni testler yazıldı; bu ortamda Swift derleyicisi yok, **bir Mac'te `swift test` ile henüz doğrulanmadı** (aşağıya bakın) |
| **F3-9** | Gerçek bir OpenAI/Gemini anahtarıyla canlı doğrulama | ✅ **tamamlandı** — ikisi de gerçek bir çıktı üretti |
| **F3-10** | Gold pasajlarla kart kalite rubriği ölçümü (§25 Faz 3 çıkış kapısı) | 🔶 puanları toplayıp dağılıma çeviren araç yazıldı ve test edildi (`evals/card_quality/aggregate.py`, `docs/MAC-ADIMLARI-FAZ3.md`); asıl ölçüm — gold pasaj seçimi ve elle puanlama — kullanıcıyı bekliyor |

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

## Canlı doğrulama — ilerleme kaydı (kronolojik)

> Bu bölüm zaman sırasıyla yazıldı ve öyle bırakıldı — Faz 2'nin
> `docs/FAZ2-PLAN.md`'sinde olduğu gibi, o anki durumun kaydı sonradan
> geçersiz olsa bile silinmiyor. Güncel özet: F3-9 tamamlandı (aşağıda,
> "F3-9 artık tamamlandı" başlığı altında).

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

## Güncelleme — gerçek anahtarla ilk iki çağrı (kullanıcının Mac'inde)

Kullanıcı anahtarları kendi yerel `.env`'ine girip `npm run cards` ve
`npm run handwriting`'i çalıştırdı. İkisi de kimlik doğrulamayı geçti (model
adlarının ikisi de — `gpt-5.6-sol`, `gemini-3.5-flash` — gerçek API'lerde
tanınıyor, aksi halde 404/"model not found" alınırdı) ve **iki ayrı gerçek
hata** çıkardı; ikisi de düzeltildi.

1. **OpenAI: `400 Invalid schema for response_format 'cizgi_llm_output':
   In context=('properties', 'schemaVersion'), schema must have a 'type'
   key.`** Düz JSON Schema `const`/`enum` yanında `type` şart koşmaz — ajv
   bunu sorunsuz kabul ediyordu — ama OpenAI'ın Structured Outputs'u daha
   kısıtlı bir alt küme kullanıyor ve şart koşuyor. `llm_output.schema.json`
   içinde üç yer etkileniyordu: `schemaVersion` (`const`), `cards.items.type`
   (`enum`), `$defs.riskFlag` (`enum`) — üçüne de `"type": "string"` eklendi.
   Regresyon: `openai.test.ts`, üretilen model şemasını özyinelemeli gezip
   `type` içermeyen bir `const`/`enum` düğümü kalmadığını doğruluyor.
2. **Gemini: `MAX_TOKENS`** — `GEMINI_MAX_OUTPUT_TOKENS=700`'de model hiç
   çıktı üretmeden token sınırına çarptı. Görünür yanıt (§15.3: metin + birkaç
   belirsiz span) bu kadar büyük olamayacağına göre, model bütçenin bir
   kısmını kendi iç muhakemesine harcıyor olmalı. Varsayılan `4096`'ya
   yükseltildi (`config.ts`, `.env.example`); **zaten var olan bir `.env`
   dosyasındaki `GEMINI_MAX_OUTPUT_TOKENS=700` satırı elle güncellenmeli**,
   kod varsayılanının değişmesi onu geçersiz kılmaz.

**Sonuç:** `npm run handwriting` **başarıyla tamamlandı** — gerçek bir Gemini
çağrısı, gerçek transkripsiyon (`kreatinin ...`), gerçek token sayıları
(1230/17). Gemini ikinci görüş sağlayıcısı artık uçtan uca doğrulandı.

`npm run cards` yeni bir hatayla durdu:

3. **OpenAI: model üretimi hiç JSON döndürmeden bitti (`Model yanıtı geçerli
   JSON değil`), 11 saniyelik gerçek işlem süresinden sonra.** Şema hatası
   değildi — schema artık kabul ediliyor (11 saniyelik çağrı, anında
   dönen bir 400 değil). En olası açıklama Gemini'dekiyle aynı sınıf:
   `gpt-5.6-sol` görünüşe göre reasoning-yetenekli bir model ve
   `max_output_tokens=700`'ün bir kısmını görünür JSON'dan önceki kendi iç
   muhakemesine harcıyor olabilir, geriye JSON'u bitirecek token kalmıyor.

   Responses API bunu `status: "incomplete"` + `incomplete_details.reason`
   alanlarıyla açıkça bildiriyor; `providers/openai.ts` artık JSON
   ayrıştırmayı denemeden önce bu alanı kontrol ediyor ve nedeni (örn.
   `max_output_tokens`) doğrudan hata mesajına yazıyor — bir sonraki
   denemede "geçerli JSON değil" yerine ne olduğunu söyleyen bir hata
   görülecek. Regresyon testi eklendi.

   **Bilerek değiştirmediğim şey:** `OPENAI_MAX_OUTPUT_TOKENS`'ın varsayılanı
   (700). Gemini'nin 700'ü Faz 3'te benim seçtiğim keyfi bir sayıydı ve
   düzeltmek bana aitti; OpenAI'ınki ANA-PLAN §20.3'ün kendisinin belirlediği
   bir maliyet sınırı ("Maksimum 4 kart ve 700 output token"). Eğer gerçek
   model reasoning token'larını da bu bütçeden düşüyorsa, §20.3'ün yazıldığı
   andaki varsayım (700 token = görünür kart içeriğine yeter) gerçek modelde
   geçerli olmayabilir — bu, benim sessizce çözeceğim bir kod hatası değil,
   kullanıcının bilerek karar vereceği bir maliyet/ürün ödünleşimi.

**Sonuç — ilk gerçek kart üretildi.** Kullanıcı `.env`'de
`OPENAI_MAX_OUTPUT_TOKENS=4096` ile tekrar denedi: `npm run cards`
**başarıyla tamamlandı** — 1 gerçek kart, kalite kapısından `quick_confirm`
kararı (beklenen: örnek cümle bir doz/kritik değer içeriyor), 1012/571
girdi/çıktı tokeni. ANA-PLAN sahibiyle görüşülüp varsayılan **4096 olarak
kalıcı yapıldı** (`config.ts`, `.env.example`, `config.test.ts`) — 700,
§20.3'ün öngördüğü gibi yalnızca görünür kart içeriğine yeterliydi, modelin
kendi reasoning token'larını hesaba katmıyordu.

**F3-9 artık tamamlandı:** hem OpenAI kart üretimi hem Gemini el yazısı
ikinci görüşü gerçek anahtarla, gerçek bir çağrıyla doğrulandı. Kalan iki
gerçek eksik: F3-8 (iOS entegrasyonu) ve F3-10 (gold pasajlarla kart kalite
rubriği ölçümü, §25 çıkış kapısı — artık altyapı hazır, yalnız gold set ve
birden fazla pasajlık ölçüm kalıyor).

**Not — maliyet:** `OPENAI_USD_PER_MILLION_*`/`GEMINI_USD_PER_MILLION_*`
hâlâ 0; gerçek harcama oluyor ama tahmini maliyet alanı bunu yansıtmıyor.
Gerçek fiyat, sağlayıcının kendi hesap/fiyatlandırma sayfasından
doldurulmalı (`docs/OPENAI-GEMINI-KURULUM.md`).

## F3-8 — iOS istemci entegrasyonu (kod yazıldı, Mac'te henüz doğrulanmadı)

Bu ortamda Swift derleyicisi yok (ne yerel toolchain ne Docker), yani bu
bölümdeki her şey **elle titiz gözden geçirme ile yazıldı, `swift test` ile
hiç çalıştırılmadı**. Faz 1/2'nin kendi kuralı burada da geçerli: kullanıcı
kendi Mac'inde `swift test` çalıştırıp sonucu bildirene kadar bu iş "tamam"
sayılmıyor.

**Yeni dosya:** `ios/CizgiCore/Sources/CizgiCore/Providers/BackendCardProvider.swift`
— `CardGenerating` protokolünün gerçek uygulaması, `BackendClient.swift`'in
aynı deseniyle (`Remote*` adlı wire tipleri, aynı hata sınıflandırması).
Bir tasarım kararı öne çıkıyor: sunucunun §19 kalite kapısı
(`runCardGate`) `output.cards`'ı **hiç değiştirmiyor** — reddedilen bir kart
hâlâ dizinin içinde duruyor, yalnız ayrı bir `gate.verdicts` raporunda
işaretleniyor. `BackendCardProvider.map` bu yüzden her kartı kendi
`cardId`'siyle `gate.verdicts`'a karşı kontrol ediyor: `reject` kararı
kartı tamamen düşürüyor, `quick_confirm` `requiresUserApproval`'ı zorluyor
(ADR-001'in taban-tavan değil kuralı istemci tarafında da uygulanıyor), ve
kapının hiç puanlamadığı bir kart id'si (olmaması gereken bir durum)
sessizce güvenilmek yerine `quick_confirm`'e düşüyor.

**Bir gerçek backend eksiği bulundu ve düzeltildi:** `_cards.ts`'in yanıtı
(`CardsSuccess`) prompt versiyonunu hiç döndürmüyordu — yalnız sunucu
log satırına yazıyordu, ve o log satırının yorumunda "iOS ModelRun kaydı
bunu bir gün buradan okuyacak" yazıyordu ki bu hiçbir zaman mümkün
olmayacak bir varsayımdı (telefonun sunucu loglarına erişimi yok).
`CardsSuccess`'e `cardPromptVersion` alanı eklendi (aynı `CARD_PROMPT_VERSION`
sabitinden, elle senkron tutulan ikinci bir kopya değil) — backend testleri
güncellendi ve geçiyor.

**Protokol/tip değişiklikleri, hepsi ekleme (mevcut çağrı yerleri bozulmadı):**
- `CardGenerationRequest`e `imageData`/`mimeType`/`selectedLineIds`/`isHandwritten`
  eklendi (hepsi varsayılanlı) — `MockCardProvider` hiç okumuyor, gerçek
  sağlayıcı gövdeyi bunlardan kuruyor.
- `GeneratedKnowledge`e `modelRun: ModelRunMetadata?` eklendi — yeni bir
  `ModelRunMetadata` (Sendable, Equatable) yalnızca sağlayıcının bilebileceği
  alanları taşıyor (`requestId`, `provider`, `model`, `purpose`,
  `promptVersion`, `latencyMs`, `inputTokens`, `outputTokens`,
  `estimatedCostUSD`); `id`/`jobId`/`success`/`errorCategory`/`createdAt`
  çağıran tarafından (zaten bildiği için) dolduruluyor.
- `PipelineOutcome`e aynı sebeple `modelRun` eklendi.
- `CapturePipeline`e `withGenerator(_:)` eklendi (`withBackend`/`withSelector`
  ile aynı desen) ve `run(...)` artık OCR çağrısı için zaten hazırlanmış
  görüntü baytlarını (`UploadImageEncoder.prepare` sonucu) ikinci kez
  kodlamadan kart üretimine de veriyor.

**`ProcessingQueue`/`AppEnvironment` (Uygulama katmanı, `CizgiCore` paketinin
dışında — `swift test` bunu hiç kapsamıyor, yalnız Xcode/cihazda denenebilir):**
- `ProcessingQueue.setCardGenerator(_:)` eklendi, `setBackend` ile birlikte
  çağrılıyor — Ayarlar'daki backend URL/token tek anahtar, hem bulut OCR'ı
  hem gerçek kart üretimini birlikte açıp kapatıyor, ikinci bir anahtar yok.
- `ProcessingQueue.persist(...)` artık `outcome.modelRun` doluysa bir
  `ModelRun` (§16.8) kaydı oluşturup ekliyor. **Bilerek eksik bırakılan:**
  yalnız başarılı çağrılar kaydediliyor — başarısız bir kart üretimi çağrısı
  için henüz bir `ModelRun` yazılmıyor (backend zaten kendi log satırında
  başarısızlığı tutuyor; iOS tarafı bunu aynalamıyor, bu ayrı, küçük bir
  sonraki adım).
- `AppEnvironment.makeCardGenerator` eklendi, `makeBackend` ile aynı
  "backend URL + cihaz tokenı var mı" kontrolünü paylaşıyor
  (`resolvedBackendConfiguration` adında ortak bir yardımcıya çıkarıldı,
  ki iki fonksiyon "yapılandırılmış" kararını birbirinden bağımsız
  vermesin). `SettingsView`'daki "Durum" bölümü artık `isBackendConfigured`e
  göre "Kart üretimi: Sahte sağlayıcı" / "Gerçek (backend)" gösteriyor —
  önceden hep "Sahte sağlayıcı" yazıyordu, bu artık yanlış olurdu.

**Yeni testler (`ios/CizgiCore/Tests/CizgiCoreTests/`, hepsi yazıldı, hiçbiri
henüz çalıştırılmadı):**
- `BackendCardProviderTests.swift` — `BackendCardProvider.map`'i doğrudan
  test ediyor (HTTP mock'lama bu pakette hiç yok, `BackendClient` için de
  yok — aynı emsal): reddedilen kart düşüyor mu, `quick_confirm` onay
  zorluyor mu, model onayı asla aşağı çekilmiyor mu, puanlanmamış bir
  kart id'si güvenilmiyor mu, boş `knowledgeUnits`/tamamı reddedilmiş kartlar
  `sourceInsufficient` fırlatıyor mu, `sourceConcern` birleşimi doğru mu,
  `modelRun` gerçek `usage`/`cardPromptVersion`'ı taşıyor mu.
- `BackendPipelineTests.swift`e eklenen `CardGenerationRequestTests` —
  `CapturePipeline` seviyesinde: sağlayıcı OCR çağrısıyla aynı baytları mı
  alıyor, backend yokken görüntü gönderilmiyor mu, `modelRun` outcome'a
  ulaşıyor mu, mock sağlayıcı `modelRun`'ı `nil` bırakıyor mu.

**Kullanıcıdan istenen:** `cd ios/CizgiCore && swift test` bir Mac'te —
mevcut 114 test hâlâ geçmeli, yeni testler de geçmeli. Geçmezse hata mesajı
bu oturuma geri bildirilirse düzeltilir; bu depoda derleme aracı olmadığı
için önceden yakalanamadı.

## F3-10 — gold pasaj kart kalite ölçümü altyapısı

`evals/card_quality/rubric.py` (§23.3'ün tek-kart puanlayıcısı: 7 kriter,
0-2 puan, 12-14 kabul / 9-11 inceleme / 0-8 ret) zaten Faz 3'ün başında
yazılmış ve testliydi — bu oturumda eksik olan, bulunan şey **çok sayıda
kartın puanını toplayıp bir dağılıma çeviren katman**dı; o hiç yoktu.

Eklenen: `evals/card_quality/scores.schema.json` (bir insanın 0-2 puanlarını
yazacağı dosyanın şeması — `gold-manifest.schema.json`'ın aynı deseni:
`additionalProperties: false`, `jsonschema` ile doğrulama) ve
`evals/card_quality/aggregate.py` (şema + tutarlılık hatalarını basan,
geçerliyse her kartın kararını ve toplam kabul/inceleme/ret dağılımını
yazan bir CLI — `evals/ocr_eval/validate_manifest.py`'nin aynı deseni).
**Bilerek yapılmayan:** bir tek "geçti/kaldı" sayısı üretmek — ANA-PLAN §25
yalnızca "kalite rubriği kabul sınırını geçmelidir" diyor, kaç pasaj ya da
kaç yüzde kabul gerektiğini söylemiyor; bunu ben uydurmak yerine dağılımı
gösterip kararı kullanıcıya bırakıyorum (§0.6). 17 yeni Python testi yazıldı
**ve bu ortamda gerçekten çalıştırıldı** (Swift'in aksine, burada bir Python
yorumlayıcısı var) — hepsi geçiyor.

`docs/MAC-ADIMLARI-FAZ3.md`, Faz 2'nin `docs/MAC-ADIMLARI.md`'siyle aynı
üslupta: kullanıcının kendi kitabından pasaj seçmesi, `npm run cards --
--text ... --output ...` ile (script'in zaten desteklediği bayraklarla,
kaynağı düzenlemeden) gerçek kart üretmesi, her kartı elle puanlaması, ve
`python -m evals.card_quality.aggregate` ile dağılımı hesaplaması adım adım
anlatılıyor.

**Kalan gerçek eksik:** kullanıcının kendi kitabından gerçek pasajlar seçip
elle puanlaması — bu ne bir API anahtarı ne bir derleyici sorunu, doğrudan
kullanıcının kendi tıbbi bilgisini ve zamanını gerektiren tek adım.

## Test durumu

```
$ npm test   (backend/)
419 passed
$ python -m pytest evals -q
452 passed
```

Yeni testlerin hepsi (config, prompt, şema doğrulayıcı, kart kapısı, OpenAI/Gemini
sağlayıcıları, `/api/cards` uç noktası) sahte taşıyıcı (`Transport`) üzerinden
çalışıyor — ağ ve gerçek anahtar gerekmiyor, Google Document AI sağlayıcısının
test deseniyle aynı.
