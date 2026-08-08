# Egzersiz ve Bilgi Haritasi Gelistirme Plani

Tarih: 2026-08-08
Branch: `codex/egzersiz-bilgi-haritasi-ui`

## Urun kararlari

- Kok ozelligin adi her yerde **Egzersiz** kalir.
- Egzersiz, alt navigasyonun ortasinda ve gorsel olarak en guclu hedeftir.
- Uygulama ve genel ana sayfa eylemi Egzersiz'e acilir.
- Egzersiz sonuclari kendi gecmisini olusturur; `Card` zamanlama alanlari,
  `ReviewLog`, FSRS ve gunluk yeni kart kotasi degismez.
- Kisisel bilgi grafiginin kullaniciya gorunen adi **Bilgi Haritasi**dir.
- Bilgi Haritasi, `Bilgilerim` icindeki `Kartlar | Bilgi Haritasi` gorunumudur.

## Uygulanan ilk dilim

- [x] Bes kok hedefli ozel alt navigasyon
- [x] Ortada yukseltilmis Egzersiz eylemi
- [x] Egzersiz icin bagimsiz `NavigationStack`
- [x] Aktif oturumda alt navigasyonun gizlenmesi
- [x] Hizli 10 ve Zayif Noktalar baslangiclari
- [x] Ders/konu ve 10/20/tumu oturum kurulumu
- [x] Acik uclu kartlarda Biliyordum/Kararsizdim/Bilemedim sonucu
- [x] Coktan secmeli kartlarda otomatik dogru/yanlis sonucu
- [x] `ExerciseRun` ve `ExerciseAttempt` ile ayri kalici gecmis
- [x] Uygulama yeniden acildiginda yarim kalan oturumu kurma
- [x] Egzersiz yanlislarini Zayif Noktalar seciminde kullanma
- [x] Mevcut ders/konu semasindan ilk Bilgi Haritasi
- [x] Haritadan ders veya konu filtreli Egzersiz'e gecis
- [x] Ortak hero, bolum basligi ve hizli eylem kartlari
- [x] Ayarlarda gunluk ogrenme kontrollerini teknik kurulumun onune alma

## Inceleme turunda kapatilanlar (2026-08-08)

Ilk dilim gozden gecirildi; asagidakiler ayni dalda duzeltildi.

- **Aktif oturumdan cikis.** Oturum alt navigasyonu gizliyordu ama Egzersiz bir
  sekme koku oldugu icin geri butonu da yok: kullanici kuyrugun son kartina
  kadar ekranda kilitli kaliyordu. Yarim kalan kosu her aciliste geri
  yuklendigi ve varsayilan sekme Egzersiz oldugu icin uygulamayi oldurmek de
  cikis degildi. Artik sol ustte onay soran bir **Bitir** var
  (`ExerciseSession.finishEarly()`), yanitlanan kartlarin ozeti korunuyor ve
  kosu `finishedAt` ile kapatiliyor. Kural: alt navigasyonu gizleyen her ekran
  gorunur bir cikis borclu.
- **Alt navigasyonun derinlik mantigi.** `showsRootTabBar`, `NavigationPath.
  isEmpty` uzerinden calisiyordu; ancak uygulamadaki her push view tabanli
  `NavigationLink { ... }` ve bu, bagli `NavigationPath`i doldurmaz. Bar bu
  yuzden her detay ekraninda kaliyordu. Cozum bir bayrak degil, **yerlestirme**:
  bar artik her sekmenin `NavigationStack` *icindeki* kok icerigine
  `rootTabBarInset()` ile bagli, push edilen ekran onu dogal olarak almiyor.
- **Yerli sekme cubugu.** `.toolbar(.hidden, for: .tabBar)` TabView'in kendisine
  uygulanmisti; o yerlesim kapsayan bir TabView'i hedefler. Modifier her
  cocuga tasindi ve `.tabItem` etiketleri geri kondu: gizleme tutmazsa etiketli
  bir cubuk kalir, bes bos oge degil.
- **Oturum secimi rastgele degil, hep en yeni N karti veriyordu.** Havuz
  `createdAt` azalan sirada geldigi icin `prefix` her "Hizli 10"da ayni on
  karti sectiriyordu; karistirma yalniz *sirayi* rastgeleliyordu. Artik
  `ExerciseSelection.pick` sirali olmayan modlarda once orneklem aliyor;
  yalniz Zayif Noktalar prefix kullaniyor, cunku onun sirasi anlamli.
- **Zayif nokta puani sonumlenmiyordu.** Yanlis +3, dogru 0 ve zaman penceresi
  yoktu: bir kez kacirilan kart listeden hic dusemiyordu. Artik `knew` puani
  **eksiltiyor**, her deneme 7 gunde bir yarilaniyor ve 30 gunden eski deneme
  hic sayilmiyor (`ExercisePracticeWeight`). Siralama `WeakPointRanking`e
  tasindi, yani `swift test` kapsaminda.
- **Zayif Noktalar saglam kartlarla dolduruluyordu.** Siralama tek basina
  "zayif mi" sorusunu yanitlayamaz; saglikli bir destenin de bir ilk elemani
  vardir. `WeakPointRanking.weakOnly` yalniz aleyhine kanit olan karti aliyor
  (taze pratik hatasi, FSRS lapse'i ya da dusuk guven). Kanit yoksa dugme
  kapali ve alt yazisi bunu soyluyor.
- **Harita hedefi devam eden oturumu gormezden geliyordu.** Filtre degisiyor,
  kuyruk ayni kaliyordu: cipler "Farmakoloji" derken ekranda Patoloji kartlari.
  Artik soruluyor — yeni secimle bastan basla (kosu duzgun kapanir) ya da bu
  oturuma devam et.
- **Tekrar ekranindaki Egzersiz baglantisi filtreleri siliyordu.**
  `ExerciseTarget` artik `filter: nil` ile "beni sadece Egzersiz'e goturur"
  diyebiliyor; filtreyi yalnizca gercekten daraltma isteyen Bilgi Haritasi
  gonderiyor.
- **"Konusuz" filtresi yeniden aciliste kayboluyordu.** `topicName` hem `.all`
  hem `.none` icin `nil`; kosu bu yuzden her tekrar yuklemede "Tumu"ne
  genisliyordu. `ExerciseRun` artik filtrenin kendisini sakliyor
  (`TopicFilter.storageValue`, `topicFilterRaw`).
- **`run.attempts` sirasizdi.** `uniquingKeysWith: { _, latest in latest }`
  SwiftData iliskisinde "en son" anlamina gelmiyordu; once `answeredAt`
  siralaniyor.

## Siradaki Egzersiz asamalari

### E1 - Oturum yonetimi

- Devam eden oturumu ana ekranda ayri kartla gosterme
- ~~Oturumu bilincli olarak bitir/iptal etme~~ (yukaridaki turda geldi)
- Yanlislar ve kararsizlardan tek dokunusla yeni Egzersiz
- Son kullanilan kurulumun hatirlanmasi

### E2 - Sinav tarzi Egzersiz

- 10/20/50/100 soru
- Toplam sure veya soru basina sure
- Cevaplari oturum sonunda acma
- Soruyu isaretle ve geri don
- Konu bazli sonuc dagilimi

Kok ekran ve navigasyon adi yine Egzersiz olacaktir; "Sinav tarzi" yalnizca
bir oturum turudur.

### E3 - Gelismis secim

- Son yanlislar
- Son 7 gun yanlislari
- Yavas yanitlanan kartlar
- Ayni bilgi biriminden arka arkaya kart gelmesini azaltma
- Kart turu ve dusuk guven filtresi

## Siradaki Bilgi Haritasi asamalari

### H1 - Kavram katmani

- `ConceptNode`: kanonik ad, alternatif adlar, ders, konu, ozet
- `ConceptAssignment`: kavram ile `KnowledgeUnit` baglantisi
- Etiket ve kanonik iddialardan ilk kavramlari cikarma
- Kavram birlestirme, yeniden adlandirma ve arama

`KnowledgeUnit` dogrudan grafik dugumu olmayacaktir. Ayni kavram farkli
kaynak sayfalarindan gelebilecegi icin kalici kavram dugumu ayri tutulur.

### H2 - Iliski katmani

- `ConceptRelation`
- On kosul, neden-sonuc, parcasidir, ayirt edilir, istisnasidir ve birlikte
  gorulur iliskileri
- Her iliskiden kaynak kartlara ve sayfaya geri donus
- Dusuk guvenli otomatik iliskileri ayri gosterme

### H3 - Akilli harita

- Kullanici tarafindan tetiklenen toplu kavram/iliski analizi
- Eksik kapsama ve baglantisiz kavram tespiti
- Karistirilan kavram ciftleri
- Kavram, komsu kavram veya on kosul zincirinden Egzersiz olusturma

## Degismez kabul kosullari

- Egzersiz kaydi FSRS alanlarina ve `ReviewLog`a dokunmaz.
- Aktif oturum uygulama kapanip acilinca ayni kart sirasi ve konumla devam eder.
- Haritada bilinmeyen serbest metin ders/konular yeni kanonik dugum uretmez.
- Her ders ve konu haritadan tek dokunusla Egzersiz'e aktarilabilir.
- Derin ekranlarda ve aktif oturumda ozel alt navigasyon icerigin ustune binmez.
- Dynamic Type, VoiceOver, koyu mod ve Reduce Motion desteklenir.
