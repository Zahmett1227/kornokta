# ADR-012 — Çıkmış soru bankası: soru kart değildir

**Tarih:** 2026-09-25 · **Durum:** ✅ Kabul edildi (plan onayı) · Faz 0 ve Faz A1
`cikmis-soru-bankasi` dalında · **Plan:** [`PLAN-cikmis-soru-bankasi.md`](PLAN-cikmis-soru-bankasi.md)

## Bağlam

Sahibinin hedefi: "kitap yanımda olmadığı zaman bile TUS çalışmamı
yapabilmeliyim". Uygulama bugün yalnız işaretli kitap sayfasından kart üretiyor;
kitap kapalıyken yapılabilen tek şey mevcut kartları tekrar etmek.

2026-09-25 vizyon panelinde (sekiz bağımsız bakış açısı, on altı öneri, üç
yargıç) beş lens birbirinden habersiz aynı yere çıktı: **çıkmış sorular ikinci
girdi akışı olmalı.** Bir TUS adayının kitapsız çalışmasının gerçek adı çıkmış
soru çözmektir, ve çözülemeyen gerçek bir soru, kartsız kalmış bilginin
zeminli tek kanıtıdır. (Kapsama sözleşmesi yalnız *çekilmiş* sayfadaki kartsız
işareti görür; Karanlık Harita bu boşluğu modelin kanaatiyle doldurmaya çalıştı
ve silindi.)

Sahibinin elinde 86 PDF var. 2026-09-25'te tek tek ölçüldü: ≈ 8.430 soru
metni, ≈ 7.010'u anahtarlı; üçüncü taraf anahtarlar ÖSYM'nin kendi görünür
"DOĞRU CEVAP" işaretleriyle 77/77 uyuşuyor; hiçbir dosyada açıklama yok
(ayrıntı: planın §2'si ve Ek A).

## Karar

1. **Soru kart değildir.** Çıkmış soru ayrı bir türdür: `Card` olmaz, Tekrar'a
   girmez, FSRS'i görmez, Bilgilerim'in sayılarına karışmaz. Yalnız Egzersiz
   yüzeyinde ve yalnız ölçü olarak yaşar. Gerekçe ADR-010: başkasının içeriği
   Tekrar'a girince deste "bir başkasının içeriğiyle doldu" hissi verdi ve
   kaldırıldı. Soru sahibinin *kendi* kitabından ve provenanslı olsa da (ADR-011'in
   gri bölgesi) içeriği ÖSYM'nindir.
2. **Banka değişmez bir dosya, kullanıcı durumu SwiftData'da.** `bank.json` +
   PDF'ler telefona bir kez içe aktarılır; çözüm geçmişi, köprü bağları ve açık
   defteri **kararlı soru kimliğiyle** (`TUS-2019-1-T-045`) ayrı tutulur. Banka
   yeniden üretilince (çıkarım düzeltmesi) göç gerekmez; kimlik bir kez verildikten
   sonra asla başka soruya verilmez.
3. **Çıkarım Mac'te, tek seferlik, deterministik öncelikli** (`tools/exam_bank/`).
   Model yalnız dört yerde: bozuk çıkan soruların onarımı, 2011 İlkbahar'ın
   görüntüden okunması, ders/konu etiketi ve kitapçık sağlaması. Tek seferlik
   ≈ $3–5; uygulamada kullanım $0. Sunucuya Faz A'da dokunulmaz.
4. **Provenans PDF sayfasının kendisi.** "Kaynağı göster" ÖSYM kitapçığını açar,
   sorunun bölgesi vurgulanır; görselli sorular (EKG, radyografi) PDF'ten
   kırpılarak gösterilir.
5. **FES yalnız sahibinin köprüde seçtiği karta** `.wrong` yazılır, oturum
   başına bir kez; doğru cevap hiçbir karta yazmaz ("vinyet doğru ≠ kart doğru").
   FES'in canlı yazımı tek fonksiyonda: `FesScore.record(_:on:at:)`.
6. **`EarlyPractice` ve `ReviewLog` asla.** ADR-007'nin köprüsü tek karta bakar;
   bir sorunun yanlışını birden çok kartın vadesine dağıtmanın doğru yolu yok.
7. **Açıklama Faz A'da yok.** Kaynakta açıklama yok; yanlışta köprü kartlara
   götürür. Model açıklaması ancak kanıt turundan sonra, "Modelin açıklaması —
   kaynak değil" etiketiyle ayrı bir kararla açılır.
8. **Anahtarsız 1.380 soru** (2006–2008 ve 2024/1'in 180'i) bankada durur ama
   varsayılan filtrelerde yoktur; "yalnız oku" filtresiyle görülür.
9. **Eski sorular** (≤ 2012) açıktır ve "eski" rozeti taşır; kılavuz değişmiş
   olabilir.

## Telif ve kişisel kullanım

ÖSYM kitapçıkları resmîdir; Tusdata derlemesi ticarîdir; 2026/2 yeniden
diziminin kaynağı belirsizdir. ANA-PLAN §4.2 "tam kitap tarama/kitap korsanlığı
akışı"nı dışlar — o yasak **dağıtım** içindir. Bu banka:

- repo'ya girmez (PDF'ler `EXAM_SOURCE_DIR`'de, çıktı `tools/exam_bank/out/`
  gitignore'lu),
- telefonda iCloud yedeğinden hariçtir (`isExcludedFromBackup`),
- uygulamanın yedeğine içerik olarak girmez (yedek v10 yalnız kimlik ve sonuç
  taşır),
- tek kullanıcılı, tek cihazlı ve yayınlanmayan bir uygulamanın parçasıdır.

## Reddedilen seçenekler

- **Soruyu beş şıklı `Card` yapmak** (mevcut kart hattı, en ucuz yol).
  2.000+ gerçek soru Tekrar'a girer ve ADR-010'un kaldırılma sebebi aynen döner.
- **Soru sayfasını fotoğrafla çekme akışı.** PDF'lerin metin katmanı var;
  fotoğrafı modele okutmak hem pahalı (≈ $0,005–0,02/sayfa × binlerce) hem hatalı.
- **Sunucuda soru bankası.** Telefon dışında bir kopya, gizlilik ve telif
  yüzeyini büyütür; hiçbir özellik onu gerektirmiyor.
- **Sentetik vinyet (Sentez Egzersizi).** Gerçek soru varken uydurma riski en
  yüksek yol; aday olarak kalır, sırası gerçek sorunun arkasında.

## Faz 0'da yapılanlar

- `ReviewCardFace` bir `Card` değil `StudyFaceContent` değeri çizer; Tekrar ve
  Egzersiz'in çağrıları değişmedi (`init(card:...)` korunuyor). Simülatörde
  önce/sonra karşılaştırması: Tekrar piksel piksel aynı; Egzersiz'de tip
  işaretinin kenar yumuşatmasında en fazla 7/255 tonluk, 0,002 piksellik bir
  yatay kayma (toplam mürekkep birebir aynı).
- `FesScore.record(_:on:at:)` — Tekrar ve Egzersiz'in iki ayrı kopyası tek
  fonksiyona indi; üçüncü yazar (köprü) oraya bağlanacak. Foundation-only
  `FesScore.swift`'ten ayrı dosyada, Linux dilim paketi bozulmasın diye.
- `tools/exam_bank/`: kaynak kaydı (`sources.json`: 82 dosya, 85 kağıt, sha256
  sabitli) + doğrulayıcı + `build --dry-run`. İlk koşu iki gerçek hata yakaladı:
  2009–2011'de Temel ve Klinik aynı dosyada ikisi de 1'den numaralanıyor
  (kural düzeltildi) ve macOS dosya adlarını NFD döndürdüğü için `yenikeşif/`
  dışlaması eşleşmiyordu (ADR-001 sınıfı; yollar NFC'ye çevriliyor).

## Faz A1'de yapılanlar (2026-09-25)

Hat (`tools/exam_bank/` + `backend/scripts/examBank.ts`) gerçek klasörde koştu:
8.410 soru, V1–V8 ve V10 geçiyor, **V9 sahibinin onayını bekliyor** (paket onaydan
sonra yazılır). Model maliyeti $0,64 (Luna @low, 406 çağrı; plan $3–5). Karar 3'ün
"model yalnız dört yerde" sınırı tuttu: A5 onarım (15 soru), A6 2011/1 (31 sayfa),
A7 etiket (351 küme), V6 sağlama (61 kağıt).

Bu karar belgesini etkileyen iki ölçüm:

- **Kimlik kuralı ilk kez sınandı.** Tusdata derlemesinin 2024/1 Klinik
  numaraları ÖSYM'nin görünür sorularından kayıyor. Karar 2 ("kimlik bir kez
  verildikten sonra asla başka soruya verilmez") gereği çapaların iki yanı
  tutarsız 22 soru kimlik almadı ve bankaya girmedi; tahmini bir kimlik, ileride
  ÖSYM'nin tam kitapçığı gelince başka bir soruya ait çıkabilirdi.
- **2011 İlkbahar Temel-1 + Temel-2**, Klinik değil: kayıtta `TUS-2011-1-T2`; o
  sınavın Klinik testi eksik kaynaklar listesinde.

## Geri dönüş

Faz A'dan itibaren kaldırma tek revert + tek göç olacak şekilde tasarlanır:
üç yeni SwiftData modeli (`ExamRun`, `ExamAttempt`, `ExamQuestionState`)
`Card`'a ilişki kurmaz (kart kimliği düz dize); banka klasörü
`Application Support/Cizgi/ExamBank/` silinir; yedek v10'un iki dizisi
`decodeIfPresent` ile okunur. Faz 0'ın iki kod değişikliği (kart yüzü değeri,
`FesScore.record`) özellikten bağımsız iyileştirmelerdir ve kalabilir.
