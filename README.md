# Çizgi — Kişisel Tıbbi Hafıza Uygulaması

Kitapta işaretlediğin tıbbi bilgiyi fotoğraftan yakalayan kişisel bir iOS
uygulaması. İşaret altı çizgi, fosforlu kalem, yıldız, daire, kutu ya da kenara
düşülmüş el yazısı bir not olabilir. Uygulama sayfayı bir vision modeline
okutup öğrenme kartlarına dönüştürür, sonra **FSRS-6** ile bilgiyi unutmadan
önce yeniden sorar.

Uygulama tek kişilik: sahibi TUS'a hazırlanan Türkçe konuşan bir hekim ve
uygulama yayınlanmayacak. Tek çalışma kaynağı olmadığı için modelin hata riski
bilerek kabul edildi. Şüpheli kartlar bu yüzden engellenmiyor, işaretleniyor
([ADR-005](docs/ADR-005-kisisel-vision-yeniden-tasarim.md)).

> **Yeni bir oturuma (Claude Code ya da başka biri) başlıyorsan önce
> [`CLAUDE.md`](CLAUDE.md)'yi oku.** Güncel durum, açık kararlar, cihaz
> doğrulama listesi ve sıradaki iş orada tutuluyor. Bu README projeyi özetler.

Ürün şartnamesi:
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md).
Kod yorumlarındaki §0.5, §19.3 gibi bölüm numaraları bu belgeye atıf yapar.
Ancak ANA-PLAN'ın tıbbi güvenlik omurgası, kişisel kullanım için Faz 6
pivotunda (2026-08-05) bilerek gevşetildi. Çelişki olduğunda ADR-005 ve
sonrasındaki ADR'ler geçerlidir.

## Nasıl çalışır

```text
kamera / galeri
  → çift sayfa mı? (Sol / Sağ / Tümü) → "bu sayfayı daha önce çektin mi?" (dHash)
  → yerel kuyruk: 3 sayfa paralel işlenir, geçici hatalar kendiliğinden yeniden denenir
  → POST /api/jobs   Vercel → Supabase iş kuyruğu → OpenAI vision (Structured Outputs)
  → GET  /api/jobs   telefon sonucu yoklar; iş kimliği = sayfa kimliği
  → kartlar onay beklemeden aktif desteye girer (SwiftData, telefonda)
  → Tekrar (FSRS-6)  +  Egzersiz (ayrı puanlanır, FSRS'i korumalı bir köprüyle besler)
```

- **Model, kullanıcının neyi önemsediğini kendisi okur.** İşaretler bir öncelik
  merdiveniyle sıralanır: el yazısı → sembol işaretleri (yıldız, artı, ünlem,
  ok, daire, kutu) → altı çizili → fosforlu. Prompt kuralları ve sıralama
  testlerle kilitli (`backend/prompts/cardGeneration.ts`).
- **Üretim asenkron.** Telefon sayfayı bırakır ve birkaç saniye içinde 202
  yanıtı alır. Üretim sunucuda sürer. Uygulama beklerken kapansa bile sonraki
  açılışta biten iş bulunur ve aynı sayfa iki kez ücretlendirilmez
  ([ADR-006](docs/ADR-006-supabase-is-kuyrugu.md)).
- **Veri telefonda yaşar.** Supabase yalnızca bir iş kuyruğu ve geçici görüntü
  deposudur: görüntü iş bitince, sonuç metni 60 gün sonra silinir
  ([PRIVACY](docs/PRIVACY.md)).
- **Zamanlama deterministiktir.** FSRS-6, Egzersiz köprüsü ve kapsama
  hesabı LLM kullanmayan koddadır. Model yalnızca görüntü okumak ve içerik
  üretmek için kullanılır (ANA-PLAN §0.8).

## Uygulamada neler var

| Sekme | Ne yapar |
|---|---|
| **Egzersiz** (açılış sekmesi) | FSRS'ten ayrı puanlanan pratik. Kurulum altı boyutta filtrelenir: ders, konu, kart tipi, kart durumu, eklenme tarihi ve FES. Bütçe kart sayısı ya da süre olarak seçilir. "FES kartlar" hızlı başlangıcı, zayıf kartları getirir. Oturum sırasında kart askıya alınabilir. FSRS'i yalnızca `EarlyPractice` köprüsüyle besler: vadesinden önce doğru cevaplanan kart kısmi kredi, yanlış cevaplanan kart yumuşak bir düşüş alır ([ADR-007](docs/ADR-007-egzersiz-fsrs-koprusu.md), [ADR-008](docs/ADR-008-fes-sicili.md)). |
| **Tekrar** | FSRS-6 oturumu. Her not düğmesinin altında bir sonraki aralık görünür ("Zor · 8 gün"). Oturum sırasında sekme çubuğu gizlenir ve "Bitir" tek çıkış olur. Tekrar ve Egzersiz aynı kart yüzünü (`ReviewCardFace`) kullanır. Soru ekranının boş alanında dersin silik gravürü durur. |
| **Yakala** | Kamera ya da galeri. Galeriden gelen fotoğraf JPEG'e ve düz yöne çevrilir. Çift sayfa kırpılır, ders seçilir. Kuyruk ekranında bitmiş bir sayfa açılınca kartlar düzenlenebilir, kaydırılarak silinebilir, elle kart eklenebilir. Aynı ekranda **"Kartlaşmamış işaretler"** listesi ve **"Kapsama denetle"** düğmesi bulunur. |
| **Bilgilerim** | Ders → konu → kart gezintisi ve Türkçe'ye duyarlı arama. **"Gözden geçir"** listesi şüpheli (`lowConfidence`) kartları toplar; bu kartlar için Gemini'den **ikinci görüş** istenebilir. Ayrıca FES kartları, en çok unutulanlar, istatistik ekranı ve Bilgi Haritası (11 ders, 143 konu) burada. |
| **Ayarlar** | Backend bağlantısı; yakalama ayarları (varsayılan ders, sayfa başına kart tavanı, beş şıklı kart modu); görünüm (vurgu rengi derse, saate göre ya da sabit); günlük hatırlatıcı ve yeni kart limiti; yedek alma ve geri yükleme; **Kullanım** (çağrı başına gerçek USD ve token dökümü). |

Bütün uygulamayı kesen özellikler:

- **Beş şıklı (TUS tipi) kart** (§13.3). Yanlış şık doğrudan "Unuttum"
  sayılır. Doğru şıkta Zor, İyi ya da Kolay sorulur. Mod Ayarlar'dan
  Kapalı/Karışık/Hepsi olarak seçilir
  ([FAZ7-PLAN](docs/FAZ7-PLAN-coktan-secmeli.md)).
- **Kapsama sözleşmesi.** Model sayfada gördüğü işaretleri bir listeye yazar ve
  her kartı bir işarete bağlar. Hiçbir karta dönüşmemiş işaretleri sunucu
  deterministik olarak bulur. `/api/coverage` ise Gemini ile ikinci, bağımsız
  bir okuma yapar ([PLAN-kapsama-sozlesmesi](docs/PLAN-kapsama-sozlesmesi.md)).
- **FES sicili.** Tekrar ve Egzersiz cevapları, kalıcı ve ağırlıklı bir
  zayıflık skorunu besler. Skor hiçbir zamanlama kararını etkilemez
  ([ADR-008](docs/ADR-008-fes-sicili.md)).
- **Yedek v9.** Dışa aktarma JSON'u görüntü içermez. Geri yükleme ise
  isteğe bağlı sayfa fotoğraflarını da kurar. Böylece dışarıda üretilmiş
  kartlarda da "Kaynağı göster" sayfa fotoğrafını gösterir
  ([ADR-011](docs/ADR-011-yedek-v9-sayfa-fotografi.md)).
- **Tasarım dili "Kemik & Oxblood".** Kemik rengi kâğıt, lacivert gece modu,
  gölge yerine 1 px çizgi. Vurgu rengi o an çalışılan dersin rengidir (on bir
  derslik bir renk yayı). Serif yazı yalnızca üç yerde kullanılır: kart
  sorusu, boş durum başlığı ve büyük sayılar. Tek kaynak:
  `ios/App/Theme/CizgiTheme.swift`.

## Mevcut durum (2026-09-25)

Son kod değişikliği 2026-09-14'te `main`'e girdi (PR #50). Ayrıntılı tablo ve
cihaz doğrulama listesi [`CLAUDE.md`](CLAUDE.md)'de.

| İş | Durum |
|---|---|
| Faz 0–5: iskelet, OCR ölçümü, kart üretimi, FSRS-6, sertleştirme | ✅ Tamam. Faz 2'nin deterministik OCR hattı 2026-08-09'da koddan silindi; kaydı `docs/HISTORY.md`'de |
| Faz 6: vision öncelikli yeniden tasarım + Supabase iş kuyruğu | ✅ Tamam ve cihazda doğrulandı |
| Galeriden fotoğraf, çift sayfa kırpma | ✅ Cihazda doğrulandı |
| Faz 7: beş şıklı kart | 🟡 Kod `main`'de. **A6 açık:** çeldiricilerin kalitesi gerçek sayfalarla denenmedi |
| Ders/konu sınıflandırması, Egzersiz, Bilgi Haritası | ✅ Tamam |
| Egzersiz → FSRS köprüsü (ADR-007) | ✅ Cihazda doğrulandı |
| FES sicili ve altı boyutlu Egzersiz filtresi (ADR-008) | 🟡 `main`'de; cihazda doğrulanmadı |
| İkinci görüş (Gemini) ve çağrı başına maliyet defteri | ✅ Cihazda doğrulandı |
| Sayfa detayında kart ekleme, düzenleme ve silme | 🟡 `main`'de; cihazda doğrulanmadı |
| Kopya kartların askıya alınması (117 kart) | ✅ Cihazda doğrulandı |
| Kapsama sözleşmesi (şema v2.3 + `/api/coverage`) | 🟡 `main`'de; cihazda doğrulanmadı. Açmadan önce `GEMINI_USD_PER_MILLION_*` Vercel'e girilmeli |
| Tasarım dili "Kemik & Oxblood", yeni Tekrar ekranı | 🟡 Simülatörde doğrulandı; gerçek cihazda bakılmadı |
| Bilgilerim gezintisi, istatistik, günlük hatırlatıcı, ders gravürleri, kaynak fotoğrafında yakınlaştırma (2026-09-14) | 🟡 Simülatörde doğrulandı; gerçek cihazda bakılmadı |
| Yedek biçimi v9: geri yüklemede sayfa fotoğrafı (ADR-011) | 🟡 Simülatörde uçtan uca doğrulandı; gerçek cihazda bakılmadı |
| ~~Kavram destesi~~ (ADR-010) | ⛔️ 2026-09-14'te tamamen kaldırıldı (kod, şema sütunu, cihazdaki veri) |
| ~~Karanlık Harita~~ (ADR-009) | ⛔️ 2026-09-09'da tamamen kaldırıldı |

**Canlı model:** `gpt-5.6-luna` ve `reasoning_effort=high`. Seçim üç turluk
kör karşılaştırmaya dayanıyor: kalite `sol@low` ile yakın, maliyet 7,5 kat
düşük. İkinci görüş ve kapsama denetimi, bilerek başka bir model ailesi olan
Gemini ile yapılıyor
([PLAN-model-karsilastirma](docs/PLAN-model-karsilastirma.md)).

**CI:** GitHub Actions kotası 2026-08-14'ten beri dolu. Üç iş akışı da bir
runner'a atanmadan kırmızı dönüyor. Bu kod hakkında bir sinyal değil. Kota
dönene kadar tek kapı yerel testler (aşağıda).

## Teknoloji

| Katman | Kullanılan |
|---|---|
| iOS | Swift, SwiftUI, SwiftData, iOS 17+. Mantık `CizgiCore` Swift paketinde, arayüz `App`'te. Proje dosyası XcodeGen ile üretiliyor |
| Backend | TypeScript, Node 22, Vercel Functions (`kornokta-nu.vercel.app`) |
| İş kuyruğu | Supabase Postgres (`jobs` tablosu) + Storage (`page-uploads` kovası). RLS açık, policy yok; yalnızca `service_role` erişebiliyor |
| Modeller | OpenAI Responses API: vision kart üretimi. Google Gemini: ikinci görüş ve kapsama denetimi |
| Değerlendirme | Python 3.11, pytest: FSRS-6 referansı, sözleşme senkron testleri, model karşılaştırma araçları |

## Repo yapısı

```text
├── ios/
│   ├── CizgiCore/        Swift paketi: modeller, kuyruk, FSRS-6, Egzersiz, yedek (Mac'te `swift test`)
│   ├── App/              SwiftUI uygulaması: Features/{Capture, ProcessingQueue, Review, Library, Settings}, Theme/
│   ├── Resources/        Gömülü yazı tipi (Libre Caslon Text, OFL)
│   ├── spikes/           AppleVisionSpike: Faz 0 ölçüm aracı (tarihsel)
│   └── project.yml       XcodeGen spec (`.xcodeproj` commit edilmez)
├── backend/
│   ├── api/              Tek Vercel fonksiyonu (`index.ts`) ve uçları: jobs, cards-vision, second-opinion, coverage
│   ├── providers/        OpenAI, Gemini, Supabase iş deposu, kart kapısı, kapsama, beş şık, Türkçe normalizasyon
│   ├── prompts/          Sürümlü sistem promptları
│   ├── schemas/          LLM çıktı sözleşmesi (§14) ve ders/konu şablonu (11 ders, 143 konu)
│   ├── scripts/          Yerel sunucu, cihaz tokenı, tek çağrı denemesi, model karşılaştırma
│   ├── supabase/         `jobs` tablosu migration'ları
│   └── config.ts         Model, eşik ve fiyat ayarlarının tek yeri (§0.6)
├── evals/
│   ├── fsrs/             FSRS-6 Python referansı (Swift portunun kilidi)
│   ├── shared/           İki dilin paylaştığı test vakaları
│   ├── tests/            pytest: sözleşme senkronu, FSRS, ders renk yayı…
│   ├── card_quality/     §23.3 kart kalite rubriği
│   ├── model_compare/    Kör model karşılaştırmasının puan birleştiricisi
│   ├── tools/            Ders gravürlerini üreten `engrave.py`
│   ├── ocr_eval/, spikes/  Faz 0–2 OCR ve işaret tespiti araçları (tarihsel, testleri hâlâ koşuyor)
│   ├── fixtures/         Gerçek sayfa fotoğrafları: YEREL, commit edilmez
│   └── reports/          Karşılaştırma çıktıları: YEREL, commit edilmez
├── docs/                 ADR'ler, planlar, gizlilik, runbook, geçmiş
├── .github/workflows/    CI: backend, evals, ios
├── CLAUDE.md             Güncel durum ve sıradaki iş (her oturumun başlangıç noktası)
└── Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md   Ürün şartnamesi
```

## Çalıştırma

Ayrıntı: [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

```bash
python -m pytest evals -q                       # eval ve sözleşme testleri (kökten)
cd backend && npm install && npm test           # vitest
cd backend && npm run typecheck                 # tsc --noEmit
cd backend && npm run serve                     # yerel sunucu, 127.0.0.1:8787
cd ios/CizgiCore && swift test                  # yalnızca Mac'te
cd ios && xcodegen generate && open Cizgi.xcodeproj   # App'e dosya eklendiyse generate şart
```

Backend kurulumu ve Vercel'e dağıtım için [`backend/README.md`](backend/README.md),
iOS derlemesi ve cihazda deneme için [`ios/README.md`](ios/README.md).
Gerekli ortam değişkenleri `backend/.env.example`'da listeli.

## Belgeler

**Güncel yön:**

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): akış ve bileşenler
- [ADR-005](docs/ADR-005-kisisel-vision-yeniden-tasarim.md): kişisel, vision öncelikli pivot
- [ADR-006](docs/ADR-006-supabase-is-kuyrugu.md): asenkron iş kuyruğu
- [ADR-007](docs/ADR-007-egzersiz-fsrs-koprusu.md): Egzersiz → FSRS köprüsü
- [ADR-008](docs/ADR-008-fes-sicili.md): FES sicili
- [ADR-011](docs/ADR-011-yedek-v9-sayfa-fotografi.md): yedek v9
- Planlar: [PLAN-kapsama-sozlesmesi](docs/PLAN-kapsama-sozlesmesi.md), [PLAN-model-karsilastirma](docs/PLAN-model-karsilastirma.md), [PLAN-egzersiz-bilgi-haritasi](docs/PLAN-egzersiz-bilgi-haritasi.md), [PLAN-galeriden-foto](docs/PLAN-galeriden-foto.md), [FAZ6-PLAN](docs/FAZ6-PLAN.md), [FAZ7-PLAN](docs/FAZ7-PLAN-coktan-secmeli.md)
- İşletme: [PRIVACY](docs/PRIVACY.md), [RUNBOOK](docs/RUNBOOK.md), [MALIYET-OLCUMU](docs/MALIYET-OLCUMU.md), [OPENAI-GEMINI-KURULUM](docs/OPENAI-GEMINI-KURULUM.md), [FIGURES-SOURCES](docs/FIGURES-SOURCES.md)

**Tarihsel.** Bu belgeler bugünkü davranışı anlatmaz, yalnızca kararların
gerekçesini taşır: [`docs/HISTORY.md`](docs/HISTORY.md), ADR-001…004
(Türkçe normalizasyon ve OCR dönemi), ADR-009 (Karanlık Harita), ADR-010
(kavram destesi), `FAZ0`–`FAZ5` belgeleri, `MAC-ADIMLARI*`,
`GOOGLE-CLOUD-KURULUM`, `GOLD-SET-GUIDE`, `COKLU-FOTO-TIMEOUT`, `MODEL-CARD`.

Dil kuralı: belgeler ve kullanıcıya görünen metin Türkçe; kod
tanımlayıcıları ve yorumlar İngilizce.

## Güvenlik kuralları (bağlayıcı; ANA-PLAN §0, §7.3, §24.6)

- **API anahtarı repoya ya da iOS uygulamasına asla konmaz.** Anahtarlar
  yalnızca backend ortam değişkenlerinde (Vercel ya da gitignore'lu yerel
  `.env`) durur.
- `DEVICE_TOKEN` yalnızca iki yerde durur: backend ortam değişkeni ve
  telefonun Keychain'i. Üçüncü kopya yok.
- `SUPABASE_SERVICE_ROLE_KEY` RLS'i tamamen atlar. Yalnızca yerel `.env` ve
  Vercel proje ayarlarında durur. Telefon Supabase'i hiç görmez.
- `evals/fixtures/` içine **telifli kitap sayfası commit edilmez**.
- Sunucu loglarında görüntü içeriği, kart metni ya da tam sayfa metni
  saklanmaz.
- Hasta verisi hiçbir akışta işlenmez; içerik yalnızca kişisel eğitim içindir.
