# ADR-003 — OCR uzlaştırma kapısı Google'ın kendi okumasıyla sınırlandı

**Durum:** Kabul edildi (2026-08-03)
**Karar veren:** ANA-PLAN sahibi
**İlgili:** ANA-PLAN §10.2, §10.3, §19.2, §24.2 · `docs/ADR-002-birincil-ocr-secimi.md`

---

## Bağlam

Kullanıcı gerçek bir sayfa ("Tip 4 hipersensitivite") çekip backend'e bağlandıktan
sonra onay ekranında dört "kritik değer uyuşmazlığı" uyarısı gördü:

```
replace: kaynak [hipersenstvite (hypo_hyper)] -> okuma [hipersensitivite (hypo_hyper)]
insert:  kaynak [-] -> okuma [12 (number_decimal)]
insert:  kaynak [-] -> okuma [K- (ion_charge)]
delete:  kaynak [1 (number_decimal)] -> okuma [-]
```

İnceleme iki ayrı sorunu ortaya çıkardı.

### Bulgu 1 — "kaynak"/"okuma" etiketleri ters

`backend/providers/reconcile.ts`, `runGate(gold, hypothesis)` imzasına
`second.text` (Apple, ikincil) değerini `gold`, `first.text` (Google, birincil)
değerini `hypothesis` olarak veriyordu — dosyanın kendi docstring'inin
tanımladığı güven modelinin ("The engine we treat as primary — Google, which
can write Turkish.") tam tersi. Sonuç: ekranda "kaynak" yazan taraf Türkçe
okuyamayan motorun (Apple) çıktısıydı, "okuma" yazan taraf ise gerçekten
kaynağa sadık olan Google'ın çıktısıydı. Bu yalnızca kafa karıştırıcı değil,
IV/IM gibi bir uygulama yolu uyuşmazlığında kullanıcıyı yanlış tarafa "kaynak"
diyerek yönlendirebilirdi.

### Bulgu 2 — Apple Vision'ın metni hâlâ kapıydı

ADR-002 zaten karar vermişti: *"Google Document AI birincil ve tek metin
kaynağı; Apple Vision'ın rolü yerleşimle sınırlı."* Ama `reconcile.ts`'in
`decide()` fonksiyonu, Apple ile Google'ın kritik token düzeyinde
uyuşmadığı **her durumda** `quick_confirm` üretmeye devam ediyordu — yani
ADR-002'den sonra bile Apple'ın (Türkçe okuyamayan) okuması hâlâ "ikinci
görüş" gibi davranıp onay ekranını tetikliyordu.

Ekrandaki dört uyarının tamamı bunun somut örneğiydi — hepsi
`docs/FAZ0-BULGULAR.md`'de belgelenmiş Apple Vision arıza imzalarıydı, gerçek
bir tıbbi belirsizlik değil:

| Uyarı | Gerçekte olan |
|---|---|
| `hipersenstvite` ↔ `hipersensitivite` | Apple harf düşürüyor; ikisi de **hiper**, polarite değişmedi |
| `okuma [12]`, `okuma [K⁻]` | Google okudu, Apple üst simgeleri/karakterleri kaybediyor |
| `kaynak [1 (number_decimal)]` | Apple'ın kendi uydurması (`O₂`→`0,` deseninin bir örneği) |

Ayrıca bunlardan biri (`hipersenstvite`/`hipersensitivite`) ikinci, bağımsız
bir hataydı: `hypo_hyper` regex deseni (`(?:hipo|hiper)\w*`) tüm kelimeyi
kritik-token yüzeyi sayıyordu, sadece `hipo`/`hiper` önekini değil — yani
polarite aynı kalsa bile (`hiper...` ↔ `hiper...`) sondaki bir OCR yazım
hatası "kritik uyuşmazlık" olarak raporlanıyordu.

## Karar

**İki değişiklik, birlikte:**

1. **Etiket yönü düzeltildi.** `runGate` artık `runGate(primary/Google,
   secondary/Apple)` çağrılıyor — "kaynak" her zaman Google'ı, "okuma" her
   zaman Apple'ı adlandırıyor (`reconcile.ts` satır ~150, ~168).

2. **Apple'ın Google ile uyuşmazlığı artık `decide()`'ı gatelemiyor.**
   Kritik-token uyuşmazlığı (satır bazlı `criticalTokenFlags` ve sayfa bazlı
   `gate`) hâlâ **hesaplanıyor ve sonuçta taşınıyor** (audit/denetim için —
   `criticalLineIds`, `Reconciliation.gate`), ama `quick_confirm` kararını
   artık tetiklemiyor. Gatelemeye devam edenler, hepsi Google'ın **kendi**
   okuması hakkında:
   - Okunabilir satır yok / tüm satırlar boş → `reject` (§19.3)
   - El yazısı → `quick_confirm` (§10.4, iki motor da aynı el yazısında
     güvenle yanılabilir)
   - Google'ın kendi düşük güveni (`primaryConfidence < minConfidence`) →
     `quick_confirm`

   Ayrıca `hypo_hyper` karşılaştırması artık yalnızca `hipo`/`hiper` önekini
   kıyaslıyor (`canonical_hypo_hyper` / `canonicalHypoHyper`), tüm kelimeyi
   değil — `evals/ocr_eval/critical_tokens.py` (referans) ve
   `backend/providers/criticalTokens.ts` (üretim) içinde, `canonical_route`
   ile aynı desende.

## Düzeltme — PR #7 incelemesinde bulunan gerçek bir P1

Codex, bu PR'ın incelemesinde `hypo_hyper` önek-katlamasının **paylaşılan bir
fonksiyon üzerinden** `cardGate.ts`'e de sızdığını buldu:
`cardIntroducesUnsourcedCriticalToken`, OCR uzlaştırmasıyla aynı
`addedCriticalTokens`'ı çağırıyor. Katlama koşulsuz olduğu için, modelin
ürettiği bir kart `sourceQuote: "hipokalemi"` derken `back: "hiponatremi"`
yazsa bile — **tamamen farklı bir tanı** — ikisi de `hipo`ya katlandığı için
"uydurulmuş kritik değer yok" sonucu çıkıyor ve model kendi bayraklarını
temiz bıraktıysa kart otomatik kabul edilebilirdi. Bu, tam olarak §19'un
önlemeye çalıştığı hata sınıfı.

**Düzeltme:** Katlama artık **varsayılan kapalı**, yalnızca açıkça istenince
(`fold_hypo_hyper=True` / `{ foldHypoHyper: true }`) çalışıyor:

- `evals/ocr_eval/metrics.py`: `_canonical`, `_sequence_with_surfaces`,
  `_canonical_token_counter`, `critical_token_mismatches`,
  `critical_token_recall_loss`, `added_critical_tokens` — hepsi
  `fold_hypo_hyper: bool = False` keyword-only parametresi aldı.
- `backend/providers/gate.ts`: aynı desende `GateOptions { foldHypoHyper?:
  boolean }` — `canonical`, `criticalTokenMismatches`,
  `criticalTokenErrorRate`, `addedCriticalTokens`, `runGate`.
- **Yalnızca `reconcile.ts`** (OCR-vs-OCR karşılaştırması) ve
  `evals/ocr_eval/export_gate_cases.py` (aynı senaryoyu simüle eden vaka
  üreticisi) `true` geçiyor.
- **`cardGate.ts` hiçbir şey geçmiyor** — varsayılan (katı/strict) davranışı
  kullanıyor, yani `hipokalemi` → `hiponatremi` gibi bir değişiklik artık
  doğru şekilde "uydurulmuş kritik değer" olarak yakalanıyor.

Regresyon: `backend/tests/gate.test.ts` ve `cardGate.test.ts`'e Codex'in tam
senaryosu eklendi (`hipokalemi`/`hiponatremi` katlanmadan yakalanıyor,
`hipersensitivite`/`hipersenstvite` yalnız `foldHypoHyper: true` iken
affediliyor); Python tarafında `evals/tests/test_metrics.py`'ye aynısı.

## Neden güvenli

Bu bir gevşetme değil, **yanlış yerdeki bir kapının kaldırılması**:

- Nihai pasaj metni zaten her zaman Google'dan geliyordu
  (`CapturePipeline.cloudReading`) — Apple'ın metni hiçbir zaman karta
  gitmiyordu (ADR-002). Değişen yalnızca *hangi durumda kullanıcıya
  sorulduğu*, kartın içeriği değil.
- Asıl güvenlik ağı **kartın kendisi** üzerinde çalışıyor:
  `backend/providers/cardGate.ts`, her kartın `front`/`back`'ini kendi
  `sourceQuote`'una karşı bağımsızca kontrol ediyor (`addedCriticalTokens`,
  §19) — bu kontrol `reconcile.ts`'in kararından tamamen bağımsız. (Paylaştığı
  `addedCriticalTokens` fonksiyonunun kendisinde PR incelemesinde bulunan bir
  hata vardı — yukarıdaki "Düzeltme" bölümüne bakın; düzeltmeden önce bu iki
  kullanım yanlışlıkla aynı gevşek katlamayı paylaşıyordu.)
- El yazısı, düşük Google güveni ve boş sayfa hâlâ gatelemeye devam ediyor —
  yalnızca "Apple ne dedi" sorusu artık karar vermiyor.

## Sonuçları

- **Kabul edilen:** Onay ekranı artık yalnızca gerçekten belirsiz durumlarda
  (el yazısı, Google'ın kendi düşük güveni) çıkacak — §24.2'nin "az
  müdahale" hedefine daha yakın. Apple-Google uyuşmazlıkları hâlâ
  `criticalLineIds`/`gate` alanlarında kayıtlı kalıyor (ileride ölçüm/telemetri
  için), yalnızca kullanıcıyı durdurmuyor.
- **Açık kalan:** `evals/ocr_eval/metrics.py`'deki **manifest-tabanlı**
  `critical_token_error_rate(gold_tokens, hypothesis)` ölçümü (altın-set
  değerlendirmesi, canlı uzlaştırmadan ayrı bir kod yolu) aynı
  `hypo_hyper` tüm-kelime karşılaştırması sorununu teorik olarak taşıyabilir;
  bu oturumda dokunulmadı çünkü canlı onay ekranını o değil, `gate.ts`
  besliyor. İleride altın-set ölçümünde aynı yanlış-pozitif görülürse aynı
  düzeltme (`canonical_hypo_hyper`) oraya da taşınmalı.
- **Testler:** `backend/tests/reconcile.test.ts` ve `ocrEndpoint.test.ts`
  güncellendi — Apple-Google kritik uyuşmazlığı senaryoları artık
  `auto_accept` bekliyor (uyuşmazlık `criticalLineIds`'te hâlâ görünür
  kalıyor). Yeni bir regresyon vakası (`evals/shared/gate-cases.json`,
  `hipo_hiper` grubu) tam bu oturumun senaryosunu (`hipersensitivite` ↔
  `hipersenstvite`) sabitliyor. `ios/CizgiCore/Tests/.../BackendPipelineTests.swift`
  içindeki örnek etiket metni de doğru yöne çevrildi — bu testin kendisi
  `reconcile.ts`'i çalıştırmıyor (sentetik bir `RemoteReconciliation`
  kuruyor), yalnızca örneğin doğruluğu için düzeltildi.

## İkinci düzeltme turu — aynı PR incelemesinde bulunan bir P1 + bir P2

Codex, hypo/hyper düzeltmesinin ilk halini de incelemeye devam etti ve iki
gerçek bulgu daha çıkardı.

**P1 — `explanation`'daki uydurma içerik kendi bayrağına güveniyordu.**
Kart üretim promptu v1.1 (§15.2), modele `explanation` alanında kaynak dışı
bağlam ekleme izni veriyor, `enriched=true` işaretiyle. Ama `cardGate.ts`
yalnızca `front`/`back`'i `sourceQuote`'a karşı kontrol ediyordu
(`cardIntroducesUnsourcedCriticalToken`) ve `enriched` bayrağı yanlışlıkla
`false` kalırsa (model unutursa/yanlış işaretlerse) `explanation`'daki
uydurma bir doz/yol hiçbir kontrolden geçmeden otomatik kabul edilebilirdi —
ADR-001'in "modelin kendi bayrağı taban, tavan değil" kuralının tam olarak
yakalamak istediği hata sınıfı.

**Düzeltme:** `explanationIntroducesUnsourcedCriticalToken` eklendi
(`cardGate.ts`) — `explanation`'ı da aynı `addedCriticalTokens` ile
`sourceQuote`'a karşı kontrol ediyor, **`card.enriched`'in değerinden
bağımsız olarak**. Bulunursa `quick_confirm`'e yükseltiyor (ret değil —
`explanation` kasıtlı olarak kaynak dışı içerik taşıyabilir, yalnızca
onaysız geçemez).

**P2 — Türkçe noktalı büyük İ, `hipo`/`hiper` önek eşleşmesini bozuyordu.**
`canonical_hypo_hyper`/`canonicalHypoHyper`, önek testinden önce
`casefold()`/`toLowerCase()` çağırıyordu. Türkçe `İ` (U+0130) varsayılan
küçük harfe çevrildiğinde `i` + birleşen nokta (U+0307) üretir — yani
`"HİPERSENSİTİVİTE".toLowerCase()` düz `"hiper"` ile **başlamaz**, birleşen
noktalı bir dizgiyle başlar. Sonuç: doğru büyük harfli bir Türkçe başlıkta
(`foldHypoHyper: true` ile bile) suffix farkı hâlâ kritik uyuşmazlık
sayılırdı — düzeltmenin kendisi tam da düzeltmesi gereken metinde sessizce
başarısız oluyordu.

**Düzeltme:** Her iki fonksiyon da artık `fold_diacritics`/`foldDiacritics`'i
(zaten var olan, `İ`→`I` gibi tek karakterlik bir çeviri tablosu) önek
testinden **önce** çalıştırıyor — `casefold`/`toLowerCase`'in kendisi asla
birleşen bir işaret üretemeyecek hale geliyor.

Regresyon: `evals/tests/test_critical_tokens.py::TestCanonicalHypoHyper`,
`backend/tests/criticalTokens.test.ts` (`canonicalHypoHyper` describe),
`backend/tests/cardGate.test.ts` (Codex'in tam senaryosu: `enriched: false`
bırakılmış ama `explanation`'da uydurma doz olan bir kart hâlâ
`quick_confirm` alıyor mu).

Testler: Python 511/511, backend 449/449 (bu ortamda koşuldu).

## Üçüncü düzeltme — kritik-token denetimi tek başına yeterli değil

Codex, `explanationIntroducesUnsourcedCriticalToken` eklendikten hemen sonra
aynı fikri bir adım daha derinleştirdi: bu fonksiyon yalnızca §10.5'in
saydığı **sınırlı sınıfları** (sayı, doz, yol, olumsuzluk, ...) yakalayabilir.
Modelin `explanation`'a eklediği ama hiçbir kritik-token sınıfına girmeyen
uydurma bir cümle — Codex'in örneği: kaynakta hiç geçmeyen bir mekanizma
iddiası, "Adrenalin mast hücresi degranülasyonunu tetikler" — `addedCriticalTokens`'tan
boş dönerdi, ve `enriched` yanlışlıkla `false` kaldıysa kart yine
`auto_accept` olurdu.

Bu, aslında **çözülemeyecek bir problem**: serbest bir cümlenin kaynaktan
"gerçekten çıkarılabilir" olup olmadığını anlamak semantik bir yargıdır,
regex tabanlı bir dedektörün yapabileceği bir şey değil (§0.5'in tam
uyardığı tür belirsizlik). Bu yüzden kural, cümlenin içeriğini anlamaya
çalışmak yerine daha basit ve dürüst bir sinyale dayandırıldı:

**Düzeltme:** `verdictForCard` artık `explanation` boş değilse — kritik
token bulunsun ya da bulunmasın, `enriched` ne olursa olsun —
`quick_confirm`'e yükseltiyor. `explanationIntroducesUnsourcedCriticalToken`
hâlâ çalışıyor, ama artık yalnızca *neden* metnini (bulunursa "kaynakta
olmayan kritik değer X" diye) netleştirmek için; kararın kendisi artık ona
bağlı değil. Bu, §12.2'nin zaten söylediği kuralı ("her ek içerik açıkça
onay gerektirir") modelin kendi bayrağına güvenmeden, doğrudan alanın
kendisinden türetiyor — ADR-001'in "modelin bayrağı taban, tavan değil"
ilkesinin bir dedektörün kör noktasına değil, doğrudan alana uygulanmış hali.

**Kabul edilen ödünleşim:** Artık gerçekten kaynağa sadık, hiçbir şey
uydurmayan ama `explanation` alanını dolduran bir kart da onay ister —
§24.2'nin "az müdahale" hedefine küçük bir sürtünme ekliyor. Ama serbest
metnin gerçekten kaynaklı olup olmadığını güvenilir biçimde ayıramadığımız
için, güvenlik tarafında hata yapmak (§0.5, §19.2) daha az müdahaleden
önceliklidir.

Regresyon: `backend/tests/cardGate.test.ts`'e Codex'in ikinci örneği
(kritik-token sınıfına girmeyen uydurma mekanizma cümlesi) eklendi.

Testler: backend 450/450 (bu ortamda koşuldu).
