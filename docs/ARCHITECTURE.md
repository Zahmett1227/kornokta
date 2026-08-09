# Mimari

> Ayrıntılar için ana kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §7 (teknik mimari), §16 (veri modeli), §17 (iş kuyruğu ve durum makinesi).

> **Not (2026-08-09):** Faz 6 öncesi deterministik hat (Apple Vision + cihaz
> üstü işaret tespiti + Google Document AI + uzlaştırma + grounding + fotoğraf
> üstü onay) önce ana akıştan çıkmıştı (ADR-005); bu tarihte **koddan da
> silindi**. Geri dönüş artık bir config bayrağı değil, ilgili tıraş commit'inin
> revert'idir. O mimarinin kaydı ADR-002/003/004 ve `docs/HISTORY.md`'dedir.

## Ana akış (Faz 6 + ADR-006 + ADR-007)

```text
kamera ─┐
galeri ─┴→ yerel düzeltme + JPEG (galeride: yön + format normalize)
        → dHash ile yinelenen sayfa sorusu → diske yaz
  → ProcessingQueue (3'lü paralel, ekran kilidi + arka plan assertion)
  → POST /api/jobs  ─ sayfa Supabase Storage'a yazılır, satır 'queued', 202 döner
                     ─ üretim yanıttan SONRA waitUntil altında sürer:
                       claim → OpenAI vision (Structured Outputs) → sonuç satıra yazılır
  → GET /api/jobs?ids=  (telefon yoklar; unutulmuş işi başlatır, ölü işi geri alır,
                         60 günden eski biten sonuçları süpürür)
  → kartlar onaysız .active → SwiftData → FSRS-6 tekrarı
     (kartın bir kısmı beş şıklı olabilir; şüpheli olanlar bloklanmaz,
      "Gözden geçir" listesinde işaretlenir)
  → Egzersiz pratiği FSRS'i yalnız EarlyPractice köprüsünden besler (ADR-007):
     erken doğru → kısmi stabilite kredisi; erken yanlış → soft lapse;
     vadeye yakın yanlış → gerçek lapse
```

Omurga ilkeleri:

- **İş kimliği = sayfa kimliği.** Uygulama beklerken öldürülse bile bir sonraki
  açılış biten işi bulup alır; aynı sayfa iki kez üretilmez, ikinci ücret yok.
- **Her durum değişikliği koşullu.** `claim`/`complete`/`fail`/`expire`/
  `purgeFinished` PostgREST filtreleriyle (`?status=eq.queued` gibi) yazılır;
  kaybeden yazma 0 satır günceller ve kendi yüklemesini temizler. Kural
  `JobStoreLike`'ın başında.
- **Telefon Supabase'i hiç görmez.** `jobs` tablosu ve `page-uploads` kovasında
  RLS açık, policy yok; yalnız Vercel'deki `service_role` anahtarı geçer.
- **Tekrar planlaması deterministik.** FSRS-6 ve Egzersiz köprüsü LLM'siz kodda;
  model yalnız görüntü yorumlama ve içerik üretiminde (§0.8).

Beş şıklı (TUS tipi) kart (§13.3) bu akışın içinde yaşar: sözleşme
(`options`/`correctOption`) şema v2.1'de, yapısal kontrol
`providers/multipleChoice.ts`'te, cihaz tarafı kuralları
`CizgiCore/Models/MultipleChoice.swift`'te. **Şık karşılaştırma anahtarı iki
yerde tanımlı** (sunucu `optionKey`, cihaz `comparisonKey`) ve ikisi aynı
çiftlerle test edilir — anti-drift disiplininin bu fazdaki örneği.

Karar kayıtları: [`ADR-005`](ADR-005-kisisel-vision-yeniden-tasarim.md) (pivot),
[`ADR-006`](ADR-006-supabase-is-kuyrugu.md) (iş kuyruğu + saklama),
[`ADR-007`](ADR-007-egzersiz-fsrs-koprusu.md) (Egzersiz→FSRS köprüsü),
[`FAZ6-PLAN`](FAZ6-PLAN.md) (dosya bazlı plan),
[`COKLU-FOTO-TIMEOUT`](COKLU-FOTO-TIMEOUT.md) (zaman aşımının teşhisi),
[`PLAN-galeriden-foto`](PLAN-galeriden-foto.md) (galeri içe aktarma),
[`FAZ7-PLAN-coktan-secmeli`](FAZ7-PLAN-coktan-secmeli.md) (beş şıklı kart),
[`PLAN-egzersiz-bilgi-haritasi`](PLAN-egzersiz-bilgi-haritasi.md) (Egzersiz +
Bilgi Haritası).

## Bileşenler

- **iOS istemci** (`ios/`): Swift 6+, SwiftUI, SwiftData. Yakalama (kamera +
  galeri), dayanıklı işleme kuyruğu, kart üretimi istemcisi, gerçek FSRS-6
  tekrarı, Egzersiz modu + Bilgi Haritası, yedekleme (v5). Ana veri kaynağı
  telefondaki SwiftData'dır.
- **Backend** (`backend/`): Vercel Functions. Sağlayıcı anahtarını saklar,
  OpenAI vision ile kart üretir ve bunu asenkron iş kuyruğu üzerinden yürütür
  (`/api/jobs`); `/api/cards-vision` senkron ikinci kapı. Kalıcı veri kaynağı
  değildir — Supabase yalnız bir **iş kuyruğu ve geçici görüntü kovasıdır**:
  görüntü iş bitince, sonuç metni 60 gün sonra silinir.
- **Evals** (`evals/`): FSRS-6 referans algoritması (Swift portunun kilidi),
  sözleşme senkron testleri (kart tipi enum'ları, ders/konu şeması, FSRS
  ağırlıkları), Türkçe normalizasyon referansı ve tarihsel OCR/işaret-tespiti
  araçları.

## Aynı davranış iki yerde — anti-drift disiplini

Tıraş sonrası hâlâ canlı olan çiftler:

- **FSRS-6**: Python referansı (`evals/fsrs/`) ↔ Swift portu; davranış
  `evals/shared/fsrs-cases.json` ile, ağırlık dosyası `test_fsrs_config_sync.py`
  ile kilitli.
- **Kart tipi enum'u**: `llm_output.schema.json` ↔ `llmOutputTypes.ts` ↔
  `Enums.swift`; eşitlik iki Python testiyle bağlı
  (`test_ts_contract_sync.py`, `test_swift_contract_sync.py`).
- **Ders/konu şeması**: `backend/schemas/subject_topics.json` ↔
  `ios/.../Resources/subject_topics.json` byte-birebir;
  `backend/tests/subjectTopics.test.ts` ayrışırsa kırılır.
- **Şık karşılaştırma anahtarı**: sunucu `optionKey` ↔ cihaz `comparisonKey`,
  aynı vaka çiftleriyle iki tarafta test edilir. Bu çift PR #29'da iki kez
  ayrıştı — küçük bir tablonun bile elle senkron tutulamadığının kaydı.

Kural değişmedi: yeni bir "aynı davranış iki yerde" durumu çıkarsa elle senkron
tutma — üret ve testle kilitle.

## Kanonik sözleşmeler

- LLM çıktı sözleşmesi: [`backend/schemas/llm_output.schema.json`](../backend/schemas/llm_output.schema.json) (ANA-PLAN §14)
- Model kimlikleri ve eşikler merkezi config'te tutulur, koda gömülmez (§0.6, §11.3).
