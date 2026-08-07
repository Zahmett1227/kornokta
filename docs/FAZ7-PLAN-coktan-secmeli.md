# Faz 7 — Beş şıklı (TUS tipi) kart

**Durum:** A1 + A2 uygulandı (2026-08-07); A3–A6 açık · **Tarih:** 2026-08-07 · **Dayanak:** ANA-PLAN §13.3 (çoktan
seçmeli kurallar), §4.2 (ilk sürümde varsayılan **değil**), §4.3 (sonraki sürüm
adayı), §13.2 (üretim kuralları), §18 (FSRS).

## 0. Bir cümlede

Kartın yanına **beş şık ve tek doğru cevap** ekle; tekrar ekranında kullanıcı
şıkkı seçsin, seçtiği anda doğru/yanlış görünsün ve **her yanlış şıkkın neden
yanlış olduğu** yazsın. Mevcut düz kart tipleri aynen kalır — çoktan seçmeli
onların yerine geçmez, bir seçenek olarak eklenir.

## 1. Neden ve neden şimdi

TUS beş şıklı sorulur; bilgiyi "hatırlıyor muyum" diye değil "beş yakın
seçenek arasından ayırt edebiliyor muyum" diye sınamak sınavın kendi biçimi.
ANA-PLAN bunu baştan öngörmüş ama **ilk sürümde bilerek dışarıda bırakmış**
(§4.2) çünkü kötü distraktör üretmek kartı işe yaramaz hâle getirir. Şimdi
mantıklı olmasının sebebi: Faz 6'da kart üretimi zaten zenginleştirmeye açıldı,
**kart düzenleme var** (PR #27) ve kötü bir şıkkı elle düzeltmek mümkün.

Bu plan, ANA-PLAN §13.3'ün altı kuralını taban alır:

1. Beş seçenek olmalı.
2. Tek doğru cevap bulunmalı.
3. Distraktörler aynı semantik sınıftan olmalı.
4. İki doğruya dönüşen seçenekler otomatik kalite kontrolünden geçmeli.
5. Model, her distraktörün neden yanlış olduğunu **ayrı alanlarda** açıklamalı.
6. Şüpheli soru kullanıcı onayı olmadan aktif karta dönüşmemeli.

**6. madde Faz 6 ile çatışıyor** — Faz 6 onay adımını tamamen kaldırdı
(ADR-005). Çözüm §9'da; kısaca: bloklamak yerine **işaretlemek**.

## 2. Sözleşme değişikliği — şema v2.1

`backend/schemas/llm_output.schema.json`, kart nesnesine iki alan ekler.
Structured Outputs katı modda **her alanı `required` ister**, o yüzden
çoktan seçmeli olmayan kartlarda alanlar `null` döner:

```jsonc
{
  "id": "…", "type": "multiple_choice", "front": "…", "back": "…",
  "explanation": "…", "difficulty": 3, "tags": ["…"], "lowConfidence": false,

  // YENİ — çoktan seçmeli değilse null
  "options": [
    { "text": "Hipokalemi",  "correct": true,  "why": "" },
    { "text": "Hiperkalemi", "correct": false, "why": "EKG'de sivri T dalgası yapar; burada tablo tersi." },
    { "text": "Hiponatremi", "correct": false, "why": "…" },
    { "text": "Hipokalsemi", "correct": false, "why": "…" },
    { "text": "Hipomagnezemi","correct": false,"why": "…" }
  ],
  // YENİ — şıkların kanonik sırasındaki doğru cevabın indeksi (0–4), değilse null
  "correctOption": 0
}
```

Kararlar ve gerekçeleri:

- **`options` nesne dizisi, düz string dizisi değil.** §13.3'ün 5. maddesi her
  distraktör için ayrı bir gerekçe alanı istiyor; bunu `why` olarak yanına
  koymak, sonradan "hangi açıklama hangi şıkka ait" diye eşleştirmeye çalışmaktan
  daha sağlam.
- **`correct` **ve** `correctOption` birlikte.** Fazlalık gibi duruyor ama
  ikisinin **uyuşmaması** en ucuz bozukluk sinyali: model iki şıkka `correct:true`
  koyduysa ya da `correctOption` başka bir şıkkı gösteriyorsa kart şüphelidir
  (§4.2'deki "iki doğru" durumu). Kapı bunu kullanır (§4).
- **`back` yine zorunlu.** Doğru şıkkın metni `back`'e de yazılır; böylece
  şıklar bozuk çıksa bile kart düz kart olarak kurtarılabilir (§4) ve
  Bilgilerim/arama/yedek tarafında hiçbir şey değişmez.
- **`schemaVersion` `"2.1"`.** İstemci `"2.0"`'ı da kabul etmeye devam eder;
  yeni alanlar yoksa kart düz karttır.

### 2.1 Anti-drift — aynı gerçeği beş yerde tutan zincir

`multiple_choice`, `CardType`'ın altıncı değeri olarak **beş dosyaya birden**
girer; biri unutulursa CI kırılır (bu proje bunu bilerek yapıyor):

| Dosya | Ne değişir |
|---|---|
| `backend/schemas/llm_output.schema.json` | `type` enum'una `multiple_choice`; `options`/`correctOption` tanımı |
| `backend/schemas/llmOutputTypes.ts` | `CARD_TYPES` dizisi + `LlmCard` tipi |
| `ios/CizgiCore/Sources/CizgiCore/Models/Enums.swift` | `CardType.multipleChoice = "multiple_choice"` |
| `evals/tests/test_ts_contract_sync.py` | Otomatik — sıralı karşılaştırma yapıyor, yeni değer iki tarafta da olmalı |
| `evals/tests/test_swift_contract_sync.py` | Aynısı Swift için |
| `evals/tests/test_llm_output_schema.py` | Şema örneklerinin geçerliliği |

> **Sıra önemli:** `CARD_TYPES` ile Swift `CardType` **aynı sırada** olmak
> zorunda (sync testi sıralı kıyaslıyor). Yeni değeri iki yerde de **sona** ekle.

## 3. Backend — prompt v2.4

`backend/prompts/cardGeneration.ts`'e çoktan seçmeli bölümü eklenir. Taslak
kurallar (asıl iş bunu gerçek sayfalarla iyileştirmek — B3'ün aynısı):

> Bazı kartları **beş şıklı TUS sorusu** olarak kur. Kurallar:
> - Tam **beş** şık; **tek** doğru cevap.
> - Distraktörler doğru cevapla **aynı semantik sınıftan** olmalı: aynı tür
>   varlık (hepsi enzim / hepsi tanı / hepsi ilaç), benzer uzunluk ve biçim.
>   "Hiçbiri", "Hepsi", "A ve B" gibi şıklar **yasak**.
> - Distraktör, öğrencinin gerçekten karıştırabileceği bir şey olmalı — sayfada
>   ya da konuda geçen komşu kavramlar birinci tercihtir; alakasız şık soruyu
>   kolaylaştırır ve öğretmez.
> - Hiçbir distraktör, sorunun kurgusunda **ikinci bir doğru** hâline
>   gelmemeli. Emin değilsen o şıkkı değiştir; olmuyorsa kartı düz kart yap.
> - Her yanlış şık için `why` alanına **tek cümlelik** "neden yanlış" yaz
>   (ayırt edici özellik ya da klasik tuzağın adı). Doğru şıkkın `why`'ı boştur.
> - `back`'e doğru şıkkın metnini yaz; `explanation`'a kavramın kendisini.

Ne zaman çoktan seçmeli üretileceği **config'ten** gelir (§0.6 — koda gömülmez):

```
OPENAI_MULTIPLE_CHOICE_MODE = off | mixed | all      (varsayılan: mixed)
```

- `off` — hiç üretme (bugünkü davranış).
- `mixed` — ayırt etme/istisna-tuzak gibi **doğal olarak ayrıştırıcı** kartları
  beş şıklı yap, tanım/mekanizma kartlarını düz bırak. Önerilen varsayılan:
  her kartı beş şıklı yapmak hem pahalı hem de tanım ezberinde faydasız.
- `all` — üretilebilen her kartı beş şıklı yap.

## 4. Backend — kalite kapısı (§13.3'ün 4. maddesi)

`backend/providers/cardGate.ts` bugün yalnız boş front/back'e bakıyor. Çoktan
seçmeli kart için **deterministik** kontroller eklenir (§0.8 — yargı gerektiren
kısım modelde, sayılabilir kısım kodda):

| Kontrol | Sonuç |
|---|---|
| Şık sayısı ≠ 5 | **düz karta indir** |
| `correct: true` sayısı ≠ 1, veya `correctOption` onunla uyuşmuyor | **düz karta indir** + `lowConfidence` |
| Boş şık metni | **düz karta indir** |
| İki şık normalize edilince aynı (Türkçe normalizasyon: NFC + İ/ı katlama + diyakritik — ADR-001'in mevcut yardımcıları) | **düz karta indir** + `lowConfidence` |
| Bir şık ötekinin tam alt dizgisi (ör. "hipokalemi" / "ağır hipokalemi") | `lowConfidence` (indirme yok — bazen meşru) |
| Yanlış şıkta `why` boş | `lowConfidence` |
| `back`, doğru şıkkın metniyle uyuşmuyor | `back`'i doğru şıktan **yeniden yaz** (kart kaybolmaz) |

**"Düz karta indir" neden reddetmekten iyi:** kartın front/back'i zaten
geçerli; bozuk olan yalnız şıklar. Reddetmek, parayla üretilmiş sağlam bir
kartı çöpe atmak olur. İndirme sessiz olmaz: `lowConfidence` ve sunucu logunda
sayaç (içerik değil, yalnız sayı — güvenlik kuralı).

**Yapılamayan:** "iki şık da doğru" durumunun **anlamsal** hâli. İki farklı
metnin ikisinin de doğru cevap olup olmadığı bir yargı sorusudur (§0.5) ve
deterministik olarak çözülemez. Bu yüzden §9'daki işaretleme çözümü şart.

## 5. iOS — veri modeli

`ios/CizgiCore/Sources/CizgiCore/Models/Models.swift`, `Card`'a **iki opsiyonel
alan** ekler:

```swift
/// Beş şıklı kart için kanonik şık listesi (JSON). Düz kartta nil.
public var optionsRaw: String?
/// Kanonik listedeki doğru şıkkın indeksi. Düz kartta nil.
public var correctOptionIndex: Int?
```

- **SwiftData göçü:** ikisi de opsiyonel ve varsayılanı `nil` → **hafif göç**,
  mevcut kartlar aynen kalır (§10.4'ün "mevcut kartlar korunmalı" şartı
  kendiliğinden sağlanır). Ayrı bir migration planı gerekmez.
- **JSON string olarak saklamak** (ilişkili bir `CardOption` modeli yerine):
  şık listesi kartın dışında hiçbir yerden sorgulanmıyor, ayrı bir tablo yalnız
  cascade-silme ve yedek karmaşası getirirdi. Kod-oku/yaz `CizgiCore`'da tek
  yerde ve testli.

`CizgiCore` tarafında yeni, **Foundation-only** (yani bu ortamda gerçekten test
edilebilir) bir dosya: `Models/MultipleChoice.swift`

```swift
public struct CardOption: Codable, Equatable, Sendable {
    public let text: String
    public let isCorrect: Bool
    public let why: String?          // yanlış şıkkın neden yanlış olduğu
}

public enum MultipleChoice {
    /// Şık listesini doğrular; geçersizse nil (kart düz kart gibi gösterilir).
    public static func decode(_ raw: String?) -> [CardOption]?
    public static func encode(_ options: [CardOption]) -> String?
    /// §13.3: tam 5 şık, tek doğru, boş metin yok, tekrar eden şık yok.
    public static func validate(_ options: [CardOption]) -> MultipleChoiceValidation
    /// Sunum sırası — aşağıya bak.
    public static func presentationOrder(cardId: UUID, reviewCount: Int, count: Int) -> [Int]
}
```

### 5.1 Şık sırası — kararlı ama sabit değil

Doğru cevap her zaman aynı konumda görünürse kullanıcı **konumu** ezberler.
Ama sıra her `body` yeniden çiziminde değişirse kart gözünün önünde zıplar.
Çözüm: **kart kimliği + o kartın tekrar sayısı**ndan üretilen tohumla küçük bir
LCG (`presentationOrder`) — aynı tekrar boyunca sabit, tekrardan tekrara
değişir, testte deterministik (`Math.random`/`Date.now` yok, bu projede zaten
yasak sayılan türden bir belirsizlik).

## 6. iOS — tekrar ekranı

`ios/App/Features/Review/ReviewView.swift`:

- Kart `multipleChoice` ve şıkları geçerliyse: "Cevabı göster" düğmesi yerine
  **beş dokunulabilir satır**.
- Bir şıkka dokunulunca: seçilen şık ve doğru şık işaretlenir (doğru yeşil,
  yanlış seçim kırmızı; renk tek başına anlam taşımaz — ikon + metin de var,
  §29), **her yanlış şıkkın `why`'ı** açılır, `explanation` ve "Kaynağı göster"
  bugünkü gibi görünür.
- **FSRS eşlemesi** — burası kritik:
  - **Yanlış seçildiyse → doğrudan `again`.** Kullanıcıya sorulmaz; yanlış
    bildiği bir kart için "İyi"ye basabilmek FSRS'i bozar ve o veri geri
    dönülemez biçimde kartın geçmişine yazılır.
  - **Doğru seçildiyse → `Zor / İyi / Kolay`** (üç düğme; `again` gösterilmez).
  - `ReviewSession.advance(relearn: rating == .again)` **değişmez** — öğrenme
    adımı ve "oturum sonunda geri gelir" davranışı otomatik olarak doğru çalışır.
  - "Geri al" da değişmez; yalnız seçili şık arayüz durumu sıfırlanır.
- **`ReviewPace` etkisi:** beş şık okumak düz karttan uzun sürer, yani
  `responseTimeMs` medyanı yükselir ve "hızlı oturum"da kart sayısı kendiliğinden
  azalır. Bu **doğru davranış**, ama karışık destede medyan iki tipin arasında
  kalır. İlk sürümde tek medyan yeterli; gerçekte rahatsız ederse kart tipine
  göre ayrı medyan (`ReviewPace`'e bir parametre) küçük bir iş.

## 7. iOS — düzenleme, detay, yedek

- **`CardEditorView`** (`ios/App/Features/Library/CardEditorView.swift`): beş
  şık metni + hangisinin doğru olduğu (tek seçim) + yanlış şıkların `why`
  alanları. Kaydetme kuralı `MultipleChoice.validate`'ten geçer; geçmezse
  "Kaydet" pasif ve sebep yazılı (bugünkü `CardEditValidation` deseninin aynısı).
  Ayrıca **"Şıkları kaldır"** — kötü şıkları temizleyip kartı düz karta çevirmek
  bir tıkla mümkün olmalı.
- **`CardDetailView`** (`LibraryView.swift`): şıklar doğru işaretiyle listelenir.
- **Yedek** (`Storage/BackupExporter.swift`): biçim **v3** — `CardRecord`'a
  `options` + `correctOption`. v1/v2 dosyalar `decodeIfPresent` ile okunmaya
  devam eder (bugünkü desen). Geri yükleme yine **yalnızca ekler**.
- **Ayarlar** (`SettingsView.swift` + `AppSettings`): `multipleChoiceMode`
  (Kapalı / Karışık / Hepsi). `maxCardsPerPage` ile aynı yolu izler — istek
  gövdesine yazılır, sunucu **kendi config'ini tavan kabul eder** (§21.3:
  istemci daha azını isteyebilir, dağıtımın kararını aşamaz).
- **İş kuyruğu:** işçi isteği çok sonra çalıştığı için ayar satırda taşınmalı →
  `jobs` tablosuna nullable `mc_mode` sütunu (yeni migration), `max_cards`'ın
  yaptığının aynısı. *Not:* üçüncü bir ayar gelirse sütun başına bir migration
  yerine tek bir `client_options jsonb` sütununa geçmek daha temiz olur; iki
  ayar için henüz gerekmiyor.
  **A2'de bilerek yapılmadı:** sütunu şimdi eklemek, Ayarlar'da karşılığı
  olmayan bir alan demekti — bu projenin bir kez düştüğü tuzağın aynısı
  (`maxCardsPerPassage` iki faz boyunca hiçbir şey yapmadı). Mod şu an yalnız
  sunucu config'inden (`OPENAI_MULTIPLE_CHOICE_MODE`) geliyor; istemci override'ı
  Ayarlar arayüzüyle **birlikte** A5'te gelecek.

## 8. Maliyet ve gecikme

Beş şık + beş gerekçe, kart başına kabaca **+80–150 çıktı token'ı**. Sayfa
başına 12 kartta bu, çıktının yaklaşık iki katına çıkması demek — ve gecikmenin
baskın bileşeni çıktı token'ı (`docs/COKLU-FOTO-TIMEOUT.md` §4).

- `OPENAI_MAX_OUTPUT_TOKENS` 8192 sınırına yaklaşılır; `mixed` modda sorun
  olmaması beklenir, `all` modda **ölçülmeden açılmamalı**.
- Ölçüm için uydurma rakam yok: ilk 5–10 sayfadan sonra **Ayarlar → Kullanım**
  girdi/çıktı token sayılarını zaten gösteriyor (PR #27); öncesi/sonrası
  karşılaştırılır.
- Kart üretimi asenkron olduğu için (ADR-006) **gecikme kullanıcıyı
  bekletmiyor** — bu özelliğin şimdi makul olmasının bir sebebi de bu.

## 9. §13.3'ün 6. maddesi ile Faz 6 çatışması

> "Şüpheli soru kullanıcı onayı olmadan aktif karta dönüşmemelidir."

Faz 6 onay adımını tamamen kaldırdı (ADR-005) ve gerekçesi hâlâ geçerli: onay
ekranı her kartı yavaşlatıyordu ve kullanıcı hata riskini kabul etti. Öte yandan
§13.3'ün endişesi gerçek: **iki doğrulu bir soru sessizce ezberlenirse yanlış
öğrenilir** — bu, yanlış yazılmış düz bir karttan daha sinsi.

**Önerilen çözüm — bloklamak yerine işaretlemek:**

1. Kapının şüpheli bulduğu (§4) kart yine `.active` girer, ama `lowConfidence`
   taşır.
2. Tekrar ekranında bu kartlarda küçük bir **"şüpheli şıklar"** rozeti ve
   düzenlemeye tek dokunuş.
3. **Bilgilerim'de "Gözden geçir" bölümü:** `lowConfidence` kartlar tek listede.
   (Faz 6'da kaldırılan "Onay bekliyor" bölümünün *bloklamayan* hâli.)
4. `all` modu açıksa ve kapı bir sayfada çok sayıda şüpheli üretirse, bu
   kullanıcıya sayfayı yeniden üretme ya da modu düşürme sinyalidir.

Bu, ANA-PLAN'dan **bilinçli bir sapma**; uygulanırsa ADR-005'in "gevşetilen
ilkeler" listesine bir madde olarak yazılmalı (ya da kısa bir ADR-007).
Kullanıcı bunun yerine gerçek bir onay adımı isterse §6'daki akış
`.needsReview` durumuna (enum'da hâlâ duruyor) bağlanarak da yapılabilir.

## 10. Aşamalar

| Adım | Kapsam | Nerede test edilir |
|---|---|---|
| **A1** | `MultipleChoice` modeli, doğrulama, sunum sırası; `CardType` altı değere çıkar (anti-drift zinciri) | ✅ **Koşuldu** — izole pakette 115 test yeşil (15'i yeni), mutasyonla doğrulandı; şema/TS/Swift kart tipleri elle karşılaştırılıp eşit çıktı (`pytest` bu ortamda kurulu değil, CI koşacak) |
| **A2** | Şema v2.1, `llmOutputTypes.ts`, prompt v2.4, kalite kapısı, config anahtarı | ✅ **Koşuldu** — backend 500 test yeşil (18'i yeni), `tsc` temiz. **`mc_mode` sütunu A5'e ertelendi** — aşağıya bak |
| **A3** | `BackendCardProvider` çözümlemesi + `GeneratedCard`'a şıklar; `ProcessingQueue.persist` kartı şıklarıyla yazar | `swift test` (CizgiCore, Mac) |
| **A4** | Tekrar ekranı: şık seçimi, doğru/yanlış gösterimi, FSRS eşlemesi | **Mac derlemesi + gerçek cihaz** |
| **A5** | Editör, kart detayı, yedek v3, Ayarlar'daki mod, "Gözden geçir" bölümü | Mac + cihaz |
| **A6** | Gerçek sayfalarla prompt/distraktör kalite döngüsü | Yalnız gerçek kullanım |

A1+A2 tek başına anlamlı ve tamamen bu ortamda doğrulanabilir; A3–A5 bir Mac
gerektirir. **Asıl iş A6** — tıpkı B3'te olduğu gibi, kodun bittiği yerde
kalite başlıyor.

## 11. Kabul kriterleri

- Bir sayfadan üretilen kartların bir kısmı beş şıklı geliyor; şıklar aynı
  semantik sınıftan ve tek doğru cevap var.
- Yanlış şık seçilince kart otomatik `again` alıyor; doğru seçilince Zor/İyi/
  Kolay soruluyor ve FSRS geçmişi tutarlı kalıyor.
- Her yanlış şıkkın neden yanlış olduğu görünüyor (§13.3/5).
- Bozuk şık üreten bir kart kaybolmuyor: düz karta iniyor ve "Gözden geçir"de
  görünüyor.
- Kötü bir şık **düzenlenebiliyor** ya da tek dokunuşla kaldırılabiliyor.
- Mevcut kartların hiçbiri etkilenmiyor (opsiyonel alanlar, hafif göç).
- Yedek alıp geri yüklemek şıkları koruyor; v2 yedekler hâlâ okunuyor.

## 12. Riskler

1. **Distraktör kalitesi.** En büyük risk ve deterministik olarak çözülemez.
   Azaltma: `mixed` varsayılanı, şüpheli işaretleme, kolay düzenleme, ve
   gerçek sayfalarla prompt iterasyonu.
2. **Gizli ikinci doğru.** Kapı yalnız metinsel eşleşmeyi yakalar; anlamsal
   olanı yakalayamaz (§4'te açıkça yazılı). Kullanıcı yakaladığında düzeltir.
3. **Tahminle kazanılan tekrar.** Beşte bir ihtimalle doğru seçilen bir kart
   FSRS'e "biliyorum" diye yazılır. İlk sürümde bilerek çözülmüyor (kişisel
   kullanım, kullanıcı kendini kandırmaz); rahatsız ederse "Emin değildim"
   işareti → `hard` eşlemesi küçük bir ek.
4. **Maliyet/gecikme.** §8; `all` modu ölçmeden açılmamalı.
5. **Uzun şıklar.** Beş uzun şık telefonda kaydırma gerektirir. Prompt'ta şık
   uzunluğu sınırı (kısa isim/ifade) ve arayüzde kaydırılabilir liste.
