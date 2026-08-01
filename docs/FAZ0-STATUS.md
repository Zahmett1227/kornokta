# Faz 0 — Durum Özeti

**Tarih:** 1 Ağustos 2026
**Dal:** `claude/tibbi-hafiza-app-04elp1`
**PR:** [#1](https://github.com/Zahmett1227/kornokta/pull/1) — açık, merge edilmedi

---

## Test durumu

```
$ python -m pytest evals -q
328 passed
```

Bu çıktı **gerçekten çalıştırıldı** — varsayılmadı. Her commit öncesi ve sonrası koşuldu, ayrıca CI'da (GitHub Actions, `.github/workflows/evals.yml`) her push'ta koşuyor ve son çalıştırmalar yeşil.

CI'ın koştuğu adımlar:

| Adım | Komut |
|---|---|
| Manifest doğrulama | `python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json` |
| Birim + entegrasyon testleri | `python -m pytest evals -q` |
| İşaret tespiti duman testi | `python -m evals.spikes.marker_detection.run --demo` |
| Sağlayıcı karşılaştırma kuru çalıştırma | `python -m evals.spikes.provider_compare.run --dry-run` |

Test dağılımı kabaca: kritik token tespiti, kritik token metrikleri (üç kapı ölçümü), Türkçe normalizasyon, manifest şeması, LLM çıktı sözleşmesi, işaret tespiti spike'ı, kart kalite rubriği, config canlılığı, kapı entegrasyonu, Vision rapor okuyucusu.

---

## Ne hazır

| Bileşen | Konum | Durum |
|---|---|---|
| Ana şartname | `Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md` | route kuralları §10.5.1 ile güncellendi |
| Altın set manifest şeması + doğrulayıcı | `evals/gold-manifest.schema.json`, `evals/ocr_eval/validate_manifest.py` | Hazır |
| Türkçe normalizasyon, CER/WER, seçim P/R/F1 | `evals/ocr_eval/normalize.py`, `metrics.py` | Hazır |
| Kritik token tespiti (17 sınıf, route dahil) | `evals/ocr_eval/critical_tokens.py` | Hazır |
| Üç ölçümlü kritik token kapısı | `evals/ocr_eval/metrics.py` | Hazır |
| İşaret tespiti spike'ı (fosforlu + alt çizgi) | `evals/spikes/marker_detection/` | Sentetik görüntülerle doğrulandı |
| Model karşılaştırma iskeleti | `evals/spikes/provider_compare/` | İskelet, `--live` Faz 3'e kadar kapalı |
| Kart kalite rubriği | `evals/card_quality/rubric.py` | Hazır |
| Kanonik LLM çıktı sözleşmesi | `backend/schemas/llm_output.schema.json` | Hazır |
| **Apple Vision spike** | `ios/spikes/AppleVisionSpike/` | Yazıldı, **Mac'te derlenmedi** |
| **Vision çıktısı puanlayıcı** | `evals/ocr_eval/vision_report.py` | Hazır, sentetik girdiyle test edildi |

### Doğrulanmamış olan

`AppleVisionSpike` bu ortamda (Linux) **derlenemedi ve çalıştırılamadı.** Kod incelendi ve API kullanımı Vision belgelerine göre yazıldı, ama ilk `swift build` senin Mac'inde olacak. Derleme hatası çıkarsa bana ilet.

---

## Ne hazır değil

| Eksik | Neden |
|---|---|
| Gerçek altın set görselleri | Senin kitapların, senin işaretlemen gerekiyor |
| Apple Vision gerçek ölçümü | Mac gerekiyor |
| Eşik kalibrasyonu (§9.3) | Gerçek görsel olmadan anlamsız |
| Google Document AI entegrasyonu | Faz 2 |
| AI uzlaştırma katmanı | Faz 3 — karar: [ADR-001](ADR-001-hibrit-turkce-morfoloji.md) |
| iOS uygulaması | Faz 1 — Faz 0 çıkış kapıları geçilmeden başlamıyor |

---

## PR durumu

- **25 commit**, `main` üzerine
- **29 inceleme notu**, **28'i kapatıldı**
- CI yeşil
- **Merge edilmedi** — talimatın gereği tüm kontroller yeşil olmadan merge yok, ayrıca açık bir not var (aşağıda)

### Açık kalan tek not

**"Cover bare and converb negation suffixes"** — [discussion_r3695383407](https://github.com/Zahmett1227/kornokta/pull/1#discussion_r3695383407)

Codex iki şey istedi:
1. Converb/koşul olumsuzlukları (`-madan`, `-masa`, `-mayarak`, `-maksızın`) → **uygulandı**
2. Çıplak `-ma/-me` ekinin de olumsuzluk sayılması → **uygulanmadı**

İkinciyi reddettim çünkü çıplak `-ma/-me` olumlu isim-fiil ile eşyazımlı ve tıbbi metinde her yerde. Ölçtüm: 20 sıradan tıbbi isim-fiilin (`kanama`, `uygulama`, `gelişme`, `yayılma`, `beslenme`, `daralma`, `tıkanma`, `iyileşme`…) **20'si de** yanlış bayrak alıyordu. Bu, neredeyse her pasajı kritik işaretleyip onay adımını anlamsız kılardı — ANA-PLAN §24.2'nin düşük müdahale hedefiyle doğrudan çelişir.

`İlacı kullanma` (olumsuz emir) ile `ilaç kullanma` (isim tamlaması) biçimbilimsel olarak ayrılamaz; ayrım sözdizimsel bağlam gerektirir. Bu yüzden [ADR-001](ADR-001-hibrit-turkce-morfoloji.md)'de AI katmanının işi olarak konumlandırıldı.

Thread bilinçli olarak **açık bırakıldı** — bir anlaşmazlığı kapatıp gizlemek doğru olmaz. Senin kararınla kapanabilir.

---

## İnceleme sürecinden çıkan ders

15 tur inceleme yapıldı, ~30 bulgu geldi ve neredeyse tamamı gerçekti. İki gözlem:

**1. Bulguların çoğu iki dosyada toplandı** (`critical_tokens.py`, `metrics.py`) ve hepsi aynı kök nedene çıkıyordu: sözlüksüz düzenli ifadeyle Türkçe biçimbilimi çözmeye çalışmak. Bu, ADR-001'in gerekçesi oldu.

**2. Birkaç bulgu benim kendi düzeltmelerimin yan etkisiydi.** Tekrar eden kalıp: bir davranışı birden fazla yerde uygulayıp yalnız birini güncellemek (kelime listesi sınırı, yol katlaması, boşluk kanonikleştirmesi — üçü de aynı hata). Buna karşı regresyon testleri artık **üç ölçümü birlikte** kontrol ediyor, tek tek değil.

Ayrıca bir kez kendi entegrasyon testimin **yanlış sebepten geçtiğini** buldum (yol değişimi yerine tire farkını yakalıyordu). Yeşil test tek başına doğruluk kanıtı değil.

---

## Sıradaki adım

[MAC-ADIMLARI.md](MAC-ADIMLARI.md) — 20 görsel çek, etiketle, Vision'ı çalıştır, puanla. Sonuçları birlikte değerlendirip 100'lük sete geçip geçmeyeceğimize karar veriyoruz.
