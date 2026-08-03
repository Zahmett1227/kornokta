# Model kartı

> Taslak — kaynak: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §11 (model stratejisi), §27 (değerlendirme planı).

## Görev → model eşlemesi (hedef)

| Görev | Model/servis | Ne zaman |
|---|---|---|
| Hızlı yerel OCR | Apple Vision | Her çekim, cihaz üzerinde |
| Belge/el yazısı OCR | Google Enterprise Document OCR | Her yakalama |
| Nihai transkripsiyon + kart | GPT-5.6 Sol | Her bilgi üretimi |
| El yazısı ikinci görüş | Gemini 3.5 Flash | Yalnız belirsiz/el yazılı bölgeler |
| Tekrar planlama | FSRS (yerel, deterministik) | Her tekrar — LLM kullanılmaz |

Model kimlikleri merkezi config'te tutulur (§11.3); kod içine gömülmez. Üretim öncesi snapshot sürüm sabitlenir.

## Değerlendirme durumu

OCR tarafı ölçüldü: Apple Vision Türkçe desteklemiyor (`docs/FAZ0-BULGULAR.md`),
Google Document AI birincil OCR olarak seçildi ve gerçek bir sayfayla uçtan
uca doğrulandı (`docs/FAZ2-PLAN.md`). Kart üretimi tarafı (Faz 3) gerçek bir
OpenAI/Gemini anahtarıyla uçtan uca doğrulandı ve gold pasaj kart kalite
rubriğiyle ölçüldü (2 pasaj, 8 kart, %100 kabul — kullanıcının kendi kararı,
`docs/FAZ3-PLAN.md`); §27'deki 8 boyutlu tam model karşılaştırması henüz
yapılmadı. Tekrar planlama tarafı (Faz 4) gerçek FSRS-6 ile değiştirildi ve
bir Mac'te `swift test` ile doğrulandı (`docs/FAZ4-PLAN.md`).

## Bilinen sınırlar

- LLM çıktısı §14 şemasına uymadıkça kaydedilmez.
- Kritik token sınıflarında (§10.5) uyuşmazlık otomatik geçemez; kullanıcı onayı zorunludur.
- Kaynağa sadık modda modelin dış bilgisi cevap anahtarına giremez; `enriched` içerik ayrıca etiketlenir.
