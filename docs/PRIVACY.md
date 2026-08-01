# Gizlilik ve veri saklama

> Taslak — bağlayıcı kurallar: [ANA-PLAN](../Kisisel-Tibbi-Hafiza-Uygulamasi-ANA-PLAN.md) §22, §7.3, §24.6.

## Temel kurallar

- Hasta verisi hiçbir akışta işlenmez; uygulama klinik karar destek sistemi değildir (§0.12).
- Kitap sayfası görselleri yalnız kişisel eğitim amacıyla işlenir.
- API anahtarları istemcide veya repoda bulunmaz; yalnız backend ortam değişkenlerinde yaşar.
- Sunucu, görselleri yalnız sağlayıcı işlemi süresince geçici tutar ve hemen siler.
- Sunucu loglarında görüntü, tam OCR metni veya kişisel el yazısı saklanmaz; debug loglarında OCR içeriği maskelenir.
- Telifli kitap sayfaları repoya commit edilmez; altın set görselleri yerelde (`evals/fixtures/`, gitignore'lu) tutulur.

## Model sağlayıcılarına gönderilen veri

| Sağlayıcı | Gönderilen | Amaç |
|---|---|---|
| Google Document AI | Sayfa/kırpıntı görseli | OCR |
| OpenAI (GPT-5.6 Sol) | Yalnız işaretli pasaj kırpıntısı + OCR adayları | Transkripsiyon doğrulama, kart üretimi |
| Gemini (fallback) | Yalnız belirsiz el yazısı kırpıntısı | İkinci görüş transkripsiyon |

Bu tablo her yeni entegrasyonda güncellenir.
