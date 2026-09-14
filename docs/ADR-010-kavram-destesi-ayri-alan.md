# ADR-010 — Kavram destesi: ayrı model değil, koleksiyon ayracı

**Tarih:** 2026-09-09 · **Durum:** ⛔️ **KALDIRILDI (2026-09-14) — kod ve veri
silindi.** Yalnız karar arkeolojisi için okuyun; bu belge artık davranışı
tarif etmiyor.

> **Kaldırma notu (2026-09-14).** Sahibi kavram destesini denedi ve istemedi:
> "deneme amaçlıydı, sevmedim; yalnız Çekimlerim kalacak, kavramlara dair
> hiçbir şey bırakma". Silinenler: `CardScope`, `CardScopePicker`,
> `ConceptPackImporter` + `ConceptPackImportView`, `ConceptRelease` +
> `ConceptQueueSection`, `CardCollection`, **`Card.collectionRaw` sütunu**,
> **`CardStatus.queued`**, deste başına günlük sicil, `CardScopeTests`,
> `ConceptPackImporterTests`, `ConceptReleaseTests` ve
> `evals/tests/test_card_scope_sites.py`. Yedek biçimi v8'e çıktı (alan yok).
>
> Cihazdaki veri `ConceptDeckRemovalMigration` ile silinir — kartlar,
> unit'ler, `ReviewLog`'lar ve (düz `cardId` taşıdıkları için cascade'in
> ulaşmadığı) Egzersiz koşuları/denemeleri. Tanıma bu belgenin "Sonuçlar"
> bölümündeki etiketle yapılır, çünkü aynı açılışta sütun şemadan düşer:
> **kaldırmadan sağ çıkan tek iz `ConceptDeckLegacy.tag`'dir** ve eski v7
> yedeklerindeki kavram kayıtlarını atlamak için de o kullanılır.
>
> Aşağıdaki "iki katmanlı kilit" gerekçesi kaldırmayla birlikte konusuz kaldı:
> tek deste varken filtrelenecek bir şey yok. Geri dönüş = kaldırma commit'inin
> revert'i (`git log`'da "Kavram destesini tamamen kaldır").

## Bağlam

Uygulamanın bugüne kadarki tek kart kaynağı Yakala akışıydı: fotoğraf → model →
kart. Dışarıda hazırlanmış bir **kavram paketi** (831 kavram / 3.017 kart,
Farmakoloji) bu akışın hiçbir adımından geçmiyor — sayfası yok, model çağrısı
yok, `TextRegion`'ı yok.

Bu kartlar çekim destesine karışsaydı iki şey birden bozulurdu. Nicelik: 996
kartlık bir destenin üstüne 3.017 kart, yani Tekrar ve Egzersiz artık ağırlıklı
olarak *bir başkasının* ürettiği içeriği sorar. Nitelik: "Kaynağı göster" boş
kalır ve Bilgi Haritası'nın Farmakoloji kapsaması bir anda dolar — "bu konuda
kaç kartım var" sorusu, karışık bir destede "ben mi çalıştım paket mi getirdi"
ayrımını kaybeder.

## Karar

**Ayrı bir SwiftData modeli değil.** `Card` üzerinde tek bir koleksiyon ayracı
(`CardCollection`: `capture` | `concept`) ve arayüzde ortak bir kapsam anahtarı.

### Neden ayrı model değil

Ayrı bir `ConceptCard` FSRS'i, tekrar oturumunu, Egzersiz seçimini, FES'i,
yedeklemeyi, arama ve filtreleri **ikinci kez yazmak** demekti — yaklaşık iki bin
satır kopya ve sonsuza kadar senkron tutulacak iki zamanlayıcı. Bu projenin
anti-drift disiplini (CLAUDE.md) tam olarak bunun maliyetini anlatıyor: "aynı
davranış iki yerde" her çıktığında ısırdı.

Ayracın tek gerçek riski şu: **bir filtre yerini unutmak.** O yüzey sayılabilir
— `Card` sorgusu yapan altı ekran — ve testle kilitlenebilir. Kopya bir
zamanlayıcının riski sayılabilir değil.

### Neden altıncı sekme değil

`CizgiRootTabBar` beş öğe ve **ortası yükseltilmiş** bir tasarım; çift sayıda
öğede "orta" yoktur. Kapsam anahtarı üç kart ekranının (Tekrar / Egzersiz /
Bilgilerim) tepesinde duruyor ve `LibraryView`'ın zaten kullandığı
Kartlar/Bilgi Haritası deseninin aynısı — yani kod tabanına yeni bir fikir
değil, yeni bir eksen.

### Sessiz başarısızlık ve iki katmanlı kilit

Filtre unutulursa **hiçbir şey patlamaz**: kartlar geçerli, aktif ve vadesinde;
ekran sağlıklı görünürken yanlış desteyi anlatır. Aynı sınıf, `OPENAI_MODEL`'i
fiyatlarıyla birlikte değiştirmeme hatasıyla aynı: kaçırılması en kolay olanı,
çünkü hiçbir şey çökmez. İki kilit:

1. `CizgiCoreTests/CardScopeTests` — **bileşimin** doğruluğu: kapsamlanmış deste
   `ReviewSessionPlanner`, `ExerciseFilter`, `LibraryCardFilter`, `CardSearch` ve
   `KnowledgeMapBuilder`'a verildiğinde kapsamlar kesişmiyor.
2. `evals/tests/test_card_scope_sites.py` — **çağrının varlığı**: altı ekranın
   her biri gerçekten `CardScope`'u çağırıyor mu, ve yeni bir `[Card]` sorgusu
   listeye katılmış mı. SwiftUI görünümlerini bir Swift testi göremez;
   `test_swiftdata_migration_safety.py`'nin gerekçesinin aynısı.

`CardScope` bu yüzden var: kısaltmak için değil, **aranabilir tek bir ad** olsun
diye.

## Sonuçlar

- **Şema:** `Card.collectionRaw`, declaration-time default'lu. Mevcut her kart
  `.capture` olarak göç eder — hepsi hakkındaki doğru cevap bu, çünkü bugüne
  kadar kart üreten tek şey Yakala akışıydı.
- **Yedek biçimi v7:** opsiyonel `collection` alanı (`decodeIfPresent`, v2'den
  beri süregelen desen). Bu alan olmasaydı bir geri yükleme 3.017 kavram kartını
  çekim destesine kurardı ve **bunu hiçbir şey bildirmezdi** — her kart tek tek
  geçerli. Kavram paketi JSON'dan yeniden üretilebilir ama bir kartın FSRS
  geçmişi üretilemez; dosyada başka hiçbir yerde bulunmayan tek şey o.
- **Ayarlar bilerek kapsamsız:** yedek ve geri yükleme cihaz geneli işlemlerdir.
  Kapsamlı bir `existingIds` kümesi, zaten burada olan kartları
  `@Attribute(.unique)` altında yeniden eklemeye kalkardı.
- **Bilgi Haritası kapsamlı:** çekim destesinde bakıldığında Farmakoloji boş
  görünür, kavram destesinde dolu. İstenen davranış bu — iki deste ayrı
  çalışma evrenleri.
- **`DuplicateSuspendMigration` yalnız `.capture`:** 2026-08-18 denetimi o
  desteyi okudu; kavram paketinde aynı ilacı iki kavram altında sormak kasıtlı.
- **Kapsam değişince açık oturum kapanır.** Egzersiz'de `finishEarly()` ile,
  `session = nil` ile değil: `finishedAt`'i boş bir `ExerciseRun`, bir sonraki
  açılışta `restoreActiveRunIfNeeded` tarafından geri açılır ve eski destenin
  koşusu yeni kapsamın içine sürüklenirdi.

## Paketin kendi düzensizliği (ölçülerek bulundu)

`kitapSayfa` bir **sayfa referansı**, sayı değil — ve paket ikisini de yazıyor:
831 kavramın 741'i tırnaklı ("242-243", "243"), 90'ı çıplak sayı (448). `String`
olarak çözmek 559. kavramda `typeMismatch` veriyor ve `JSONDecoder` ilk
uyuşmazlıkta **bütün dosyayı** bıraktığı için import'un tamamı düşüyordu —
diğer 830 kavram da dahil. `LooseString` ikisini de kabul ediyor.

Bu, planın spesifikasyonunu okuyarak bulunamazdı; import gerçek dosyaya karşı
koşturulduğunda çıktı. Kayıt için: paketi kod okuyarak değil **çalıştırarak**
doğrulamak, bu işte tek gerçek hatayı yakalayan adım oldu.

## Kapsam dışı (bilinçli)

- **`CardType`'a `sirali_coklu` eklemek.** Enum backend şemasına kilitli
  (`test_swift_contract_sync.py`); paketin 466 böyle kartı `direct_recall`'a
  düşüyor ve orijinal adı paketin kendi `originalType` alanında duruyor.
- **Kavramın kendi ekranı.** Kavram bugün yalnız kartlarının altındaki bir grup;
  "kavramı oku, sonra kartlarını çöz" akışı ayrı bir iş.
- **Performans.** Filtreleme bellekte, `@Query` predicate'inde değil: ekranlar
  zaten bellekte filtreliyor (`LibraryView` sebebini yazıyor — SQLite Türkçe
  büyük/küçük harf katlamıyor) ve bir `@Query` predicate'i `@AppStorage`
  değerini okuyamaz. Ölçüm sonucu gerekirse çözüm **bu** filtreyi sorguya
  taşımak; çağrı yerleri aynı kalır.
