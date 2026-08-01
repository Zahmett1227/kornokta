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

Çalıştırma: `python -m pytest evals` (100 test), `python -m evals.spikes.marker_detection.run --demo`.

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

1. Her gold görüntüde `analyze_page` çalıştır, tahmin edilen seçili satırları çıkar.
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

## Ölçüm metodolojisi

- **OCR:** her gold görüntü için `cer`/`wer` (normalize açık) + `critical_token_error_rate(gold_tokens, hypothesis)`. Kritik token hata oranı otomatik-kabul edilenlerde **0 hedeflenir**.
- **Seçim:** kategori bazında `selection_prf`. Ana kapı precision (yanlış otomatik kabul) ve "tek dokunuşla düzeltilebilirlik".
- **Kart:** gold pasajlardan üretilen kartlar `card_quality.rubric.score_card` ile puanlanır; kabul oranı raporlanır.
- **Maliyet/latency:** `provider_compare` çıktısı; §20 bütçe varsayımlarıyla karşılaştırılır.
