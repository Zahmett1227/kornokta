# Çizgi — proje durumu (yeni oturum için)

Bu dosya her yeni Claude Code oturumunun başında otomatik okunur. Amacı: bir
önceki oturumun hafızasını taşımadan, buradan devam edilebilmesi.

## Proje ne

Tek kullanıcılık (sahibi için) iOS uygulaması: kitapta işaretlenen (altı
çizili/fosforlu) tıbbi bilgiyi fotoğraftan yakalar, kaynak-sadık öğrenme
kartlarına dönüştürür, FSRS ile tekrar ettirir. Kullanıcı Türkçe konuşan bir
TUS öğrencisi/hekim.

**Tüm ürün/mimari/kalite kararlarının kaynağı:**
[`Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md`](Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md).
Bölüm numaralarına (§0.5, §19.3 gibi) bu dosyada ve tüm kod yorumlarında
sürekli atıf yapılır — bir davranış tuhaf görünüyorsa önce oraya bak.

Dokümantasyon ve kullanıcıyla iletişim **Türkçe**; kod tanımlayıcıları ve
yorumları **İngilizce**.

## Şu an neredeyiz (2026-08-02)

| Faz | Durum |
|---|---|
| Faz 0 — Risk azaltma | ✅ Tamam |
| Faz 1 — Yerel uygulama iskeleti | ✅ Tamam |
| Faz 2 — Bulut OCR + işaret tespiti | ✅ Kod ve dağıtım tamam. **Çıkış kapısı (20 görüntülük altın set ölçümü) kullanıcı tarafından bilinçli olarak atlandı** — sebep ve araçlar `docs/FAZ2-PLAN.md`'de. Eşikler hâlâ "ilk kalibrasyon". |
| Faz 3 — AI kart üretimi | Başlamadı. Sıradaki iş. |
| Faz 4 — FSRS tekrar motoru | Başlamadı |
| Faz 5 — Sertleştirme | Başlamadı |

**Dal durumu:** Her şey `main`'de. Önceki oturumlar `claude/faz1-ios-iskelet`
ve `claude/tibbi-hafiza-app-04elp1` dallarında çalıştı, bu ikisi `main`'e
ileri sarıldı (fast-forward, kayıp yok). Yeni bir görev dalı açarken bunu
bilerek aç; eski dal isimlerine bağlı kalman gerekmiyor.

**Test durumu (hepsi yeşil):**
- Python (`evals/`): 431 test — `python -m pytest evals -q`
- Swift (`ios/CizgiCore/`): 114 test, **gerçek bir Mac'te doğrulandı** — `swift test`
- Backend (`backend/`): 313 test — `npm test`

**Dağıtım:** Backend Vercel'de canlı (`kornokta-nu.vercel.app`), uçtan uca
doğrulandı — gerçek bir kitap sayfası fotoğrafı Google Document AI'dan doğru
Türkçe metinle döndü (`ı ş ğ İ ü ö ç` dahil).

## Kararlar (değiştirmeden önce oku)

- **`docs/ADR-002-birincil-ocr-secimi.md`** — Apple Vision Türkçe metin
  tanımayı desteklemiyor (ölçüldü, `docs/FAZ0-BULGULAR.md`). Google Document
  AI birincil ve tek metin kaynağı; Vision yalnız önizleme + satır geometrisi
  için kullanılıyor. Bunu tersine çevirecek bir değişiklik yapmadan önce bu
  ADR'yi oku.
- **`docs/ADR-001-hibrit-turkce-morfoloji.md`** — Türkçe normalizasyon
  (İ/ı büyük-küçük harf, NFC, diyakritik katlama) kararı.
- **§0.5** — hiçbir sayı/birim/yön/olumsuzlama/sembol sessizce
  "düzeltilmez". OCR farklı okuduğunda kullanıcıya sorulur, otomatik
  seçilmez.
- **§0.6** — model adı, eşik, maliyet sınırı asla koda gömülmez; hep merkezi
  config'te (`evals/spikes/marker_detection/config.json`, backend `config.ts`).
- **§0.8** — hesaplama ve zamanlama deterministik kodda; LLM yalnız
  görüntü/metin yorumlama ve içerik üretimi için.

## Anti-drift disiplini (bu projede iki kez ısırdı, artık yapısal önlemli)

Kritik token motoru ve işaret tespiti mantığı **iki dilde** var (Python
referans + TypeScript/Swift üretim). Ayrışmayı önleyen mekanizma:
- Regex kalıpları Python'dan üretilip JSON'a yazılıyor
  (`backend/providers/criticalTokenPatterns.json`), elle yazılmıyor.
- Davranış paylaşılan vaka dosyalarıyla sabitleniyor (`evals/shared/*.json`).
- Eşik config'leri byte-birebir kopya (`ios/CizgiCore/Sources/CizgiCore/Resources/`),
  bir Python testi ayrışırsa kırılıyor.
- Her üretici `--check` modunda CI'da çalışıyor.

Yeni bir "aynı davranış iki yerde" durumu çıkarsa aynı deseni uygula —
elle senkron tutma, üret ve kilitle.

## Güvenlik (bağlayıcı)

- API anahtarı **hiçbir zaman** repoda veya iOS uygulamasında olmaz.
- Google kimlik bilgisi iki biçimde: yerelde dosya yolu
  (`GOOGLE_APPLICATION_CREDENTIALS`), Vercel'de dosya içeriği tek satır JSON
  (`GOOGLE_CREDENTIALS_JSON`). İkisi de `.env`/Vercel env'de, asla kodda.
- `DEVICE_TOKEN` yalnız iki yerde: backend ortam değişkeni + telefonun
  Keychain'i. Üçüncü kopya yok.
- `evals/fixtures/` içine telifli kitap sayfası **commit edilmez** (gitignore'lu).
- Sunucu loglarında görüntü içeriği veya tam OCR metni saklanmaz.

## Nasıl çalıştırılır

Ayrıntı: `docs/RUNBOOK.md`. Özet:

```bash
python -m pytest evals -q                    # 431 test
cd ios/CizgiCore && swift test                # 114 test
cd backend && npm test                        # 313 test
cd backend && npm run serve                    # yerel sunucu, 127.0.0.1:8787
```

## Doküman haritası

- `docs/RUNBOOK.md` — nasıl çalıştırılır, sorun giderme
- `docs/ARCHITECTURE.md` — bileşenler, işlem hattı, anti-drift mekanizması
- `docs/FAZ2-PLAN.md` — Faz 2'nin tam kaydı: ne yapıldı, hangi hatalar
  bulundu/düzeltildi, çıkış kapısının neden atlandığı
- `docs/MAC-ADIMLARI.md` — altın set ölçümü istenirse adım adım rehber
  (araçlar hazır, hiç çalıştırılmadı)
- `backend/README.md` — backend yapısı, Vercel dağıtımında çıkan beş gerçek
  tuzak ve çözümleri
- `ios/README.md` — iOS yapısı, cihazda elle kontrol listesi
- `docs/PRIVACY.md`, `docs/MODEL-CARD.md` — gizlilik kuralları, model stratejisi
- `docs/FAZ0-*.md`, `docs/FAZ1-DURUM.md` — tarihsel kayıtlar (güncel durum
  için değil, o anki karar gerekçelerini görmek için)

## Sıradaki iş: Faz 3 — AI kart üretimi

Kapsam (ANA-PLAN §25): OpenAI Responses API + Structured Outputs, kart
şeması/kalite doğrulama, kaynağa sadık kartlar, token/maliyet kaydı. Yeni bir
API anahtarı (OpenAI) gerekiyor — Google Cloud kurulumunda izlenen yol
tekrarlanır (`docs/GOOGLE-CLOUD-KURULUM.md` örnek alınabilir).

Çıkış kapısı (§25): "Gold pasajlardan üretilen kartların kalite rubriği kabul
sınırını geçmelidir."
