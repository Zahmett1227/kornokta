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
| Supabase Postgres (`jobs`) | İş durumu + üretilen kart metinleri ve modelin okuduğu sayfa metni (`result`) | Telefonun sonucu yoklayıp alması | **Süresiz** — aşağıya bak. Görüntü içermez |
| Google Document AI | Sayfa/kırpıntı görseli | OCR | **Faz 6'da ana akıştan çıktı** — kod geri dönüş için duruyor, çağrılmıyor |
| Gemini | Belirsiz el yazısı kırpıntısı | İkinci görüş transkripsiyon | **Faz 6'da ana akıştan çıktı** — çağrılmıyor |

Bu tablo her yeni entegrasyonda güncellenir.

### Açık kalan: biten işlerin `result` satırı silinmiyor

Görüntü için §7.3 tam olarak uygulanıyor (her terminal yol nesneyi siler), ama
**metin için uygulanmıyor**. `complete`, üretilen kartların tamamını ve modelin
sayfadan okuduğu metni (`readText`) `jobs.result` sütununa yazar; bu satırı
temizleyen hiçbir yol yok:

- `ready` bir işe gelen yeniden gönderim, satırı olduğu gibi geri döndürür
  (`backend/api/_jobs.ts` — ikinci üretim ücreti ödenmesin diye, bilerek);
- `requeue` yalnız `failed` satırları temizler;
- ADR-006 gereği cron yok, dolayısıyla zamana bağlı bir temizlik de yok.

Yani bir sayfanın kartları, telefon onları çoktan almış olsa bile Supabase'de
süresiz durur. Bu bir sızıntı değil (RLS açık, policy yok, yalnız
`service_role` erişir) ama §7.3'ün "yalnız iş süresince tut" ilkesinin metin
tarafında tutulmamış bir sözüdür.

**Neden hemen kapatılmadı:** her iki makul çözüm de bir ödünç istiyor ve bu
uygulamanın sahibinin kararı:

1. *Zamana bağlı temizlik* (Supabase `pg_cron` ile, ör. 7 günden eski `ready`
   satırları sil). Basit; ama telefon o pencerede hiç açılmazsa iş kaydı yok
   olur ve aynı sayfa yeniden gönderildiğinde **ikinci kez ücret ödenir**.
2. *Telefon aldığını bildirince sil* (yeni bir onay/ack ucu). Ücret riski yok;
   ama sözleşmeye yeni bir uç ekler ve telefon kartları kaydettiğini
   söylemeden önce ölürse iş kaydı yine kaybolur.

Karar verilene kadar doğru olan şey, saklama süresini olduğu gibi yazmaktır —
bu bölüm onun için var. Elle temizlik her zaman mümkün: Supabase SQL
düzenleyicisinde `delete from public.jobs where status = 'ready';` (telefonun
almayı beklediği bir sayfa yokken).
