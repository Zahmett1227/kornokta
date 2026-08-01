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

Faz 0'da GPT-5.6 Sol / Gemini / Claude adayları aynı altın set üzerinde §27'deki 8 boyutta karşılaştırılacak. Sonuçlar bu dosyaya işlenecek. Henüz çalıştırılmadı — altın set toplanıyor (bkz. [GOLD-SET-GUIDE](GOLD-SET-GUIDE.md)).

## Bilinen sınırlar

- LLM çıktısı §14 şemasına uymadıkça kaydedilmez.
- Kritik token sınıflarında (§10.5) uyuşmazlık otomatik geçemez; kullanıcı onayı zorunludur.
- Kaynağa sadık modda modelin dış bilgisi cevap anahtarına giremez; `enriched` içerik ayrıca etiketlenir.
