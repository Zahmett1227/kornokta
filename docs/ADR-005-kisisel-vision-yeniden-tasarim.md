# ADR-005 — Kişisel kullanım için vision-öncelikli yeniden tasarım (B)

**Durum:** Kabul edildi (2026-08-05) — uygulama sahibinin kararı.

**İlgili:** [`docs/FAZ6-PLAN.md`](FAZ6-PLAN.md) (uygulama planı), bu kararın
gevşettiği ilkeler: ANA-PLAN §0.5, §10, §12.1, §19; süperseded mimari:
[`ADR-002`](ADR-002-birincil-ocr-secimi.md), [`ADR-003`](ADR-003-ocr-uzlastirma-kapisi-daraltildi.md),
[`ADR-004`](ADR-004-annotation-grounding.md).

## Bağlam

Uygulama sahibi, gerçek cihazda kullandıktan sonra üç net şikâyet bildirdi ve
kod tabanı bu şikâyetlere karşı dört boyutta (onay/sürtünme zinciri, işaret
tespiti, kart üretimi, ürün felsefesi) derinlemesine incelendi. Bulgular:

1. **"Her fotoğrafta onayım gerekiyor."** İki kapı üst üste biniyor: (A)
   sayfadaki tek bir el yazısı grubu bile tüm sayfayı fotoğraf-onay ekranına
   sokuyor (`CapturePipeline.swift:442`, `AnnotationGrouper.swift:597`); (B)
   boş olmayan her `explanation` kartı onaya yükseltiyor (`cardGate.ts:146`) ve
   v1.1 promptu neredeyse her karta explanation ekliyor. İkisi de §0.5/§10.4/
   §19.2'nin bilinçli sonucu.
2. **"İşaretlemeler çok alakasız."** İşaret tespiti renk/geometri tabanlı ve
   **seyrek, ayrık işaret** varsayıyor. Kullanıcının gerçek tarzı ise sayfanın
   %70–80'ini üç renkle fosforlamak + satır aralarına el yazısı not almak +
   terimleri daire/yıldız/T ile işaretlemek. Ek olarak: **turuncu renk hiç
   tespit edilmiyor** (config'teki hue aralıklarında pembe ile sarı arasındaki
   ölü bölgeye düşüyor); dairelenmiş terimler, semboller ve el yazısı kenar
   notları hiçbir tespit kategorisine girmiyor; işaret eşikleri hiç kalibre
   edilmedi (Faz 2 altın-set atlandı).
3. **"Karttan üretim kalitesi düşük."** Tavan modelde değil felsefede: cevabın
   **yalnızca kaynaktan** çıkması zorunlu (§12.1) ve kaynakta olmayan kritik
   token içeren kart reddediliyor (`cardGate.ts:118`). Yani dış bilgiyle
   birleştiren, "ders çalışmayı kısaltan" sentez kartlar mimari olarak yasak.

Bu üç şikâyetin ortak kökü **ANA-PLAN'ın tıbbi-güvenlik omurgasıdır**: bir
LLM'in "sayfada ne önemli / ne doğru" kararına güvenmemek için kurulmuş
deterministik piksel tespiti + OCR uzlaştırması + kritik-token kapıları + onay
akışı. Bu omurga korunduğu sürece "çek, dokunma, otomatik iyi kart al" hedefi
yapısal olarak imkânsız.

Uygulama sahibi bilinçli üç karar verdi:

- **Hata riskini kabul ediyor.** Bu uygulama tek çalışma kaynağı değil; arada
  çıkabilecek hatalı tıbbi bilgi riski göze alınıyor.
- **Yayınlanma yok.** Tamamen kişisel, tek kullanıcılık kullanım.
- **OpenAI'de kalınıyor.** LLM sağlayıcısı değişmiyor.

## Karar

Ürün, **kişisel kullanım için vision-öncelikli bir mimariye** geçirilir (B).
Ana akış:

> **Fotoğrafı çek → tüm işaretli sayfayı OpenAI'nin vision modeline gönder →
> model fosforları, altı çizilenleri, daireleri ve el yazısı notları kendisi
> okuyup kullanıcının önemsediği kısımlara odaklı kartlar üretsin → kartlar
> onaysız doğrudan desteye girsin → FSRS ile tekrar edilsin.**

Bunun sonucu olarak aşağıdaki ANA-PLAN ilkeleri **kişisel kullanım için
gevşetilir/süperseded edilir**:

1. **§0.5 (sessiz düzeltme yasağı) artık sert bir kapı değildir.** Model,
   gördüğü sayı/birim/olumsuzluğu kendi okumasına göre karta yazar; kullanıcı
   onayı **varsayılan olarak istenmez**. Belirsizlik, kartın içinde
   görünür kılınabilir (ör. modelin emin olmadığını belirtmesi) ama akışı
   durdurmaz.
2. **§12.1 (cevap yalnızca kaynaktan) kaldırılır.** Model, kaynağı temel alıp
   **dış bilgiyle zenginleştirebilir** — mekanizma, ayırt etme, klinik bağlam.
   "Kaynağa sadık mod" ile "zenginleştirilmiş mod" ayrımı ortadan kalkar;
   zenginleştirme varsayılan olur.
3. **§10 (Apple Vision + Google Document AI + uzlaştırma) birincil metin yolu
   olmaktan çıkar.** Metni artık vision modeli okur. Google Document AI ve
   iki-motor uzlaştırması ana akıştan çıkarılır (kod korunur, çağrılmaz).
4. **§9 (deterministik cihaz-üstü işaret tespiti) ana akıştan çıkar.** İşareti
   artık vision modeli görsel olarak yorumlar. Renk eşiği/geometri motoru ve
   annotation-grounding (ADR-004) ana akışta kullanılmaz.
5. **§19 (kart kalite kapısı + zorunlu onay) sertlikten çıkar.** `cardGate`
   varsayılan olarak **auto-accept** eder; onay isteğe bağlı, opsiyonel bir
   "sonradan gözden geçir/düzenle/sil" adımına iner.

**Değişmeyen ilkeler (korunur):**

- **Güvenlik/gizlilik (§0.7, §7.3):** API anahtarı repoda/istemcide olmaz;
  görüntü ve tam metin sunucu logunda saklanmaz; cihaz tokenı yalnız iki yerde
  durur; hasta verisi işlenmez; içerik kişisel eğitim içindir.
- **Deterministik tekrar (§0.8, P6):** FSRS-6 tekrar planlaması LLM'siz,
  deterministik kodda kalır. LLM yalnız görüntü yorumlama ve içerik üretiminde.
- **Model kimlikleri/eşikler merkezî config'te (§0.6, §11.3):** koda gömülmez.
- **Kişisel kullanım sadeliği (P7):** hesap, paywall, sosyal özellik yok.

## Ne yeniden kullanılır, ne değişir, ne kaldırılır

Ayrıntılı dosya bazlı döküm [`FAZ6-PLAN.md`](FAZ6-PLAN.md)'dedir. Özet:

- **Korunur (hazır, test edilmiş):** FSRS-6 tekrar motoru (Faz 4), SwiftData
  veri modeli ve depolama, kart/deste ve tekrar arayüzleri, kamera/yakalama
  arayüzü, Vercel backend iskeleti + cihaz-token doğrulaması, `input_image`
  ile zaten var olan OpenAI vision çağrısı (`openai.ts`).
- **Değişir:** kart üretim promptu (kaynağa-sadıktan → işaret-odaklı,
  zenginleştirmeli vision okumasına); `/api/cards` sözleşmesi (ham işaretli
  sayfayı kabul et, `cleanText` zorunluluğunu kaldır); `cardGate` (varsayılan
  auto-accept); iOS yakalama akışı (tespit/gruplama/onay yok, doğrudan gönder).
- **Kaldırılır/ana akıştan çıkar (kod silinmez, çağrılmaz):** cihaz-üstü
  `MarkerDetection/`, `Annotation/` grounding, `OCRSnapshot`, `ConfirmationView`
  akışı, `needsReview` yönlendirmesi; backend `documentAI.ts`/`reconcile.ts`/
  `gate.ts` ana akıştan çıkar.

## Sonuçlar

- Ana akış "çek ve geç" olur: temiz sayfada çoğunlukla hiç dokunmadan kartlar
  desteye girer. Bu, ANA-PLAN §2.2/§2.3/§5.1'in orijinal "en az sürtünme"
  vaadine döner — ama onu güvenlik kapılarıyla değil, güvenlik kapılarını
  kaldırarak sağlar.
- Karşılığında ürün **tıbbi-güvenli, kaynağa-sadık bir araç olmaktan çıkar**;
  hata riski bilinçli olarak kullanıcıya geçer. Bu, ANA-PLAN §0 talimat-2'nin
  ("genel amaçlı flashcard üreticisine dönüştürme") kişisel kullanım için
  **bilinçli olarak iptalidir**. Yayınlanma olmadığı için bu kabul edilebilir.
- Deterministik motorların (kritik token, işaret tespiti, uzlaştırma) çift-dilli
  (Python + TS/Swift) anti-drift disiplini ana akış için gereksizleşir; ilgili
  testler ana akıştan ayrılır ama kod referans olarak repoda kalır.
- En büyük kalan belirsizlik kodda değil **prompt kalitesindedir**: vision
  modelinin (a) yoğun-işaretli sayfada "sadece önemsenen kısmı" seçmesi ve (b)
  Türkçe el yazısı notları doğru okuması, gerçek sayfalarla iteratif olarak
  ölçülmelidir (FAZ6-PLAN §B3). Bu ADR o ölçümün yerine geçmez.
- ~~Geri dönüş mümkün: eski deterministik akış kodu silinmediği için, istenirse
  "güvenli mod" bir config bayrağıyla geri getirilebilir (FAZ6-PLAN'da opsiyonel).~~
  **Güncelleme (2026-08-09):** kullanıcı kararıyla ölü kod tıraşlandı —
  deterministik hattın kodu (backend OCR/uzlaştırma/Gemini, iOS işaret
  tespiti/grounding/onay ekranı) artık repoda değil. Geri dönüş hâlâ mümkün
  ama bir bayrak değil: tıraş commit'inin (`git log`'da "Ölü kodu tıraşla")
  revert'i. Bu ADR'nin karar ve gerekçe kaydı değişmeden geçerli.
