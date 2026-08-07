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
| Supabase Postgres (`jobs`) | İş durumu + üretilen kart metinleri (sonuç satırı) | Telefonun sonucu yoklayıp alması | Satır sonraki gönderime dek kalır; görüntü içermez |
| Google Document AI | Sayfa/kırpıntı görseli | OCR | **Faz 6'da ana akıştan çıktı** — kod geri dönüş için duruyor, çağrılmıyor |
| Gemini | Belirsiz el yazısı kırpıntısı | İkinci görüş transkripsiyon | **Faz 6'da ana akıştan çıktı** — çağrılmıyor |

Bu tablo her yeni entegrasyonda güncellenir.
