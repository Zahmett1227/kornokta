# Altın Test Seti — Çekim ve Etiketleme Rehberi

> Kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §23.1. Bu, Faz 0'ın **ilk zorunlu işidir**: en az 100 gerçek görüntü ve her biri için gold veri.

## Önemli: gizlilik ve telif

- **Telifli kitap sayfaları repoya commit EDİLMEZ.** Görseller yalnız `evals/fixtures/` altında yerelde tutulur (`.gitignore` korur).
- Görüntüde **hasta bilgisi bulunmamalıdır** (§22). Yalnız kitap sayfası fotoğrafı.
- Manifest (`evals/gold-manifest.json`) yalnız gold **veriyi** taşır (metin, satır kimlikleri, kartlar); görselleri değil.

## Kategori kotaları (toplam ≥ 100)

| Kategori | Kimlik | Hedef | İçerik |
|---|---|---:|---|
| Basılı + fosforlu | `printed_highlight` | 40 | Renkli fosforlu kalem (sarı/yeşil/pembe/mavi) |
| Basılı + tükenmez alt çizgi | `printed_ink_underline` | 20 | Siyah/renkli kalem alt çizgisi |
| Kurşun kalem alt çizgisi | `pencil_underline` | 10 | En zor sınıf (§30) |
| Basılı + kenar el yazısı | `printed_with_margin_note` | 15 | El yazısı kısaltma/not |
| Ağırlıklı el yazısı | `handwriting_heavy` | 5 | Çoğunlukla el yazısı sayfa |
| Karmaşık yerleşim | `complex_layout` | 5 | İki sütun / tablo / şekil |
| Kötü çekim | `poor_capture` | 5 | Kötü açı, gölge, düşük ışık |

## Çekim önerileri

- Sayfayı düz yüzeye koy, mümkünse dengeli ışık.
- `poor_capture` dışındaki kategorilerde açı düz olsun; kötü çekim örneklerini bilinçli olarak zorlaştır.
- Aynı sayfayı iki kez çekme (perceptual hash çakışması, §8.3).
- Her görüntüyü ilgili alt klasöre koy: `fixtures/highlight/`, `fixtures/underline/`, `fixtures/pencil/`, `fixtures/margin/`, `fixtures/handwriting/`, `fixtures/layout/`, `fixtures/poor/`.

## Her görüntü için gold veri (§23.1)

Manifeste bir girdi ekle. Zorunlu alanlar (`annotated` + otomatik/onay beklenen için):

1. **id**: `gold_NNN` (ör. `gold_017`).
2. **category**: yukarıdaki kimliklerden biri.
3. **imagePath**: `fixtures/...` ile başlamalı.
4. **goldSelectedLines**: doğru işaretlenmiş satırlar (`lineId`, birebir `text`, `selectionType`, `markerType`, renk).
5. **exactTranscription**: pasajın **birebir** transkripsiyonu — Türkçe karakter, sayı, birim, sembol aynen (§10.5). Sessizce düzeltme yok.
6. **criticalTokens**: metindeki kritik token'lar ve sınıfları (`number_decimal`, `unit`, `dose_frequency`, `hypo_hyper`, `negation_pair`, `laterality`, `ion_charge`, `greek_letter`, `drug_name`, `organism_name` …).
7. **handwriting**: varsa el yazısı bölgeleri (`text`, gerekirse `expandedText`, `containsCriticalToken`).
8. **acceptableCards**: en az 2 kabul edilebilir kart.
9. **rejectCardExamples**: en az 1 reddedilmesi gereken kart + `rejectReason`.
10. **expectedOutcome**: `auto_accept` | `needs_confirmation` | `reject`.

`pending` durumundaki girdiler (görsel var, henüz etiketlenmedi) daha az alanla geçerlidir; şema bunu esnetir.

## Doğrulama

Girdi ekledikçe çalıştır:

```bash
# Şema + tutarlılık (kota, kritik token metinde var mı, lineId kartla uyumlu mu)
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json

# Görsel dosyaları da yerelde var mı kontrol et
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json --check-files
```

Uyarılar (WARN) kota eksikliğini gösterir; hedefler dolunca kaybolur. Hatalar (ERROR) mutlaka giderilmelidir.

## Kritik token etiketleme ipucu

`critical_tokens` detektörü aday çıkarmaya yardımcı olur (kesin doğru değil, insan onayı gerekir):

```bash
python -c "from evals.ocr_eval.critical_tokens import detect_critical_tokens as d; \
print([(t.text,t.token_class) for t in d('Anafilakside 0,3–0,5 mg IM adrenalin')])"
```

Çıkan adayları gözden geçir; ilaç/organizma adları için `Wordlists` genişletilebilir.
