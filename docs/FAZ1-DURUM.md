# Faz 1 — Yerel uygulama iskeleti

**Dal:** `claude/faz1-ios-iskelet`
**Durum:** Yazıldı, **cihazda denenmedi**
**Hedef (ANA-PLAN §25):** Uygulama çevrimdışı fotoğraf alıp sahte kart oluşturabilmeli ve tekrar edebilmelidir.

---

## Bu faz bir varsayım üzerine yazıldı

ANA-PLAN §0.9 "her faz sonunda kabul testlerini çalıştırmadan sonraki faza geçme" diyor. **Bu kural bilerek esnetildi:** ANA-PLAN sahibi, Apple Vision ölçümünü yarın yapacağını ve o zamana kadar Faz 1'in yazılmasını istedi.

Yani şu an **Faz 0 çıkış kapılarının geçtiği varsayılıyor**, doğrulanmıyor:

| Kapı | Durum |
|---|---|
| Altın test seti ≥ 100 görüntü | Yapılmadı (önce 20 planlandı) |
| Alt çizgi tespitinde %95 tek-dokunuş | Ölçülmedi |
| Basılı metinde kritik token hatası kayda geçmiyor | Ölçülmedi |
| Apple Vision doğruluğu | Ölçülmedi |

### Ölçüm kötü çıkarsa ne olur

Etkilenecek yerler dar tutuldu:

| Faz 0 sonucu | Etkilenen Faz 1 kodu | Etkilenmeyen |
|---|---|---|
| Vision doğruluğu yetersiz | `CizgiCore/OCR/VisionTextRecognizer.swift`, onay ekranı | Veri modeli, kuyruk, durum makinesi, tekrar |
| Vision tamamen yetersiz | Yukarıdakiler + Google OCR'ın Faz 2 yerine öne alınması | Aynı |
| Eşikler çok farklı | Faz 2 işaret tespiti | Faz 1'in tamamı |

OCR bir protokolün (`TextRecognizing`) arkasında olduğu için değişim tek dosyayla sınırlı kalır. Kuyruk, veri modeli ve tekrar akışı OCR'ın ne kadar iyi olduğundan bağımsız.

---

## Ne yazıldı

### `ios/CizgiCore/` — mantık (Xcode'suz test edilebilir)

| Bileşen | ANA-PLAN | Not |
|---|---|---|
| SwiftData modelleri | §16 | 8 model, tam şema |
| Durum makinesi | §17 | Geçiş kuralları, idempotens, iptal |
| Retry politikası | §17 | Üstel geri çekilme + jitter; 4xx/şema hatası tekrarlanmıyor |
| İşlem hattı | §17 | Yakalama → OCR → seçim → kart |
| Apple Vision OCR | §10.1 | Dil düzeltmesi kapalı (§0.5) |
| Sahte kart üreticisi | §25 Faz 1 | Çevrimdışı, kaynağı her karta iliştiriyor |
| Tekrar planlayıcı | §18 | **Geçici** — FSRS Faz 4'te |
| Oturum planlayıcı | §18.3 | Aynı bilgi biriminin kartlarını arka arkaya sormuyor |
| Görüntü deposu | §8.3 | Atomik yazma, göreli yol, orijinal + işlenmiş ayrı |

### `ios/App/` — SwiftUI

Dört sekme (§6.1): Yakala, Tekrar, Bilgilerim, Ayarlar. Ayrıca işleme kuyruğu, onay ekranı ve kart detayı.

Belge kamerası için `VNDocumentCameraViewController` kullanıldı — sayfa kenarı algılama, perspektif düzeltme ve seri çekim (§8.1, §8.3) hazır geliyor.

---

## Bilinçli davranışlar

**Her çekim onay ekranına düşüyor.** Cihaz üstü işaret tespiti Faz 2'de. §19.3 "işaret algılanmadı ve kullanıcı manuel seçim yapmadı → otomatik ret" dediği için, tespit yokken her pasajı elle seçmek doğru davranış. Sessizce tüm sayfayı seçmek şartnameye aykırı olurdu.

**Kartlar taslak niteliğinde.** Sahte üretici gerçek soru yazmıyor; `[Taslak]` önekiyle işaretli. Amaç akışı denemek, içerik kalitesini değil.

**Tekrar aralıkları FSRS değil.** `PlaceholderScheduler` düz katlama kullanıyor ve bunu hem kodda hem Ayarlar ekranında söylüyor. §18 FSRS'i Faz 4'e koyuyor ve referans implementasyonla test edilmesini istiyor.

---

## Yarın yapılacaklar

1. **Önce Faz 0:** `docs/MAC-ADIMLARI.md` — 20 görsel, Vision ölçümü. Sonucu bana ilet.
2. **Sonra Faz 1:** `ios/README.md` içindeki elle kontrol listesi. Gerçek iPhone gerekiyor; belge kamerası simülatörde çalışmıyor.

Mantık testleri Xcode olmadan hemen koşar:

```bash
cd ios/CizgiCore && swift test
```

**Uyarı:** Swift kodu bu ortamda derlenemedi (Linux'ta Swift yok). Derleme hatası çıkması olası; çıkarsa bana ilet, düzeltirim.
