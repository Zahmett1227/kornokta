# Mimari

> Ayrıntılar için ana kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §7 (teknik mimari), §16 (veri modeli), §17 (iş kuyruğu ve durum makinesi).

> **⚠️ Faz 6 (2026-08-05'te karar, 2026-08-07'de kod tamam):** "Deterministik
> işlem hattı" başlığından itibaren anlatılanlar (Apple Vision + cihaz-üstü
> işaret tespiti + Google Document AI + uzlaştırma + grounding + fotoğraf-üstü
> onay) **ana akış olmaktan çıktı.** İlgili kod repoda duruyor ama çağrılmıyor
> (geri dönüş için, ADR-005). Güncel akış hemen aşağıda.

## Güncel ana akış (Faz 6 + ADR-006)

```text
kamera ─┐
galeri ─┴→ yerel düzeltme + JPEG (galeride: yön + format normalize)
        → dHash ile yinelenen sayfa sorusu → diske yaz
  → ProcessingQueue (3'lü paralel, ekran kilidi + arka plan assertion)
  → POST /api/jobs  ─ sayfa Supabase Storage'a yazılır, satır 'queued', 202 döner
                     ─ üretim yanıttan SONRA waitUntil altında sürer:
                       claim → OpenAI vision (Structured Outputs) → sonuç satıra yazılır
  → GET /api/jobs?ids=  (telefon yoklar; unutulmuş işi başlatır, ölü işi geri alır)
  → kartlar onaysız .active → SwiftData → FSRS-6 tekrarı
     (kartın bir kısmı beş şıklı olabilir; şüpheli olanlar bloklanmaz,
      "Gözden geçir" listesinde işaretlenir)
```

Üç şey bu akışın omurgası:

- **İş kimliği = sayfa kimliği.** Uygulama beklerken öldürülse bile bir sonraki
  açılış biten işi bulup alır; aynı sayfa iki kez üretilmez, ikinci ücret yok.
- **Her durum değişikliği koşullu.** `claim`/`complete`/`fail`/`expire` PostgREST
  filtreleriyle (`?status=eq.queued` gibi) yazılır; kaybeden yazma 0 satır
  günceller ve kendi yüklemesini temizler. Kural `JobStoreLike`'ın başında.
- **Telefon Supabase'i hiç görmez.** `jobs` tablosu ve `page-uploads` kovasında
  RLS açık, policy yok; yalnız Vercel'deki `service_role` anahtarı geçer.

Beş şıklı (TUS tipi) kart (§13.3) bu akışın içinde yaşar: sözleşme
(`options`/`correctOption`) şema v2.1'de, yapısal kontrol
`providers/multipleChoice.ts`'te, cihaz tarafı kuralları
`CizgiCore/Models/MultipleChoice.swift`'te. **Şık karşılaştırma anahtarı iki
yerde tanımlı** (sunucu `optionKey`, cihaz `comparisonKey`) ve ikisi aynı
çiftlerle test edilir — anti-drift disiplininin bu fazdaki örneği.

Karar kayıtları: [`ADR-005`](ADR-005-kisisel-vision-yeniden-tasarim.md) (pivot),
[`ADR-006`](ADR-006-supabase-is-kuyrugu.md) (iş kuyruğu),
[`FAZ6-PLAN`](FAZ6-PLAN.md) (dosya bazlı plan ve durum),
[`COKLU-FOTO-TIMEOUT`](COKLU-FOTO-TIMEOUT.md) (zaman aşımının teşhisi),
[`PLAN-galeriden-foto`](PLAN-galeriden-foto.md) (galeri içe aktarma ve HEIC
tuzağı), [`FAZ7-PLAN-coktan-secmeli`](FAZ7-PLAN-coktan-secmeli.md) (beş şıklı
kart).

## Bileşenler

- **iOS istemci** (`ios/`): Swift 6+, SwiftUI, SwiftData, Vision/VisionKit, Core Image. Yakalama, yerel OCR önizleme (satır kutuları için — metin için değil, bkz. aşağı), cihaz üstü işaret tespiti, kuyruk, gerçek kart üretimi istemcisi (Faz 3), gerçek FSRS-6 tekrarı (Faz 4). Faz 1'de başladı, Faz 2-4'te tamamlandı; hepsi bir Mac'te `swift test` ile doğrulandı.
- **Backend** (`backend/`): Vercel Functions. Sağlayıcı anahtarlarını saklar, OpenAI vision ile kart üretir ve bunu asenkron bir iş kuyruğu üzerinden yürütür (`/api/jobs`). Google Document AI/uzlaştırma yolu (`/api/ocr`) kodda duruyor ama ana akışta çağrılmıyor. Kalıcı veri kaynağı değildir; ana veri iPhone'daki SwiftData'dadır — Supabase yalnız bir **iş kuyruğu ve geçici görüntü kovasıdır**, işi biten sayfanın görüntüsü silinir.
- **Evals** (`evals/`): Altın test seti, OCR/işaret metrikleri, model karşılaştırma araçları, FSRS-6 referans algoritması (Faz 4). Faz 0'da kuruldu; sonraki fazlarda regresyon kapısı olarak kalıyor (517 Python testi). Kart tipi enum'unun üç dilde aynı kalmasını da bu paket kontrol ediyor (`test_ts_contract_sync.py`, `test_swift_contract_sync.py`).

## Apple Vision yalnız önizleme ve geometri için — metin için değil

`docs/ADR-002-birincil-ocr-secimi.md`: Apple Vision Türkçe metin tanımayı
**desteklemiyor** (`ı ş ğ İ` sıfır kez üretiyor, ölçüldü). Bu yüzden:

- Vision'ın **metni** hiçbir zaman karta gitmiyor — yalnız canlı önizleme ve
  işaret tespitinin çalıştığı satır kutuları için kullanılıyor.
- Google Document AI **birincil ve tek metin kaynağı**.
- İki motorun satırları farklı numaralandığı için (`line_00` her ikisinde de
  farklı fiziksel satırı gösterebilir) eşleştirme id ile değil, **geometrik
  örtüşmeyle (IoU)** yapılıyor — hem backend'de hem iOS'ta aynı eşik (0.3).

## İşlem hattı (özet)

```text
kamera/fotoğraf → yerel sayfa düzeltme → Apple Vision (önizleme + token/satır geometrisi)
  → cihaz üstü işaret kanıtı → Google Document AI OCR (bir kez) → token-geometri ile grounding
  → cihazdaki OCR anlık görüntüsü + fotoğraf üzeri onay → grup başına kart üretimi
  → kalite doğrulama → hazır → SwiftData + FSRS-6 (Faz 4)
```

Durum makinesi ve hata dalları: ANA-PLAN §17. Tüm adımlar idempotent; tekrar planlama LLM'siz, deterministik kodda (§0.8, P6).

## Annotation-grounding ve fotoğraf tabanlı onay

İşaret seçimi artık düz bir `lineIds` dizisi değildir. `AnnotationEvidence`
(tip, normalize bbox, token/satır kimlikleri, güven ve piksel ölçümleri) ile
`AnnotationGroup` (seçili metin, bağlam, başlık, düzen türü, el yazısı ilişkisi)
ayrı sözleşmelerdir. Aynı metin farklı bölgelerdeyse, iki sütundaysa ya da
geometrik olarak uzaksa iki grup olarak kalır. Kısa bir alt çizgi seçili tokenı
gösterir; bağlamı yalnız kendi OCR satırına genişler.

Google sonucu geldikten sonra `OCRSnapshot` cihazda saklanır. Belirsiz/quick
confirm durumunda SwiftUI ekranı Vision veya Google'ı yeniden çağırmaz: sayfa
fotoğrafı üzerinde renkli bbox katmanları, büyütme/kaydırma ve erişilebilir
metin özeti gösterir. Onaylanan aynı snapshot kart üretimine devam eder; bu
akışta ikinci OCR ücreti veya farklı OCR sonucu yoktur.

Her onaylı grup için SwiftData'da gerçek bbox, token/evidence kimlikleri,
seçili ve bağlam metni, düzen/seçim türü, varsa el yazısı notu ve gerçek kaynak
kırpması saklanır. Bu ayrıntılı yerel metadata mevcut `/api/cards` sözleşmesine
otomatik eklenmez; kullanıcı açıkça onaylamadan OCR türevi konum/not verisi yeni
bir dış isteğe taşınmaz.

Document AI token/stil alanları (el yazısı, altı çizili, arka plan rengi)
`DOCUMENTAI_COMPUTE_STYLE_INFO=true` ile istenir; Enterprise OCR sürümü ve
maliyet doğrulanana kadar varsayılan kapalıdır. Karar: ADR-004.

## Aynı davranış iki yerde — anti-drift disiplini

Kritik token motoru hem Python'da (referans, `evals/ocr_eval/critical_tokens.py`)
hem TypeScript'te (backend, üretimde çalışan) var. İşaret tespiti hem Python'da
(`evals/spikes/marker_detection/`) hem Swift'te (`ios/CizgiCore/Sources/CizgiCore/MarkerDetection/`)
var. İkisinin ayrışmaması için:

- Regex kalıpları Python'dan üretilip `backend/providers/criticalTokenPatterns.json`'a yazılıyor.
- Davranış, Python'dan üretilen paylaşılan vaka dosyalarıyla (`evals/shared/*.json`) her iki dilde de sabitleniyor.
- Eşikler (`evals/spikes/marker_detection/config.json`) byte-birebir aynı kopya olarak `ios/CizgiCore/Sources/CizgiCore/Resources/`'a taşınıyor; bir Python testi ayrışırsa kırılıyor.
- Her üretici `--check` modunda çalışıp CI'da doğrulanıyor.
- Kart tipi enum'u üç yerde (`llm_output.schema.json`, `llmOutputTypes.ts`,
  `Enums.swift`) ve eşitliği iki Python testiyle bağlı.
- Şık karşılaştırma anahtarı iki dilde (`optionKey` / `comparisonKey`);
  üretilemeyecek kadar küçük olduğu için **aynı çiftlerle** test ediliyor, yani
  biri kayarsa iki test dosyası birlikte kırılıyor. Bu çift PR #29'da iki kez
  ayrıştı (noktalama, sonra circumflex) — küçük bir tablonun bile elle senkron
  tutulamadığının kaydı.

## Kanonik sözleşmeler

- LLM çıktı sözleşmesi: [`backend/schemas/llm_output.schema.json`](../backend/schemas/llm_output.schema.json) (ANA-PLAN §14)
- Altın set manifesti: [`evals/gold-manifest.schema.json`](../evals/gold-manifest.schema.json) (ANA-PLAN §23.1)
- Model kimlikleri ve eşikler merkezi config'te tutulur, koda gömülmez (§0.6, §11.3). Faz 0 spike eşikleri: [`evals/spikes/marker_detection/config.json`](../evals/spikes/marker_detection/config.json)
- Annotation-grounding kararı: [`docs/ADR-004-annotation-grounding.md`](ADR-004-annotation-grounding.md)
