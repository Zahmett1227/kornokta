# Egzersiz ve Bilgi Haritası geliştirme planı

Tarih: 2026-08-08
Dal: `codex/egzersiz-bilgi-haritasi-ui`

## Ürün kararları

- Kök özelliğin adı her yerde **Egzersiz** kalır.
- Egzersiz, alt navigasyonun ortasında ve görsel olarak en güçlü hedeftir.
- Uygulama ve genel ana sayfa eylemi Egzersiz'e açılır.
- Egzersiz sonuçları kendi geçmişini oluşturur; `Card` zamanlama alanları,
  `ReviewLog`, FSRS ve günlük yeni kart kotası değişmez.
- Kişisel bilgi grafiğinin kullanıcıya görünen adı **Bilgi Haritası**dır.
- Bilgi Haritası, `Bilgilerim` içindeki `Kartlar | Bilgi Haritası` görünümüdür.

## Uygulanan ilk dilim

- [x] Beş kök hedefli özel alt navigasyon
- [x] Ortada yükseltilmiş Egzersiz eylemi
- [x] Egzersiz için bağımsız `NavigationStack`
- [x] Aktif oturumda alt navigasyonun gizlenmesi
- [x] Hızlı 10 ve Zayıf Noktalar başlangıçları
- [x] Ders/konu ve 10/20/tümü oturum kurulumu
- [x] Açık uçlu kartlarda Biliyordum/Kararsızdım/Bilemedim sonucu
- [x] Çoktan seçmeli kartlarda otomatik doğru/yanlış sonucu
- [x] `ExerciseRun` ve `ExerciseAttempt` ile ayrı kalıcı geçmiş
- [x] Uygulama yeniden açıldığında yarım kalan oturumu kurma
- [x] Egzersiz yanlışlarını Zayıf Noktalar seçiminde kullanma
- [x] Mevcut ders/konu şemasından ilk Bilgi Haritası
- [x] Haritadan ders veya konu filtreli Egzersiz'e geçiş
- [x] Ortak hero, bölüm başlığı ve hızlı eylem kartları
- [x] Ayarlarda günlük öğrenme kontrollerini teknik kurulumun önüne alma

## İnceleme turunda kapatılanlar (2026-08-08)

İlk dilim gözden geçirildi; aşağıdakiler aynı dalda düzeltildi.

### Bloklayıcılar

- **Aktif oturumdan çıkış yoktu.** Oturum alt navigasyonu gizliyordu ama
  Egzersiz bir sekme kökü olduğu için geri butonu da yok: kullanıcı kuyruğun
  son kartına kadar ekranda kilitli kalıyordu. Yarım kalan koşu her açılışta
  geri yüklendiği ve varsayılan sekme Egzersiz olduğu için uygulamayı öldürmek
  de çıkış değildi. Artık sol üstte onay soran bir **Bitir** var
  (`ExerciseSession.finishEarly()`); yanıtlananların özeti korunuyor ve koşu
  `finishedAt` ile kapanıyor. **Kural: alt navigasyonu gizleyen her ekran
  görünür bir çıkış borçludur** (`AppNavigator.isTabBarHidden`).
- **Alt navigasyonun derinlik mantığı yanlıştı.** `showsRootTabBar`,
  `NavigationPath.isEmpty` üzerinden çalışıyordu; ancak projedeki her push
  view tabanlı `NavigationLink { ... }` ve o, bağlı `NavigationPath`i
  **doldurmaz**. Bar bu yüzden her detay ekranında kalıyordu. Çözüm bir bayrak
  değil, **yerleştirme**: bar artık her sekmenin `NavigationStack`'i
  *içindeki* kök içeriğe `rootTabBarInset()` ile bağlı, push edilen ekran onu
  doğal olarak almıyor.
- **Yerli sekme çubuğu gizlenmemiş olabilirdi.**
  `.toolbar(.hidden, for: .tabBar)` TabView'ın kendisine uygulanmıştı; o
  yerleşim kapsayan bir TabView'ı hedefler. Modifier her çocuğa taşındı ve
  `.tabItem` etiketleri geri kondu: gizleme yine de tutmazsa etiketli bir
  çubuk kalır, beş boş öğe değil.

### Mantık

- **Oturum seçimi hep en yeni N kartı veriyordu.** Havuz `createdAt` azalan
  sırada geldiği için `prefix` her "Hızlı 10"da aynı on kartı seçtiriyordu;
  karıştırma yalnız *sırayı* rastgeleliyordu. `ExerciseSelection.pick` sıralı
  olmayan modlarda önce örneklem alıyor; yalnız Zayıf Noktalar prefix
  kullanıyor, çünkü onun sırası anlamlı.
- **Zayıf nokta puanı sönümlenmiyordu.** Yanlış +3, doğru 0, zaman penceresi
  yok: bir kez kaçırılan kart listeden hiç düşemiyordu. Artık doğru yanıt
  puanı **eksiltiyor**, her deneme 7 günde bir yarılanıyor, 30 günden eskisi
  sayılmıyor (`ExercisePracticeWeight`).
- **Zayıf Noktalar sağlam kartlarla dolduruluyordu.** Sıralama tek başına
  "zayıf mı" sorusunu yanıtlayamaz; sağlıklı bir destenin de bir ilk elemanı
  vardır. `WeakPointRanking.weakOnly` yalnız aleyhine kanıt olan kartı alıyor
  (taze pratik hatası, FSRS lapse'i ya da düşük güven). Kanıt yoksa düğme
  kapalı ve alt yazısı bunu söylüyor.
- **Harita hedefi devam eden oturumu görmezden geliyordu.** Filtre değişiyor,
  kuyruk aynı kalıyordu. Artık soruluyor — yeni seçimle baştan başla (koşu
  düzgün kapanır) ya da bu oturuma devam et.
- **Tekrar ekranındaki bağlantı filtreleri siliyordu.** `ExerciseTarget` artık
  `filter: nil` ile "beni sadece Egzersiz'e götür" diyebiliyor; filtreyi
  yalnızca gerçekten daraltma isteyen Bilgi Haritası gönderiyor.
- **"Konusuz" filtresi yeniden açılışta kayboluyordu.** `topicName` hem `.all`
  hem `.none` için `nil` döndüğü için koşu her yüklemede "Tümü"ne
  genişliyordu — farklı bir kart kümesi. `ExerciseRun` artık filtrenin
  kendisini saklıyor (`TopicFilter.storageValue`, `topicFilterRaw`).
- **`run.attempts` sırasızdı.** `uniquingKeysWith` içindeki "latest" SwiftData
  ilişkisinde en son anlamına gelmiyordu; önce `answeredAt` sıralanıyor.

### Tasarım, veri ve tutarlılık

- **Yükseltilmiş Egzersiz düğmesinin üstü tıklanamıyordu.** `.offset` pikseli
  taşır, düzeni taşımaz: taşan kısım `contentShape`'in dışında kalıyor ve
  `safeAreaInset`'in ayırdığı alanı aşıp üstteki içeriğin üzerine biniyordu.
  Yükselme artık gerçek düzen (daha büyük ikon kuyusu + `alignment: .bottom`),
  dokunma alanı görünenle birebir.
- **Egzersiz sekmesi hep seçili görünüyordu.** Seçiliyken dolu amber disk,
  değilken çerçeveli disk. Hâlâ birincil hedef, ama artık "burada değilsin"
  diyebiliyor.
- **Dynamic Type.** Kuyular `@ScaledMetric` ile büyüyor, etiketler kırpılmadan
  küçülüyor, erişilebilirlik boyutlarında etiketler tamamen kalkıyor (ikon +
  VoiceOver etiketi taşıyor). Dokunma hedefi en az 44 pt.
- **Bilgi Haritası bugünkü destede boş görünüyordu.** Backfill tüm kartlara
  ders verip konuları nil bıraktığı için kanonik-düğüm-only bir harita
  yüzlerce kartı olan kullanıcıya boş ekran gösteriyordu. Artık **Konusuz**
  kovası var (haritadan tek dokunuşla Egzersiz'e giden), ayrıca "tanınmayan
  konu" ve "sınıflandırılmamış ders" sayıları. Tanınmayan ad hâlâ **kanonik
  düğüm üretmiyor** — yalnızca sayılıyor.
- **Harita sayıları birbirini tutmuyordu.** Tüm toplamlar tek bir
  `KnowledgeMapSummary`den geliyor ve bir test her kartın tam olarak bir yerde
  sayıldığını doğruluyor.
- **`summaries` her render'da 3–4 kez hesaplanıyordu**, üstelik iç içe
  `filter` ile. Tek geçişte sözlükle gruplama, render başına bir çağrı.
- **Harita modunda arama kutusu hiçbir şey yapmıyordu.** `.searchable` artık
  yalnız Kartlar görünümünde.
- **Egzersiz geçmişi sınırsız büyüyordu**, üstelik açılış sekmesinde
  okunuyordu. Biten koşular 90 gün sonra siliniyor (`ExerciseHistory`) —
  puanlamanın onurlandırdığı 30 günlük pencerenin rahatça ötesinde, yani
  temizlik hiçbir sıralamayı değiştiremez.
- **Katman ihlali.** Bilgilerim, Yakala sekmesinin `SubjectPickerBar.schema`
  statiğini okuyordu. Şema artık `SubjectTopicSchema.shared`.
- **Ana sayfa düğmesinin sözleşmesi bayattı** ("back to Capture" diyordu,
  `goHome()` Egzersiz'e gidiyor). Belge düzeltildi; düğme sekme köklerinde
  değil yalnız push edilen ekranlarda (eksik olan `KnowledgeSubjectView`'a da
  eklendi). `ConfirmationView`'daki artık işlevsiz
  `.toolbar(.hidden, for: .tabBar)` silindi.
- **Metinler doğruyu söylüyor.** "Puanlama yok" ve "yalnız bu oturumun özeti"
  ifadeleri, puanlar kalıcılaşıp Zayıf Noktalar'ı beslemeye başladığında
  doğruluğunu yitirmişti.

### Bilinçli olarak yapılmayanlar

- **Egzersiz geçmişi yedeğe girmiyor.** Pratik geçmişi zaten 90 gün sonra
  siliniyor ve kaybı yalnız bir sezgiselin sıfırlanması demek — FSRS lapse'i
  ve `lowConfidence` çalışmaya devam eder. Yedek biçimini v5'e çıkarmak bu
  kazanç için makul değil. Karar değişirse `BackupExporter`'a iki dizi eklemek
  yeterli.
- **`goHome()` push edilen ekranı pop etmiyor.** Kökü, tüm push'ların view
  tabanlı olması (yukarıya bak) ve düzeltmesi değer tabanlı navigasyona geçmek.
  Bu turda kapsam dışı; alt navigasyonun doğruluğu artık buna bağlı değil.

## Sıradaki Egzersiz aşamaları

### E1 — Oturum yönetimi

- Devam eden oturumu ana ekranda ayrı kartla gösterme
- ~~Oturumu bilinçli olarak bitir/iptal etme~~ (yukarıdaki turda geldi)
- Yanlışlar ve kararsızlardan tek dokunuşla yeni Egzersiz
- Son kullanılan kurulumun hatırlanması

### E2 — Sınav tarzı Egzersiz

- 10/20/50/100 soru
- Toplam süre veya soru başına süre
- Cevapları oturum sonunda açma
- Soruyu işaretle ve geri dön
- Konu bazlı sonuç dağılımı

Kök ekran ve navigasyon adı yine Egzersiz olacaktır; "Sınav tarzı" yalnızca
bir oturum türüdür.

### E3 — Gelişmiş seçim

- Son yanlışlar
- Son 7 gün yanlışları
- Yavaş yanıtlanan kartlar
- Aynı bilgi biriminden arka arkaya kart gelmesini azaltma
- Kart türü ve düşük güven filtresi

## Sıradaki Bilgi Haritası aşamaları

### H1 — Kavram katmanı

- `ConceptNode`: kanonik ad, alternatif adlar, ders, konu, özet
- `ConceptAssignment`: kavram ile `KnowledgeUnit` bağlantısı
- Etiket ve kanonik iddialardan ilk kavramları çıkarma
- Kavram birleştirme, yeniden adlandırma ve arama

`KnowledgeUnit` doğrudan grafik düğümü olmayacaktır. Aynı kavram farklı kaynak
sayfalarından gelebileceği için kalıcı kavram düğümü ayrı tutulur.

### H2 — İlişki katmanı

- `ConceptRelation`
- Ön koşul, neden-sonuç, parçasıdır, ayırt edilir, istisnasıdır ve birlikte
  görülür ilişkileri
- Her ilişkiden kaynak kartlara ve sayfaya geri dönüş
- Düşük güvenli otomatik ilişkileri ayrı gösterme

### H3 — Akıllı harita

- Kullanıcı tarafından tetiklenen toplu kavram/ilişki analizi
- Eksik kapsama ve bağlantısız kavram tespiti
- Karıştırılan kavram çiftleri
- Kavram, komşu kavram veya ön koşul zincirinden Egzersiz oluşturma

## Değişmez kabul koşulları

- Egzersiz kaydı FSRS alanlarına **yalnız `EarlyPractice` köprüsü üzerinden**
  dokunur (erken kısmi kredi / soft lapse / vadeye yakın gerçek lapse —
  docs/ADR-007, 2026-08-09'da bilinçli değişiklik); `ReviewLog`a asla yazmaz
  ve vadesi gelmiş kartı asla notlamaz.
- Aktif oturum uygulama kapanıp açılınca aynı kart sırası, konumu **ve
  filtresiyle** devam eder.
- Aktif oturumdan her zaman görünür bir çıkış vardır.
- Haritada bilinmeyen serbest metin ders/konular yeni kanonik düğüm üretmez —
  ama sayılırlar; ekrandaki satırların toplamı desteye eşittir.
- Her ders ve konu haritadan tek dokunuşla Egzersiz'e aktarılabilir.
- Derin ekranlarda ve aktif oturumda özel alt navigasyon içeriğin üstüne
  binmez.
- Dynamic Type, VoiceOver, koyu mod ve Reduce Motion desteklenir.
