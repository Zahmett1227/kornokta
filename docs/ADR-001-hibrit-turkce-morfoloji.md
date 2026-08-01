# ADR-001 — Türkçe morfoloji için hibrit yaklaşım

**Durum:** Kabul edildi (ANA-PLAN sahibi kararı)
**Tarih:** 1 Ağustos 2026
**Bağlam:** ANA-PLAN §10.4, §10.5, §19.2, §23.2
**Yerini aldığı:** `docs/FAZ0-PLAN.md` F2-5 maddesi (bu belge onun kararlaştırılmış hâlidir)

## Problem

Kritik token eşleştirmesi Türkçe biçimbilimini sözlüksüz düzenli ifadeyle çözmeye çalışıyor. Faz 0 kod incelemesi boyunca bu yaklaşımın uzun kuyruklu olduğu ortaya çıktı — her tur yeni bir çekim biçimi veya eşyazımlı sözcük:

| Girdi | Yanlış davranış |
|---|---|
| `solunum` | `sol` + `un` + `um` diye ayrışıyordu |
| `sağlıklı` | türetme ekiyle `sağ` sanılıyordu |
| `sağlar` (fiil) | `sağ` + çoğul sanılıyordu |
| `gün` | `g` birimi + ek sanılıyordu |
| `noradrenalin` | içinde `adrenalin` bulunuyordu |
| `kullanılmamalıdır` | olumsuzluk hiç görülmüyordu |

Her biri düzeltildi ve regresyona bağlandı, ancak kuyruğun bittiğine dair kanıt yok: gerçek bir biçimbilimsel çözümleyici ve sözlük olmadan `sağlar`ı `sağ`dan ayırmanın genel bir yolu yok.

**Karar:** Her ek için yeni regex/istisna yazmaya devam etmek yerine hibrit yapıya geçilir. Ancak yapay zekâ, kritik tokenlar üzerinde **karar mercii değildir.**

## Katman sorumlulukları

### Deterministik katman (kod)

Aşağıdaki sınıflar **yalnızca deterministik kodla** kontrol edilir. Bu katmanın kararı nihaidir:

| Sınıf | Örnek |
|---|---|
| Sayı ve ondalık ayraç | `0,5` `1,25` |
| Doz | `0,3–0,5 mg` |
| Birim | `mg` `mEq/L` `mmHg` |
| Oran / yüzde | `%40` `1/3` |
| Süre ve sıklık | `q8h` `günde 2` `haftada 1` |
| Uygulama yolu (route) | `IV` `IM` `PO` (§10.5.1) |
| Olumsuzluk | `kullanılmamalıdır` `değildir` `artmaz` |
| İyon yükü | `Na⁺` `Ca²⁺` `HCO₃⁻` |
| Anatomik yön | `sağ` `sol` `proksimal` `distal` |
| Karşılaştırma ifadeleri | `<` `>` `≤` `≥` `arttıkça` |

Uygulama: `evals/ocr_eval/critical_tokens.py` ve `evals/ocr_eval/metrics.py`.

### AI katmanı (LLM)

AI **yalnızca kritik olmayan sözcüklerdeki** Türkçe çekim ve anlamsal eşdeğerliği değerlendirir.

İzin verilen:
- Çekim eki farklarını eşdeğer sayma: `sağ böbrekte` ≡ `sağ böbreğin içinde` (kritik tokenlar aynıysa)
- Sözdizimi farkı: `IM uygulanır` ≡ `intramüsküler olarak uygulanır`
- Yazım/harf hatası: `hiperkalemı` → `hiperkalemi` (kritik token sınıfı dışıysa)

**Yasak:**
- Kritik token uyuşmazlığını geçersiz kılmak
- Kritik tokenı sessizce düzeltip uyuşmazlığı gizlemek
- Farklı uygulama yollarını eşdeğer saymak
- Kritik token sınıfı hakkında yeni karar üretmek

## AI'nın geçersiz kılamayacağı kritik token sınıfları

Şunlar **hiçbir koşulda** benzer/eşdeğer kabul edilmez; AI aksini söylerse kararı yok sayılır:

- `sağ` ↔ `sol`
- `artırır` ↔ `azaltır`, `yükselir` ↔ `düşer`
- `kullanılmalıdır` ↔ `kullanılmamalıdır`
- `hiper-` ↔ `hipo-`
- `pozitif` ↔ `negatif`
- `var` ↔ `yok`
- `proksimal` ↔ `distal`
- `IV` ↔ `IM` ↔ `PO` (ve diğer tüm yol çiftleri)
- Farklı sayı, doz, birim, oran, süre, sıklık değerleri
- Farklı iyon yükleri

Bu liste kodda enum olarak tutulur; AI çıktısı bu enum'a karşı doğrulanır.

## Karar akışı

```text
OCR çıktısı + kaynak transkripsiyon
  ↓
Deterministik kritik token karşılaştırması (3 ölçüm)
  ↓
Kritik uyuşmazlık VAR mı?
  ├─ Evet → hard fail veya quick_confirm.  AI'ya SORULMAZ.
  └─ Hayır → kalan metin farkı var mı?
       ├─ Hayır → otomatik kabul
       └─ Evet  → AI katmanına sor (yalnız kritik olmayan sözcükler)
            ├─ AI "eşdeğer" + güven ≥ eşik → otomatik kabul
            ├─ AI "eşdeğer değil"          → quick_confirm
            └─ AI emin değil / güven < eşik → quick_confirm
```

**Belirsizlik hiçbir zaman kabul yönünde çözülmez.**

## Kayıt (audit)

AI katmanının her kararı için saklanır:

| Alan | Açıklama |
|---|---|
| `decision` | `equivalent` \| `not_equivalent` \| `uncertain` |
| `confidence` | 0–1 |
| `rationale` | Modelin kısa gerekçesi |
| `criticalTokensChecked` | Deterministik katmanın bulduğu kritik tokenlar |
| `promptVersion`, `model` | Sürüm izlenebilirliği |
| `latencyMs`, `inputTokens`, `outputTokens`, `estimatedCostUSD` | §16.8 ModelRun ile aynı |

İçerik/metin varsayılan olarak loglanmaz (§22).

## Maliyet ve gecikme etkisi

AI katmanı **yalnızca** deterministik katman temiz çıkıp metinde kalan fark olduğunda çağrılır. Beklenen tetiklenme oranı düşük; çoğu okuma ya tam eşleşir ya da kritik uyuşmazlıkla zaten reddedilir.

| Kalem | Tahmin |
|---|---|
| Tetiklenme oranı | Yakalamaların ~%10–20'si (altın setle ölçülecek) |
| Ek gecikme | Yalnız tetiklendiğinde, yakalama başına ~1–2 sn |
| Ek maliyet | Kısa girdi (yalnız iki metin parçası), çıktı ≤150 token |
| §20 bütçesine etkisi | Sınırlı; kart üretimi çağrısına göre belirgin biçimde ucuz |

Kullanıcı akışına gecikme yansımaz: karşılaştırma arka plan kuyruğunda çalışır (§17, P1).

**Ölçülecek:** gerçek tetiklenme oranı ve maliyet, altın set toplandıktan sonra `evals/reports/` altına yazılır. Tetiklenme beklenenin üzerindeyse önce deterministik katmanın yanlış pozitifleri incelenir — AI'yı daha çok çağırmak çözüm değildir.

## Uygulama sırası

1. **Faz 0 (şimdi):** Deterministik katman ve üç ölçümlü kapı hazır. AI katmanı **yok**; belirsizlik doğrudan `quick_confirm`.
2. **Faz 2:** Altın setle deterministik katmanın yanlış pozitif/negatif oranı ölçülür. AI katmanının gerçekten hangi vakalarda gerektiği veriyle belirlenir.
3. **Faz 3:** AI katmanı backend'e eklenir; şema, enum doğrulaması ve audit kaydı bu belgeye göre yazılır.

Bu sıra bilinçli: AI katmanını veri olmadan eklemek, hangi sorunu çözdüğünü bilmeden karmaşıklık eklemek olur.

## Sonuç

- Deterministik katman güvenlik sınırıdır ve daraltılmaz.
- AI katmanı yalnızca **kabul oranını artırmak** için vardır, güvenliği gevşetmek için değil.
- Emin olunmayan her durum kullanıcıya gider.
