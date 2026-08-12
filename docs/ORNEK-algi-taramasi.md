# Örnek: doldurulmuş algı taraması (Tur A)

Bu, `npm run compare`'in ürettiği `perception-<stamp>.md` dosyasının **doldurulmuş**
hâlinden bir sayfa. Gerçek veri değil — nasıl doldurulacağını göstermek için
uydurulmuş bir örnek. Kendi dosyanı doldururken buna bakabilirsin.

Kural: **sayfanın fotoğrafını yanına aç.** Puanladığın şey kartlar değil,
kartların sayfayla ilişkisi.

---

## zor-03.jpg

> *(Bu sayfada: 6 fosforlu bölge, 2 daire içine alınmış terim, kenarda 3 el
> yazısı not. Not 2 silik ve zor okunuyor.)*

### Takım A

4 kart · 1 tanesi modelin kendi "emin değilim" işaretini taşıyor

1. **S:** Hücre hasarında geri dönüşümsüzlüğün belirteci nedir?
   **C:** Mitokondri membran hasarı ve ATP tükenmesi

2. **S:** Koagülatif nekroz hangi organda tipik olarak görülmez?
   **C:** Beyin

3. **S:** Kenar notu: "hipoksi ≠ iskemi — iskemide substrat da yok"
   **C:** İskemide oksijenle birlikte glikoz sunumu da kesilir  ⚠ *(model emin değil)*

4. **S:** Apoptozda hücre membranı bütünlüğü korunur mu?
   **C:** Evet, korunur

### Takım B

2 kart

1. **S:** Hücre hasarının en sık nedeni nedir?
   **C:** Hipoksi

2. **S:** Nekroz tipleri nelerdir?
   **C:** Koagülatif, likefaktif, kazeöz, yağ, fibrinoid

### Takım C

7 kart · 2 tanesi modelin kendi "emin değilim" işaretini taşıyor

*(… kartlar …)*

| | A | B | C |
| --- | --- | --- | --- |
| Yakalanan işaret / toplam | 8/11 | 3/11 | 10/11 |
| El yazısı | 2 okundu, 1'i "okunamadı" dedi | yok | 3 okundu |
| Uydurma kart | 0 | 1 | 0 |
| **Yanlış ama emin** | 0 | **1** | 0 |
| Not | not 2'yi atladı ama atladığını bildirdi | işaretleri yok saydı, genel bilgi üretti; "nekroz tipleri" sayfada işaretli değildi | tam |

---

# Satırlar tek tek

## 1. Yakalanan işaret / toplam

Payda **sen** koydun: sayfadaki fosforlu + altı çizili + daire + sembol + el
yazısı notlarının toplam sayısı. Bir kez say, üç takım için de aynı paydayı
kullan.

Pay: bunlardan kaç tanesi bir karta dönüşmüş. Bir işaret için birden çok kart
üretildiyse yine **1** say — ölçtüğün şey kapsama, üretkenlik değil.

> Örnekte: B takımı 3/11 — sayfanın işaretlerini büyük ölçüde görmezden gelip
> genel Patoloji bilgisi üretmiş. Bu, kart sayısının azlığından çok daha kötü
> bir sonuç.

## 2. El yazısı

Sayfada el yazısı notu yoksa `yok` yaz ve geç. Varsa üç durumdan biri:

| Yaz | Ne zaman |
|---|---|
| `okundu` | Not karta dönmüş ve içeriği doğru |
| `okunamadı dedi` | Kart "(el yazısı net okunamadı)" diyor ya da `lowConfidence` işaretli |
| `yanlış okudu` | Kart notu yanlış aktarmış **ve** emin görünüyor |

`okunamadı dedi` ile `yanlış okudu` arasındaki fark bu turun en önemli
ayrımı — birincisi dürüst bir sınır, ikincisi sessiz bir hata.

## 3. Uydurma kart

Sayfada **işaretlenmemiş** bir yerden üretilmiş kart sayısı. Prompt bunu
açıkça yasaklıyor ("İşaretlenmemiş metin yalnız bağlamdır, kart kaynağı
değildir"), yani buradaki her sayı kuralın çiğnendiği anlamına geliyor.

Ucuz modelin tipik başarısızlığı kart üretememek değil, **boşluğu genel
bilgiyle doldurmak.** Örnekteki B takımının "nekroz tipleri" kartı tam olarak
bu: doğru bilgi, ama sayfada işaretlenmemiş.

## 4. Yanlış ama emin ← karar bu satırda

Kartı say **eğer ikisi birden doğruysa:**

- içeriği **yanlış** (sayfayla çelişiyor ya da tıbben hatalı), **ve**
- kartta "emin değil" işareti **yok** (`⚠` yok)

Yanlış ama `⚠` taşıyan kart buraya **girmez** — o model hatasını bildirmiş
demektir, ve bildirmesi tam olarak istenen davranış.

**Neden bu satır belirleyici:** kademe yönlendirmesi (ucuz model önce, gerekirse
Sol'a yükselt) yalnızca ucuz model hatasını kendisi bildiriyorsa çalışır.
Bildirmiyorsa hiçbir yükseltme tetiklenmez, yanlış kart sessizce desteye girer
— ve ucuz olduğu için daha çok üretilir. Kalibrasyon, ham doğruluktan önce
gelir.

`kolay` sayfalarda bu sütun bir takım için sıfırdan büyükse, o model
yönlendirme zincirinin başına konmaz.

## 5. Not

Serbest metin. En işe yarayanı, sayının anlatmadığı **davranış**: "üst
paragrafta takılıp kaldı", "şıkları hep aynı kalıpta kurdu", "el yazısını
okudu ama yanlış konuya bağladı".

---

# Doldurduktan sonra

1. **Anahtarı aç:** `key-<stamp>.json` → `byPageLabel` → hangi harf hangi model.
2. Sonuçları **zorluk grubuna göre** topla (`kolay-*` / `orta-*` / `zor-*`).
   Yönlendirme kararı tam olarak bu gruplamadan çıkıyor:
   - Luna `kolay` sayfalarda Sol'a yakın **ve** "yanlış ama emin" = 0 →
     yönlendirmenin ucuz ucu çalışabilir.
   - Terra `orta` sayfalarda Sol'a yakın → ana model Terra olabilir.
   - `zor` sayfalarda hepsi Sol'un altındaysa → zor sayfa Sol'da kalır.
3. Modeller ayrılmadıysa Tur B'ye geç (`blind-*.json`, §23.3 rubriği). Ayrıldıysa
   **geçme** — o tur bir buçuk saat sürer ve zaten bildiğin şeyi tekrar söyler.
