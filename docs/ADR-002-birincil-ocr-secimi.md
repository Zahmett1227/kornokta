# ADR-002 — Birincil OCR olarak bulut servisi

**Durum:** Kabul edildi (2026-08-02)
**Karar veren:** ANA-PLAN sahibi
**İlgili:** ANA-PLAN §10.1, §10.2, §10.3, §24.3, §25 · `docs/FAZ0-BULGULAR.md`

---

## Bağlam

Faz 0 ölçümü Apple Vision'ın Türkçe metin tanımayı **desteklemediğini** gösterdi.
`AppleVisionSpike --list-languages` cihazda çalıştırıldı ve Türkçe listede yok.
148 satırlık gerçek bir patoloji sayfasında `ı ş ğ İ` harfleri sıfır kez üretildi;
buna karşılık Almanca/Fransızca'da da bulunan `ü ö ç` 77 kez çıktı.

Bu bir kalite sorunu değil, eksik dil desteği. Daha iyi fotoğraf, daha yüksek
çözünürlük veya eşik ayarı bunu değiştirmez.

Ölçümün ayrıntısı `docs/FAZ0-BULGULAR.md` içinde.

## Karar

**Google Document AI birincil OCR olsun.** Apple Vision, canlı önizleme ve satır
kutusu (yerleşim) görevine indirilsin; metnin kaynağı olmasın.

ANA-PLAN §10.2 bulut OCR'ı zaten "doğruluk katmanı" olarak tanımlıyordu. Bu
karar onu isteğe bağlı olmaktan çıkarıp **zorunlu** hale getiriyor ve Faz 2'den
öne çekiyor.

### Neden diğer seçenekler değil

| Seçenek | Neden seçilmedi |
|---|---|
| Apple Vision + Türkçe diakritik geri-yükleme (deasciifier) | Sıradan kelimelerde işe yarar ama yok olan üst/alt simgeleri (`Fe⁺³`, `O₂`) ve el yazısını kurtarmaz. Ayrıca tahmin ürünü olduğu için §0.5 gereği kritik token sınıflarında kullanılamaz. Tek başına Faz 0 kapısını geçirmez. |
| Yalnızca işaretli bölgeyi buluta göndermek | Daha az veri dışarı çıkar ve daha ucuz. Ancak cihaz üstü işaret tespitine (Faz 2) bağımlı; bulut OCR'ı ona bağlamak her şeyi geciktirir. **Sonraki iyileştirme olarak açık bırakıldı.** |
| Karar için 20'lik altın seti beklemek | Cevap zaten kesin. Altın set hâlâ gerekli, ama artık "Apple Vision yeter mi?" sorusunu değil, seçilen OCR'ın kalitesini ölçmek için. |

## Sonuçları

### Kabul edilenler

- **Kart üretimi internet gerektirir.** Tekrar etmek çevrimdışı çalışmaya devam
  eder (§24.5) ve çekim yine anında biter (§24.1); yalnızca metne dönüşüm
  kuyruğa girer.
- **Backend öne alınıyor.** Anahtarlar istemciye konulamaz (§0.7, §7.3), yani
  proxy katmanı Faz 3'ten önce gerekiyor.
- **Maliyet.** Kişisel kullanımda düşük, ama artık sıfır değil. §11'deki bütçe
  sınırları ilk günden anlamlı hale geliyor.
- **Gizlilik/telif.** Sayfa görüntüsü işlenmek üzere dışarı çıkıyor. §22 sunucu
  tarafında görüntü ve tam OCR metninin saklanmamasını zaten şart koşuyor; bu
  kural artık kritik. Bölge-kırpma seçeneği bu yüzden açık bırakıldı.

### Ölçüm altyapısına yapılan değişiklik

Kritik token **tespiti** diakritiksiz Türkçe'de de çalışacak şekilde
genişletildi; **karşılaştırma** ise kasıtlı olarak katlamıyor.

Ayrım şöyle:

- **Tespit katlıyor.** `sag` artık laterality olarak tanınıyor. Katlamasaydı
  `ilac kullanilmamalidir` metni "hiç kritik token içermeyen bir cümle" gibi
  görünürdü — tespit edilmemiş bir olumsuzluk karşılaştırılamaz bile. Asıl
  güvenlik açığı buydu.
- **Karşılaştırma katlamıyor.** Seçilen OCR Türkçe yazabildiği için, `sağ`
  yerine `sag` okunması gerçek bir çeviri hatasıdır ve §24.3 bunun
  raporlanmasını istiyor.

Yan fayda: hüküm artık `delete: sağ -> —` yerine
`replace: sağ -> sag` diyor. Kelimenin kaybolduğunu değil, değiştiğini söylüyor.

Ayrıntı: `evals/tests/test_diacritic_folding.py`.

## Açık kalanlar

1. **Hangi Google işlemcisi?** Document AI'ın OCR işlemcisi mi, yoksa Form/Layout
   Parser mı? Çok sütunlu ders notu sayfalarında sütun tespiti gerekiyor. **Kısmen
   ele alındı (2026-08-03):** işlemci seçimi hâlâ OCR işlemcisi, ama okuma sırası
   artık sütun farkında — bir sütun/karşılaştırma listesi satır satır yerine sütun
   sütun okunuyor (`ReadingOrder.swift` / `documentAI.ts`'teki
   `orderByReadingPosition`). Gerçek bir Nekroz/Apoptoz karşılaştırma sayfasının
   iki sütununun tek bir cümlede karıştığı bir kullanıcı raporuyla bulundu.
2. **El yazısı.** Google'ın Türkçe el yazısında ne kadar iyi olduğu ölçülmedi.
   §10.6 kişisel sözlüğün üzerine kurulacağı taban buna bağlı.
3. **Bölge kırpma.** Faz 2 işaret tespiti çalıştıktan sonra tekrar
   değerlendirilecek.
4. **Apple Vision'ın kalan rolü.** Satır kutuları geometrik olarak doğru
   (metin yanlış olsa da), yani işaret tespiti için kullanılabilir. Bu
   varsayım 20'lik altın sette doğrulanmalı.
