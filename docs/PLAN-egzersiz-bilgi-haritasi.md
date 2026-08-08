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

## Siradaki Egzersiz asamalari

### E1 - Oturum yonetimi

- Devam eden oturumu ana ekranda ayri kartla gosterme
- Oturumu bilincli olarak bitir/iptal etme
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
