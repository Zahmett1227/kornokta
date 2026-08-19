# Kapsama sözleşmesi — ucuzlayan modelle ne yapılmalı

> **Durum: Katman A ve Katman B yazıldı (2026-08-19).** Belge önce bir öneriydi;
> sahibi "1 + 2" (her iki katman) dedi ve ikisi de uygulandı. Aşağıdaki tasarım
> bölümleri olduğu gibi duruyor — gerekçe kaydı onlar. Uygulamada tasarımdan
> sapan tek şey alan adı: kart başına `markIndex` yerine **`markId`** (modelin
> saymasına değil, kendi yazdığı etikete dayanır).
>
> **Neyin bittiği ve neyin cihazda görülmesi gerektiği aşağıda "Uygulama
> durumu" bölümünde.**

## Özet

Sistemde iki atıl kaynak var: (1) kart üretimi 7,5 kat ucuzladı ve model sayfa
başına **yalnız bir kez** kullanılıyor, ondan sonra hiç; (2) Gemini — bilinçli
olarak *bağımsız* bir model ailesi — tek bir düğmenin arkasında, yalnız
`lowConfidence` kartlar için, yalnız elle tetiklenerek duruyor.

Bu iki kaynağın birleştiği en değerli yer bir "yeni özellik" değil, sistemin
bugün **göremediği tek kayıp**: işaretlediğin ama hiç kartlaşmayan içerik.
Önerilen iş buna *kapsama sözleşmesi* adını veriyor ve iki katmandan oluşuyor:
modelin kendi işaret defterini tutması (şema v2.3, ek çağrı yok) ve bağımsız
bir ikinci okuyucunun aynı sayfayı denetlemesi (Gemini). İlk çıktısı bir ekran
değil **bir sayı**: kaçırma oranı. O sayı bugün hiç bilinmiyor ve en az üç açık
kararı birden kilitliyor.

Alternatif iki büyük aday (Sentez Egzersizi, Deste Doktoru) §4'te; sıra önerisi
§5'te.

---

## 1. Bugünkü tablo: iki atıl kaynak

**Model sayfa başına bir kez çalışıyor.** Kartlar desteye girdikten sonra
sistemin geri kalanı — FSRS-6, Egzersiz, FES, Bilgi Haritası, arama, yedek —
tamamen deterministik. Bu doğru bir tasarımdı (§0.8: hesaplama ve zamanlama
kodda, LLM yalnız yorumlama/üretim). Ama §0.8 modelin **sayfa dışındaki**
içeriği yorumlamasını yasaklamıyor; yalnız zamanlamaya karışmasını yasaklıyor.
Bugünkü kısıt teknik değil, tarihsel: model pahalıyken sayfa başına ikinci bir
çağrı düşünülemezdi.

**Maliyet 7,5 kat düştü.** Tur A3'ün ölçümü: `sol@low` $0.1394/sayfa,
`luna@high` $0.0186/sayfa (`docs/PLAN-model-karsilastirma.md`). Kart üretimi
artık akışın pahalı adımı değil. Sayfa başına ikinci, hatta üçüncü bir çağrı
bugün "maliyet kararı" olmaktan çıkmış durumda.

**Gemini neredeyse hiç kullanılmıyor.** `/api/second-opinion` yalnız
`lowConfidence` bir kartın detayındaki düğmeden çağrılıyor. Yani elde
*bağımsız bir görme yığını* var ve ayda birkaç kez çalışıyor. Bağımsızlığın
kendisi değerli: aynı ailedeki bir modele kendi işini denetletmek, aynı
körlükleri paylaşan bir denetçi demektir (§10.4'ün ilk gerekçesi, ADR-005
sonrası hâlâ geçerli).

## 2. Boşluk: sessiz kapsama kaybı

Bu proje iki tür hata üretebilir ve ikisi hiç benzemiyor.

**Yanlış kart görülür.** `lowConfidence` bayrağı var, Bilgilerim'de "Gözden
geçir" kovası var, kart detayında İkinci Görüş düğmesi var, Tekrar'da kartı
okuyunca da fark edilir. Tur A bu tarafta iyi haber verdi: `luna@high` 120
kartta sıfır "yanlış ama emin" üretti.

**Eksik kart görülmez.** Üretilmemiş kartın bayrağı olmaz, sayısı olmaz,
listesi olmaz. Kanıt zinciri repoda zaten yazılı:

- `PLAN-model-karsilastirma.md`: "Luna'nın asıl eksiği kendinden emin hata
  değil, **sessiz kapsama boşluğu**… Bunu gören tek gözlenebilir sinyal tavanın
  dolması" — ve Tur A'da **18 setin 18'i de tavana çarptı**, yani ölçülen her
  sayfada kapsama *bilinmiyor*.
- Prompt v2.6 kural 2'ye bir sayım adımı eklendi (bitirmeden önce işaretleri
  say ve kartlarla karşılaştır).
- Prompt v2.7 aynı sorun için yazıldı: sahibi gerçek sayfada bildirdi — model
  yıldızlı pasajı `readText`'e yazıyor, yani **görüyor**, ama kartları
  sayfanın işaretsiz yerlerinden kuruyor. Kural üç Codex turunda üç kez
  sertleştirildi (kademe adlandırıldı, kapı kapatıldı, sıra kilitlendi).

Yani: **prompt üç kez denendi ve sonuç hâlâ ölçülmedi.** Ölçülemedi de —
ölçecek hiçbir sinyal yok. Bir kural yazıp "artık tutuyordur" demek, tam da bu
reponun iki kez ısırıldığı yer (v2.6'nın kendi ölçümü, sadece tercih bildiren
kural 5'in hiç kımıldamadığını gösterdi).

**Neden en pahalı hata bu:** işaretlenmiş içerik, sahibinin *özellikle önemli*
dediği içeriktir — kitabın en değerli %5'i. Kartlaşmazsa çalışma döngüsüne hiç
girmez, ve kaynağı da kalıcı değildir: sunucudaki sonuç 60 günde silinir,
telefondaki orijinal fotoğraf `keepOriginalPage` kapalıysa iş biter bitmez
gider. Yanlış kart düzeltilir; eksik kart, farkına varılmadığı için asla
düzeltilmez.

**Ölçek (dürüst tahmin, ölçüm değil):** kaçırma oranı %15 ise bugünkü ~1000
kartlık destede yaklaşık 150 kart eksik demektir. %5 ise 50. Aradaki fark
"öncelikli iş" ile "boş ver" arasındaki farktır — ve bugün hangisi olduğunu
söyleyen tek bir sayı yok.

## 3. Öneri: kapsama sözleşmesi

Fikrin özü: **modelin ne gördüğünü, ne ürettiğiyle deterministik olarak
karşılaştırılabilir hâle getirmek.** Yargı modelde kalır, muhasebe kodda olur
(§0.8'in ruhu). Kapsama artık prompt'un iyi niyetine değil, iki listenin
farkına bakar.

### Katman A — modelin kendi işaret defteri (şema v2.3, ek çağrı yok)

Çıktı sözleşmesine iki alan:

```jsonc
"marks": [                       // sayfada tespit edilen işaretler
  { "id": "m1",
    "kind": "handwriting|symbol|underline|highlight",
    "quote": "..." }             // işaretin üstündeki/yanındaki metin, birebir
],
// ve her kartta:
"markId": "m1" | null            // bu kart hangi işaretten doğdu
```

> Uygulamada `importance` düştü: kademe (`kind`) zaten prompt kural 3'ün
> öncelik merdiveni, ve ikinci bir önem alanı hem token hem de modelin
> tutarsız olabileceği ikinci bir yargı demekti.

Sunucu bunlardan **iki listeyi deterministik olarak** çıkarır:

1. **Kartsız işaret** — `marks` içinde olup hiçbir kartın `markId`'si
   göstermediği işaret. Aranan sinyal budur.
2. **İşaretsiz kart** — `markId: null` ile gelen kart. Bu, prompt kural
   1'in ("işaretsiz metinden kart üretme") ihlalidir ve bugün onu da gören
   hiçbir şey yok. Bedavaya gelen ikinci bir sinyal.

Neden bu, "bir kural daha" değil: kural, modelden *davranış* ister ve
tutmadığında sessizdir. Sözleşme, modelden *beyan* ister; beyan ile ürünü
arasındaki tutarsızlığı kod görür. Model kendi defterinde yıldızı listeleyip
ona kart üretmediyse bu artık bir veri satırıdır, bir tahmin değil.
(v2.7'nin bildirilen kusuru tam olarak bu şekli alır: `readText`'te var,
kartta yok.)

- **Maliyet:** sayfa başına ~300–600 ek çıktı token'ı ≈ **$0.0005**. Çıktı
  tavanı canlıda 48000; sıkışma riski yok.
- **Risk ve sınırlaması:** katı şemaya alan eklemek ana akışı etkiler. Üç
  koruma: `marks` **boş dizi olabilir** (işaret yoksa iş düşmez); `markId`
  **null olabilir**; tanınmayan/geçersiz `markId` sunucuda null'a çevrilir
  ve **iş asla düşürülmez** — `sanitizeTopics`'in aynısı, aynı sebeple.
- **Migration gerektirmez:** yalnız `jobs.result` içeriği büyür, yeni sütun
  yok. (CLAUDE.md'nin "sütun eklenirse dağıtımdan önce canlıya uygula"
  kuralına takılmamak bilinçli bir tasarım tercihi.)

### Katman B — bağımsız ikinci okuyucu (Gemini)

Katman A'nın **göremediği** bir sınıf var: modelin *hiç görmediği* işaret.
Kendi defterini tutan bir okuyucu, görmediği şeyi deftere de yazmaz. Bu sınıfı
yalnız ikinci bir göz görebilir — ve tercihen başka bir ailenin gözü.

- **`/api/coverage`** (dördüncü kapı, `/api/second-opinion` gibi kendi başına
  düşer): sayfa görüntüsü + üretilen kartların `front`/`back`'i →
  Gemini `responseSchema` ile
  `marks[]: { quote, kind, coveredByCardIndex | null }`.
- Sunucu yalnız `coveredByCardIndex === null` olanları döner. Kart üretmez;
  prompt'u kart üretmeyi yasaklar ve şemada koyacak yer yoktur — İkinci
  Görüş'ün aynı disiplini.
- **Önce elle düğme** ("Kapsama denetle"), sonra otomatik. Gerekçe reponun
  kendi mantığı (`PLAN-model-karsilastirma.md` → Kademeli akış): elle tetiğin
  yanlış-pozitifi yoktur, kullanılmadığında bedavadır ve otomatik tetiğin ne
  sıklıkta haklı çıkacağını ölçmenin en ucuz yoludur.
- **Sonraki adım (otomatik):** yalnız Katman A'nın "her işaret kartlaştı"
  dediği sayfalarda koş. Yani denetçi, denetçinin denetçisi olur — ve en pahalı
  yerde değil, en şüpheli yerde harcar.

### iOS yüzeyi

Yer hazır: `PageDetailView` (PR #43) artık salt-okunur değil, kart ekleme ve
düzenleme oradan yapılıyor.

- Yeni bölüm: **"Kartlaşmamış işaretler (N)"** — her satırda alıntı + işaret
  türü, iki eylem:
  - **Kart üret** → alıntıyı metin-only bir çağrıyla (~$0.0005) taslak karta
    çevirir ve mevcut `ManualCardSheet`'i **önceden doldurulmuş** açar. Doğrudan
    desteye girmez: burada kaynağı seçen model değil sahibidir, ve elle kart
    yolu (boş `canonicalClaim`, `KnowledgeUnitBinding`) zaten bu sözleşmeyi
    taşıyor.
  - **Yoksay** → kalıcı; bir daha sorulmaz (yanlış-pozitif bir işaret sonsuza
    kadar rahatsız etmesin).
- Bilgilerim'de "Gözden geçir"in yanına ikinci kova: **"Eksik olabilir"** —
  kart bazlı değil **sayfa bazlı**, çünkü eksik olanın kartı yok.
- Depolama: `CapturedPage`'e `coverageJSON` (declaration-time default —
  `ModelRun.attempt` dersi: varsayılansız zorunlu alan uygulamayı hiç
  açılmaz hâle getirir).

### Ön koşullar (atlanırsa sessizce yanlış çalışır)

1. **`GEMINI_USD_PER_MILLION_*` doldurulmadan Katman B otomatikleştirilemez.**
   Bugün üçü de 0; Kullanım ekranı her Gemini çağrısını **bedava** sayıyor. Tek
   düğmede bu küçük bir sapmaydı, sayfa başına otomatik çağrıda defter
   sistematik olarak yanlış okur — CLAUDE.md'nin "model değiştirirken fiyatları
   da değiştir" kuralıyla **birebir aynı hata sınıfı**: hiçbir şey patlamaz,
   sadece sayı yanlış olur.
2. **`keepOriginalPage` kapalıysa** telefon sayfayı yeniden yükleyemez (görüntü
   silinmiş) — o kurulumda Katman B sunucuda, iş bitmeden ve kova temizlenmeden
   önce koşmak zorunda. Varsayılan açık; tasarım bu bağımlılığı bilerek
   taşımalı.
3. Katman B'nin çağrısı **ödenen bir çağrıdır**: `ModelRun`'a
   `purpose: "coverage_audit"` ile yazılmalı, yoksa Kullanım toplamı gerçek
   faturanın altında kalır (PR #39'un kapattığı hata).

### Asıl ürün: üç sayı

30 sayfa sonra elde edilecekler:

| Sayı | Kapattığı açık soru |
|---|---|
| Sayfa başına kartsız işaret ortalaması | Kaçırma oranı gerçekte nedir? (bugün bilinmiyor) |
| Kabul / yoksay oranı | Denetçi haklı mı, yoksa gürültü mü üretiyor? |
| A ile B'nin bulduklarının kesişimi | Katman A tek başına yeter mi — B'ye para vermeye değer mi? |

Üçüncüsü ayrıca `PLAN-model-karsilastirma.md`'nin askıda bıraktığı kademe
sorusunu ilk kez ölçülebilir yapar: "kapsama bilinmiyor" tetiği, Sol'a
yükseltmeyi gerçekten hak ediyor mu? Bugün o karar veri olmadan bekliyor.

---

## 3b. Uygulama durumu (2026-08-19)

**Yazıldı ve testli:**

| Parça | Yer |
|---|---|
| Şema v2.3 (`marks[]` + `markId`) | `backend/schemas/llm_output.schema.json`, `llmOutputTypes.ts` |
| Kartsız işaret / işaretsiz kart çıkarımı | `backend/providers/coverage.ts` (`deriveCoverage`, `coverageFromGate`) |
| Onarım (bozuk işaret, boşta `markId`) | `sanitizeMarks`, `openai.ts` içinde `sanitizeTopics`'in yanında |
| Prompt v2.8, kural 13 + anti-teşvik | `backend/prompts/cardGeneration.ts` |
| Model-yüzlü katı şema (zorunlu-ve-nullable, `maxItems = MARK_REGISTER_CEILING`) | `buildModelResponseSchema` |
| Bağımsız denetçi (Gemini) | `backend/prompts/coverageAudit.ts`, `providers/gemini.ts` → `GeminiCoverageAudit` |
| Dördüncü kapı | `backend/api/_coverage.ts` + `api/index.ts` |
| Kademe enum'u üç dilde kilitli | şema ↔ `MARK_KINDS` ↔ `MarkKind`; `evals/tests/test_*_contract_sync.py` |
| Telefon çekirdeği (birleştirme, sıralama, yoksayma, depolama) | `CizgiCore/Models/Coverage.swift` + `CoverageTests` |
| Denetim istemcisi | `CizgiCore/Providers/CoverageAuditProvider.swift` |
| Sayfa detayında "Kartlaşmamış işaretler" + "Kapsama denetle" | `App/Features/ProcessingQueue/CoverageSection.swift` |
| İşaretten kart yazma (önceden doldurulmuş) | `ManualCardSheet(prefill:)` |
| Maliyet defteri | `ModelRun(purpose: "coverage_audit")`, Kullanım ekranında kendi adıyla |

Yeşil: backend 351 test + `tsc`, evals 509 test. Swift tarafı bu ortamda
**gerçekten koşturuldu**: indirilen bir araç zinciriyle (6.0.3) kurulan dilim
paketlerinde 76 test geçti — `CoverageTests` (13), `CoverageAuditProviderTests`
(4), `BackendCardProviderTests` (35), `PipelineTests` (19) ve dahil olan
diğerleri. Yöntem CLAUDE.md'nin "Bu ortamın kalıcı sınırı" notunda.
**Doğrulanmayan:** SwiftUI görünümleri (`CoverageSection`, `PageDetailView`,
`ManualCardSheet`) ve SwiftData modeli — onlar yalnız `swiftc -parse`'tan
geçti; `swift test` + `xcodegen generate` bir Mac'te ya da CI'da koşmalı.

> **Codex turu (PR #47) iki gerçek ters kurulumu yakaladı ve ikisi de düzeltildi.**
> (1) Defter tavanı kullanıcının *kart* ayarına bağlıydı — oysa kart sayısı
> azaldıkça raporlanacak kartsız işaret **artar**; `maxCards=1`'de on işaretli
> bir sayfa yalnız üçünü yazabiliyor, kalanı sessizce kayboluyordu (tam da bu
> katmanın bitirmek için var olduğu hata). Artık sabit bir tavan
> (`MARK_REGISTER_CEILING = 60`). (2) Denetçi şemasında `coveredByCardIndex`
> zorunlu değildi; alanı hiç yazmayan bir satır açık `null` gibi okunup
> **kapsanmış bir işareti kartsız gösteriyordu** — yani denetimin üretmemesi
> gereken tek şeyi, yanlış pozitifi. Artık zorunlu-ve-nullable, eksik alan ise
> "okunamadı" sayılıp eleniyor.

**Açılmadan önce yapılacak iki şey (§3'ün ön koşulları, hâlâ geçerli):**

1. **`GEMINI_USD_PER_MILLION_*` Vercel'e girilmeli.** Bugün 0 ve Kullanım her
   Gemini çağrısını bedava sayıyor. Denetim elle tetiklendiği sürece sapma
   küçük; otomatikleşince defter sistematik olarak yanlış okur.
2. `GEMINI_COVERAGE_MAX_OUTPUT_TOKENS` (varsayılan 8192) kod varsayılanından
   geliyor; Vercel'e girilirse kod varsayılanı devre dışı kalır — kart tavanı
   değişkeninin 2026-08-14'te öğrettiği ders.

**Cihazda görülmeden kapanmaz:**

- Yeni bir sayfa çek → sayfa detayının altında "Kartlaşmamış işaretler"
  bölümü çıkıyor mu; model gerçekten defter yazıyor mu (yazmıyorsa "kapsama
  defteri olmadan üretilmiş" satırı görünür).
- Bir işarete dokun → `ManualCardSheet` işaretin metniyle açılıyor mu; kaydedilen
  kart Tekrar'da görünüyor mu.
- Bir işareti "Yoksay" → listeden düşüyor; **denetimden sonra geri gelmiyor**.
- "Kapsama denetle" → Gemini yanıtı geliyor mu; Ayarlar → Kullanım'da
  "kapsama denetimi" satırı gerçek maliyetle görünüyor mu.
- Eski (v2.3 öncesi) bir sayfayı aç → uygulama açılıyor mu (SwiftData'ya
  `coverageJSON` eklendi) ve o sayfa "defter yok" diyor mu.

**30 sayfadan sonra bakılacak üç sayı** (§3'ün "asıl ürün" tablosu): sayfa
başına kartsız işaret, kabul/yoksay oranı, A ile B'nin kesişimi.

## 4. Diğer iki aday (aynı çerçeve, farklı yüzey)

### Aday 2 — Sentez Egzersizi (en yüksek tavan, en büyük iş)

FES ve konu filtresinden seçilen 3–5 kart → **yalnız o kartlardaki olgulardan
kurulmuş** TUS tipi klinik vinyet. Üretici Luna (metin-only, ~$0.001/soru),
doğrulayıcı Gemini: "kurguda tek doğru şık var mı; verilen kartlarda
bulunmayan bir iddia var mı?" Geçmeyen soru kullanıcıya hiç gösterilmez.

Neden bu mimaride mümkün: **Egzersiz zaten FSRS'ten ayrı** (ADR-007). Üretilmiş
içerik, tekrar planlamasına hiç bulaşmadan denenebilir — seam zaten açık.

**Bağlayıcı sınır:** sentez sorusu **yalnız FES'i besler** (ADR-008: saf
muhasebe, hiçbir zamanlama kararı yok), `EarlyPractice`'e **asla** dokunmaz.
Beş kartlık bir vinyetteki tek yanlışı beş kartın vadesine dağıtmanın doğru bir
yolu yok; ADR-007'nin köprüsü tek karta bakan bir köprüdür.

Değeri: deste atomik olgu sorar, TUS entegrasyon sorar. Aradaki mesafe tam
olarak "biliyorum ama soruyu yapamadım" mesafesidir. Riski: uydurma tıp —
üç sınırla bastırılır (yalnız kendi kartlarındaki olgular, bağımsız
doğrulayıcı, "hangi kartlardan kuruldu" görünürlüğü).

### Aday 3 — Deste Doktoru (kanıtlı değer, orta iş)

2026-08-18 denetimi 996 aktif kartın **117'sini** (%12) kopya ya da kapsanan
buldu ve bu elle, sohbette yapıldı. Kaynak (aynı sayfayı birden çok kez çekmek)
duruyor, yani birikme de duruyor. Aynı denetim ayrıca metni düzeltilmeli ~25
kart ve içeriği şüpheli 3 kart çıkardı — sonuncular `lowConfidence` olmadıkları
için hiçbir otomatik sinyalin görmediği kartlar.

Tekrarlanabilir hâli: `(ders, konu)` kovaları içinde toplu metin çağrıları →
kopya / kapsanan / **çelişen** / iki-fikirli / sayfaya atıf yapan kart önerileri
→ tek dokunuşla geri alınabilir eylem (askıya al, birleştir, düzelt). Tam deste
tek geçişte ~70k girdi token ≈ **$0.015**. Yani haftalık koşturulabilir.

Çelişki tespiti burada gizli mücevher: iki kartın birbirine ters cevap vermesi,
tıpta gerçek bir zarar ve onu bugün hiçbir şey görmüyor.

### Aday 4 — Tekrar anında öğretmen (küçük, ucuz)

Bir kartı ikinci kez unuttuğunda tek dokunuş: "neden karıştırıyorum?" → destedeki
komşu kartlarla karşılaştırmalı kısa açıklama (~$0.0005). Yan ürünü daha
değerli: çıktı çoğu zaman "bu kart kötü" der (iki fikir soruyor, muğlak) ve
doğrudan Aday 3'ün düzeltme kuyruğuna düşer. FES bugün "zor olgu" ile "kötü
kart"ı ayırt edemiyor; bu ayrımı yapan ilk sinyal budur.

---

## 5. Sıra önerisi

1. **Katman A** (küçük, ek çağrı yok, migration yok) → 30 sayfa **ölç**.
2. Sonuca göre **Katman B'nin elle sürümü** → 30 sayfa daha ölç.
3. Otomatikleştirme / kademe yönlendirmesi kararı — artık veriyle.
4. **Aday 3** (kanıtlı, ucuz, geri alınabilir).
5. **Aday 2** (en büyük iş; deste temizlendikten sonra en verimli).

Gerekçe: 1–2 numaranın kaybı **geri döndürülemez** (kaçan işaretin kaynağı
zamanla siliniyor), Aday 3'ünki döndürülebilir (askıya alma zaten var), Aday
2 ise mevcut destenin kalitesini **çarpar** — delikli ve kopyalı bir desteden
üretilen vinyet, deliği ve kopyayı da miras alır.

Sahibi tersini seçerse yol açık: Aday 2 tek başına da yapılabilir; §4'teki
bağlayıcı sınır (FES evet, EarlyPractice hayır) o durumda da geçerlidir.

## 6. Bilinçle dışarıda bırakılanlar

- **Modelin kartı kendiliğinden düzeltmesi/silmesi.** Öneri + tek dokunuş
  yeter; geri alınamaz otomatik eylem bu projenin hiçbir yerinde yok
  (`DuplicateSuspendMigration` bile silmiyor, askıya alıyor).
- **Tekrar (FSRS) akışına üretim sokmak.** §0.8 ve ADR-007'nin sınırı; Egzersiz
  bu iş için zaten ayrılmış yüzeydir.
- **İşaretsiz sayfa metninden "bunu da bilmelisin" kartı üretmek.** ADR-005'in
  kimliği: kart kaynağı yalnız işaretli içeriktir. Kapsama denetimi bu kuralı
  *uygular*, gevşetmez.
