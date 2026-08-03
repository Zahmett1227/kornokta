# Faz 4 — FSRS tekrar motoru

**Dal:** `claude/proje-analizi-planlama-r7lxw4` (Faz 3'ün üstüne)
**ANA-PLAN:** §18, §25 Faz 4
**Çıkış kapısı:** Tüm FSRS testleri ve offline review akışı geçmelidir.

---

## Faz 4'e girerken zaten hazır olan

Faz 1'in kendi tasarımı Faz 4'ü büyük ölçüde önceden karşılamış:

- `Card`/`ReviewLog` SwiftData modelleri zaten FSRS'in kendi alanlarını
  taşıyor (`stability`, `difficulty`, `reviewCount`, `lapseCount`,
  `elapsedDays`, `deviceTimeZone`) — "Faz 1 uses a placeholder scheduler;
  FSRS replaces the algorithm in Faz 4 (§18) without changing these fields"
  yorumuyla, tam da bunun için.
- `ReviewScheduling` protokolü (`schedule(rating:state:now:) ->
  SchedulingResult`) zaten FSRS'in oturacağı kalıp — `ReviewView.swift`
  yalnızca bu protokolü çağırıyor, hangi uygulamanın arkasında olduğunu
  bilmiyor.
- `ReviewSessionPlanner.plan(...)` §18.3'ün "bugün bekleyen tüm kartlar",
  "askıya alınmış kartlar planlamaya girmez" ve "aynı bilgi biriminin
  kartları arka arkaya yığılmamalı" kurallarını zaten uyguluyor.
- `ReviewView.swift` tüm çevrimdışı akışı zaten çalışır durumda: oturum
  başlatma, ön yüz, "Cevabı göster", "Kaynağı göster", dört puan butonu,
  `ReviewLog` kaydı, kart durumunun güncellenmesi.
- `LibraryView.swift`'te askıya alma/askıdan çıkarma zaten var.

Yani Faz 4'ün gerçek eksiği tek bir şeydi: **`PlaceholderScheduler`'ın
yerine gerçek FSRS**. Bildirimler ve "hızlı mod" (süre bütçesine göre
kart seçimi) ayrı, daha küçük kalemler — aşağıda ayrı bölümde.

---

## FSRS formülleri nereden geldi

§18.1: "Açık kaynak ve güncel FSRS algoritması kullanılmalı... Algoritma
birim testleri referans implementasyonla karşılaştırılmalıdır." Bu, kendi
formüllerimi uydurmamam gerektiği anlamına geliyor — ve gerçekten de ilk
denemede **iki bağımsız kaynak farklı bir başlangıç-zorluk formülü verdi**
(biri üstel `D0(G) = w4 - e^(w5·(G-1)) + 1`, diğeri doğrusal `D0(G) = w4 -
(G-3)·w5`). Üçüncü, en yetkili kaynağa (open-spaced-repetition'ın kendi
`fsrs-optimizer` referans kodu) bakılarak üstel formül doğrulandı; doğrusal
olan muhtemelen daha eski bir FSRS sürümünün formülüyle karışıklıktı. Bu,
tam olarak §0.6'nın "asla uydurma rakam" kuralının neden var olduğunun
kanıtı — ilk fetch'e güvenilseydi yanlış bir formül koda girecekti.

Kullanılan sürüm: **FSRS-6**, 21 ağırlık, açık kaynak projenin kendi
yayınladığı varsayılan (kişiselleştirilmemiş) ağırlıklar. Bu ağırlıklar bu
kullanıcının kendi tekrar geçmişine göre optimize edilmemiş — çünkü henüz
hiç geçmiş yok. İleride `ReviewLog` verisi birikince gerçek bir
optimizasyon çalıştırılıp `weights.json` güncellenebilir; kodun kendisi
değişmez (§0.6).

---

## Ne yazıldı

### Python referansı (`evals/fsrs/`)

- `weights.json` — 21 ağırlık + `desiredRetention` (0.9, algoritmanın kendi
  yayınlanmış varsayılanı), provenance yorumuyla.
- `algorithm.py` — saf fonksiyonlar: `init_difficulty`, `init_stability`,
  `next_difficulty` (ortalamaya-dönüş/mean-reversion dahil),
  `retrievability`, `next_interval`, başarı/başarısızlık/aynı-gün stabilite
  formülleri, ve hepsini birleştiren `schedule(state, rating, elapsed_days,
  w, desired_retention)`.
- `export_cases.py` — 21 vakayı (`evals/shared/fsrs-cases.json`) üretiyor:
  ilk tekrar × 4 puan, genç/olgun kart × 4 puan, aynı-gün tekrar × 4 puan,
  ve aynı-gün/uzun-vade sınırının tam kendisi (elapsed=0.999 vs 1.0).

**Bu modülün kendi kararları** (algoritma spesifikasyonunun uygulayana
bıraktığı yerler):

1. **İki tekrar arasındaki süre her zaman mutlak bir süre**
   (`(now - son_tekrar) / 1 gün`), asla takvim günü farkı değil. Bir takvim
   günü sınırı, cihazın saat dilimi değiştiğinde kayar — §18.1'in
   yasakladığı "saat dilimi değişimi kart kaybına/çift tekrara yol açar"
   hatası tam olarak bu. `evals/tests/test_fsrs_timezone_safety.py`,
   `FSRSScheduler.swift`'in hiç `Calendar`/`TimeZone` kullanmadığını metin
   olarak doğruluyor (Swift derleyicisi olmadan çalıştırılabilen bir test).
2. **"Aynı gün" (kısa-vade formülü)** `elapsed_days < 1.0` ile karar
   veriliyor, takvim günü eşitliği değil — aynı sebepten.
3. **Stabilite küçük pozitif bir tabana (0.01) sabitleniyor** — spesifikasyon
   bunu belirtmiyor; sıfır ya da negatif bir stabilite `S^-w9` ve
   `S/factor` ifadelerini patlatır. Bu modülün kendi savunmacı eklemesi.
4. **Maksimum aralık 36.500 gün (100 yıl)** — FSRS'in kendi yaygın
   konvansiyonu, bu uygulamaya özgü bir sayı değil.

### Testler (`evals/tests/test_fsrs_*.py`, hepsi çalıştırıldı — 48 test)

- `test_fsrs_algorithm.py` (41 test) — iki türde: **cebirsel değişmezler**
  (hangi FSRS uygulaması olursa olsun geçerli — `R(S,S) == 0.9`,
  `next_interval` ve `retrievability` birbirinin tersini vermeli) ve
  **davranışsal testler** (Again < Hard < Good < Easy sıralaması, zorluk
  [1,10] aralığında kalıyor, aynı-gün/uzun-vade sınırı tam `elapsed_days=1.0`
  noktasında).
- `test_fsrs_export.py` (5 test) — `fsrs-cases.json`'un `algorithm.py`'den
  üretilmiş ve güncel olduğunu doğruluyor.
- `test_fsrs_config_sync.py` (3 test) — `evals/fsrs/weights.json` ile
  `ios/.../Resources/fsrs-weights.json`'un byte-birebir aynı olduğunu
  doğruluyor (marker-detection config'iyle aynı desen).
- `test_fsrs_timezone_safety.py` (2 test) — yukarıdaki §18.1 güvencesi.

### Swift portu (`ios/CizgiCore/Sources/CizgiCore/Scheduling/`)

- `FSRSWeights.swift` — `MarkerConfig.swift` ile birebir aynı desen:
  `Codable` struct, `bundled()`/`bundled(bundle:)`/`load(contentsOf:)`,
  eksik/bozuk kaynakta sessizce yerleşik sayılara düşmek yerine fırlatıyor.
- `FSRSScheduler.swift` — `algorithm.py`'nin satır satır portu, aynı
  fonksiyon isimleri ve aynı sırayla. `ReviewScheduling` protokolüne uyuyor,
  yani `ReviewView.swift`'te **hiçbir değişiklik gerekmedi**.
- `AppEnvironment.makeScheduler()` eklendi — `makeSelector()`'la aynı
  desen: `(try? FSRSScheduler()) ?? PlaceholderScheduler()`. Ağırlıklar
  okunamazsa placeholder'a düşüyor, çökmüyor.
- `SettingsView`'daki "Tekrar algoritması" satırı artık gerçek durumu
  gösteriyor ("FSRS-6" ya da "Geçici (bundled ağırlıklar okunamadı)") —
  önceden hep "Geçici (FSRS Faz 4)" yazıyordu, ki bu artık yanlış olurdu.

**Yeni Swift testleri (`FSRSSchedulerTests.swift`, 6 test) — kullanıcı
tarafından bir Mac'te `swift test` ile doğrulandı (2026-08-03):**
- `FSRSSharedCaseTests` — `evals/shared/fsrs-cases.json`'daki 21 vakanın
  hepsini Swift tarafında yeniden hesaplayıp Python referansıyla
  karşılaştırıyor (§18.1'in "referans implementasyonla karşılaştırma"
  gereksinimi, iki dil arasında).
- `FSRSSchedulerTests` — ilk tekrar, Easy>Again sıralaması, uzun aradan
  sonra Again'in bir kayıp (lapse) olması, ve gerçek bundle'dan
  ağırlıkların yüklenip mantıklı bir sonuç üretmesi.

---

## Henüz yapılmayanlar (çıkış kapısını engellemiyor)

Faz 4'ün ANA-PLAN §25'teki tam kapsamı ("FSRS, günlük oturum, kart
puanlama, kaynak gösterme, bildirim, askıya alma/düzenleme") listesinden
bildirimler ve ayarlanabilir "yeni kart limiti"/süre-bütçeli hızlı mod
henüz yok — ama **stated çıkış kapısı** ("Tüm FSRS testleri ve offline
review akışı geçmelidir") bunları istemiyor; günlük oturum, kart puanlama,
kaynak gösterme ve askıya alma zaten Faz 1'den beri çalışıyor.

1. **Bildirimler** — `AppSettings.notificationHour` alanı var ama hiçbir
   `UNUserNotification*` çağrısı yok. Sıfırdan yazılacak bir Faz 4/5 kalemi.
2. **Süre bütçeli "hızlı mod"** — `ReviewSessionPlanner.plan(...)` zaten bir
   kart-sayısı `limit` parametresi alıyor, ama §18.3'ün istediği
   **süre bütçesi** (dakika cinsinden) henüz bir UI/ayar olarak yok.
3. **Yeni kart limiti** — ayrı bir ayar olarak henüz yok
   (`maxCardsPerPassage` farklı bir şey: pasaj başına üretilecek kart
   sayısı, günlük yeni kart tanıtım limiti değil).

## Sonuç

Kullanıcı `cd ios/CizgiCore && swift test`'i kendi Mac'inde çalıştırdı:
**136/136 test yeşil** (2026-08-03) — mevcut 114 test (formüller
`ReviewScheduling` protokolünü değiştirmedi) ve Faz 3/4'ün eklediği +22
test (16'sı F3-8'den, 6'sı FSRS'ten) dahil.

## Test durumu

```
$ python -m pytest evals -q
503 passed   (bunun 51'i bu oturumda FSRS için eklendi: 41 algoritma +
              5 export-tazelik + 3 config-senkron + 2 saat dilimi güvenliği)
```

Swift: 136 test, hepsi bir Mac'te doğrulandı (2026-08-03).
