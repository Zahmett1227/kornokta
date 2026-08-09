# ADR-007 — Egzersiz, FSRS'i korumalı bir köprüyle besliyor (erken tekrar + soft lapse)

**Tarih:** 2026-08-09 · **Durum:** kabul edildi, uygulandı · **Kaynak fikir:**
uygulama sahibinin tusoskop projesindeki `smartReviewScheduler` (erken tekrar
ağırlığı, soft lapse, aynı-gün dondurma).

## Bağlam

Egzersiz modu bilinçli olarak FSRS'e tamamen kördü (PR #32/#33):
"Egzersiz kaydı FSRS alanlarına ve `ReviewLog`a dokunmaz." İki iyi sebebi
vardı — pratik yürüyüşü kartın aralığını suni olarak büyütmemeli, ve vadesinden
önce yapılan bir öz-sınavda yanılmak gerçek bir lapse sayılmamalı.

Ama tam körlüğün ters maliyeti Egzersiz merkeze alınınca görünür oldu:
kullanıcı ne kadar çok pratik yaparsa, FSRS gerçek bilgi durumunun o kadar
azını görüyor. Egzersiz'de üç kez doğru yapılmış bir kart tekrar kuyruğunda
hâlâ "hiç görülmemiş" gibi duruyor; Egzersiz'de vadesine bir gün kala unutulan
bir kart FSRS için hâlâ sapasağlam.

Tusoskop aynı problemi yıllar önce çözmüştü: erken tekrar tam puan değil
**kısmi kredi** alır, erken yanlış gerçek değil **yumuşak** lapse'tir,
aynı gün içindeki tekrarlar programı **dondurur**. Mekanik oradan taşındı;
formüller değil — tusoskop'un zamanlayıcısı hafif bir yaklaşımken burada
gerçek FSRS-6 var, o yüzden köprü zamanlayıcının *önünde* bir politika
katmanı olarak kuruldu.

## Karar

Tek politika noktası: **`CizgiCore/Scheduling/EarlyPractice.swift`** (saf,
Foundation-only, izole pakette 12 testle koşuldu). Egzersiz'de bir yanıt
kaydedilirken (`ExerciseView.recordAndAdvance`) karta yalnız bu politikanın
döndürdüğü alanlar uygulanır:

| Durum | Sonuç |
|---|---|
| "Kararsızdım" | FSRS'e **hiç** dokunmaz (yalnız `ExerciseAttempt` analitiği) |
| FSRS'in hiç görmediği kart (`reviewCount == 0`) | Dokunmaz — ilk notu tekrar oturumu verir |
| Vadesi gelmiş kart | Dokunmaz — vadesi gelen kartı notlamak tekrar oturumunun işi; Egzersiz kuyruğu boşaltamaz. (Bu kontrol dondurmalardan **önce**: soft lapse'in öne çektiği kart bir gün sonra buraya düşer, aşağıdaki oran hesabına asla geri dönmez.) |
| Gerçek tekrarın üzerinden **24 saat geçmemişken** | Donuk. Sürekli pencere, takvim günü değil — takvim sınırı saat dilimiyle kayar (§18.1'in yasakladığı şey); 23:50'de tekrar edilen kart 00:10'da "yeni gün" sayılamaz. |
| Son FSRS-dokunuşlu pratiğin üzerinden **24 saat geçmemişken** (`Card.lastPracticedAt`) | Donuk. Bu olmadan aynı akşam üç "Hızlı 10" koşusu kartın kredisini geçiş başına bileşik büyütürdü — Egzersiz'in engellemek için var olduğu davranış. Aynı pencere, soft lapse'in değiştirdiği vadenin bir sonraki yanıtın oranını bozmasını da imkânsız kılar. |
| **Erken doğru** | Kısmi stabilite kredisi: gerçek bir "Bildim"in kazandıracağı stabilite artışının, aralığın ne kadarı geçtiyse ona göre bir kesri (0.15'e kadar %10, 0.5'e kadar %35, 0.8'e kadar %65, üstü %90 — tusoskop'un basamak tablosu). **Vade asla ileri itilmez**, zorluk ve sayaçlar değişmez. Kredi farklı günlerde tekrar kazanılabilir (günde en fazla bir kez, dondurma sayesinde) — bu bilinçli: bir gün arayla tekrar hatırlamak gerçek bir kanıttır. |
| **Erken yanlış**, aralığın < %75'i geçmişken | **Soft lapse:** `softLapseCount += 1`, kart en fazla 1 gün ileriye çekilir (`min(vade, şimdi+1g)`), stabilite/zorluk/gerçek lapse sayısı değişmez. Çok erken alınan öz-sınavda yanılmak unutma kanıtı değildir. |
| **Erken yanlış**, aralığın ≥ %75'i geçmişken | **Gerçek lapse:** tekrar oturumunun uygulayacağı FSRS "Unuttum" güncellemesinin aynısı (stabilite/zorluk/vade zamanlayıcıdan, `lapseCount+1`, `reviewCount+1`, `lastReviewedAt = şimdi`). |

> İlk taslak takvim-günü dondurması kullanıyor ve pratik dondurması hiç
> taşımıyordu; PR #36 incelemesi üç gerçek açık buldu (aynı akşam bileşik
> kredi, soft lapse sonrası oran bozulması, saat dilimine duyarlı takvim
> kontrolü). Üçü de yukarıdaki iki sürekli 24 saatlik pencereyle kapatıldı;
> `Card.lastPracticedAt` bu yüzden var ve yedeğe (v5) giriyor.

**Değişmeyenler:**

- `ReviewLog` Egzersiz'den **asla** yazılmaz — tekrar geçmişi, gerçek planlı
  tekrarların kaydı olarak kalır (FSRS ağırlık optimizasyonunun girdisi de o).
- `ExerciseSession` saf kalır; köprü kayıt anında, App katmanında uygulanır.
- Zayıf Nokta seçimi değişmedi: Egzersiz yanlışı zaten pratik-hatası kanalından
  besleniyor; `softLapseCount`'u ayrıca saydırmak aynı olayı iki kez tartardı.

**Yeni alanlar:** `Card.softLapseCount` (varsayılan 0) ve
`Card.lastPracticedAt` (opsiyonel) → hafif SwiftData göçü, `optionsRaw` ile
aynı desen. Yedek biçimi **v5** ikisini de taşıyor (`decodeIfPresent`, eski
dosyalar 0/nil okur).

## Sonuçlar

- PR #32'nin "Egzersiz FSRS'e dokunmaz" değişmezi bilinçli olarak
  daraltıldı: artık "Egzersiz FSRS'e **yalnız `EarlyPractice` üzerinden ve
  yalnız erken kartlarda** dokunur". `docs/PLAN-egzersiz-bilgi-haritasi.md`'nin
  kabul koşulları buna göre güncellendi.
- Cihazda gözlenecek etki: sık pratik yapılan sağlam kartların gerçek
  tekrarları seyrekleşir (stabilite kredisi bir sonraki gerçek tekrarın
  aralığını büyütür); Egzersiz'de vadesine yakın unutulan kart tekrar
  kuyruğuna hemen düşer.
- Eşikler (`0.75`, basamak ağırlıkları, 1 günlük çekme) kod içinde adlandırılmış
  sabitler ve tek dosyada — gerçek kullanım başka değerler isterse değişecek
  yer belli.
