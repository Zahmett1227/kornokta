# ADR-008 — FES: kalıcı, iki kaynaklı "takıldığım kart" sicili

**Tarih:** 2026-08-14 · **Durum:** kabul edildi, uygulandı

## Bağlam

Egzersiz'in "Zayıf noktalar" seçimi (`WeakPointRanking`/`ExercisePracticeWeight`,
`ExerciseSelection.swift`) yalnız **son 30 günün** pratik geçmişinden besleniyor
ve `ExerciseAttempt` satırları **90 günde** siliniyor (`ExerciseHistory.retention`).
İkisi birlikte, aylardır tekrar tekrar unutulan bir kart eninde sonunda listeden
sessizce düşüyor — "kanayan noktalarım" kalıcı değil, sönümlü.

Kullanıcı bu sicile bir isim ve kalıcılık istedi: hem Tekrar (FSRS) hem
Egzersiz'de birkaç kez yanlış/kararsız işaretlenen bir kart, kaç gün geçerse
geçsin işaretli kalsın; ama düzelttiğinde de kendiliğinden temizlensin.

## Karar

**FES**, `Card` üzerinde saklanan bir yürüyen skor — hesaplanan değil, biriken:

```
Signal   Ağırlık
wrong     +2   (Tekrar: Unuttum · Egzersiz: Bilemedim)
unsure    +1   (Tekrar: Zor      · Egzersiz: Kararsızdım)
correct   −2   (Tekrar: Bildim/Kolay · Egzersiz: Biliyordum)
```

Skor `[0, 12]` aralığında kırpılır (`FesScore.floor`/`ceiling`); **eşik 3**
(`FesScore.threshold`). Tavan bilinçli: aylarca yanlış yapılan bir kart bile
altı doğru cevapta tamamen temizlenir — düzeltilmiş bir kartı sonsuza dek
etiketli bırakmak "kendiliğinden temizlenir" vaadini bozardı.

**Neden saklanan, hesaplanan değil:** `ExercisePracticeWeight`'in kendisi zaten
zaman-sönümlü bir skor hesaplıyor (`ExerciseSelection.swift`) — FES onun
yerine geçmiyor, **yanına** giriyor. Sönümlü skor "şimdi ne çalışmalıyım"
sorusuna cevap verir ve doğru şekilde unutur; FES "hangi kart beni tarih
boyunca hep zorladı" sorusuna cevap verir ve **hiç unutmaz**. `ExerciseAttempt`
90 günde silindiği için ikinci soruyu türetilmiş bir değerle cevaplamak
imkânsız — cevap saklanmak zorunda.

**Neden iki ekrandan besleniyor:** tek ekrandan beslenen bir sicil yarım bir
resim çizer — yalnız Egzersiz'de zorlanılan ama Tekrar'da hiç yanlış
yapılmayan bir kart (ya da tam tersi) FES'e hiç girmez. "Zor" (Tekrar) ile
"Kararsızdım" (Egzersiz) aynı ağırlığı taşıyor çünkü ikisi de aynı şeyi söylüyor:
hatırlandı ama temiz değil.

**Çekirdek:** `CizgiCore/Scheduling/FesScore.swift` — saf, Foundation-only,
`EarlyPractice.swift` ile aynı mimari. İki yazma noktası (`ReviewView.grade`,
`ExerciseView.recordAndAdvance`), ikisi de kendi mevcut `context.save()`'ine
biner, ADR-007'nin FSRS köprüsünden **tamamen bağımsız** — FES saf muhasebe,
hiçbir zamanlama kararını etkilemez, `EarlyPractice`'in due/frozen kapılarına
tabi değildir (Egzersiz'de `unsure` FSRS'e hiç dokunmaz ama FES'i besler).

**Geçmiş replay'i:** `FesBackfillMigration`, `Card.fesInitializedAt == nil`
olan her kartın `ReviewLog` + hayatta kalan `ExerciseAttempt` geçmişini
kronolojik sıraya dizip `FesScore.replay` ile oynatır. Bir UserDefaults
bayrağıyla değil, **kartın kendi alanıyla** tetiklenir (`SubjectBackfillMigration`/
`TopicBackfillMigration`'dan farkı budur): yeni bir kart da `nil` ile
başlar (replay'i boş geçer, zararsız), pre-v6 bir yedekten gelen kart da
`nil` ile gelir — ikisi de bir sonraki açılışta kendiliğinden işlenir; global
bir bayrak "her zaman nil kartları yakala" davranışını ifade edemezdi.

**Egzersiz'deki "Zayıf noktalar" → "FES kartlar":** üyelik artık FES'in kalıcı
kuralıyla belirleniyor; sıralama hâlâ `WeakPointRanking.rank` — ama
`weakOnly`'nin kendi sönümlü `isWeak` filtresinden **geçmeden**. Filtreden
geçseydi, son yanlışı 30 günden eski olan ama FES eşiğini aşmış bir kart
tam FES'in var olma sebebi olan durumda sessizce listeden düşerdi.

**Filtre/bütçe genişlemesi (aynı iş, birlikte geldi):** Egzersiz kurulumu
altı boyuta çıktı — ders, konu (mevcut `TopicFilter`), kart tipi, kart durumu
(`unstudied`/`due`/`needsReview`), eklenme tarihi, FES (`ExerciseFilter.swift`).
Bütçe de kart sayısı kademelerinin yanına süre bütçesini aldı
(`ExerciseBudget.swift`), Tekrar'ın `ReviewPace`'ini (ölçülen, varsayılmayan
kart-başı süre) yeniden kullanarak — Egzersiz kendi `ExerciseAttempt.responseTimeMs`
örnekleriyle besliyor, çekirdekte hiçbir değişiklik gerekmedi.

## Yedek biçimi v6

`fesScore`/`fesNegativeCount`/`fesInitializedAt` — üçü de **zaten sonuçlanmış**
olarak yazılır, alıcı cihazda yeniden hesaplanmaz. `fesInitializedAt`'in
`nil` olmaması, `FesBackfillMigration`'a "bu kartı tekrar oynatma" der — bu
önemli, çünkü `ExerciseRun`/`ExerciseAttempt` **hiçbir zaman** yedeğe girmiyor;
restore sonrası bir replay yalnız `ReviewLog` yarısını görür ve orijinal
skorun Egzersiz kaynaklı kısmını sessizce kaybederdi. Pre-v6 bir dosyada üçü
de yok → `nil`/`0` ile açılır, alıcı cihaz elindeki `ReviewLog` geçmişinden
mümkün olan en iyi tahmini kendi çıkarır (zaten var olan, kabul edilmiş bir
sınırın devamı — Egzersiz geçmişi hiçbir sürümde yedeğe girmiyor).

## Sonuçlar

- Yeni `Card` alanları (`fesScore = 0`, `fesNegativeCount = 0`,
  `fesInitializedAt: Date?`) declaration-time default'lu — mevcut kartlar
  hiçbir kararı beklemeden göçer.
- FES, ADR-007'nin FSRS köprüsüyle karışmıyor: ikisi aynı `recordAndAdvance`
  çağrısında yan yana çalışıyor ama farklı sorulara cevap veriyor
  (biri "zamanlama ne olsun", biri "bu kart tarihsel olarak zor muydu").
- `AppNavigator.ExerciseTarget.Filter` bilinçli olarak genişletilmedi — Bilgi
  Haritası'ndan gelen bir "bu dersten Egzersiz" hâlâ yalnız ders/konu taşıyor;
  altı boyutun geri kalanı yalnız Egzersiz'in kendi kurulum sheet'inde yaşıyor.
