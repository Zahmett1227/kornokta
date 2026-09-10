# Gizlilik ve veri saklama

> Taslak — bağlayıcı kurallar: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §22, §7.3, §24.6.

## Temel kurallar

- Hasta verisi hiçbir akışta işlenmez; uygulama klinik karar destek sistemi değildir (§0.12).
- Kitap sayfası görselleri yalnız kişisel eğitim amacıyla işlenir.
- API anahtarları istemcide veya repoda bulunmaz; yalnız backend ortam değişkenlerinde yaşar.
- Sunucu görüntüyü kalıcı tutmaz: senkron uçlarda yalnız sağlayıcı işlemi
  süresince bellekte; asenkron iş kuyruğunda (ADR-006) **iş sonuçlanana kadar**
  özel Supabase Storage kovasında durur ve her terminal yol (başarı, hata,
  zaman aşımı) nesneyi siler (§7.3).
- Telefon Supabase'i hiç görmez: kovada ve `jobs` tablosunda RLS açık, policy
  yok; yalnız Vercel'deki `service_role` anahtarı erişir.
- Sunucu loglarında görüntü, kart metni, tam OCR metni veya kişisel el yazısı saklanmaz; debug loglarında OCR içeriği maskelenir.
- Telifli kitap sayfaları repoya commit edilmez; altın set görselleri yerelde (`evals/fixtures/`, gitignore'lu) tutulur.

## Model sağlayıcılarına ve altyapıya gönderilen veri

Güncel ana akış vision-öncelikli (Faz 6, ADR-005): **işaretli sayfanın
fotoğrafının tamamı** OpenAI'ye gider — Faz 6 öncesindeki "yalnız işaretli
pasaj kırpıntısı" daraltması bu pivotla bilinçli olarak gevşetildi.

| Alıcı | Gönderilen | Amaç | Saklama |
|---|---|---|---|
| OpenAI (vision) | **Tam sayfa fotoğrafı** + varsa kullanıcı ipucu | İşaretli içeriği okuma + kart üretimi | İstek süresince |
| Supabase Storage (özel kova) | Tam sayfa fotoğrafı | Asenkron işin bekleme alanı | İş sonuçlanana kadar; terminal durumda silinir |
| Supabase Postgres (`jobs`) | İş durumu + üretilen kart metinleri ve modelin okuduğu sayfa metni (`result`) | Telefonun sonucu yoklayıp alması | **En fazla 60 gün** (aşağıya bak). Görüntü içermez |
| Gemini (ikinci görüş) | Sayfa fotoğrafı + tek kartın metni | `lowConfidence` bir kartı bağımsız bir model ailesine yeniden okutmak (`/api/second-opinion`, istek üzerine) | İstek süresince. Verdiktin **metni kaydedilmez**; yalnız maliyeti `ModelRun`'a yazılır |
| Gemini (kapsama denetimi) | Tam sayfa fotoğrafı | "Hangi işaret hiç kartlaşmadı?" (`/api/coverage`, istek üzerine) | İstek süresince. Bulgular sunucuda kalmaz, telefonda (`CapturedPage.coverageJSON`) durur |
| Google Document AI | Sayfa/kırpıntı görseli | OCR | **Kullanılmıyor.** Faz 6'da ana akıştan çıktı, 2026-08-09'da **koddan da silindi**. Canlıda `DOCUMENTAI_*` / `GOOGLE_CREDENTIALS_JSON` değişkenleri hâlâ duruyor ve hiçbir kod okumuyor — temizlenmeli (`GOOGLE_CREDENTIALS_JSON` gerçek bir kimlik bilgisi) |

**Hiçbir yere gitmeyen:** toplu içe aktarılan kavram destesi (ADR-010).
`ConceptPackImporter` tamamen cihazda çalışır — ağ çağrısı yok, sağlayıcı yok,
`jobs` tablosuna satır yok. Kartları yalnız yedek dosyasına girer (biçim v7),
o da kullanıcının kendi eline çıkar.

**2026-09-09'da kaldırılan:** Karanlık Harita (`/api/dark-map`) iki model
ailesine deste düzeyinde **konu adları ve kart soruları** gönderiyordu. Uç
tamamen silindi; artık böyle bir gönderim yok (`docs/ADR-009`, tarihsel).

Bu tablo her yeni entegrasyonda güncellenir.

### Biten işlerin `result` satırı: 60 gün sonra silinir (karar: 2026-08-09)

Görüntü için §7.3 her terminal yolda uygulanıyor; metin için karar uzun süre
açıktı (Codex, PR #30). Uygulamanın sahibi **zamana bağlı temizlik + 60 gün**
seçti ve uygulandı:

- Biten (`ready`/`failed`) bir satır, `finished_at` üzerinden **60 günden**
  eskiyse telefonun yoklamalarına binen bir arka plan süpürmesiyle silinir
  (`SUPABASE_RESULT_RETENTION_MS`, varsayılan 60 gün; süpürme örnek başına
  6 saatte bir denenir). Cron yok — ADR-006'nın kurtarma süpürmeleriyle aynı
  desen.
- Canlı satırlar (`queued`/`processing`) yaşına bakılmaksızın **asla**
  silinmez; onların kaderi bayatlık süpürmesinindir.
- **Kabul edilen ödünç:** telefon 60 günden uzun süre hiç açılmazsa, alınmamış
  bir sonuç kaybolur ve aynı sayfa yeniden gönderildiğinde ikinci kez üretim
  ücreti ödenir. Günlük kullanılan tek kullanıcılık bir uygulamada bu risk
  bilinçli olarak kabul edildi; ack ucu eklemek sözleşmeyi büyütecekti.

Elle temizlik hâlâ mümkün: Supabase SQL düzenleyicisinde
`delete from public.jobs where status = 'ready';` (telefonun almayı beklediği
bir sayfa yokken).
