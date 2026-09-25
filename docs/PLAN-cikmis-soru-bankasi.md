# PLAN — Çıkmış Soru Bankası ("Çıkmış")

*Sahibi tarafından onaylandı: 2026-09-25. §13'teki yedi karar önerilen
öntanımlılarla kabul edildi; sahibi herhangi birini değiştirebilir.*
*Kaynak: sahibinin yerel çıkmış soru klasöründeki 86 PDF (repo dışında; betik yolu
`EXAM_SOURCE_DIR`'den okur), 2026-09-25'te tek tek ölçüldü (bkz. §2 ve Ek A).
2026-09-25 vizyon panelinin ("kitap yanımda olmadan çalışma") çekirdek önerisinin
PDF'lere göre yeniden yazılmış, uygulanabilir hâlidir.*

## Durum

| Faz | Durum |
|---|---|
| Faz 0 — hazırlık | ✅ `cikmis-soru-bankasi` dalında (2026-09-25): plan + [ADR-012](ADR-012-cikmis-soru-bankasi.md); `FesScore.record` (tek canlı FES yazarı, 8 test); kart yüzü `StudyFaceContent` refaktörü (Tekrar simülatörde piksel piksel aynı, Egzersiz'de 0,002 piksellik gözle görülmez kayma); `tools/exam_bank/` kaynak kaydı (82 dosya, 85 kağıt, sha256) + `--dry-run` + 33 test. Sahibin işi olan kaynak klasör düzeni isteğe bağlı kaldı (§9.1) |
| Faz A1 — banka hattı | ✅ `cikmis-soru-bankasi` dalında (2026-09-25): A1–A9 gerçek klasörde koştu, **V1–V10 geçti** (V9: Tuğba Çağlar, 30 soru). Paket `tools/exam_bank/out/CizgiSoruBankasi/` (gitignore'lu): sürüm **2026-09-25.2**, 8.410 soru, 85 kağıt, 82 PDF, 163 MB. Model $0,65. Ölçümün düzelttikleri: "Faz A1 sonucu" |
| Faz A2 — uygulama çekirdeği | ✅ `cikmis-soru-bankasi` dalında (2026-09-26): CizgiCore çekirdeği + üç SwiftData modeli + içe aktarma + Pratik + köprü + "Kitaba dönünce"; §9.3/6 senaryosu simülatörde uçtan uca gerçek paketle koştu. Ayrıntı: "Faz A2 sonucu" |
| Faz A3 — Deneme | 🔲 |
| Kanıt turu | 🔲 |
| Faz B / C | 🔲 |

### Faz A1 sonucu (ölçülen, 2026-09-25)

| | |
|---|---|
| Soru | **8.410**: ok 6.985 · anahtarsız 1.357 · iptal 55 · değiştirilmiş 12 · insan gerekli 1 |
| Görsel | gerekli 163 · atıf 51 |
| Ders/konu | 85 kağıdın hepsi monoton; 932 referans etiketle **%97,9**; konulu soru 7.856 |
| Kapılar | V1 tamam · V2 tamam · V3 tamam · V4 80/80 · V5 100/100 · V6 61/61 (ort. %95) · V7 %97,9 · V8 163 · V9 Tuğba Çağlar, 30 soru · V10 temiz |
| Model | Luna @low, 410 çağrı, **$0,65** (A5 18 · A6 31 · A7 351 · V6 61) |
| Paket | sürüm 2026-09-25.2 · 82 PDF (F4'ler yalnız görünür soru sayfaları) · bank.json 6,7 MB · toplam 163 MB |

Planın varsaydığı, ölçümün düzelttiği:

1. **2011 İlkbahar = Temel Testi-1 + Temel Testi-2**, Temel+Klinik değil (kitapçığın
   açıklama sayfası ve anahtar başlıkları). Kayıtta `TUS-2011-1-K` → `TUS-2011-1-T2`;
   o sınavın Klinik testi klasörde **yok** (§10'a eklenen eksik).
2. **Klinik test 6 blok:** Dahiliye → Küçük Stajlar (dahilî) → Pediatri → Genel
   Cerrahi → Küçük Stajlar (cerrahî) → Kadın-Doğum — 2006'dan 2026'ya her yıl
   (F1'in "İç Hastalıkları, Pediatri, Cerrahi, Kadın-Doğum" başlığına rağmen soruları
   aynı bloklarda). Temel Testi-2'nin sırası yıla göre değişiyor (2012/1 Biyokimya →
   Mikrobiyoloji, 2011/1 tersi); oylardan okunuyor. §5.2 ve §5.10'daki sıra buna göre.
3. **Derlemenin 2024/1 Klinik numarası ÖSYM'den kayıyor** (resmî 64 = derleme 63,
   70 = 69, 89 = 89): ÖSYM'nin görünür soruları çapa; iki yanı tutarsız **22 soru**
   (anahtarsız) bankaya girmiyor — kimlik tahminle verilmez. V5 artık numara eşitliği
   değil metin çapası.
4. **Derleyici değişikliği kendisi yazıyor:** 14 soruda "modifiye/revizyon" notu —
   dış rapora gerek kalmadı; 2'sinin resmî metni var, 12'si `modified`.
5. **İptal iki kaynaktan:** 29'u kitapçık+anahtar, 16'sı yalnız anahtar (2009–2013
   kitapçığı metni korumuş), 10'u yalnız kitapçık (2017 anahtarı eski harfi basıyor).
6. **V4 80/80** (Faz 0'da 77/77): 2024/2, 2025/1, 2025/2, 2026/2'nin 20'şer görünür sorusu.
7. **Yıllar arası neredeyse aynı soru yok** (Jaccard > 0,8): `similarTo` boş.
8. **Model maliyeti planın ~%15'i** ($0,65 / $3–5): Luna @low, kısa çıktılar.
9. **V9 bir hata sınıfı yakaladı:** tablo satırı biçimindeki şıklarda sarılan hücrenin
   kuyruğu komşu hücreye düşüyordu (2010/1 Temel 52). Hücre hücre okuma bütün bankada
   12 sorunun 28 şıkkını düzeltti; aynı incelemede iki satırlık hücrelerin birleşmesi ve
   kesirli şıklar da giderildi. Anahtarsız sorularda "cevap yok" beklenen durum; V9
   sayfası bunu açıkça yazıyor.

### Faz A2 sonucu (2026-09-26)

**Yazılan:** CizgiCore'da `ExamBankDocument` (şemayla `evals/tests/test_exam_bank_contract_sync.py`
kilidi: alanlar, boş olabilirlik, enum değerleri, ÖSYM ders sırası, `schemaVersion`), `ExamBank`,
`ExamQuestionID`, `ExamFilter`, `ExamSelection`, `ExamScoring`, `ExamBridgeRanking`, `ExamGapLedger`,
`ExamPace`/`ExamTimeLimit`, `ExamPageGeometry`, `ExamBankStore` (içe aktarma) ve `ExamRecorder`
(bütün yazımlar tek yerde) + üç SwiftData modeli. Uygulamada Ayarlar → Veri → "Çıkmış soru bankası",
Egzersiz'de dördüncü satır "Çıkmış", `ExamHomeView`, `ExamSetupSheet`, `ExamSessionView` (Pratik),
köprü paneli, görsel kırpıntısı, "Kaynağı göster" (kitapçık sayfası, soru ders renginde vurgulu),
"Soruda hata bildir", "Kitaba dönünce" (Egzersiz + Bilgilerim bölümü) ve soru ayrıntısı.

**Ölçülen / görülen:**

| | |
|---|---|
| Testler | CizgiCore'a 74 yeni test (sentetik banka fikstürü; gerçek paket testi `EXAM_BANK_PACKAGE` ile) · sözleşme kilidi 18 test |
| Gerçek paket (Mac, hata ayıklama derlemesi) | `bank.json` 0,2 sn'de çözülüyor ve doğrulanıyor; 162 MB içe aktarma (her dosyada sha256) 0,5 sn |
| Şema kanıtı | Eski şemalı simülatör deposu (380 kart, 723 log, 7 koşu) üzerine silmeden kuruldu: açıldı, sayılar aynı, üç yeni tablo boş |
| Simülatörde uçtan uca (§9.3/6) | Arayüzden içe aktarma (klasör yedekten hariç, 82 PDF) → Pratik → yanlış + karta bağla (FES 0→2; vade, tekrar sayısı, stabilite, ReviewLog değişmedi) → yanlış + "Kitaba dönünce" → boş + atla → erken bitir → Bilgilerim'de "Kitaba dönünce · 1" → yeni kart → "muhtemelen kapandı" → onay (kapatan kartın FES'i değişmedi) → yeniden açılışta aynı soruda devam → görselli soru kırpıntısı + tam ekran → hata bildirimi |

**Planın varsaydığı, simülatörün düzelttiği:**

1. **Kart puntosu vinyete büyük.** Kart yüzünün 27'lik serif sorusu 80 kelimelik bir vakada beş şıkkı
   ilk ekranın dışına itiyordu; `StudyFaceContent.questionSize` eklendi (kart 27, soru 20 — hâlâ serif).
2. **İlişki üzerinden gözlem gecikiyor.** `attempt.run = run` ile doldurulan `run.attempts` SwiftUI'a
   değiştiğini haber vermedi: cevap kaydedildi, ekran açılmadı. Cevaplar artık soru kimliğiyle
   sorgulanıyor; FES'in "oturum başına bir kez" kontrolü de ilişkiye değil sorguya dayanıyor.
3. **Yarı saydam vurgu `fill`'de siyah kutu oldu** (opak bağlamda `UIRectFill` rengi kopyalıyor); açık
   `.normal` karışım.
4. **Kilitli şık soluklaşmamalı.** `.disabled` doğru şıkkın yeşilini ve yanlışın kırmızısını da
   soldurduğu için dokunma `allowsHitTesting` ile kapatılıyor.

**Bilinçli ayrıntılar:** Pratik'in ders filtresi ÖSYM'nin 12 dersi (Histoloji ayrı); konuları eşlenen
uygulama dersinden (eşleme bankanın kendi verisinden okunuyor, ikinci bir tablo yok). "Boş bırak" da
köprüyü sorar (sahibi için "yapamadığım soru"). Deneme (süreli kağıt) Faz A3'te. Yedek v10 Faz B'de —
o gelene kadar çözüm geçmişi uygulama yedeğine girmez (ADR-012 geri dönüş notu).

---

## 0. Tek paragraf özet

Sahibinin elindeki PDF'lerden **yaklaşık 8.400 gerçek TUS sorusu**, bunların
**yaklaşık 7.000'i cevap anahtarıyla**, tek seferlik bir Mac betiğiyle yapılandırılmış
bir soru bankasına çevrilir ve telefona **dosya olarak** içe aktarılır. Fotoğraf
çekilmez, sunucuya gidilmez. Uygulamada Egzersiz sekmesine bir **"Çıkmış"** girişi
eklenir: kitapsızken gerçek sorular çözülür (Pratik ya da süreli Deneme), yanlış
yapılan her soru için "bu soruyu karşılayan bir kartın var mı?" diye sorulur. Kart
varsa o kartın FES'i işlenir; yoksa soru **"Kitaba dönünce"** listesine düşer:
kitabı açtığında neyi çekeceğini gerçek sınav söyler. Soru asla `Card` olmaz,
Tekrar'a girmez, FSRS'i görmez. Tek seferlik model maliyeti **≈ $3–5**; kullanım
maliyeti **$0**.

---

## 1. Amaç ve başarı ölçütleri

**Amaç.** "Kitap yanımda değilken TUS çalışabileyim" isteğinin en yüksek getirili
biçimi: gerçek çıkmış soruyla sınav pratiği + her yanlışın kendi desteyle
yüzleştirilmesi + desteyle sınav arasındaki açığın kitaba geri dönen bir çekim
listesine çevrilmesi.

**Başarı ölçütleri (kanıt turu, 2 hafta — §9.5):**

| Ölçüt | Hedef | Neden |
|---|---|---|
| Çıkmış oturumu yapılan gün | 14 günün ≥ 8'i | Günlük alışkanlık olmazsa özellik raftadır (kavram destesi dersi) |
| Yanlışlarda köprü sorusuna cevap oranı (kart seçti ya da "Hiçbiri") | ≥ %50 | Köprü özelliği haklı çıkaran parça; atlanıyorsa tasarım yanlış |
| Açılan açıkların çekimle kapanan kısmı | ≥ %20 | Döngünün kitaba gerçekten döndüğünün kanıtı |
| Soru metni/şık/anahtar hatası bildirimi | 200 çözülen soruda ≤ 2 | Bankanın güvenilirliği |

**Başarısızlık tanımı:** 14 günde 4'ten az kullanım günü → Faz B'ye geçilmez,
özellik yerinde kalır ama büyütülmez.

---

## 2. Kaynak envanteri (ölçülmüş)

Tüm sayılar bu oturumda PDF'lerden çıkarıldı (PDFKit metin katmanı, soru/şık
sayımı, cevap anahtarı ayrıştırması). Kitapçık kitapçık tablo: **Ek A**.

### 2.1 Aileler

| Aile | Kapsam | Biçim | Anahtar | Bilinen sorun |
|---|---|---|---|---|
| **F1** | 2006–2008 (6 sınav × Temel 100 + Klinik 100) | Ayrı Temel/Klinik PDF, iki sütun | **Yok** | Klinik testte Küçük Stajlar yok ("İç Hastalıkları, Pediatri, Cerrahi, Kadın-Doğum") |
| **F2** | 2009–2011 (6 sınav, 200 soru tek PDF) | Birleşik kitapçık, iki sütun | Son iki sayfada, "A KİTAPÇIĞI" | **2011 İlkbahar'ın metin katmanı bozuk kodlu** (özel font eşlemesi); anahtar okunuyor. 2011 İlkbahar'ın iki testi Temel-1 + Temel-2 (Faz A1'de ölçüldü) |
| **F3** | 2012–2021 (Temel 120 + Klinik 120) | Ayrı PDF, iki sütun | Son sayfada ızgara | 2013–2017'de 39 "Bu soru iptal edilmiştir"; 2012 İlkbahar'da ek bir **Temel Testi-2** (120 soru) |
| **F4** | 2022–2026 ÖSYM resmî | Kitapçığın ~%10'u görünür, geri kalanı boş yuva | Görünen soruda "DOĞRU CEVAP: X" | Yalnız 212 soru görünür |
| **F5** | Tusdata derlemesi (`TUS_2024-2026_TamSorular_Derleme.pdf`) | 2024/1, 2024/2, 2025/1, 2025/2 — 800 soru; Temel 1–100, Klinik 101–200 | 2024/2, 2025/1, 2025/2 için var; **2024/1 için yok** | Ticarî (Tusdata); önceki analizde 14 "derleyen değiştirmiş" kaydı, 12'si güvenilmez |
| **F6** | `Temel_Bilimler_Sinav_1-100.pdf` + `Klinik_Sinav_1-100 2026.pdf` | **2026/2** tam 100+100, "Soru N" biçimi, ReportLab ile üretilmiş | Tablo hâlinde | Kaynağı belirsiz (yeniden dizim) |

### 2.2 Doğrulama sonuçları (bu oturumda)

- **Üçüncü taraf anahtarlar ÖSYM'nin kendi işaretleriyle 77/77 uyuşuyor:** Tusdata
  2024/2 18/18, 2025/1 20/20, 2025/2 20/20; 2026/2 yeniden dizimi 19/19.
- 2024/1'in 19 resmî görünür sorusu **hiçbir** derleme anahtar bölümüyle uyuşmuyor →
  derlemede 2024/1 anahtarı yok (yalnız ÖSYM'nin gösterdiği 20 sorunun anahtarı var).
- ÖSYM görünür soruları ile F5/F6 **aynı numaralandırmayı** kullanıyor (eşleşen
  sorularda numara birebir aynı; tek istisna önceki çıkarımda Klinik 181'in 81 diye
  okunmasıydı — biçim hatası, veri hatası değil).
- 134 sayfalık `2024-2025-2026 TUS.pdf` (ABBYY taraması) ile F5 derleme **%98 aynı** —
  içe aktarılmaz; `yenikeşif/` klasörü üç dosyanın birebir kopyası (SHA-1 aynı).
- **Açıklama hiçbir dosyada yok** (ÖSYM kitapçıkları yalnız soru+anahtar; Tusdata
  yorumlarını sitesinde tutuyor).
- 2006–2021 metninde **147 görsele/tabloya atıf** (EKG, radyografi, mikrograf, tablo).
- Sınav tarihleri kitapçıkların ilk sayfasında (2010+); süre ve "yanlışların dörtte
  biri düşülür" kuralı yalnız 2009–2015 kitapçıklarında metin olarak var
  (2009–2011: 200 soru/210 dk; 2012–2015: 120 soru/150 dk).

### 2.3 Sayılar

| | Soru metni | Anahtarlı (iptaller hariç) |
|---|---|---|
| 2006–2008 | 1.200 | 0 |
| 2009–2011 | 1.200 (200'ü görüntüden okunacak) | 1.200 |
| 2012 | 600 | 600 |
| 2013–2021 | 4.320 | 4.281 (39 iptal) |
| 2022–2023 (ÖSYM kısmi) | 92 | 92 |
| 2024/1 (F5) | 200 | 20 |
| 2024/2–2025/2 (F5) | 600 | 600 |
| 2026/1 (ÖSYM kısmi) | 20 | 20 |
| 2026/2 (F6) | 200 | 200 |
| **Toplam** | **≈ 8.430** | **≈ 7.010** |

**Eksik:** 2022/1, 2022/2, 2023/1, 2023/2, 2026/1'in görünmeyen **1.008** sorusu;
2024/1'in 180 sorusunun ve 2006–2008'in 1.200 sorusunun anahtarı; açıklamalar.

---

## 3. Temel kararlar (öntanımlılar — sahibi değiştirebilir)

| # | Karar | Öntanımlı | Gerekçe |
|---|---|---|---|
| D1 | Soru bir `Card` mı? | **Hayır, ayrı tür** | ADR-010 dersi: başkasının içeriği Tekrar'a girmez. Soru yalnız Egzersiz'de ve ölçü olarak yaşar |
| D2 | Banka nerede? | **Değişmez bir dosya** (`bank.json` + PDF'ler); kullanıcı durumu **SwiftData**'da, kararlı soru kimliğiyle | Bankayı yeniden üretmek (çıkarım düzeltmesi) göç gerektirmez; yedek yalnız küçük durumu taşır, telifli içerik taşımaz |
| D3 | Çıkarım nerede? | **Mac'te, tek seferlik, deterministik öncelikli** (`tools/exam_bank/`); model yalnız dört yerde (§5.8) | 7.000 soruyu fotoğraftan okutmak hem pahalı hem hatalı olurdu; metin katmanı zaten var |
| D4 | Provenans | **PDF sayfasının kendisi** — telefonda PDFKit ile çizilir, sorunun bölgesi vurgulanır | "Kaynağı göster" ÖSYM kitapçığını gösterir; görselli sorular da buradan çözülür |
| D5 | Açıklama | **Faz A'da yok**; yanlışta köprü kartlara | Kaynakta açıklama yok; uydurma riskini almadan önce köprünün yetip yetmediği ölçülür |
| D6 | Anahtarsız 1.380 soru | **Bankada dururlar ama varsayılan filtrelerde yoklar** ("Anahtarsız — yalnız oku") | Puanlanamayan soru Pratik'i ve Deneme'yi bozar |
| D7 | Eski yıllar | **Hepsi açık; ≤2012 soruları "eski" rozetli**, filtrede "2013+" tek dokunuş | Kılavuz değişmiş olabilir; karar sahibinin (K2) |
| D8 | FES | **Yalnız sahibinin köprüde seçtiği karta** `.wrong`; doğru cevap hiçbir karta yazmaz | "Vinyet doğru ≠ kart doğru"; yanlış bağ kalıcı FES kirliliği yapmasın |
| D9 | FSRS | **`EarlyPractice` ve `ReviewLog` asla** | ADR-007: tek karta bakan köprü, bir soru birden çok karta dağıtılamaz |
| D10 | Telif | PDF'ler ve `bank.json` **repo'ya asla girmez**; telefonda iCloud yedeğinden **hariç** | Kişisel kullanım; ANA-PLAN "tam kitap tarama" yasağıyla açık uzlaşma ADR-012'de |

---

## 4. Mimari

```text
[Mac, tek seferlik]
  SOY AĞACI/01 - TUS Çıkmış Sorular/*.pdf
    │  tools/exam_bank/sources.json   (kaynak kaydı: dosya → yıl/dönem/test/aile)
    ▼
  A1 çıkarım (pdfplumber, sütun duyarlı)  ─┐
  A2 anahtar + iptal                        │  deterministik, pytest'li
  A3 birleştirme / tekilleştirme            │
  A4 görsel tespiti + bbox                 ─┘
  A5 onarım kuyruğu (yalnız başarısızlar) ──► model (görüntü kırpıntısı)
  A6 2011/1 görüntüden okuma               ──► model (sayfa görüntüsü)
  A7 ders/konu etiketi                      ──► model (metin, toplu) + monoton düzeltme
  A8 doğrulama kapıları V1–V10              (biri düşerse paket çıkmaz)
  A9 paketleme → CizgiSoruBankasi/ { manifest.json, bank.json, pdf/<sha256>.pdf }
    │  AirDrop / Dosyalar
    ▼
[iPhone]
  Ayarlar → Veri → "Çıkmış soru bankası → İçe aktar"
    → Application Support/Cizgi/ExamBank/<bankVersion>/   (iCloud yedeğinden hariç)
  CizgiCore: ExamBank (yükleme, dizin) · ExamFilter · ExamSelection · ExamScoring
             · ExamBridgeRanking · ExamGapLedger
  SwiftData: ExamRun · ExamAttempt · ExamQuestionState   (kararlı soru kimliğiyle)
  App: Egzersiz → "Çıkmış" → Pratik / Deneme / Yanlışlarım / Kitaba dönünce
       Bilgilerim → "Kitaba dönünce" bölümü
       Kaynağı göster → PDF sayfası (ExamPageRenderer → SourceImageViewer)
```

Sunucuya Faz A'da **hiç** dokunulmaz (`jobs` tablosu, migration, Vercel değişmez).

---

## 5. Bölüm A — Banka üretim hattı (Mac)

### 5.1 Yer ve dosyalar

```text
tools/exam_bank/
  README.md                 nasıl koşulur, girdiler, çıktılar, telif notu
  requirements.txt          pdfplumber, jsonschema (sürüm aralıklı)
  sources.json              kaynak kaydı (Ek A'dan üretilir, elle gözden geçirilir)
  exam_bank.schema.json     banka biçimi — tek kaynak (Swift Codable bununla kilitli)
  build.py                  orkestratör: A1→A9, her aşamanın çıktısı out/stageN.json
  extract/columns.py        kelime kutularından sütun ayırma
  extract/segment.py        soru bölme (numara + sıra kısıtı)
  extract/options.py        şık ayrıştırma (satır ve ızgara düzenleri)
  extract/families.py       F1–F6 adaptörleri
  keys.py                   anahtar ayrıştırma (F2 çift sayfa, F3 ızgara, F4 "DOĞRU CEVAP",
                            F5 iki blok, F6 üç sütunlu tablo)
  merge.py                  tekilleştirme, resmî metin önceliği
  figures.py                görsel tespiti, bbox
  subjects.py               monoton ders bölütleme (dinamik programlama)
  gates.py                  V1–V10
  package.py                qpdf ile sayfa alt kümesi, manifest, sha256
  tests/                    sentetik fikstürler (telifli PDF yok)
  out/                      .gitignore'lu
backend/scripts/examBank.ts  model aşamaları (A5, A6, A7, V6) — config.ts ve fiyat defterini kullanır
backend/providers/openaiText.ts  metin/görüntü + katı JSON şema, amaç başına effort/tavan
```

`.gitignore`: `tools/exam_bank/out/`, `tools/exam_bank/.venv/`. Kaynak klasör yolu
yalnız ortam değişkeninden: `EXAM_SOURCE_DIR`. PDF'ler repo'ya kopyalanmaz.

**Neden Python + TS ikilisi:** PDF kelime koordinatları için olgun araç `pdfplumber`
(önceki analiz de onu kullanmış). Model çağrıları ise TS'te, çünkü model adı, effort,
tavan ve fiyat `config.ts`'te (§0.6) ve maliyet defteri (`tokenUsage.ts`) orada.

### 5.2 Kaynak kaydı (`sources.json`)

JSON, YAML değil: standart kütüphaneyle okunur, yerel `.venv` (Python 3.9) ve CI
(3.11) ek bağımlılıksız çalışır (`evals/gold-manifest.json` deseni). Her kağıt için
bir kayıt; bir PDF birden çok kağıt taşıyabilir (F2, F5):

```jsonc
{
  "file": "2013-2021/TUS_2019_Ilkbahar_Temel.pdf",
  "family": "F3",
  "sourceKind": "osym",          // osym | osymPartial | tusdata | reconstruction
  "papers": [{
    "id": "TUS-2019-1-T",        // TUS-<yıl>-<dönem 1|2>-<T|K|T2>
    "date": "2019-02-24",        // ilk sayfadan; yoksa null
    "expected": 120,             // "Bu testte 120 soru vardır" ya da bilinen
    "numberOffset": 0,           // F5 Klinik: 100 (101–200 → 1–100)
    "timeLimitMinutes": null,    // kitapçıkta yazıyorsa sayı
    "penalty": "quarter",        // quarter | unknown
    "keySource": "osym"          // osym | tusdata | reconstruction | none
  }]
}
```

- F2 dosyaları **iki kağıda** bölünür (`TUS-2009-1-T` 1–100, `TUS-2009-1-K` 1–100).
- F5 dört kağıda bölünür (Temel 1–100, Klinik 101–200 → K 1–100).
- 2012 İlkbahar: `TUS-2012-1-T`, `TUS-2012-1-T2`, `TUS-2012-1-K`.
- Dışarıda: `yenikeşif/*`, `2024-2025-2026 TUS.pdf`, `tmp/`, `TUS_Guncellik_Raporu/`.
- Klinik blok sırası (Faz A1'de ölçüldü): `[Dahiliye, Küçük Stajlar, Pediatri, Genel
  Cerrahi, Küçük Stajlar, Kadın Doğum]` — Küçük Stajlar iki kez (dahilî, cerrahî). F1
  kitapçığı başlıkta dört ders yazsa da soruları aynı altı blokta.

### 5.3 A1 — Metin çıkarımı (deterministik)

1. `pdfplumber` ile her sayfanın **kelime kutuları** (`x0, top, x1, bottom, text`).
2. **Sütun ayırma:** kelimelerin `x0` dağılımında iki küme; sayfa ortasındaki boşluk
   eşiği sayfa başına hesaplanır. Okuma sırası: sol sütun yukarıdan aşağı, sonra sağ.
   (Düz metin çıkarımı sütunları karıştırıyor — 2006'da "5. 2. Vertebra…" gibi; bu
   aşamanın var olma sebebi bu.)
3. **Soru bölme:** satır başındaki `^\d{1,3}\.` işaretleri aday; kabul kuralı
   **sıra kısıtı** (beklenen sonraki numara) + bloğun `A)`–`E)` içermesi. Böylece
   soru içindeki "I. … II. …" öncülleri ve "5. vertebra" gibi sayılar soru sanılmaz.
4. **Şık ayrıştırma:** üç düzen desteklenir: (a) satır başına bir şık; (b) iki şık
   bir satırda (`A) X  B) Y`); (c) etiketler önce, metinler sonra (`A) B)` satırı +
   altında metinler — 2006 s.1 örneği). Kural: her metin parçası **kendisinden
   solda ve üstte en yakın etikete** bağlanır (koordinatla).
5. Kök metni: satır sonu tirelemesi birleştirilir (`bir-\nleştiren` → `birleştiren`),
   NFC, gereksiz boşluklar sadeleşir; **içerik düzeltilmez** (yazım, noktalama aynen).
6. Başlık/altlık gürültüsü atılır: "Diğer sayfaya geçiniz.", sayfa numarası,
   `2006-B-TTBT-1`, "Bu testlerin her hakkı saklıdır…", F5'te "Tusdata'nın yorumları için…".
7. Her soruya **bbox**: numaranın üstünden bir sonraki sorunun başına (aynı sütunda)
   kadar; pdfplumber koordinatı (sol üst köken, punto). Soru sütun/sayfa kırılıyorsa
   birden çok bbox.
8. F4: yalnız metni olan yuvalar alınır; boş yuvalar atlanır ama numaraları
   `expected` sayımında "görünmez" diye kaydedilir.
9. F6: `Soru N` başlıklı bloklar; tek sütun, düzen basit.
10. 2011/1 (F2 bozuk): bu aşamada yalnız **bbox ve numara konumları** alınır (glif
    konumları doğru, kodlama bozuk); metin A6'da görüntüden okunur.

### 5.4 A2 — Cevap anahtarı ve iptal (deterministik)

| Aile | Yer | Ayrıştırma |
|---|---|---|
| F2 | Son iki sayfa (Temel, Klinik), "A KİTAPÇIĞI" | `N. X` çiftleri, 1–100 |
| F3 | Son sayfa, 3 sütun ızgara | `N. X` çiftleri, 1–120; **başlık satırındaki sayılar dışlanır** (ilk denemede 121–122 eşleşme bu yüzdendi) |
| F4 | Her görünür sorunun altında | `DOĞRU CEVAP:\s*([A-E])` (sonuna sayfa numarası yapışabiliyor: "E1") |
| F5 | Sınav sonu anahtar sayfası; 2025/1'de metin dağınık | Anahtar başlığının bulunduğu **sayfanın tamamı** taranır; 1–200 ilk görülen çift |
| F6 | Son sayfa, satır-sütun tablo | Sıra: `r L r+25 L r+50` × 25, ardından `L r+75 L` × 25 |

- **İptal:** soru yuvasında "Bu soru iptal edilmiştir." → `status: cancelled`; anahtar
  satırı yok sayılır. 2009–2011'de "iptal" kelimesi farklı biçimde geçiyor — A2 ayrıca
  anahtarında harf yerine işaret bulunan numaraları iptal sayar ve raporlar.
- Anahtar harfi → `answer: 0…4`.

### 5.5 A3 — Birleştirme ve tekilleştirme

1. F4 görünür soruları (resmî metin) ile F5/F6 aynı sorunun iki kopyası → **resmî
   metin ve resmî sayfa öncelikli**, F5/F6 sayfası `altProvenance`'a.
2. Eşleşme: 6-kelimelik parçacık örtüşmesi ≥ 0,5 **ve** aynı numara (V5).
3. F5'in güvenilmez 12 kaydı (`TUS_Guncellik_Raporu/DISLANAN_SORULAR.md`) →
   resmî metni yoksa `status: modified` (varsayılan filtrelerde yok).
4. Yıllar arası neredeyse aynı sorular (Jaccard > 0,8) → `similarTo: [id]`; oturum
   seçici aynı oturumda ikisini birden vermez.

### 5.6 A4 — Görsel tespiti

- **Anahtar kelime:** "yukarıdaki (şekil|görüntü|grafik|tablo|resim|elektrokardiyogram|
  EKG|film|radyografi|mikrograf|kesit)", "şekilde", "görüntüde", "resimde",
  "grafikte", "tabloda", "mikrografta", "radyografide".
- **Sayfa nesnesi:** bbox içinde `page.images` ya da çok sayıda çizgi/eğri (vektör EKG).
- Sonuç: `figure: none | reference | required`. `required` sorular Pratik'te **kırpıntı
  görüntüsüyle** gösterilir (PDF'den canlı çizilir, §7.4).
- 2006–2021'de 147 anahtar kelime eşleşmesi var; A4'ün beklenen `required` sayısı
  ≈ 120–200.

### 5.7 A5 — Onarım kuyruğu (yalnız başarısız sorular)

- Tetik: V2'den düşen soru (5 şıktan biri boş, iki şık katlanmış hâlde aynı, kök boş,
  şık sayısı ≠ 5).
- İşlem: sorunun bbox kırpıntısı PNG (150 dpi) → model (`gpt-5.6-luna`, effort `low`)
  → katı şema `{stem, options[5]}`. Kural: **aynen aktar, düzeltme yapma, okuyamadığını
  `⟨?⟩` ile işaretle**.
- Kabul: onarılan metin ile deterministik çıkarımın ortak kelimeleri ≥ %70 (modelin
  başka bir soruyu okumadığının kanıtı); değilse soru `status: needsHuman`, pakete
  girer ama varsayılan filtrede yok.
- `textQuality: repaired`.

### 5.8 Model kullanılan dört yer (başka hiçbir yerde yok)

| Aşama | Girdi | Çıktı | Model / effort | Tahmini maliyet |
|---|---|---|---|---|
| A5 onarım | Soru kırpıntısı | `{stem, options}` | Luna / low | ≈ 250 soru × $0,005 = **$1,3** |
| A6 2011/1 | 36 sayfa görüntüsü | Sorular + şıklar | Luna / low | ≈ **$0,3** |
| A7 ders/konu | 25'lik soru kümeleri, metin | `{subject, topic}` | Luna / low | ≈ 340 çağrı → **$1–2** |
| V6 kitapçık sağlaması | Kağıt başına 15 soru | Modelin cevabı | Luna / low | ≈ 900 soru → **$1** |

Toplam tek seferlik **≈ $3–5**. Yeni env değişkenleri (yalnız betik okur):
`OPENAI_EXAM_MODEL`, `OPENAI_EXAM_REASONING_EFFORT` (low), `OPENAI_EXAM_MAX_OUTPUT_TOKENS`
(8000), fiyatlar mevcut `OPENAI_USD_PER_MILLION_*`'dan. **Küresel `high` effort miras
alınmaz** (miras alınırsa maliyet 5–8 kat şaşar).

### 5.9 A6 — 2011 İlkbahar

- Sayfa görüntüsü (pdfplumber → 200 dpi) → model: sütun sırasıyla soruları numarası,
  kökü ve beş şıkkıyla aynen aktar.
- Doğrulama: 1–100 + 1–100 numara eksiksiz; her soruda 5 şık; anahtarla hizalama
  (anahtar zaten okunuyor). Başarısız numara → `needsHuman`.
- `textQuality: vision`.

### 5.10 A7 — Ders ve konu etiketi

1. Model, her soru için ÖSYM dersini seçer (enum: 7 Temel + 5 Klinik ders adı) ve
   uygulamanın konu listesinden birini (dinamik şema: o dersin `subject_topics.json`
   konuları + `null`). `sanitizeTopics` kuralı: geçersiz konu → `null`, iş düşmez.
2. **Monoton bölütleme** (Klinik altı blok, Temel yedi ders; Temel-2'nin sırası oylardan —
   bkz. "Faz A1 sonucu"): ÖSYM her testte dersleri sabit sırayla dizer. Model etiketi
   bir öneri; nihai ders, "sıra bozulmadan en çok model etiketiyle uyuşan bölütleme"
   dinamik programlamasıyla seçilir. Tek bir yanlış etiket böylece kendiliğinden düzelir.
   Kağıdın sırası kayıttakiyle tutarsızsa bölütleme o kağıt için kapanır ve raporlanır.
3. ÖSYM dersi → uygulama dersi eşlemesi (Ek C): **Histoloji-Embriyoloji → Fizyoloji**
   (uygulamanın Fizyoloji dersi "HistoFizyoloji" konularını taşıyor), İç Hastalıkları →
   Dahiliye, Cerrahi → Genel Cerrahi, Kadın-Doğum → Kadın Hastalıkları ve Doğum.
   Orijinal ad `osymSubject`'te saklanır ve ekranda "Histoloji-Embriyoloji" diye görünür.
4. Doğrulama: önceki raporun 932 etiketiyle (2022–2026) uyuşma ≥ %90 (V7).

### 5.11 A8 — Doğrulama kapıları (biri düşerse paket üretilmez)

| # | Kapı | Ölçüt |
|---|---|---|
| V1 | Kağıt bütünlüğü | Her kağıtta 1…N eksiksiz ve tekil (F4'te görünür + görünmez = N) |
| V2 | Şık bütünlüğü | 5 dolu şık, katlanmış hâlde birbirinden farklı; düşenler A5'e |
| V3 | Anahtar bütünlüğü | Anahtarlı kağıtta iptal dışı her soruda cevap var; anahtar sayısı = N |
| V4 | Resmî uyuşma | Üçüncü taraf her anahtar, ÖSYM'nin görünür "DOĞRU CEVAP"ıyla **%100** uyuşur (bugün 77/77) |
| V5 | Numara uyuşması | Örtüşen resmî/F5/F6 sorularında numara aynı |
| V6 | Kitapçık sağlaması | Kağıt başına 15 rastgele anahtarlı soruda model cevabı anahtarla ≥ %60 uyuşur (şans %20). Düşük çıkarsa anahtar başka kitapçığa (B) ait olabilir → kağıt karantinaya |
| V7 | Ders etiketi | Monotonluk + önceki 932 etiketle ≥ %90 uyuşma |
| V8 | Görsel | Her `required` soruda bbox var; kırpıntı boş değil (beyaz olmayan piksel ≥ %2) |
| V9 | İnsan örneklemi | Betik 30 rastgele soruyu sayfa referansıyla basar; sahibi PDF'le karşılaştırır (~10 dk); onay `manifest.json`'a yazılır |
| V10 | Telif hijyeni | Çıktı klasörü repo dışında ya da gitignore'lu; `git status` temiz |

### 5.12 A9 — Paketleme

```text
CizgiSoruBankasi/
  manifest.json   { bankVersion, schemaVersion, builtAt, sources[], files[{path, sha256, bytes}],
                    gates{V1..V10: pass}, humanCheck{by, at, sample} }
  bank.json       §6 biçimi (~7 MB)
  pdf/<sha256>.pdf
```

- 2006–2021 PDF'leri **aynen** (≈ 115 MB); F5 derleme (21 MB); F6 iki dosya (0,2 MB).
- F4 resmî PDF'lerinden **yalnız görünür soru sayfaları** `qpdf --pages` ile ayrı
  dosyalara (≈ 212 sayfa, birkaç MB) — boş yuva sayfaları taşınmaz.
- Toplam ≈ **140–150 MB**.
- `bankVersion` = tarih + artış (`2026-10-02.1`). Aynı soru kimliği sürümler arasında
  **asla** değişmez (kullanıcı durumu buna bağlı).

### 5.13 Testler (hat)

- pytest, **sentetik** fikstürler: kelime kutusu JSON'ları (iki sütun, ızgara şık,
  "A) B)" düzeni, I-II-III öncüllü soru, iptal yuvası, F3 anahtar ızgarası başlık
  sayılarıyla, F6 tablo). Telifli PDF fikstür olmaz (`evals/fixtures` kuralı).
- `subjects.py` için DP testleri (tek yanlış etiket düzelir; sıra ihlali raporlanır).
- `exam_bank.schema.json` ↔ Swift `ExamBankDocument`: `evals/tests/test_swift_contract_sync.py`
  desenine yeni bir kilit (alan adları ve enum değerleri birebir).
- `examBank.ts` için vitest: şema doğrulama, effort'un küresel ayardan bağımsız
  okunduğu, defter satırının `purpose: "exam_bank_build"` ile yazıldığı.

---

## 6. Bölüm B — Banka biçimi (`exam_bank.schema.json`, v1)

```jsonc
{
  "schemaVersion": 1,
  "bankVersion": "2026-10-02.1",
  "subjectSchemaVersion": 1,                 // subject_topics.json sürümü
  "papers": [{
    "id": "TUS-2019-1-T",                    // TUS-<yıl>-<dönem 1|2>-<T|K|T2>
    "year": 2019, "session": 1, "test": "T",
    "date": "2019-02-24",                    // null olabilir
    "questionCount": 120,
    "timeLimitMinutes": null,                // kitapçıkta yazıyorsa sayı
    "penalty": "quarter",                    // quarter | unknown
    "sourceKind": "osym",                    // osym | osymPartial | tusdata | reconstruction
    "keySource": "osym",                     // osym | tusdata | reconstruction | none
    "pdf": { "path": "pdf/<sha256>.pdf", "pageCount": 29 }
  }],
  "questions": [{
    "id": "TUS-2019-1-T-045",                // kararlı; asla yeniden kullanılmaz
    "paperId": "TUS-2019-1-T",
    "number": 45,
    "stem": "…",
    "options": ["…", "…", "…", "…", "…"],   // A–E sırasıyla
    "answer": 2,                             // 0…4 ya da null
    "answerSource": "osym",                  // osym | tusdata | reconstruction | null
    "status": "ok",                          // ok | cancelled | keyless | modified | needsHuman
    "osymSubject": "Farmakoloji",
    "subject": "Farmakoloji",                // uygulamanın kanonik dersi
    "topic": "Otonom Sinir Sistemi" ,        // ya da null
    "figure": "none",                        // none | reference | required
    "provenance": [{ "path": "pdf/<sha>.pdf", "page": 17,
                     "bbox": [x0, top, x1, bottom] }],   // punto, sol üst köken
    "altProvenance": [],
    "textQuality": "native",                 // native | repaired | vision
    "similarTo": []
  }]
}
```

Koordinat notu: pdfplumber sol üst köken kullanır; PDFKit sayfa sınırı sol alt köken.
Telefonda `y_pdfkit = pageHeight − bottom`. Sayfa döndürmesi (`/Rotate`) paketlemede
sıfırlanmış olmalı (V8 kontrol eder).

---

## 7. Bölüm C — Uygulama

### 7.1 İçe aktarma

- **Yer:** Ayarlar → Veri → yeni satır **"Çıkmış soru bankası"**: durum (sürüm, soru
  sayısı, anahtarlı sayısı, boyut), **"İçe aktar / Güncelle"**, **"Kaldır"**.
- **Seçici:** `fileImporter(allowedContentTypes: [.folder])` — `CizgiSoruBankasi`
  klasörü seçilir (güvenlik kapsamlı erişim).
- **Akış (ana aktörün dışında, ADR-011 dersi):**
  1. `manifest.json` okunur; `schemaVersion` desteklenmiyorsa "Uygulamayı güncelle"
     mesajı.
  2. Her dosyanın sha256'sı hesaplanır ve manifestle karşılaştırılır; uyuşmazlık →
     "Dosya bozuk: pdf/…" ve içe aktarma durur.
  3. `Application Support/Cizgi/ExamBank/<bankVersion>/` altına kopyalanır;
     klasör `isExcludedFromBackup = true`.
  4. `bank.json` çözülür ve dizinlenir; başarılıysa `ExamBank/active.json` işaretçisi
     yeni sürüme çevrilir, eski sürüm silinir. Başarısızsa yeni klasör silinir, eski
     aynen kalır.
  5. **Kullanıcı durumu korunur:** kimlikler kararlı olduğu için eski denemeler yeni
     bankaya kendiliğinden bağlanır. Yeni bankada olmayan bir kimliğe ait durum
     silinmez, "bankada yok" sayılır ve Ayarlar'da gösterilir.
- **Kaldır:** banka dosyaları silinir; "Çözüm geçmişini de sil" ayrı bir onayla sorulur
  (varsayılan: sakla).
- Sonuç mesajı: "7.012 soru içe aktarıldı (1.380'i anahtarsız, 39'u iptal). 142 MB."

### 7.2 CizgiCore (Foundation-only; Linux dilim paketinde de test edilebilir)

| Tip | Sorumluluk |
|---|---|
| `ExamBankDocument` | `bank.json`'un Codable karşılığı (şemayla kilitli) |
| `ExamBank` | Yükleme, dizinler: kağıt → sorular, (ders, konu) → sorular, durum filtreleri |
| `ExamQuestionID` | Kimlik ayrıştırma/üretme (`TUS-2019-1-T-045`) |
| `ExamFilter` | Ders, konu, yıl aralığı, dönem, test (Temel/Klinik), kaynak, durum (çözülmemiş / yanlışlarım / açıklar / tümü), görselli dahil mi, "eski" (≤2012) dahil mi |
| `ExamSelection` | Oturum kuyruğu: filtre → iptal/anahtarsız/modified dışla → önceliklendir (çözülmemiş önce; "yanlışlarım"da en eski yanlış önce) → **dersler arası karıştırma** (round-robin) → `similarTo` çiftlerini aynı oturuma koyma. Enjekte edilen RNG (`ExerciseSession` deseni) |
| `ExamScoring` | Doğru/yanlış/boş, **net = D − Y/4** (kağıdın `penalty`'si `quarter` ise; `unknown` ise aynı kural "varsayılan" etiketiyle), ders bazında net, soru başı süre |
| `ExamBridgeRanking` | Köprü adayları (§7.5): katlanmış (fold) kelimeler, durak kelimeler, IDF ağırlığı, en fazla 8 kart |
| `ExamGapLedger` | Açık aç/kapat/yoksay/yeniden aç kuralları (§7.6) |
| `ExamPace` | Soru başı süre: son 50 `ExamAttempt.responseTimeMs` medyanı (`ReviewPace.secondsPerCard` yeniden kullanılır); süre bütçesini soru sayısına çevirir |
| `ExamTimeLimit` | Kağıdın süresi: kitapçıktaki değer, yoksa **75 sn/soru** (2012–2015 kitapçıklarındaki 150 dk/120 soru oranı; Ayarlar'da değiştirilebilir) |

### 7.3 SwiftData (yalnız ekleme; `CizgiSchema.allModels`'e üç model)

```swift
@Model final class ExamRun {
    @Attribute(.unique) var id: UUID
    var modeRaw: String            // practice | mock | wrongOnly
    var paperId: String?           // mock'ta tek kağıt
    var filterJSON: String?
    var queuedQuestionIds: [String]
    var position: Int
    var flaggedQuestionIds: [String] = []
    var timeLimitSeconds: Int?
    var startedAt: Date
    var finishedAt: Date?
    var attempts: [ExamAttempt]
}

@Model final class ExamAttempt {
    @Attribute(.unique) var id: UUID
    var questionId: String
    var selectedOption: Int?       // nil = boş
    var isCorrect: Bool?           // nil = boş ya da anahtarsız
    var responseTimeMs: Int
    var answeredAt: Date
    var bridgeOutcomeRaw: String?  // linked | noCard | skipped | notAsked
    var linkedCardId: UUID?
    var run: ExamRun?
}

@Model final class ExamQuestionState {
    @Attribute(.unique) var questionId: String
    var linkedCardIds: [String] = []
    var gapStatusRaw: String = "none"   // none | open | closed | dismissed
    var gapOpenedAt: Date?
    var gapClosedAt: Date?
    var closedByCardId: String?
    var attemptCount: Int = 0
    var wrongCount: Int = 0
    var lastResultRaw: String?          // correct | wrong | blank
    var lastAnsweredAt: Date?
    var reportedIssueRaw: String?       // stem | options | key | figure (kullanıcı bildirimi)
}
```

- Her yeni alan **bildirimde varsayılanlı** (`ModelRun.attempt` dersi: hafif göç
  başlatıcıyı çağırmaz).
- **Saklama:** `ExamAttempt` **süresiz** (Egzersiz'in 90 günü gibi silinmez) — ilerleme
  kaydı bu; hacmi küçük (günde 50 soru × 1 yıl ≈ 18.000 satır).
- **Kanıt:** eski şemalı gerçek depo üzerine yeni build silmeden kurulur, açılış ve
  sayılar doğrulanır (kavram destesi kaldırmasındaki şema kanıtı deseni).

### 7.4 Ekranlar

**(a) Egzersiz kökü.** Mevcut üç `NumeralActionRow`'un altına dördüncüsü:
**"Çıkmış"** — büyük serif sayı = çözülmemiş anahtarlı soru; alt satır
"yanlışlarım 23 · açık 7". Banka yoksa satır "Soru bankası yok — Ayarlar'dan içe aktar".
Dokunuş `exercisePath`'e değer tabanlı push (`ExamRoute.home`).

**(b) `ExamHomeView`.** Dört giriş:
- **Pratik** — son kullanılan filtreyle hemen başlar; sağ üstte filtre.
- **Deneme** — kağıt seçici (yıl → dönem → Temel/Klinik; her satırda soru sayısı,
  süre, anahtar kaynağı rozeti; anahtarsız kağıtlar gri) ya da **"Karma deneme"**
  (N soru, gerçek bir kağıdın ders dağılımıyla).
- **Yanlışlarım** — son cevabı yanlış olan sorular, en eskiden.
- **Kitaba dönünce** — açık listesi (§7.6).
Altta son 5 oturum (tarih, mod, doğru/yanlış, net).

**(c) `ExamSetupSheet`.** Taslak + Uygula deseni (`ExerciseSetupSheet` gibi), canlı
"N soru hazır" sayacı. Boyutlar: ders, konu, yıl aralığı (kaydırıcı 2006–2026 +
"2013 ve sonrası" kısayolu), dönem, test, durum, kaynak, "görselli sorular",
"eski sorular". Bütçe: soru sayısı (10/20/40/Tümü) ya da süre (`ExamPace` ile).

**(d) `ExamSessionView` (Pratik).** Sekme çubuğu gizli, "Bitir" tek çıkış
(`AppNavigator.isTabBarHidden` kuralı; yarım koşuda `finishedAt` boş kalmasın diye
Egzersiz'deki onay diyaloğu burada da var).
- Üst satır (eyebrow, `TurkishText.uppercased`): **"2019 · 1. DÖNEM · TEMEL · 45 ·
  FARMAKOLOJİ"**; ≤2012 ise yanında "eski" çipi; `answerSource` üçüncü tarafsa
  "anahtar: Tusdata" çipi.
- Kök: serif (kart sorusuyla aynı yer — tasarım dilinin üç serif yerinden biri).
- `figure == required` → kökün altında PDF kırpıntısı (tam genişlik, hairline kenar;
  dokununca tam ekran zoom).
- Şıklar: A–E, `CizgiChoiceButton` anatomisi; seçim kilitlenir; doğru şık yeşil,
  yanlış seçilen kırmızı, "Doğru cevap: C".
- Yanlışsa köprü paneli (§7.5); doğruysa bağlı kartlar varsa katlı "Kartların".
- Altlık: **"Kaynağı göster"** → PDF sayfası, sorunun bbox'ı dersin renginde yarı
  saydam vurgulu → `SourceImageViewer(image:)` (mevcut zoom görüntüleyicisi).
- Uzun basış menüsü: "Soruda hata bildir" (kök / şık / anahtar / görsel) →
  `reportedIssueRaw`; soru bir sonraki oturumlarda "bildirildi" rozetiyle gelir.
- Süre ölçümü: soru ekrana geldiği andan şık seçimine.

**(e) `ExamMockView` (Deneme).** Geri sayım (duraklatılabilir ama duraklama süresi
kaydedilir ve sonuçta yazılır); cevap açılmaz; soru işaretleme; alt ızgarada soru
gezgini (boş / işaretli / cevaplı); "Sınavı bitir" onayı. Köprü **deneme sırasında
sorulmaz**, sonuç ekranında yanlışlar tek tek gezilirken sorulur.

**(f) `ExamResultView`.** Doğru / yanlış / boş, **net**, ders bazında net ve doğru %,
ortalama süre; "Yanlışları gözden geçir" (köprüyle); "Kitaba dönünce'ye eklenenler: N".
Deneme için aynı kağıdın önceki denemeleriyle karşılaştırma satırı.

**(g) Bilgilerim.** "Gözden geçir" ile "FES kartlar" arasına **"Kitaba dönünce · N"**
bölümü (§7.6). Arama kutusu Faz A'da soruları aramaz (Bilgilerim kart ekranıdır).

**(h) `ExamPageRenderer` (App).** `PDFDocument` önbelleği (`NSCache`, en fazla 3 belge);
sayfayı 2× ölçekte `UIGraphicsImageRenderer` ile çizer; isteğe bağlı bbox vurgusu ya da
yalnız bbox kırpıntısı. Ana aktörün dışında çizer.

**(i) Kart yüzü refaktörü (Faz 0).** `ReviewCardFace` bugün `let card: Card` alıyor.
Değer tipine çekilir: `StudyFaceContent { eyebrow, question, answer?, subjectColor,
typeMark?, marks }`; `Card` için bir adaptör. Tekrar ve Egzersiz görsel olarak
değişmez; soru aynı yüzü kullanır. Ayrı, küçük bir PR.

### 7.5 Köprü (yanlış cevaptan sonra)

- **Soru:** "Bu soruyu karşılayan bir kartın var mı?"
- **Adaylar (`ExamBridgeRanking`, deterministik, API yok):**
  1. Havuz: `status == .active` kartlar; ders = sorunun uygulama dersi; konu biliniyorsa
     önce aynı konu, sonra dersin geri kalanı.
  2. Metin: soru kökü + **doğru şık (2× ağırlık)**; kart: `front + back + explanation`.
  3. `CardSearch.fold` ile katlama (ADR-001), 4 harften kısa kelimeler ve durak kelimeler
     ("aşağıdakilerden", "hangisi", "hangisidir", "olası", "yaşındaki", "hasta", "en",
     "ile", "olan"…; liste CizgiCore'da, testli) atılır.
  4. Puan = ortak kelimelerin IDF toplamı (IDF havuz içinde); eşik altı elenir; en fazla 8.
  5. Bu soruya daha önce bağlanmış kartlar en üstte.
- **Eylemler:**
  - Karta dokun → `ExamQuestionState.linkedCardIds`'e eklenir, kartın FES'ine
    `.wrong` (tek sefer; aynı oturumda aynı karta ikinci kez yazılmaz),
    `bridgeOutcome = linked`.
  - **"Hiçbiri — destemde yok"** → açık açılır (§7.6), `bridgeOutcome = noCard`.
  - **"Atla"** → hiçbir şey yazılmaz, `bridgeOutcome = skipped`.
- Aday yoksa panel doğrudan "Bu konuda kartın yok" der ve tek düğme: "Kitaba dönünce'ye ekle".
- FES yazımı üçüncü bir kopya olmasın diye `ExerciseView.applyFesScore`'un altı satırı
  CizgiCore'a `FesScore.record(_:on:at:)` olarak çıkarılır (`fesInitializedAt` dahil);
  Tekrar, Egzersiz ve Çıkmış üçü de onu çağırır.

### 7.6 "Kitaba dönünce" (açık defteri)

- **Açılır:** köprüde "Hiçbiri" seçilince.
- **Satır:** tek soru, konu düzeyinde özet asla: "Farmakoloji · Otonom — 2019/1 T45:
  destende kart yok". Gruplama ders → konu. Dokununca soru (kırpıntı + kaynak).
- **Kapanır:**
  - Sahibi satırdan "Kart ekledim" der ve bir kart seçer (köprü sıralamasıyla adaylar),
  - ya da o (ders, konu)'ya açığın açılışından sonra yeni kart gelir: satırda
    **"muhtemelen kapandı"** rozeti ve aday kart; onay tek dokunuş. **Sessizce kapanmaz.**
- **Yoksay:** sola kaydır → `dismissed` (bir daha açılmaz).
- **Yeniden açılır:** `closedByCardId` kartı silinmişse yükleme sırasında `open`'a döner
  (deterministik kontrol).
- Egzersiz'in "Kitaba dönünce" girişinden bu sorular Pratik olarak da çözülebilir
  (kart eklendikten sonra "şimdi yapabiliyor muyum?").

### 7.7 "Sorudan kart yaz" (Faz B)

- Köprüde ve açık satırında düğme. `ManualCardSheet` bir `CapturedPage` istiyor; bu
  yüzden:
  1. PDF sayfası JPEG'e çizilir (`ExamPageRenderer`, bbox vurgusu yok) ve `ImageStore`'a
     yazılır.
  2. `BackupPageInstaller` zincirinin aynısı: `CapturedPage(.ready)` → tam sayfa
     `.manual TextRegion` → `KnowledgeUnit(canonicalClaim: "")` → `ManualCardSheet`.
     `.ready` sayfayı `ProcessingQueue.shouldProcess` hiç seçmez (sunucuya gitmez).
  3. Ön dolgu: soru kökü + doğru şık metni "İşaretlenen" alanına; ders/konu kilitli.
  4. `KnowledgeUnit.tags`'e `"cikmis-soru:TUS-2019-1-T-045"` (izlenebilirlik; kavram
     destesindeki etiket deseni).
  5. Kaydedince kart otomatik bağlanır ve açık kapanır.
- Kural 8 (kart tek başına anlaşılmalı) sahibinin yazdığı kart için de geçerli; sheet
  "sorudaki şıkları karta taşıma, olguyu yaz" ipucunu gösterir.

### 7.8 İstatistik ve Bilgi Haritası (Faz B)

- İstatistik'e "Çıkmış" bölümü: ders bazında doğru %, çözülen sayı, son 30 gün eğrisi,
  yıl grubu (2006–2012 / 2013–2021 / 2022+) bazında doğru %.
- Bilgi Haritası konu satırına ikinci şerit: **çözülen soru · doğru % · açık**; n < 10
  gri. "TUS ağırlığı" kelimesi kullanılmaz; yalnız sayılar.

### 7.9 Yedek v10

- Yeni isteğe bağlı diziler: `examStates[]` (`questionId`, `linkedCardIds`, açık durumu
  ve tarihleri) ve `examAttempts[]` (`questionId`, `selectedOption`, `isCorrect`,
  `answeredAt`, `responseTimeMs`). **Soru metni ve PDF yedeğe girmez** — yedek
  telifli içerik taşımaz, küçük kalır (~1 MB).
- Geri yükleme yalnız ekler: deneme tekilliği `(questionId, answeredAt)`; durumlar
  birleşir (bağlar birleşimi, açık durumu en yeni tarihli kazanır).
- v9 ve öncesi dosyalar `decodeIfPresent` ile hatasız okunur.

---

## 8. Bölüm D — Sunucu

- **Faz A: hiçbir değişiklik yok.**
- **Faz B (koşullu):** `/api/exam-link` — `_secondOpinion.ts` deseninde senkron,
  saklamasız; girdi: soru + en fazla 40 aday kart; çıktı: en fazla 3 kart **indeksi**
  + her biri için kart metninden **alıntı**; sunucu alıntının kart metninde
  (katlanmış) alt dizi olduğunu doğrular, geçmeyeni düşürür. Yalnız deterministik
  sıralamanın isabeti sahibinin kararlarına karşı ölçülüp yetersiz bulunursa açılır
  (açılma eşiği: model önerisi sahibinin seçimini ilk 3'te ≥ %85 yakalar).
- `CallPurpose` (TS) birliğine `exam_link` ve **eksik olan `coverage_audit`**;
  `UsageDetailView.purposeLabel`'a "soru köprüsü" ve betik için "soru bankası üretimi".
- **Faz C (karar K3):** `/api/exam-explain` — isteğe bağlı açıklama; "Modelin açıklaması —
  kaynak değil" başlığıyla; önbelleklenir; Gemini tutarlılık kapısı (açıklama anahtarla
  çelişiyorsa gösterilmez). Açılmadan önce `GEMINI_USD_PER_MILLION_*` Vercel'e girilmeli.

---

## 9. Yol haritası

Her faz tek başına değer üretir; her fazın sonunda "sevmedim" denebilir. Süreler tek
geliştirici + Claude Code temposu, cihaz doğrulaması hariç.

### 9.1 Faz 0 — Hazırlık (2–3 gün)

| İş | Çıktı | Kabul |
|---|---|---|
| Sahibinin kararları (§13) | Karar notu | K1–K7 yazılı |
| Kaynak klasör düzeni (sahibin işi, isteğe bağlı) | `yenikeşif/` ve 134 sayfalık tarama kenara; F6 dosyalarına doğru ad | `sources.json` bu adlarla tutarlı |
| ADR-012 taslağı | `docs/ADR-012-cikmis-soru-bankasi.md` | D1–D10 + kaldırma reçetesi |
| Kart yüzü refaktörü | `StudyFaceContent` + `Card` adaptörü | Tekrar/Egzersiz simülatörde görsel olarak aynı |
| `FesScore.record` çıkarımı | CizgiCore + test | Tekrar ve Egzersiz onu çağırır, davranış aynı |
| Hat iskeleti | `tools/exam_bank/`, `.gitignore`, `requirements.txt`, README | `build.py --dry-run` kaynakları listeler |

### 9.2 Faz A1 — Banka hattı (7–9 gün)

1. A1 çıkarım + F1/F3 adaptörleri + testler → V1/V2 geçen F3 kağıtları.
2. F2, F4, F5, F6 adaptörleri → tüm kağıtlarda V1.
3. A2 anahtarlar + iptal → V3, V4, V5.
4. A3 birleştirme, A4 görsel.
5. `openaiText.ts` + `examBank.ts`: A5 onarım, A6 2011/1, A7 etiket, V6.
6. V7–V10, paketleme, sahibinin 30 soruluk örneklemi.

**Kabul:** tüm kapılar yeşil; `manifest.json`'da insan onayı; toplam model maliyeti
defterde ≤ $5.
**Geri alma:** repo'da yalnız betikler ve şema; kaldırmak klasör silmek.

### 9.3 Faz A2 — Uygulama çekirdeği (10–12 gün)

1. CizgiCore: `ExamBankDocument`, `ExamBank`, `ExamQuestionID`, `ExamFilter`,
   `ExamSelection`, `ExamScoring`, `ExamBridgeRanking`, `ExamGapLedger`, `ExamPace`,
   `ExamTimeLimit` + testler (sentetik küçük banka fikstürü).
2. SwiftData üç model + `allModels` + eski depoyla şema kanıtı.
3. İçe aktarma (Ayarlar → Veri).
4. Egzersiz kökü satırı, `ExamHomeView`, `ExamSetupSheet`, `ExamSessionView` (Pratik),
   köprü paneli, "Kaynağı göster", görsel kırpıntısı, hata bildirimi.
5. "Kitaba dönünce" (Egzersiz girişi + Bilgilerim bölümü).
6. `xcodegen generate` + simülatör derlemesi + simülatörde uçtan uca: içe aktar → 20
   soru Pratik → 3 yanlış → biri karta bağla, biri açık, biri atla → açık Bilgilerim'de
   → yeni kart ekle → "muhtemelen kapandı" → onayla.

### 9.4 Faz A3 — Deneme (4–5 gün)

`ExamMockView`, süre, işaretleme, gezgin, `ExamResultView`, net, ders bazında sonuç,
sonuçta köprülü gözden geçirme, önceki denemeyle karşılaştırma.

### 9.5 Kanıt turu (14 gün kullanım)

Ölçülenler (hepsi yerel veriden, ek çağrısız): kullanım günleri, günlük soru sayısı,
köprü sonuç dağılımı (linked/noCard/skipped), açılan/kapanan açık, ders bazında doğru %,
Deneme kullanımı, hata bildirimleri. **Karar kapısı §1'deki ölçütler.**

### 9.6 Faz B (3–4 hafta, kapı geçerse)

"Sorudan kart yaz" (§7.7), İstatistik + Bilgi Haritası şeridi (§7.8), yedek v10 (§7.9),
yanlış seçilen şıkkın karıştırma sinyali olarak saklanması (köprü adaylarında
"bu şıkkı seçtiğin kart" önde), koşullu `/api/exam-link` (§8), eksik kaynakların
eklenmesi için adaptör (yeni bir Tusdata cildi F5 adaptörüyle girer).

### 9.7 Faz C (seçmeli)

- **Güncellik bayrağı:** 2006–2015 anahtarlı sorularda iki bağımsız aile (Luna + Gemini)
  soruyu çözer; ikisi de anahtara karşı ve birbirleriyle aynı fikirdeyse
  `currency: disputed` — cevaptan sonra "Bu sorunun cevabı günümüz kaynaklarında
  tartışmalı olabilir"; Deneme netinden isteğe bağlı çıkarılır. ≈ $8–15 tek sefer.
- **Açıklama iste** (K3).
- **Anahtarsız 2006–2008 için "önerilen cevap"** (iki aile uzlaşırsa, açıkça
  "model önerisi" etiketiyle) — K4.
- "Bugün ne çalışayım" planlayıcısının konu ağırlığını çözülen soru sayısından alması.

---

## 10. Eksik veriler — nasıl tamamlanır

| Eksik | Etki | Yol | Kimde |
|---|---|---|---|
| 2022/1, 2022/2, 2023/1, 2023/2, 2026/1 tam setleri (1.008 soru) | En yeni yılların yarısı yok | Aynı serinin (Tusdata vb.) 2022–2023 cildi ve 2026/1 derlemesi; F5 adaptörü aynen çalışır; V4 resmî görünürlerle doğrular | Sahibi (kaynak edinme) |
| 2011/1 Klinik testi (100 soru) | Klasörde yok (kitapçık Temel-1 + Temel-2) | Aynı sınavın Klinik kitapçığı | Sahibi |
| 2024/1 anahtarı (180 soru) | Çözülür ama puanlanmaz | Başka bir derlemenin 2024/1 anahtarı; ya da Faz C "önerilen cevap" | Sahibi / Faz C |
| 2006–2008 anahtarları (1.200 soru) | En eski dilim, varsayılanda zaten dışarıda | ÖSYM arşivi ya da Faz C | Düşük öncelik |
| Açıklamalar | "Neden" yok, yalnız köprü | Açıklamalı soru kitabı (yeni adaptör: açıklama alanı `explanation` + `explanationSource`); ya da Faz C model açıklaması | K3 |
| Görselli sorular (~150) | Metin tek başına yetmez | Zaten çözüldü: PDF kırpıntısı (§7.4) | — |

---

## 11. Riskler ve önlemler

| Risk | Olasılık | Etki | Önlem |
|---|---|---|---|
| Kavram destesi refleksi ("başkasının içeriği, sevmedim") | Orta | Yüksek | Soru ≠ kart; Tekrar'a girmez; köprü ilk günden; kanıt turu ve kapı |
| Yanlış anahtar yanlış öğretir | Düşük (77/77) | Yüksek | V4 %100; V6 kitapçık sağlaması; "Soruda hata bildir"; anahtar kaynağı rozeti |
| Eski soruda güncelliğini yitirmiş cevap | Orta (≤2012) | Orta | "Eski" rozeti, yıl filtresi, Faz C güncellik bayrağı |
| Sütun/şık ayrıştırma hatası | Orta | Orta | Deterministik + V2 + A5 onarım + V9 insan örneklemi |
| Yanlış bağ FES'i kirletir | Düşük | Orta | FES yalnız sahibinin dokunduğu karta, oturum başına bir kez; bağlar kaldırılabilir |
| Köprü sürtünme olur, atlanır | Orta | Orta | "Atla" serbest; ölçülür (§1); aday yoksa tek düğme |
| 150 MB depolama | Kesin | Düşük | iCloud yedeğinden hariç; Ayarlar'da boyut ve "Kaldır" |
| SwiftData'ya yeni modeller açılışı bozar | Düşük | Yüksek | Yalnız ekleme, bildirimde varsayılan, eski depoyla simülatör kanıtı, cihaz maddesi |
| Telif | — | — | Repo'ya girmez, yedeğe girmez, tek cihaz, kişisel; ADR-012'de yazılı |
| 2026/2 yeniden dizimin kaynağı belirsiz | — | Düşük | 19/19 resmî uyuşma; `sourceKind: reconstruction` rozeti |
| CI kapalı (Actions kotası) | Kesin | Orta | Yerel pytest + vitest + `swift test` + simülatör; CLAUDE.md kuralı |

---

## 12. Test ve doğrulama

- **pytest (hat):** §5.13.
- **vitest (backend):** `openaiText.ts` şema/effort, `examBank.ts` defter satırı.
- **Sözleşme:** `exam_bank.schema.json` ↔ Swift Codable (yeni Python kilidi).
- **swift test (CizgiCore):** `ExamBankDocumentTests` (sentetik banka çözme, bilinmeyen
  alan toleransı), `ExamFilterTests`, `ExamSelectionTests` (karıştırma, `similarTo`,
  tekrar yok, RNG sabitliği), `ExamScoringTests` (net, ders netleri, `unknown` ceza),
  `ExamBridgeRankingTests` (Türkçe katlama, durak kelime, IDF, doğru şık ağırlığı,
  önceki bağ önceliği), `ExamGapLedgerTests` (aç/kapat/yoksay/silinen kartla yeniden
  aç), `ExamPageGeometryTests` (bbox koordinat dönüşümü), `BackupExporterTests` v10
  gidiş-dönüş, `FesScoreRecordTests`.
- **Simülatör:** §9.3/6 senaryosu + Deneme + yedek al/geri yükle + banka güncelle
  (kimlikler korunuyor mu) + banka kaldır.
- **Cihaz doğrulama listesine eklenecek maddeler (CLAUDE.md, 42+):**
  1. Banka içe aktarma gerçek telefonda (150 MB kopya, bellek, süre).
  2. İlk açılış yeni SwiftData modelleriyle (eski depo).
  3. Görselli bir soruda kırpıntı okunaklı mı (EKG).
  4. Deneme süresi uygulama arka plana gidip gelince doğru mu.
  5. "Kitaba dönünce" → kitap sayfası çek → yeni kart → "muhtemelen kapandı".

---

## 13. Sahibinin kararları

| # | Soru | Seçenekler | Önerim |
|---|---|---|---|
| K1 | Çıkmış soru ayrı tür mü? | Ayrı tür / kart hattından beş şıklı kart | **Ayrı tür** |
| K2 | Eski sorular (≤2012) varsayılan filtrede mi? | Hepsi açık "eski" rozetli / yalnız 2013+ | **Hepsi açık, rozetli** |
| K3 | Açıklama | Yok (köprü) / açıklamalı kitap ekle / Faz C model açıklaması | **Faz A'da yok**, kanıt turundan sonra karar |
| K4 | Anahtarsız 1.380 soru | Dışarıda / "yalnız oku" filtresi / Faz C önerilen cevap | **"Yalnız oku" filtresi** |
| K5 | Eksik setler (2022–2023, 2026/1) ve 2024/1 anahtarı | Kaynak edin / olduğu gibi | **Kaynak edin** (F5 adaptörü hazır) |
| K6 | PDF'lerin telefona kopyalanması (~150 MB) | Evet / yalnız metin (provenans ve görselli sorular kaybolur) | **Evet** |
| K7 | Deneme'de net kuralı | D − Y/4 / yalnız doğru sayısı | **D − Y/4** (2009–2015 kitapçıklarında yazılı) |

---

## 14. Bilinçle kapsam dışı

- Soruyu `Card` yapmak ve Tekrar'a sokmak (K1 tersine dönmedikçe).
- Egzersiz'in `EarlyPractice` köprüsünü sorularla beslemek (ADR-007).
- Sentetik vinyet üretimi (gerçek soru varken gereksiz).
- Sunucuda soru bankası tutmak; telefon dışında kopya.
- Fotoğraftan soru sayfası çekme akışı (PDF varken gereksiz; yeni kaynak PDF değilse
  hatta A6'nın görüntü yolu eklenir, uygulamaya kamera modu eklenmez).
- Sesli Tekrar (ayrı plan).

---

## 15. Doküman değişiklikleri

- `docs/ADR-012-cikmis-soru-bankasi.md` (yeni): D1–D10, telif uzlaşması, kaldırma
  reçetesi (üç model cascade'siz bağımsız; banka klasörü; yedek alanları
  `decodeIfPresent` — tek revert + tek göç).
- `CLAUDE.md`: ana akışa madde 10 (Çıkmış), durum tablosu satırı, anti-drift listesine
  "banka şeması ↔ Swift Codable", cihaz doğrulama maddeleri, "Sıradaki iş".
- `docs/ARCHITECTURE.md`: ikinci girdi akışı (banka) ve bileşenler.
- `docs/PRIVACY.md`: banka yalnız telefonda ve Mac'te; sunucuya gitmez; yedek yalnız
  kimlik ve sonuç taşır.
- `docs/RUNBOOK.md`: bankayı üretme ve içe aktarma.
- `README.md`: özellik tablosu ve durum.

---

## Ek A — Kitapçık kaydı (ölçülmüş)

"Soru" sütunu PDF'teki şık sayımından; F4'te görünür soru sayısı. Tarihler ilk
sayfadan (2006–2009 ve bazı 2011–2012 dosyalarında ilk sayfada yok).

| Kitapçık dosyası | Tarih | Soru | Anahtar | Aile | Not |
|---|---|---|---|---|---|
| TUS_2006_Ilkbahar_Klinik.pdf | — | 100 | yok | F1 |  |
| TUS_2006_Ilkbahar_Temel.pdf | — | 100 | yok | F1 |  |
| TUS_2006_Sonbahar_Klinik.pdf | — | 100 | yok | F1 |  |
| TUS_2006_Sonbahar_Temel.pdf | — | 100 | yok | F1 |  |
| TUS_2007_Ilkbahar_Klinik.pdf | — | 100 | yok | F1 |  |
| TUS_2007_Ilkbahar_Temel.pdf | — | 100 | yok | F1 |  |
| TUS_2007_Sonbahar_Klinik.pdf | — | 100 | yok | F1 |  |
| TUS_2007_Sonbahar_Temel.pdf | — | 100 | yok | F1 |  |
| TUS_2008_Ilkbahar_Klinik.pdf | — | 100 | yok | F1 |  |
| TUS_2008_Ilkbahar_Temel.pdf | — | 100 | yok | F1 |  |
| TUS_2008_Sonbahar_Klinik.pdf | — | 100 | yok | F1 |  |
| TUS_2008_Sonbahar_Temel.pdf | — | 100 | yok | F1 |  |
| TUS_2009_Ilkbahar_TemelKlinik.pdf | — | 200 | var | F2 |  |
| TUS_2009_Sonbahar_TemelKlinik.pdf | — | 200 | var | F2 |  |
| TUS_2010_Ilkbahar_TemelKlinik.pdf | 18 Nisan 2010 | 200 | var | F2 |  |
| TUS_2010_Sonbahar_TemelKlinik.pdf | 12 Aralık 2010 | 200 | var | F2 |  |
| TUS_2011_Ilkbahar_TemelKlinik.pdf | — | 200 (metin bozuk) | var | F2 | metin katmanı bozuk kodlu |
| TUS_2011_Sonbahar_TemelKlinik.pdf | — | 200 | var | F2 |  |
| TUS_2012_Ilkbahar_Klinik.pdf | — | 120 | var | F3 |  |
| TUS_2012_Ilkbahar_Temel-1.pdf | — | 120 | var | F3 |  |
| TUS_2012_Ilkbahar_Temel-2.pdf | — | 120 | var | F3 |  |
| TUS_2012_Sonbahar_Klinik.pdf | — | 120 | var | F3 |  |
| TUS_2012_Sonbahar_Temel.pdf | — | 120 | var | F3 |  |
| TUS_2013_Ilkbahar_Klinik.pdf | 14 Nisan 2013 | 120 | var | F3 |  |
| TUS_2013_Ilkbahar_Temel.pdf | 14 Nisan 2013 | 120 | var | F3 |  |
| TUS_2013_Sonbahar_Klinik.pdf | 8 Eylül 2013 | 120 | var | F3 | 1 iptal |
| TUS_2013_Sonbahar_Temel.pdf | 8 Eylül 2013 | 120 | var | F3 | 1 iptal |
| TUS_2014_Ilkbahar_Klinik.pdf | 13 Nisan 2014 | 120 | var | F3 | 1 iptal |
| TUS_2014_Ilkbahar_Temel.pdf | 13 Nisan 2014 | 120 | var | F3 | 3 iptal |
| TUS_2014_Sonbahar_Klinik.pdf | 14 Eylül 2014 | 120 | var | F3 | 1 iptal |
| TUS_2014_Sonbahar_Temel.pdf | 14 Eylül 2014 | 120 | var | F3 |  |
| TUS_2015_Ilkbahar_Klinik.pdf | 12 Nisan 2015 | 120 | var | F3 | 5 iptal |
| TUS_2015_Ilkbahar_Temel.pdf | 12 Nisan 2015 | 120 | var | F3 | 2 iptal |
| TUS_2015_Sonbahar_Klinik.pdf | 20 Eylül 2015 | 120 | var | F3 | 7 iptal |
| TUS_2015_Sonbahar_Temel.pdf | 20 Eylül 2015 | 120 | var | F3 | 4 iptal |
| TUS_2016_Ilkbahar_Klinik.pdf | 10 Nisan 2016 | 120 | var | F3 | 2 iptal |
| TUS_2016_Ilkbahar_Temel.pdf | 10 Nisan 2016 | 120 | var | F3 | 1 iptal |
| TUS_2016_Sonbahar_Klinik.pdf | 25 Eylül 2016 | 120 | var | F3 |  |
| TUS_2016_Sonbahar_Temel.pdf | 25 Eylül 2016 | 120 | var | F3 | 1 iptal |
| TUS_2017_Ilkbahar_Klinik.pdf | 22 Nisan 2017 | 120 | var | F3 | 3 iptal |
| TUS_2017_Ilkbahar_Temel.pdf | 22 Nisan 2017 | 120 | var | F3 | 3 iptal |
| TUS_2017_Sonbahar_Klinik.pdf | 27 Ağustos 2017 | 120 | var | F3 | 3 iptal |
| TUS_2017_Sonbahar_Temel.pdf | 27 Ağustos 2017 | 120 | var | F3 | 1 iptal |
| TUS_2018_Ilkbahar_Klinik.pdf | 25 Şubat 2018 | 120 | var | F3 |  |
| TUS_2018_Ilkbahar_Temel.pdf | 25 Şubat 2018 | 120 | var | F3 |  |
| TUS_2018_Sonbahar_Klinik.pdf | 12 Ağustos 2018 | 120 | var | F3 |  |
| TUS_2018_Sonbahar_Temel.pdf | 12 Ağustos 2018 | 120 | var | F3 |  |
| TUS_2019_Ilkbahar_Klinik.pdf | 24 Şubat 2019 | 120 | var | F3 |  |
| TUS_2019_Ilkbahar_Temel.pdf | 24 Şubat 2019 | 120 | var | F3 |  |
| TUS_2019_Sonbahar_Klinik.pdf | 1 Eylül 2019 | 120 | var | F3 |  |
| TUS_2019_Sonbahar_Temel.pdf | 1 Eylül 2019 | 120 | var | F3 |  |
| TUS_2020_Ilkbahar_Klinik.pdf | 23 Şubat 2020 | 120 | var | F3 |  |
| TUS_2020_Ilkbahar_Temel.pdf | 23 Şubat 2020 | 120 | var | F3 |  |
| TUS_2020_Sonbahar_Klinik.pdf | 4 Ekim 2020 | 120 | var | F3 |  |
| TUS_2020_Sonbahar_Temel.pdf | 4 Ekim 2020 | 120 | var | F3 |  |
| TUS_2021_Ilkbahar_Klinik.pdf | 21 Mart 2021 | 120 | var | F3 |  |
| TUS_2021_Ilkbahar_Temel.pdf | 21 Mart 2021 | 120 | var | F3 |  |
| TUS_2021_Sonbahar_Klinik.pdf | 5 Eylül 2021 | 120 | var | F3 |  |
| TUS_2021_Sonbahar_Temel.pdf | 5 Eylül 2021 | 120 | var | F3 |  |
| Klinik_Sinav_1-100 2026.pdf | — | 100 | 100 | F6 yeniden dizim | 2026/2; ÖSYM ile 19/19 |
| TUS_2022_Ilkbahar_Klinik.pdf | 6 Mart 2022 | 12 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2022_Ilkbahar_Temel.pdf | 6 Mart 2022 | 12 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2022_Sonbahar_Klinik.pdf | 4 Eylül 2022 | 12 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2022_Sonbahar_Temel.pdf | 4 Eylül 2022 | 12 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2023_Ilkbahar_Klinik.pdf | 15 Nisan 2023 | 12 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2023_Ilkbahar_Temel.pdf | 15 Nisan 2023 | 12 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2023_Sonbahar_Klinik.pdf | 24 Eylül 2023 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2023_Sonbahar_Temel.pdf | 24 Eylül 2023 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2024-2026_TamSorular_Derleme.pdf | — | 800 (2024/1–2025/2) | 600 (2024/1 yok) | F5 Tusdata | ÖSYM ile 58/58 |
| TUS_2024_Ilkbahar_Klinik.pdf | 17 Mart 2024 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2024_Ilkbahar_Temel.pdf | 17 Mart 2024 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2024_Sonbahar_Klinik.pdf | 18 Ağustos 2024 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2024_Sonbahar_Temel.pdf | 18 Ağustos 2024 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2025_Ilkbahar_Klinik.pdf | 23 Mart 2025 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2025_Ilkbahar_Temel.pdf | 23 Mart 2025 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2025_Sonbahar_Klinik.pdf | 17 Ağustos 2025 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2025_Sonbahar_Temel.pdf | 17 Ağustos 2025 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2026_Ilkbahar_Klinik.pdf | 15 Mart 2026 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2026_Ilkbahar_Temel.pdf | 15 Mart 2026 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2026_Sonbahar_Klinik.pdf | 23 Ağustos 2026 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| TUS_2026_Sonbahar_Temel.pdf | 23 Ağustos 2026 | 10 görünür | görünenlerde | F4 ÖSYM kısmi | diğerleri boş yuva |
| Temel_Bilimler_Sinav_1-100.pdf | — | 100 | 100 | F6 yeniden dizim | 2026/2; ÖSYM ile 19/19 |

## Ek B — Maliyet dökümü

| Kalem | Hesap | Tutar |
|---|---|---|
| A7 ders/konu | 8.430 soru × ~250 girdi token + 340 çağrı × ~2k prompt ≈ 2,8M girdi × $0,2/M + ~0,3M çıktı × $1,2/M | ≈ $0,9 (+ düşük reasoning ≈ $0,5) |
| A5 onarım | ~250 soru × kırpıntı ($0,005) | ≈ $1,3 |
| A6 2011/1 | 36 sayfa × ~$0,008 | ≈ $0,3 |
| V6 sağlama | ~60 kağıt × 15 soru × ~$0,001 | ≈ $0,9 |
| **Tek seferlik toplam** | | **≈ $3–5** |
| Kullanım (Faz A) | Çağrı yok | **$0** |
| Faz B `/api/exam-link` (açılırsa) | ~$0,001 × günlük yanlış sayısı | ≈ $0,5/ay |
| Faz C güncellik bayrağı | ~4.000 soru × 2 aile | ≈ $8–15 tek sefer |

## Ek C — Ders eşlemesi

| ÖSYM dersi (kitapçık) | Uygulama dersi (`subject_topics.json`) | Not |
|---|---|---|
| Anatomi | Anatomi | |
| Histoloji-Embriyoloji | Fizyoloji | Konu listesinde "…HistoFizyolojisi", "Genel Embriyoloji", "Baş Boyun Embriyolojisi" |
| Fizyoloji | Fizyoloji | |
| Biyokimya | Biyokimya | |
| Mikrobiyoloji | Mikrobiyoloji | |
| Patoloji | Patoloji | |
| Farmakoloji | Farmakoloji | |
| İç Hastalıkları / Dahiliye | Dahiliye | |
| Pediatri | Pediatri | |
| Cerrahi / Genel Cerrahi | Genel Cerrahi | |
| Kadın-Doğum | Kadın Hastalıkları ve Doğum | |
| Küçük Stajlar | Küçük Stajlar | F1'de yok |

## Ek D — Örnek kayıt

```json
{
  "id": "TUS-2013-1-T-001",
  "paperId": "TUS-2013-1-T",
  "number": 1,
  "stem": "…",
  "options": ["…", "…", "…", "…", "…"],
  "answer": 4,
  "answerSource": "osym",
  "status": "ok",
  "osymSubject": "Anatomi",
  "subject": "Anatomi",
  "topic": null,
  "figure": "none",
  "provenance": [{ "path": "pdf/3f2a….pdf", "page": 3, "bbox": [56.7, 112.4, 290.1, 268.0] }],
  "altProvenance": [],
  "textQuality": "native",
  "similarTo": []
}
```
