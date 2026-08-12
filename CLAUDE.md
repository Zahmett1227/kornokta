# Çizgi — proje durumu (yeni oturum için)

Bu dosya her yeni Claude Code oturumunun başında otomatik okunur. Amacı: bir
önceki oturumun hafızasını taşımadan, buradan devam edilebilmesi. **Yalnız
güncel durumu taşır** — oturum-tarihi kayıtları ve süperseded mimarinin
ayrıntıları [`docs/HISTORY.md`](docs/HISTORY.md)'de.

## Proje ne

Tek kullanıcılık (sahibi için) iOS uygulaması: kitapta işaretlenen (altı
çizili/fosforlu/dairelenmiş/yanına not alınmış) tıbbi bilgiyi fotoğraftan
yakalar, OpenAI vision modeline okutup zenginleştirilmiş öğrenme kartlarına
dönüştürür, FSRS-6 ile tekrar ettirir. Kullanıcı Türkçe konuşan bir TUS
öğrencisi/hekim.

**Tüm ürün/mimari/kalite kararlarının kaynağı:**
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md).
Bölüm numaralarına (§0.5, §19.3 gibi) kod yorumlarında sürekli atıf yapılır.
Ancak ANA-PLAN'ın tıbbi-güvenlik omurgası Faz 6 pivotuyla kişisel kullanım
için bilinçle gevşetildi — güncel kararlar ADR-005/006/007'dedir ve ANA-PLAN'ın
üstündedir.

Dokümantasyon ve kullanıcıyla iletişim **Türkçe**; kod tanımlayıcıları ve
yorumları **İngilizce**.

## Güncel yön — Faz 6 / vision-öncelikli (pivot: 2026-08-05)

Ana akış: *işaretli sayfa fotoğrafını doğrudan OpenAI vision modeline gönder →
model kullanıcının önemsediği kısmı kendisi okuyup zenginleştirilmiş kartları
üretsin → kartlar onaysız doğrudan desteye girsin → FSRS ile tekrar edilsin.*

- **Neden ve hangi ilkeler gevşedi:** [`docs/ADR-005`](docs/ADR-005-kisisel-vision-yeniden-tasarim.md)
- **Asenkron iş kuyruğu:** [`docs/ADR-006`](docs/ADR-006-supabase-is-kuyrugu.md)
- **Egzersiz→FSRS köprüsü:** [`docs/ADR-007`](docs/ADR-007-egzersiz-fsrs-koprusu.md)
- **Kullanıcı kararları:** hata riski kabul edildi (uygulama tek çalışma
  kaynağı değil), yayınlanma yok (tamamen kişisel), OpenAI'de kalınıyor.

**Önemli (2026-08-09):** Faz 6 öncesi deterministik hat (Apple Vision OCR,
cihaz üstü işaret tespiti, Google Document AI, uzlaştırma, grounding, onay
ekranı) uzun süre "geri dönüş için diskte" durduktan sonra kullanıcı kararıyla
**koddan silindi**. Geri dönüş = tıraş commit'inin (`git log`'da "Ölü kodu
tıraşla") revert'i. O mimarinin kaydı ADR-002/003/004 + `docs/HISTORY.md`'de.

### Ana akış bugün nasıl işliyor

1. **Yakala:** işaretli sayfa fotoğrafı — kameradan ya da galeriden (galeriden
   gelen her fotoğraf tek noktada JPEG'e ve düz yöne normalize edilir,
   `ImportedImage`) → **çift sayfa mı?** (`PageSplit`, en/boy oranı; evetse tek
   dokunuşluk "Sol/Sağ/Tümü" adımı) → dHash ile "bu sayfayı daha önce çektin
   mi?" sorusu (reddetmez, **sorar**) → bayt diske yazıldıktan sonra kuyruğa
   girer.
2. **Kuyruk:** `ProcessingQueue` sayfaları 3'lü paralel işler; işlem sürerken
   ekran kilidini ve bir arka plan assertion'ını tutar, geçici hataları
   `nextAttemptAt`'e uyarak kendiliğinden tekrar dener.
3. **Üretim (asenkron, ADR-006):** `POST /api/jobs` sayfayı Supabase Storage'a
   yazar, satırı `queued` yapar ve saniyeler içinde 202 döner; üretim yanıttan
   sonra `waitUntil` altında sürer. Telefon `GET /api/jobs?ids=` ile yoklar.
   **İş kimliği = sayfa kimliği** — uygulama beklerken öldürülse bile bir
   sonraki açılış biten işi bulup alır (ikinci üretim ücreti yok). Görüntü iş
   bitince, sonuç metni **60 gün** sonra silinir (docs/PRIVACY.md).
4. **Kartlar onaysız** `.active` olarak SwiftData'ya girer ve FSRS-6 ile
   tekrar edilir. "Kaynağı göster" sayfa fotoğrafını ve modelin okuduğu metni
   gösterir; kart düzenleme FSRS geçmişine dokunmaz.
5. **Kartların bir kısmı beş şıklı** olabilir (§13.3, Ayarlar'daki mod). FSRS
   eşlemesi asimetrik: yanlış şık = Unuttum; doğru şıkta Zor/İyi/Kolay.
6. **Şüpheli kartlar bloklanmaz, işaretlenir:** `lowConfidence` kartlar
   Bilgilerim'de "Gözden geçir" bölümünde listelenir. Böyle bir kartın
   detayında **"İkinci görüş iste"** düğmesi var (2026-08-11): telefondaki
   orijinal sayfa + kart `/api/second-opinion`'a gider, **Gemini** (bilinçli
   olarak kartı üreten OpenAI'den bağımsız aile; §10.4'ün pivotu sağ çıkan
   fikri) bölgeyi yeniden okuyup `supports|contradicts|unclear` verdikti döner.
   Yalnız istek üzerine harcar; cevabın metni kaydedilmez (ekrandan çıkınca
   gider) ama maliyeti kaydedilir (`ModelRun`, `purpose: "second_opinion"` —
   Kullanım ekranı Gemini'yi de sayar),
   `GEMINI_API_KEY` yoksa/Gemini çökse yalnız bu düğme etkilenir. Kota/kredi
   biterse hata mesajı bunu **adıyla** söyler; OpenAI 429 `insufficient_quota`
   da öyle (sahibinin şartı — "sorunu arayıp arayıp durmayalım").
7. **Egzersiz** (varsayılan açılış sekmesi) FSRS'ten ayrı puanlanır
   (`ExerciseRun`/`ExerciseAttempt`, 90 gün saklanır, yedeğe girmez) ama
   FSRS'i **korumalı köprüyle** besler (ADR-007): erken doğru → kısmi
   stabilite kredisi (vade asla ileri itilmez); erken yanlış → soft lapse
   (`Card.softLapseCount`, en fazla 1 gün öne çekme); vadeye yakın yanlış →
   gerçek FSRS "Unuttum"; vadesi gelmiş kart ve "Kararsızdım" hiç dokunmaz;
   `ReviewLog` Egzersiz'den asla yazılmaz.

### Ders/konu sınıflandırması, Egzersiz ve Bilgi Haritası (kalıcı sözleşmeler)

- **Konu şablonu tek kaynak:** `backend/schemas/subject_topics.json` (11 ders,
  143 konu; tusoskop'tan elle portlandı, senkron tarihi `_comment`'te).
  `ios/CizgiCore/.../Resources/subject_topics.json` byte-birebir kopyası;
  `backend/tests/subjectTopics.test.ts` ayrışırsa kırılır. **Konu adları
  yalnız ders içinde tekil** → her kontrol `(ders, konu)` çifti üzerinden.
  Uygulamada tek erişim noktası **`SubjectTopicSchema.shared`**.
- **Şema v2.2 / prompt v2.5:** karta opsiyonel `topic`. Kanonik şemada enum
  yok; enum yalnız model-yüzlü dinamik şemada (`buildModelResponseSchema` →
  `anyOf: [enum-string, null]`). Üç katman: şema enum'u + prompt + sunucu
  sanitizasyonu (`sanitizeTopics`). **Geçersiz konu işi asla düşürmez, null'a
  çevrilir.** `subject` istekle gelir, `jobs.subject` kolonunda taşınır;
  bilinmeyen ders 400 değil null.
- **Kart başına kesin konu:** `persist`, kartları konuya bölüp konu başına bir
  `KnowledgeUnit` üretir (`TopicGrouping`); hepsi aynı `TextRegion`'ı paylaşır.
- **Migration'lar:** `SubjectBackfillMigration` (tanınmayan/boş ders →
  "Patoloji") ve `TopicBackfillMigration` (PR #34/#35: mevcut 204 Patoloji
  kartına konu atadı) idempotent, bayrakla tek seferlik.
- **Alt navigasyon** yerli `TabView` çubuğu değil, `CizgiRootTabBar`; her
  sekmenin `NavigationStack`'i içindeki kök içeriğe `rootTabBarInset()` ile
  bağlı — push edilen ekran barı doğal olarak almaz. **Tüm push'lar değer
  tabanlı** (2026-08-09 refaktörü): `NavigationLink(value:)` +
  `navigationDestination` yığın köklerinde; `goHome()` path sıfırlaması
  gerçekten pop eder.
- **Alt navigasyonu gizleyen her ekran görünür bir çıkış borçlu** (kural
  `AppNavigator.isTabBarHidden`'ın başında; Egzersiz'in "Bitir"i bunun için).
- **Bilgi Haritası:** kanonik ders/konu kapsamı; tanınmayan ad asla kanonik
  düğüm üretmez ama sayılır ("Konusuz" / "tanınmayan konu" /
  "sınıflandırılmamış" kovaları) — ekrandaki satırların toplamı desteye eşit.
- **Yedek biçimi v5:** `CardRecord` = kart + FSRS durumu + tüm `ReviewLog`
  geçmişi + şıklar + `lowConfidence` + `topic` (v4) + `softLapseCount` (v5).
  Eski dosyalar `decodeIfPresent` ile okunur; geri yükleme yalnızca ekler ve
  eski ders adlarını normalize eder.

## Şu an neredeyiz (2026-08-11)

| İş | Durum |
|---|---|
| Faz 0–5 (iskelet → sertleştirme) | ✅ Tamam (tarih: `docs/HISTORY.md`, faz planları). Faz 2'nin OCR hattı önce ana akıştan çıktı, sonra 2026-08-09'da koddan silindi. |
| Faz 6 — vision-öncelikli yeniden tasarım + ADR-006 kuyruğu | ✅ Tamam ve cihazda doğrulandı (PR #15–#27) |
| Galeriden fotoğraf ekleme | ✅ Tamam ve cihazda doğrulandı (PR #28) |
| Faz 7 — beş şıklı TUS kartı | 🟡 A1–A5 `main`'de (PR #29); **A6 (distraktör kalitesi, gerçek sayfa) açık** |
| Ders/konu sınıflandırması + Egzersiz modu | ✅ Tamam (PR #32); `jobs.subject` kolonu canlıda |
| Egzersiz merkeze + Bilgi Haritası | ✅ `main`'de (PR #33); üç P0 cihazda doğrulandı |
| Konu backfill (204 Patoloji kartı) | ✅ `main`'de (PR #34/#35) |
| `jobs.result` 60 günlük saklama süpürmesi | ✅ `main`'de (PR #36); karar: docs/PRIVACY.md |
| Ölü kod tıraşı (deterministik hat silindi) | ✅ `main`'de (PR #36); ADR-005'e not düşüldü |
| Değer tabanlı navigasyon refaktörü | ✅ `main`'de (PR #36); **cihaz doğrulaması açık** |
| Egzersiz→FSRS köprüsü (ADR-007) | ✅ `main`'de (PR #36); **cihaz doğrulaması açık** |
| Çift sayfa kadraj düzeltmesi (`PageSplit` + "Sol/Sağ/Tümü") | ✅ `main`'de (PR #37); **cihaz doğrulaması açık** |
| Gemini ikinci görüş (`/api/second-opinion` + "İkinci görüş iste") | 🟡 Kod hazır; **Vercel'e `GEMINI_API_KEY` girilmeli** ve cihaz doğrulaması açık |
| Çağrı başına maliyet defteri (cached/reasoning token, başarısız çağrılar, Kullanım dökümü) | 🟡 Kod hazır; `jobs.usage` migration'ı **canlıya uygulandı**; dağıtım + cihaz doğrulaması açık |
| Teşhis mesajı (sunucunun gerçek hatası ekrana) + model karşılaştırma düzeneği | 🟡 `main`'e girecek; cihaz/çalıştırma doğrulaması açık |

**Dal durumu:** çalışma dalları merge sonrası siliniyor; yeni iş `main`'in
ucundan yeni bir dalla başlar.

**Test durumu:** sayıların tek kaynağı CI (`.github/workflows/`): backend
(vitest + tsc), evals (pytest + üretici `--check`'ler), iOS (macOS runner'da
`swift test` + `xcodegen generate` + simülatör derlemesi). Üçü de yeşilse
durum sağlıklıdır. Bu belgeye test sayısı yazmıyoruz — üç yerde üç farklı
sayı tutmayı iki kez denedik, ikisinde de ayrıştı.

**Bu ortamın kalıcı sınırı:** Linux'ta `CizgiCore` derlenmiyor (CoreGraphics,
SwiftData); SwiftUI dosyaları yalnız `swiftc -parse` ile denetlenebiliyor — bu
sözdizimi kontrolüdür, tip hatası yakalamaz. Foundation-only mantık, indirilen
bir Swift araç zinciriyle izole bir pakette gerçekten koşturulabilir (ADR-007'nin
12 testi böyle doğrulandı). App hedefi ve tam paket için tek gerçek kapı
CI'daki macOS işi ya da bir Mac derlemesi.

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`), Root Directory
`backend`. Gerekli env değişkenleri `.env.example`'da; iş kuyruğu için
`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` şart. İkinci görüş düğmesi için
`GEMINI_API_KEY` (anahtar: aistudio.google.com, `docs/OPENAI-GEMINI-KURULUM.md`)
Vercel'e girilmeli — girilmezse yalnız o düğme "eksik ortam değişkeni" der,
başka hiçbir şey etkilenmez. Supabase'de `jobs` tablosu +
`page-uploads` özel kovası; ikisinde de RLS açık ve **policy yok** (yalnız
`service_role` geçer).

**Maliyet:** `OPENAI_USD_PER_MILLION_INPUT_TOKENS=5`,
`OPENAI_USD_PER_MILLION_OUTPUT_TOKENS=30` (gpt-5.6-sol, Standard/short-context)
ve `MAX_USD_PER_CARD_GENERATION=0.30` Vercel'de ayarlı; Ayarlar → Kullanım
gerçek USD gösteriyor.

**Migration sırası (kural):** `jobs` tablosuna sütun ekleyen bir değişiklik
**dağıtımdan önce** canlıya uygulanmalı. Yeni kod sütunu yazar; sütun yoksa
PostgREST `insert`'i reddeder ve her çekim patlar. Dört sütun (`max_cards`,
`mc_mode`, `subject`, `usage`) canlıda mevcut — `usage` 2026-08-12'de uygulandı
(`jsonb not null default '[]'`, `jobs_usage_is_array` kısıtıyla; mevcut 28 iş
boş defterle geçti).

## Kararlar (değiştirmeden önce oku)

- **`docs/ADR-005`** — GÜNCEL YÖN: kişisel vision-öncelikli pivot;
  §0.5/§10/§12.1/§19'un gevşetilmesi. 2026-08-09 notu: deterministik hat
  koddan silindi, geri dönüş = tıraş commit'inin revert'i.
- **`docs/ADR-006`** — GÜNCEL YÖN: kart üretimi asenkron; iş kimliği = sayfa
  kimliği; cron yok, kurtarma + saklama süpürmeleri telefonun yoklamalarına
  biner. `_jobs.ts`/`supabaseJobs.ts`'e dokunmadan önce oku — kural: **her
  durum değişikliği onu haklı çıkaran duruma koşullu olmak zorunda.**
- **`docs/ADR-007`** — GÜNCEL YÖN: Egzersiz FSRS'i yalnız `EarlyPractice`
  köprüsünden besler. `ExerciseView.recordAndAdvance`/`EarlyPractice.swift`'e
  dokunmadan önce oku.
- **`docs/ADR-001`** — Türkçe normalizasyon (İ/ı, NFC, diyakritik katlama);
  `providers/turkish.ts` ↔ `MultipleChoice.comparisonKey` hâlâ buna dayanır.
- **`docs/ADR-002/003/004`** — tarihsel: OCR seçimi, uzlaştırma kapısı,
  annotation-grounding. Kod silindi; yalnız karar arkeolojisi için oku.
- **§0.6** — model adı, eşik, maliyet sınırı asla koda gömülmez; hep merkezi
  config'te (backend `config.ts`).
- **§0.8** — hesaplama ve zamanlama deterministik kodda; LLM yalnız
  görüntü/metin yorumlama ve içerik üretimi için.

## Anti-drift disiplini (bu projede iki kez ısırdı, yapısal önlemli)

Canlı çiftler ve kilitleri:

- **FSRS-6:** Python referansı (`evals/fsrs/`) ↔ Swift portu —
  `evals/shared/fsrs-cases.json` + `test_fsrs_config_sync.py`.
- **Kart tipi enum'u:** şema ↔ TS ↔ Swift — `test_ts_contract_sync.py`,
  `test_swift_contract_sync.py`.
- **Ders/konu şeması:** backend JSON ↔ iOS Resources kopyası —
  `subjectTopics.test.ts`.
- **Şık karşılaştırma anahtarı:** `optionKey` (TS) ↔ `comparisonKey` (Swift) —
  aynı vaka çiftleri iki tarafta test edilir.

Yeni bir "aynı davranış iki yerde" durumu çıkarsa aynı deseni uygula — elle
senkron tutma, üret ve testle kilitle.

## Güvenlik (bağlayıcı)

- API anahtarı **hiçbir zaman** repoda veya iOS uygulamasında olmaz; yalnız
  backend ortam değişkenlerinde (`.env` gitignore'lu / Vercel).
- `DEVICE_TOKEN` yalnız iki yerde: backend ortam değişkeni + telefonun
  Keychain'i. Üçüncü kopya yok.
- `SUPABASE_SERVICE_ROLE_KEY` RLS'i tamamen atlar: yalnız yerel `.env` ve
  Vercel proje ayarları. Repoda, `config.ts`'te ve iOS uygulamasında asla —
  telefon Supabase'i hiç görmez, her şeye backend üzerinden erişir.
- `evals/fixtures/` içine telifli kitap sayfası commit edilmez (gitignore'lu).
- Sunucu loglarında görüntü içeriği, kart metni veya tam sayfa metni saklanmaz.

## Nasıl çalıştırılır

Ayrıntı: `docs/RUNBOOK.md`. Özet:

```bash
python -m pytest evals -q                      # eval + sözleşme testleri
cd ios/CizgiCore && swift test                 # yalnız bir Mac'te / CI
cd backend && npm test                         # vitest
cd backend && npm run typecheck                # tsc --noEmit
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
cd ios && xcodegen generate                    # App'e dosya eklendiyse ŞART
```

## Doküman haritası

Güncel yön: `docs/ARCHITECTURE.md` (akış + bileşenler), `docs/ADR-005/006/007`,
`docs/FAZ6-PLAN.md`, `docs/FAZ7-PLAN-coktan-secmeli.md`,
`docs/PLAN-egzersiz-bilgi-haritasi.md`, `docs/PLAN-galeriden-foto.md`,
`docs/PLAN-model-karsilastirma.md` (Sol/Terra/Luna deneyi + kademe
yönlendirmesi tasarımı), `docs/ORNEK-algi-taramasi.md` (Tur A nasıl doldurulur),
`docs/PRIVACY.md`, `docs/RUNBOOK.md`, `docs/MALIYET-OLCUMU.md` (çağrı başına
maliyet defteri, teşhis yordamı, model karşılaştırması), `backend/README.md`,
`ios/README.md`.

Tarihsel (davranış için değil, karar gerekçesi için): `docs/HISTORY.md`
(oturum kayıtları arşivi), `docs/ADR-001..004`, `docs/FAZ0-*` – `FAZ5-*`,
`docs/COKLU-FOTO-TIMEOUT.md`, `docs/MAC-ADIMLARI*.md`, `docs/GOLD-SET-GUIDE.md`,
`docs/GOOGLE-CLOUD-KURULUM.md`, `docs/OPENAI-GEMINI-KURULUM.md`,
`docs/MODEL-CARD.md`.

## Sıradaki iş

### 1. Cihaz doğrulama listesi

**Bu bölüm kullanıcıya sorulacak soruların listesidir.** Kod ve CI yeşil;
buradaki maddeler yalnız gerçek cihazda görülerek kapanır. Doğrulanan madde
buradan silinip "doğrulananlar"a taşınır.

**✅ Cihazda doğrulanmış (2026-08-08):** alt navigasyon kök ekranlarda doğru;
Bilgi Haritası'nın "Konusuz" kovası dolu; Egzersiz'in "Bitir"i çalışıyor ve
biten koşu "Son Egzersizler"e düşüyor.

**🔲 Henüz doğrulanmamış — önem sırasıyla:**

1. **Bir sayfa çek (en kritik).** Sistemin en büyük açık riski: OpenAI'nin
   model-yüzlü şemadaki `anyOf: [enum-string, null]` konu alanını kabul edip
   etmediği hiç denenmedi.
   - *Beklenen:* kart geliyor; kart detayında "Sınıflandırma"da makul ders/konu.
   - *Olmazsa:* tüm işler düşer. **B planı:** `buildModelResponseSchema`'dan
     enum'u kaldırıp yalnız prompt + `sanitizeTopics`'e güvenmek.
   - Aynı çekim **A6'yı da açar** (aşağıda).
2. **Çift sayfa kadraj düzeltmesi (`PageSplit`):** açık kitap çek —
   "Fotoğrafa iki sayfa girmiş" adımı çıkmalı, "Sol/Sağ" seçince karşı yarı
   kararmalı, çizgi sürüklenebilmeli, "Devam"dan sonra kart detayındaki
   "Kaynağı göster"de **yalnız seçilen sayfa** durmalı. Tek sayfa çektiğinde bu
   adım **hiç çıkmamalı** (oran eşiği `spreadAspectThreshold = 1.05`). Çoklu
   çekimde her çift sayfa için sırayla sorulmalı ("2 / 3" sayacı).
   - **Aynı testi galeriden de yap.** Bilinen artık risk (PR #37, Codex): iOS
     `PhotosPicker` bir kapanma-tamamlanma geri çağrısı sunmuyor, dolayısıyla
     küçük ve yerel bir fotoğraf picker kapanırken yüklenip biterse kadraj
     cover'ının sunumu SwiftUI tarafından düşürülebilir. Bu olursa **sessiz
     değil**: yakalama ekranında "N sayfa kadraj seçimi bekliyor" kartı
     çıkar, tek dokunuşla açılır. *Bu kartı gördüysen not et* — yapısal
     çözüm (kadraj adımını modal cover yerine görünüm hiyerarşisi içinde tam
     ekran katman yapmak) o zaman gerekçelenir; görmediysen gerek yok.
3. **Değer tabanlı navigasyon (2026-08-09 refaktörü):** Yakala → Kuyruk →
   sayfa detayı ve Bilgilerim → kart / Bilgi Haritası → ders push'ları
   çalışıyor mu; derin ekranda alt bar kayboluyor mu; ev düğmesi derin
   ekrandan gerçekten köke dönüyor mu.
4. **Egzersiz→FSRS köprüsü (ADR-007):** vadesi gelmemiş bir kartı Egzersiz'de
   yanlış yapınca kartın vadesinin en fazla yarına çekildiğini (Bilgilerim →
   kart detayı), vadesi gelmiş kartın Egzersiz'den etkilenmediğini gör.
5. **Bilgi Haritası → "Konusuz" satırına dokun:** o dersin konusuz kartlarıyla
   Egzersiz başlamalı (`TopicFilter.none` yolu).
6. **"Hızlı 10"u üst üste iki kez çalıştır:** farklı kartlar gelmeli.
7. **Aktif oturumdayken haritadan derse dokun:** "Devam eden Egzersiz var"
   diyaloğu çıkmalı.
8. **Erişilebilirlik yazı boyutu (en büyük iki kademe):** alt barda etiketler
   kalkıp yalnız ikonlar kalmalı.
9. **Yedek al → geri yükle (v5):** `softLapseCount` dahil durum korunuyor mu.
10. **"İkinci görüş iste" (2026-08-11):** önce Vercel'e `GEMINI_API_KEY` gir.
    "Gözden geçir"deki bir kartın detayında düğmeye bas — verdikt + "İkinci
    okuma (Gemini)" metni gelmeli; anahtarı bilerek silip denersen hata
    mesajı `GEMINI_API_KEY` demeli. `anyOf` şeması riski buraya da benzer
    şekilde uygulanır: Gemini `responseSchema`'yı reddederse B planı şemayı
    bırakıp yalnız prompt + sunucu doğrulamasına güvenmek
    (`providers/gemini.ts` RESPONSE_SCHEMA).
11. **Zayıf nokta sönümlemesi** — haftalar sürer, bilinçli sona bırakıldı.

### 2. A6 — beş şıklı kartın gerçek sayfayla denenmesi

Kod bitti, kalite bitmedi — ancak gerçek sayfalarla oturur.

- İlk denemede **Ayarlar → Beş şıklı kart: Hepsi** (`Karışık` bilerek seçici;
  yolu doğrulamak için "Hepsi" net).
- Bakılacaklar: şıklar aynı semantik sınıftan mı, distraktörler gerçekten
  karıştırılabilir mi, "iki doğru" var mı, "neden yanlış" öğretiyor mu, şıklar
  telefonda okunacak kadar kısa mı. Bulgular prompt'un
  `multipleChoiceInstruction` bloğuna işlenir.
- İlk turda ölç: Ayarlar → Kullanım'daki çıktı token artışı (tahmin: kart
  başına +80–150).

### 3. Küçük ve gerçek kalanlar

1. **`Models` alan sadeleşmesi + SwiftData göçü** (`sourceQuote`, TextRegion'ın
   OCR-dönemi alanları vb.). Bilerek ertelendi: §10.4 "mevcut kartlar
   korunmalı" — SwiftData şemasına dokunmak ayrı, dikkatli bir iş.
2. **`TopicBackfillMigration` sonlanma koşulu** (PR #36 incelemesinin bulgusu,
   kod `main`'den geliyor): bayrak ancak 203 eşlenmiş kimliğin **hepsi**
   görülünce yazılıyor; v2'den önce silinmiş tek bir kart, migration'ın her
   açılışta tüm desteyi taramasına yol açar. Maliyet bugün küçük (tek fetch)
   ama sınırsız; bir tamamlanma/yaş koşulu eklenmeli.

### Aday sonraki özellikler

Öneri, taahhüt değil; sırayı kullanıcı seçer.

- **Tekrar (FSRS) oturumuna ders/konu filtresi** ("bugün yalnız Farmakoloji").
- **Kart kalitesi geri bildirimi:** tekrar sırasında "bu kart kötü" işareti →
  prompt iterasyonuna girdi.
- **Sayfayı yeniden üret:** aynı fotoğraftan farklı `hint` ile ikinci takım.
- **FSRS ağırlık optimizasyonu:** yedeğe giren `ReviewLog` geçmişinden
  kullanıcıya özel ağırlıklar (`evals/fsrs/` referansı hazır).
- **PDF / Dosyalar'dan içe aktarma ve Share Sheet** (ANA-PLAN §4.3).
- **Tusoskop'tan analitik katman:** güven-küçültmeli konu ustalığı + bileşik
  zayıflık skoru (Bilgi Haritası'na "% biliyorum"), günlük istatistik kaydı
  (ısı haritası/seri), "bugün ne çalışayım" planlayıcısı (LLM + deterministik
  ikiz deseni). 2026-08-09 inceleme raporunda ayrıntılı.
