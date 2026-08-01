# Faz 0 — Risk Azaltma Çalışma Planı

> Kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §25 (Faz 0), §9 (işaret tespiti), §10 (OCR/el yazısı), §27 (model değerlendirme). Amaç: ürün ekranlarına yatırım yapmadan önce **alt çizgi / OCR / el yazısı** riskini doğrulamak.

## Neden Faz 0

Uygulamanın en yüksek teknik riski UI değil, şu üç sorunun birlikte çözülmesidir:
1. İşaretli (altı çizili/fosforlu) satırın doğru seçilmesi (§9, §30).
2. OCR'ın tıbbi anlamı değiştiren token'ları bozmaması (§10.5).
3. El yazısının güvenli transkripsiyonu ve kritik uyuşmazlıkta kullanıcıya dönülmesi (§10.4).

Bu sorunlar çözülmeden ekran geliştirmek boşa yatırımdır. Faz 0, bunları ölçülebilir kapılarla doğrular.

## Bu repoda şu an hazır olanlar (çalıştırılabilir)

| Teslimat | Konum | Durum |
|---|---|---|
| Altın set manifest şeması + doğrulayıcı | `evals/gold-manifest.schema.json`, `evals/ocr_eval/validate_manifest.py` | Hazır |
| OCR/seçim metrikleri (CER, WER, P/R/F1, kritik token) | `evals/ocr_eval/metrics.py` | Hazır |
| Kritik token detektörü (§10.5, 16 sınıf) | `evals/ocr_eval/critical_tokens.py` | Hazır |
| İşaret tespiti spike'ı (fosforlu/alt çizgi) | `evals/spikes/marker_detection/` | Hazır (sentetik) |
| Model karşılaştırma iskeleti (§27) | `evals/spikes/provider_compare/` | İskelet (dry-run) |
| Kart kalite rubriği (§23.3) | `evals/card_quality/rubric.py` | Hazır |
| Kanonik LLM çıktı sözleşmesi (§14) | `backend/schemas/llm_output.schema.json` | Hazır |

Çalıştırma: `python -m pytest evals`, `python -m evals.spikes.marker_detection.run --demo`.

Spike'ın **çözmediği** noktalar için aşağıdaki "Bilinen sınırlar ve Faz 2 takip maddeleri" bölümüne bakın.

## Yapılacaklar ve ortam gereksinimleri

Faz 0'ın bazı adımları bu Linux ortamında (Xcode/iPhone yok) tamamlanamaz. Aşağıda hangi adımın nerede yapılacağı işaretlidir.

| Adım | Ortam | Not |
|---|---|---|
| 100 görsellik altın set toplama | iPhone + yerel | Telifli görseller repoya girmez (§26, §30). Rehber: [GOLD-SET-GUIDE](GOLD-SET-GUIDE.md) |
| Görselleri manifeste etiketleme | Herhangi | `validate_manifest ... --check-files` ile doğrula |
| Apple Vision OCR deneyi | **macOS/iOS** | Cihaz üstü; bu ortamda çalışmaz. Çıktı, gold transkripsiyonla `metrics.py` üzerinden karşılaştırılır |
| Google Document AI OCR deneyi | Herhangi (anahtar gerekir) | `GOOGLE_APPLICATION_CREDENTIALS` env; anahtar repoya girmez |
| İşaret tespiti kalibrasyonu | Herhangi | `marker_detection/config.json` eşikleri gerçek görsellerle güncellenir |
| Sol/Gemini/Claude karşılaştırması | Herhangi (anahtar gerekir) | `provider_compare` --live (Faz 3 adaptörleri gerekince) |
| Ölçüm raporu | Herhangi | `evals/reports/` (gitignore'lu) altına yazılır |

## Kalibrasyon planı (§9.3 eşikleri)

`marker_detection/config.json` içindeki ağırlık ve eşikler **ilk başlangıç değeridir, ürün kararı değildir.** Gerçek altın set toplandıktan sonra:

1. Her gold görüntüde `analyze_page` çalıştır, tahmin edilen seçili satırları çıkar:
   `selected_line_ids(detections, include_pending=True)` — **tespit kalitesini** ölçerken onay bekleyenler de dahil edilmeli, yoksa kalibrasyonun kendisi onay kapısıyla karışır. Varsayılan (`include_pending=False`) yalnız otomatik kabul edilenleri verir ve *kapıyı* ölçmek için kullanılır.
2. `selection_prf(gold_lines, predicted_lines)` ile kategori bazında precision/recall/F1 hesapla.
3. `autoCandidate` / `quickConfirm` eşiklerini şu hedefe göre ayarla:
   - **Yanlış satırın sessiz otomatik kabulü ≈ 0** (§24.2) — yüksek precision önceliklidir.
   - Kalan belirsizlik kullanıcıya "quick_confirm" olarak yönlendirilir.
4. Kurşun kalem kategorisini ayrı raporla (en zor sınıf, §30).

## Çıkış kapıları (§25 Faz 0)

Faz 1'e geçmeden önce:

- [ ] Altın test seti ≥ 100 görüntü, kategori kotaları dolu (`validate_manifest` uyarısız).
- [ ] Alt çizgi/fosforlu tespitinde çekimlerin **≥ %95'i** tamamen doğru veya **tek dokunuşla** düzeltilebilir (§24.2).
- [ ] Basılı metinde **kritik token hatası otomatik kayda geçmiyor** (§24.3) — kritik uyuşmazlık `needs_confirmation` üretir.
- [ ] El yazısında kritik uyuşmazlık kullanıcı onayı olmadan karta dönüşmüyor (§10.4, §24.3).
- [ ] Model karşılaştırması en az bir aday için kabul rubriğini (≥12/14) geçiyor (§23.3, §27).
- [ ] Ölçüm raporu yazıldı (CER/WER, kritik token hata oranı, seçim F1, otomatik kabul precision'ı, çekim başına düzeltme dokunuşu).

## Uygulama yolu (route) kontrolü

ANA-PLAN §10.5 ve §10.5.1 uyarınca uygulama yolu kritik token sınıfıdır (ANA-PLAN sahibi tarafından onaylandı ve şartnameye işlendi). Uygulama: `evals/ocr_eval/critical_tokens.py` içindeki `ROUTE_SYNONYMS` sözlüğü.

- Aynı yolun tüm yazımları tek kanonik koda katlanır: `IV` = `intravenöz` = `damar içi`.
- Farklı kodlar **asla** eşdeğer sayılmaz; aralarındaki fark her zaman uyuşmazlıktır ve sessizce otomatik kaydedilemez.
- Katlama üç kapı ölçümünde de aynıdır. Biri katlarken diğeri katlamazsa doğru bir transkripsiyon kapıdan geçemez; bu hata bir kez yaşandı, o yüzden regresyon testi üç ölçümü **birlikte** kontrol ediyor.
- `IN`, `IA`, `TOP`, `OT`, `OPH` çıplak kısaltmaları bilinçli olarak kayıtlı değil (sıradan sözcüklerle çakışır); bu yollar tam yazımlarıyla kapsanıyor.

**Yeni yol/yazım eklerken:** `ROUTE_SYNONYMS` içine yaz, `test_full_route_spellings_detected` ve `test_synonyms_fold_to_one_code` listelerine ekle. Çıplak kısaltma ekliyorsan `test_word_internal_letters_are_not_a_route` ile çakışma kontrolü yap.

## Bilinen sınırlar ve Faz 2 takip maddeleri

Aşağıdakiler spike'ın **bilinçli olarak çözmediği** noktalardır. Kod incelemesinde tespit edildiler; gerçek altın set olmadan burada anlamlı biçimde çözülemezler, bu yüzden Faz 2'ye taşındı. "Unutulmuş boşluk" değil, kayıtlı borç.

### F2-1 — Tablo/ızgara yapısı analizi

`detector.py` şu an bir tablo cetvelini alt çizgiden **taşma** ile ayırıyor: cetvel metin satırının iki yanına da devam eder, kalem çizgisi etmez. Bu sezgisel ve iki durumda yetersiz:

- Satır sütun genişliğini tamamen kaplıyorsa yanlarda ölçülecek pay kalmaz → sinyal `overrun_observed=False` döner ve satır otomatik kabul edilemez (güvenli taraf, ama fazla temkinli).
- Dikey cetveller, ızgara kesişimleri ve hücre sınırları hiç kullanılmıyor.

Faz 2'de bağlı bileşen/tablo yapısı analizi eklenmeli (ANA-PLAN §9.2 adım 8 ile birlikte). Gerçek `complex_layout` görselleri geldiğinde ölçülebilir.

### F2-2 — Çıplak `-ma/-me` olumsuzluğu

`critical_tokens.py` olumsuzluk ekini tense/aspect ekleriyle birlikte yakalıyor (`-maz`, `-madı`, `-mamalı`, `-mayacak`, `-mayan`, `-madan`, `-masa`, `-mayarak`, `-mıyor`). **Çıplak `-ma/-me` bilinçli olarak dışarıda:** olumlu isim-fiil ile eşyazımlı ve tıbbi metinde her yerde (`kanama`, `uygulama`, `gelişme`, `yayılma`, `beslenme`). Ölçüldü: 20 sıradan tıbbi isim-fiilin 20'si de yanlış bayrak alıyor.

Sonuç: `ilacı kullanma` (olumsuz emir) ile `ilaç kullanma` (isim tamlaması) sözlüksel olarak ayrılamaz. Bu ayrım sözdizimsel bağlam gerektirir → ANA-PLAN §10.4 LLM uzlaştırma adımının işi. Faz 3'te prompt'un bu durumu `uncertainSpans` ile bildirmesi beklenmeli.

### F2-3 — Eşiklerin gerçek veriyle kalibrasyonu

`config.json` içindeki tüm eşikler sentetik görüntülerle doğrulandı. Gerçek kağıt dokusu, gölge, tarayıcı gürültüsü ve kurşun kalem çok daha zor; §9.3 ağırlıkları ve `decisionThresholds` altın set gelince yeniden ayarlanmalı (yukarıdaki kalibrasyon planı).

### F2-5 — Kritik token tespiti tek başına düzenli ifadeye bırakılmamalı

Bu PR'ın kod incelemesi sekiz tur sürdü ve bulguların ezici çoğunluğu iki dosyada toplandı: `critical_tokens.py` ve `metrics.py`. Sebep tek tek dikkatsizlik değil, yapısal: **Türkçe biçimbilimini sözlüksüz düzenli ifadeyle çözmek uzun kuyruklu bir iş.** Her tur yeni bir çekim biçimi veya eşyazımlı sözcük çıktı:

- `solunum` = `sol` + `un` + `um` diye ayrışıyordu
- `sağlıklı` türetme ekiyle `sağ` sanılıyordu
- `sağlar` (fiil) `sağ` + çoğul sanılıyordu
- `gün`, `g` birimi + ek sanılıyordu
- `noradrenalin` içinde `adrenalin` bulunuyordu

Her biri ayrı ayrı düzeltildi ve regresyon testine bağlandı, ama kuyruğun bittiğine dair bir kanıt yok — bir sözlük ve gerçek biçimbilimsel çözümleyici olmadan `sağlar`ı `sağ`dan ayırmanın genel bir yolu yok.

**Öneri:** Bu katman ANA-PLAN §10.4'teki LLM uzlaştırma adımıyla birlikte konumlandırılmalı. Regex katmanı "kesin karar veren" değil **aday üreten** olarak görülürse kuyruk risk olmaktan çıkar:

- Regex geniş tarafta kalır (yanlış pozitif ucuz, yanlış negatif pahalı).
- Anlam değiştiren uyuşmazlığın nihai kararı, sözdizimsel bağlamı görebilen modele bırakılır.
- Altın set bu iki katmanın **birlikte** doğruluğunu ölçer; tek başına regex'in F1'i hedef değildir.

Faz 2/3'te bu ayrım netleştirilmeli. Şu anki testler regex katmanının bilinen sınırlarını sabitliyor; kapsam iddiası taşımıyorlar.

### F2-4 — Sentetik görüntüler gerçek geometriyi temsil etmiyor

`synthetic.py` metni koyu dikdörtgenlerle taklit ediyor; glif şekilleri, taban çizgisi altına inen harfler (g, y, p, ç) ve satır aralığı düzensizliği yok. Taban çizgisi altı bandı gerçek inen harflerle test edilmedi — alt çizgi tespitinde yanlış pozitif kaynağı olabilir. Gerçek görseller geldiğinde ilk bakılacak yerlerden biri.

## Ölçüm metodolojisi

- **OCR:** her gold görüntü için `cer`/`wer` (normalize açık) + kritik token kontrolü **üç ölçümle birden**:
  - `critical_token_mismatches(gold_transcription, hypothesis, gold_tokens=manifest_tokens)` — **birincil kapı.** Kritik token dizilerini sıralı karşılaştırır. Diğer iki ölçüm çoklu-küme temelli olduğu için değerler arası eşleşmeyi göremez: `A ilacı 1 mg, B ilacı 2 g` okuması `A ilacı 1 g, B ilacı 2 mg` olduğunda bütün sayılar korunur ve ikisi de temiz çıkar, oysa dozların birimleri yer değiştirmiştir.

    **Manifestteki `criticalTokens` mutlaka `gold_tokens` olarak geçilmelidir.** Otomatik detektör yalnız kendi kalıplarını ve kelime listelerini bilir; listede olmayan bir ilaç adı ona görünmez. `Adrenalin 1 mg, dopamin 2 mg` okuması `Dopamin 1 mg, adrenalin 2 mg` olduğunda anotasyon geçilmezse dizi iki tarafta da özdeş çıkar ve ilaç-doz eşleşmesi takası kaçar. Neyin kritik olduğuna karar veren manifesttir, detektör değil (§23.1).
  - `critical_token_error_rate(gold_tokens, hypothesis)` — eksilme yönü tanısı: kaynaktaki kritik token korunmuş mu.
  - `added_critical_tokens(gold_transcription, hypothesis)` — fazlalık yönü tanısı: OCR kaynakta olmayan bir kritik değer *eklemiş* mi. Gold `1 mg` iken OCR `1–2 mg` okursa eksilme ölçümü temiz görünür.

  Otomatik-kabul edilenlerde **üçü de temiz** hedeflenir. Son ikisi hatanın hangi yönde olduğunu söylediği için tanı amaçlı tutulur.
- **Seçim:** kategori bazında `selection_prf`. Ana kapı precision (yanlış otomatik kabul) ve "tek dokunuşla düzeltilebilirlik".
- **Kart:** gold pasajlardan üretilen kartlar `card_quality.rubric.score_card` ile puanlanır; kabul oranı raporlanır.
- **Maliyet/latency:** `provider_compare` çıktısı; §20 bütçe varsayımlarıyla karşılaştırılır.
