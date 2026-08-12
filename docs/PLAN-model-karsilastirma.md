# Model karşılaştırma planı (Sol / Terra / Luna) ve kademe yönlendirmesi

Amaç iki soruyu birlikte cevaplamak:

1. **Ana model değişmeli mi?** Terra, Sol'un %40 fiyatına; Luna %4'üne.
2. **Sabit tek model yerine sayfaya göre kademe seçilebilir mi?**
   Sahibinin sezgisi: *net sayfa + belirgin el yazısı → Luna; okunması zor,
   yüksek fosforlu, silik → Sol; ortası → Terra.* Bu plan o sezgiyi
   sınanabilir hâle getiriyor.

İkinci soru birincisinin üstünde durmuyor — **aynı deneyden çıkıyor.** Üç
modeli aynı sayfalara koşturmak, "hangisi genel olarak iyi?" kadar "hangi
sayfada hangisi yetiyor?" sorusunu da cevaplar.

## Sabitler (deney boyunca değişmez)

| Ayar | Değer | Neden |
|---|---|---|
| Sayfa başına kart | **20** (yalnız deneyde) | Aşağıya bak — 12'de üç model de tavana yapışıyor ve kapsama farkı ölçülemiyor. Uygulama 12'de kalıyor. |
| Beş şıklı mod | `mixed` | Üç modelde de aynı |
| `reasoning_effort` | `low` | Adil karşılaştırma sabit tutar (ikinci tur notuna bak) |
| Ders | Patoloji (ya da sayfaların dersi) | Konu atamasını da ölçer |

## Sayfa seçimi

**6–8 sayfa**, ve kolay sayfa seçmemek. Kademe yönlendirmesi sınanacaksa
sayfalar **zorluk ekseninde yayılmalı** — hepsi zor olursa Luna'nın nerede
yettiği hiç görülmez.

| Etiket | Sayfa tipi | Ne sınar |
|---|---|---|
| `kolay` | Net baskı, belirgin/kalın el yazısı, temiz fosforlu | Luna'nın tavanı |
| `kolay` | Az işaretli, seyrek | **Uydurma eğilimi** — boş yere kart üretiyor mu |
| `orta` | Daire/yıldız/ok sembolleri | İşaret tipi ayrımı |
| `orta` | Tablo/şema üstünde işaret | Yerleşim okuma |
| `zor` | Soluk/silik fosforlu | Algı sınırı |
| `zor` | Yoğun, çok noktalı, karışık el yazısı | Kapsama + el yazısı |

Dosya adına zorluğu yaz (`kolay-01.jpg`, `zor-02.jpg`) — kör puanlamayı
bozmaz (harfler modelleri gizler, sayfa zorluğunu değil) ve sonuçları zorluğa
göre gruplamayı mümkün kılar. **Yönlendirme kararı tam olarak bu grupların
karşılaştırmasından çıkar.**

Sayfalar `evals/fixtures/pages/` altına — gitignore'lu, telifli sayfa repoya
girmez.

## Çalıştırma

```bash
cd backend
npm run compare -- \
  --models "gpt-5.6-sol:5/0.5/30,gpt-5.6-terra:2/0.2/12,gpt-5.6-luna:0.2/0.02/1.2" \
  --pages ../evals/fixtures/pages \
  --subject Patoloji \
  --max-cards 20
```

`--max-cards 20` **bilerek** veriliyor, ve sebebi ilk gerçek koşuda ortaya çıktı:
25'ten fazla işaret taşıyan bir sayfada üç model de tam 12 kart üretti — yani
üçü de tavana çarptı. O sayfada "yakalanan işaret / toplam" satırı modeli
değil **sınırı** ölçüyor, ve üç model birbirinden ayırt edilemiyor. Tavanı
deneyde açmak, kapsama farkını görünür kılan tek yol.

Uygulamanın kendi ayarı **12'de kalıyor**; bu yalnız ölçüm içindir. Betik
`--max-cards`'ı dağıtımın tavanının üstüne çıkarabiliyor (`experimentCardCeiling`)
— üretimde geçerli olan §21.3 kelepçesi burada yanlış olurdu, çünkü betiği
koşturan kişi dağıtımın sahibi ve kendi anahtarını harcıyor.

**Deneyin maliyeti ~$1.2** (8 sayfa: Sol ≈$0.77, Terra ≈$0.31, Luna ≈$0.03).
Cevabı tahmin etmeye çalışmaktan ucuz.

Üç dosya yazar (hepsi `evals/reports/`, gitignore'lu):

- `perception-<stamp>.md` — **Tur A**, doldurulacak algı sayfası
- `blind-<stamp>.json` — **Tur B**, kart bazlı kör rubrik sayfası
- `key-<stamp>.json` — anahtar, **doldurma bitene kadar açılmaz**

## Tur A — algı taraması (~20 dk, önce bu)

Sayfa başına üç anonim kart takımı (A/B/C), sayfanın fotoğrafı yanında.
Harfler **her sayfada bağımsız karıştırılır** — sabit sırada olsaydı kart
sayılarından ikinci sayfada hangi harfin pahalı model olduğu anlaşılır ve
gerisi körlük değil tiyatro olurdu (`labelOrder`, testle kilitli).

Doldurulacak dört satır:

| Satır | Ne ölçer |
|---|---|
| Yakalanan işaret / toplam | Kapsama |
| El yazısı | `okundu` / `okunamadı dedi` / `yanlış okudu` / `yok` |
| Uydurma kart | İşaretlenmemiş yerden üretilmiş kart sayısı |
| **Yanlış ama emin** | İçeriği yanlış OLDUĞU HÂLDE "emin değil" işareti taşımayan kart |

Dördüncü satır bu planın en önemli ölçümü ve aşağıdaki yönlendirme
tasarımının tamamı ona bağlı — ayrıntısı bir sonraki bölümde.

Doldurulmuş bir örnek ve her satırın tek tek ne demek olduğu:
[`docs/ORNEK-algi-taramasi.md`](ORNEK-algi-taramasi.md).

Çoğu senaryoda karar Tur A'da biter. Terra işaretlerin ~hepsini yakalayıp el
yazısını okuyorsa Tur B'ye gerek yok.

## Tur B — §23.3 rubriği (yalnız Tur A ayıramazsa)

Modeller Tur A'da birbirine yakın çıkarsa `blind-<stamp>.json` üzerinden kart
zanaatı puanlanır, sonra:

```bash
python -m evals.model_compare.report \
  --scores evals/reports/puanlar.json \
  --key evals/reports/key-<stamp>.json \
  --report evals/reports/compare-<stamp>.json
```

Rapor kasten kazanan ilan etmez (§0.6). Öne çıkardığı sayı sayfa başına
maliyet değil, **kabul edilen kart başına maliyet**.

## Tur A sonucu (2026-08-12 koşusu)

6 sayfa × 3 model × 20 kart üretildi, algı taraması dolduruldu, anahtar
açıldı. Not: `labelOrder` sayfa adından deterministik türediği için aynı
sayfa adları iki koşuda aynı harf→model eşlemesini verir — iki koşunun
sonuçları bu sayede doğrudan karşılaştırılabildi. Öne çıkanlar:

- **18 setin 18'i tam 20 kart** — tavan 20'de de doldu (sayfalar 25–40 işaret
  taşıyor). "Yakalanan/toplam" satırı kısmen hâlâ sınırı ölçüyor; ama
  modellerin *neyi düşürdüğü* ayrıştı ve her model en az bir sayfada bir
  bölümü komple attı (Terra bir sayfada son üç konu başlığını, bir başkasında
  ferroptozis + boya tablosunu hiç kartlaştırmadı).
- **Koşunun tek "yanlış ama emin"i Terra'dan** — ve iki bağımsız koşuda aynı
  sayfada aynı hata (Plummer-Vinson'ı web yerine Schatzki halkasına bağladı),
  ikisinde de bayraksız. Orta kademede tekrarlanabilir sessiz hata, "varsayılan
  Terra" fikrinin altını oydu.
- **Luna (fiyatın ~1/25'i) 120 kartta sıfır bayraksız hata** yaptı; el yazısı
  en yoğun sayfalardan oral kavitede en kapsamlı takımdı. Zayıf yanı el
  yazısı/kapsama: bir notu hiç anmadı, bir notu yanlış yorumladı — ama o
  yorumu kendisi "emin değilim" diye işaretledi. Sayfanın "kolaylığı"
  Luna'nın kapsamasını öngörmedi (en zayıf kapsaması en kolay sayfadaydı).
- **Sol el yazısında açık ara en iyi** (ok yönünü izleyip kenar notunu doğru
  bölüme bağlayan tek model) ve toplam kapsaması en geniş (~15 eksik konu;
  Luna ~22, Terra ~24). Ama bu sayfalarda Luna'ya farkı 25× fiyat farkını
  anlatacak boyutta görünmedi; uygulamanın kendi 12 kart tavanında kapsama
  farkı daha da görünmezleşir.

Tur B'ye gerek kalmadı: Tur A modelleri ayırdı. Kart zanaatı sorusu ayrı iş
olarak A6'da ölçülür. Model kararı sahibinin; aşağıdaki yönlendirme tasarımı
bu veriyle güncellenmeli (Terra-merkezli kademe zayıfladı, Luna-önce +
zor sayfada Sol güçlendi — Luna belirsizliğini bayrakladığı için yükseltme
tetiği gerçekten çalışabilir).

---

# Kademe yönlendirmesi (routing)

## Kim karar verir?

| Yaklaşım | Değerlendirme |
|---|---|
| **(a) Kullanıcı çekimde seçer** | Basit, deterministik, ek maliyet yok. Ama her çekime sürtünme ekler ve sayfanın zor olduğu genelde *önceden* bilinmez. |
| **(b) Cihaz üstü görüntü sezgiseli** (kontrast, mürekkep yoğunluğu) | §0.8'e uyar ama **ADR-002/003/004'ün silinme sebebi tam olarak buydu**: "soluk fosforlu"yu cihazda güvenilir tespit etmek, çözülemediği için terk edilen problemin ta kendisi. |
| **(c) Ucuz model önce, gerekirse yükselt** | Sistemin **zaten ürettiği** sinyali kullanır: `lowConfidence`, kart sayısı, `noContent`. Yeni algı kodu yok. Kötü durumda zor sayfada Luna bedeli fazladan ödenir. |
| **(d) Ayrı sınıflandırıcı çağrı** | Ek çağrı, ek gecikme; ve sınıflandırma da bir görme yargısı — işin kendisi kadar zor. |

**Öneri: (c), (a) manuel geçersiz kılmayla.** Yeni algı kodu gerektirmemesi
belirleyici — ADR-005'in dersi tam da buydu.

## (c)'nin tek koşulu — ve Tur A'nın onu ölçme sebebi

Kademeli tasarım **yalnızca ucuz model hatasını kendisi bildiriyorsa** işler.

Tehlikeli başarısızlık, Luna'nın kart üretememesi değil — o zaten görünür ve
yükseltmeyi tetikler. Tehlikeli olan **kendinden emin yanlış**: Luna
"hipokalemi"yi "hiperkalemi" okur ve kartı `lowConfidence=false` işaretler.
O zaman hiçbir yükseltme tetiklenmez, yanlış kart sessizce desteye girer ve
ucuz olduğu için daha da çok üretilir.

Bu, "pahalı ama doğru"dan kötüdür. `perception-*.md`'deki **"Yanlış ama emin"**
satırı tam olarak bunu sayar.

**Karar eşiği:** Luna (ya da Terra) `kolay` sayfalarda "yanlış ama emin"
üretmiyorsa yönlendirme güvenli; üretiyorsa **yönlendirme yapılmaz**, sabit
model kullanılır. Kalibrasyon, ham doğruluktan önce gelir.

## Kademeli akış (Tur A izin verirse)

```
sayfa → Luna
   ├─ kart yok / çok az kart            ─┐
   ├─ lowConfidence kart oranı yüksek    ├─→ Sol ile yeniden üret
   └─ "el yazısı okunamadı" dedi        ─┘
   └─ hiçbiri yoksa → kartlar desteye
```

Terra ara kademe olarak Luna ile Sol arasına girebilir, ama **iki kademeyle
başlanmalı**: her ek kademe, yükseltme kararının yanlış olma ihtimalini
çarpar ve kazanç eğrisi hızla düzleşir.

### Maliyet aritmetiği

Sayfaların %70'i kolaysa ve yükseltme doğru çalışırsa:

```
0.70 × Luna              = 0.70 × $0.004 = $0.003
0.30 × (Luna + Sol)      = 0.30 × $0.100 = $0.030
                           toplam ≈ $0.033/sayfa   (Sol: $0.096)
```

≈ **%65 tasarruf** — Terra'ya sabit geçişle (%60) yakın, ama zor sayfalarda
Sol kalitesi korunarak. Asıl kazanç budur: ortalamayı düşürmek değil, **zor
sayfada kaliteden ödün vermemek.**

Uyarı: bu hesap yükseltmenin doğru tetiklendiğini varsayar. Yanlış yükseltme
(kolay sayfa Sol'a gidiyor) tasarrufu yer; yanlış yükseltmeme (zor sayfa
Luna'da kalıyor) kaliteyi yer. İkincisi daha pahalıdır.

### Uygulama sırası (Tur A yeşil verirse)

1. **Ölç, yönlendirme yok.** Bir hafta Terra'ya geç (tek satır: Vercel'de
   `OPENAI_MODEL`). Yeni maliyet defteri modele göre kırılım veriyor —
   "Çağrı dökümü → Modele göre" satırı bunu zaten gösteriyor.
2. **Yükseltme sinyalini kaydet, uygulama.** `/api/jobs` işçisine, üretim
   bitince "bu iş yükseltilecekti mi?" kararını **loglat** ama yükseltme.
   Bir hafta sonra: kaç sayfa yükselirdi, ne kadar tutardı — gerçek veriyle.
2 numarası kritik: yükseltme mantığı **para harcamadan** doğrulanabilir.
3. **Sonra aç.** `_jobs.ts`'te ikinci bir üretim, aynı iş satırında.
   ADR-006'nın kuralı burada da geçerli: *her durum değişikliği onu haklı
   çıkaran duruma koşullu olmak zorunda* — yükseltme, yalnız ilk denemenin
   sonucu hâlâ satırdaysa yazılabilir. Defter zaten deneme başına satır
   tutuyor, yani yükseltmenin maliyeti ilk günden görünür olur.
4. **Manuel geçersiz kılma** (Ayarlar → "Bu sayfa zor"), ancak kademeli akış
   oturduktan sonra.

Bu iş ADR-006/007 seviyesinde bir karardır; açılmasına karar verilirse
**ADR-008** olarak yazılmalı.

## İkinci tur soruları (şimdi değil)

Adil karşılaştırma `reasoning_effort`'ü üç modelde sabit tutar. Ama Luna'nın
**en iyi** konfigürasyonu farklı olabilir: daha çok düşünmeyle Sol'u
yakalayabilir ve hâlâ 10 kat ucuz kalabilir. İlk turu karıştırmaz; Luna Tur
A'da sınırda kalırsa ikinci tur konusudur.
