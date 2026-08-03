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

## Neden güvenli

Bu bir gevşetme değil, **yanlış yerdeki bir kapının kaldırılması**:

- Nihai pasaj metni zaten her zaman Google'dan geliyordu
  (`CapturePipeline.cloudReading`) — Apple'ın metni hiçbir zaman karta
  gitmiyordu (ADR-002). Değişen yalnızca *hangi durumda kullanıcıya
  sorulduğu*, kartın içeriği değil.
- Asıl güvenlik ağı **kartın kendisi** üzerinde çalışıyor:
  `backend/providers/cardGate.ts`, her kartın `front`/`back`'ini kendi
  `sourceQuote`'una karşı bağımsızca kontrol ediyor (`addedCriticalTokens`,
  §19) — bu kontrol reconcile.ts'ten tamamen bağımsız ve değişmedi.
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
