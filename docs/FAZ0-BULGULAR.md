# Faz 0 — İlk gerçek ölçüm

**Tarih:** 2026-08-02
**Cihaz:** MacBook Air (Apple Silicon), macOS
**Girdi:** 8 adet gerçek kitap sayfası fotoğrafı (HEIC), patoloji ders notu
**Araç:** `ios/spikes/AppleVisionSpike`, dil düzeltmesi kapalı (§0.5)

Bu, altın test setinden önce yapılan bir ön ölçüm. 20 görüntülük etiketli set
hâlâ gerekli; buradaki amaç Apple Vision'ın Türkçe tıp metninde nerede durduğunu
erkenden görmekti. Sonuç plan açısından belirleyici çıktı.

---

## 1. Apple Vision Türkçe'ye özgü harfleri hiç üretmiyor

İlk sayfada 148 satır tanındı. Harf dağılımı:

| Harf | Kaç kez | Not |
|---|---|---|
| ü, Ü, ö, Ö, ç, Ç | **77** | Almanca/Fransızca'da da var |
| ı, ş, ğ, İ | **0** | Yalnızca Türkçe'de var |

148 satırlık Türkçe tıp metninde `ı` harfinin hiç geçmemesi mümkün değil.
Bu harfler tanınmıyor değil — **üretilemiyor**. Çıktıda karşılıkları:

| Kaynakta | Vision okudu |
|---|---|
| parçalanır | parçalan**i**r |
| şişme | **s**i**s**me |
| Yağlar | Ya**j**lar |
| MORFOLOJİSİ | MORFOLOJ**IS**i |
| kümeleşme | kümele**s**me |

Test ettiğim 21 kelimenin **21'i** böyle. Rastgele hata değil, sistematik.

Açıklama: Apple Vision'ın metin tanıma dilleri arasında Türkçe yok.
`--languages tr-TR` istense bile Vision desteklemediği dili hata vermeden yok
sayıyor, İngilizce modeliyle okuyor. Bu yüzden yalnızca Almanca/Fransızca'da da
bulunan harfler çıkıyor.

> **Doğrulandı (2026-08-02).** `AppleVisionSpike --list-languages` cihazda
> çalıştırıldı: *"Türkçe DESTEKLENMİYOR. --languages tr-TR istense de yok
> sayılır."* Yani bu bir tanıma kalitesi sorunu değil, eksik dil desteği.
> Fotoğrafı düzeltmek, çözünürlüğü artırmak veya eşik ayarlamak bunu çözmez.

### Neden önemli

§24.3 basılı metinde kritik token hatası kaydedilmemesini istiyor. Diakritik
kaybı bunu iki yerden deliyor:

- **Olumsuzluk.** `kullanılmamalıdır` → `kullanilmamalidir`. §10.5'teki olumsuzluk
  kalıpları (`-mamalı/-memeli`) `ı` üzerinden eşleşiyor; bu haliyle kaçar.
  Olumsuzluğun kaçması bu uygulamada en tehlikeli hata sınıfı.
- **CER/WER.** Her Türkçe cümlede sabit bir ceza. Ölçüm gerçek OCR kalitesini
  değil, eksik dil desteğini ölçmüş olur.

## 2. Kimyasal üst/alt simgeler yok oluyor

| Kaynakta | Vision okudu |
|---|---|
| Fe⁺³ / Fe⁺² | `Fe*3` / `Fe*2` |
| H₂O₂ | `H,0g*`, `H20г`, `H,0` |
| O₂⁻ | `(0,)` |

`Fe⁺²` ile `Fe⁺³` farklı şeyler; iyon yükü §10.5'te kritik token. Ayrıca `O₂`
`0,` (sıfır-virgül) olarak okunuyor — yani bir **sayıya** dönüşüyor. Sayı sınıfı
kritik token olduğu için bu sessiz bir sayı uydurması demek.

## 3. El yazısı okunmuyor

Kenar notları neredeyse tamamen kayıp: `оВі`, `das`, `ти₴`, `коyulos(-)`,
`mitokondé + lpzoton`, `ana menbron`, `porcolonmass`. Bazılarında Kiril harfleri
var — model Türkçe el yazısını harf düzeyinde bile tutturamıyor.

§10.6 kişisel el yazısı sözlüğü, üzerine kurulacağı bir taban tanıma gerektiriyor.
Bu tabanı Apple Vision tek başına veremiyor.

## 4. Güven puanı kaba ama işe yarıyor

Vision üç değer döndürüyor: **0.3 / 0.5 / 1.0**.

| Güven | Satır | Gözlem |
|---|---|---|
| 1.0 | 90 (%61) | Çoğunlukla doğru basılı metin |
| 0.5 | 34 (%23) | Basılı ama hatalı |
| 0.3 | 24 (%16) | Neredeyse tamamı el yazısı veya çöp |

İnce ayarlı bir kalite kapısı için fazla kaba, ama **0.3 ≈ güvenme** kuralı
gerçek bir sinyal. §9.3 eşiklerinde kullanılabilir.

## 5. Satır sırası bozuktu — bu bizim hatamızdı

Sıralama `abs(ay - by) > 0.005` toleransıyla yapılıyordu. Bu geçerli bir sıralama
bağıntısı değil: `a ≈ b` ve `b ≈ c` iken `a < c` olabiliyor. Böyle bir yüklemle
çağrılan `sorted(by:)` tanımsız sonuç verir ve yoğun bir sayfada tüm metnin
sırası bozulur. Dikey konum artık bantlara yuvarlanıyor.

Aynı kod hem spike hem `CizgiCore` içinde vardı; ikisi de düzeltildi.

Not: bu sayfa çok sütunlu ve tablolu. Bant sıralaması tek sütunlu metin için
doğru, ama sütun tespiti hâlâ yok — o Faz 2'ye ait.

---

## Plana etkisi

| ANA-PLAN | Söylediği | Ölçümün gösterdiği |
|---|---|---|
| §10.1 | Apple Vision hızlı yerel geçiş | Yerleşim ve satır kutuları için geçerli. **Türkçe metni için değil.** |
| §10.2 | Google Document AI doğruluk katmanı | İsteğe bağlı değil, **zorunlu**. Öne alınmalı. |
| §10.6 | Kişisel el yazısı sözlüğü | Apple Vision üstüne kurulamaz |
| §25 Faz 0 kapısı | Basılı metinde kritik token hatası yok | Apple Vision tek başına **geçemez** |

Öneri: Faz 2'de planlanan bulut OCR'ı öne almak ve Apple Vision'ı canlı önizleme
+ satır kutusu görevine indirmek. Karar ANA-PLAN sahibinin.

### Neyin çözmediği

Bu bir ayar veya kalite sorunu olmadığı için şunlar işe yaramaz:

- daha iyi/daha yüksek çözünürlüklü fotoğraf
- `recognitionLevel` veya eşik değişikliği
- dil düzeltmesini açmak (§0.5 zaten yasaklıyor, ve Türkçe sözlüğü yok)

Türkçe diakritiklerini metinden geri üretmek (deasciifier) kısmi bir çare olur:
sıradan kelimelerde işe yarar, ama **üç şeyi çözmez** — yok olan üst/alt simgeler
(`Fe⁺³`, `O₂`), el yazısı, ve tahmin ürünü olduğu için §0.5'in kritik token
sınıflarında kullanılamaması. Yani tek başına Faz 0 kapısını geçirmez.

### Ölçüm altyapısına etkisi

Kritik token karşılaştırması diakritik kaybına karşı dayanıklı hale getirilmeli:
`kullanılmamalıdır` ile `kullanilmamalidir` **aynı olumsuzluğu** taşıyor, çünkü
`-ma-` morfemi diakritik gerektirmiyor. Bunları katlanmış uzayda karşılaştırmak
metni düzeltmek değil; CER/WER diakritik kaybını hata olarak saymaya devam eder.

**Karar bekliyor.** 20 görüntülük altın set hâlâ gerekli — ama artık "Apple
Vision yeterli mi?" sorusunu değil, seçilecek OCR'ın kalitesini ölçmek için.
