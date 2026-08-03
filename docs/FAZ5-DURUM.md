# Faz 5 — Sertleştirme ve iPhone hazırlığı

**Durum (2026-08-03):** Kod tarafı tamamlandı; fazın son kabulü gerçek iPhone
üzerindeki aşağıdaki kontrol listesine bağlıdır. Linux ortamında Xcode, kamera,
Keychain ve bildirim izni doğrulanamaz.

## Tamamlananlar

- Kalıcı kuyruk uygulama açılışında ve her ön plana dönüşte yeniden taranıyor.
  Aynı sayfanın tekrar işlenmesi mevcut bilgi birimi kontrolüyle engelleniyor;
  geçici hatalar artan gecikmeyle yeniden deneniyor.
- Ayarların eski sürümden yeni sürüme taşınması alan bazlı ve geriye uyumlu;
  yeni bir ayar eklenmesi backend URL'sini veya mevcut tercihleri sıfırlamıyor.
- Günlük yerel tekrar bildirimi, bildirim saati, günlük yeni kart sınırı ve
  dakika bütçeli hızlı oturum ayarları eklendi.
- Kartlar, kaynak alıntıları ve FSRS durumuyla sürümlü JSON yedeği üretilebiliyor.
  Telifli tam sayfa görselleri yedeğe alınmıyor.
- “Orijinal sayfayı sakla” kapalıysa başarıyla karta dönüştürülen sayfanın tam
  görüntüsü siliniyor; kaynak alıntısı kartta kalıyor.
- Backend'in mevcut maliyet üst sınırı, retryable hata sözleşmesi, içeriksiz
  loglama ve cihaz-token doğrulaması Faz 5 güvenlik tabanını oluşturuyor.

## iPhone kabul listesi

1. Mac'te `cd ios && xcodegen generate && open Cizgi.xcodeproj` çalıştır.
2. Xcode'da **Signing & Capabilities → Team** altında Apple ID takımını seç;
   bundle kimliği çakışırsa `local.cizgi.app` değerini benzersiz yap.
3. iPhone'u bağla, geliştirici modunu aç ve `Cizgi` şemasını telefonda çalıştır.
4. Ayarlar'da Vercel adresini ve `npm run token` ile üretilen cihaz anahtarını
   gir. “Bağlı / Google Document AI / Gerçek (backend) / FSRS-6” görünmeli.
5. Gerçek bir sayfa çek; uygulamayı işleme sırasında arka plana atıp geri dön.
   İş devam etmeli ve yalnız bir kart grubu oluşmalı.
6. Uçak modunda sayfa çek; hata kaybolmamalı. Ağı açıp “Tekrar dene”ye basınca
   aynı kayıt tamamlanmalı.
7. Günlük hatırlatıcıyı aç, iOS iznini ver ve geçici olarak sonraki saate kur.
   Bildirimin geldiğini doğrula.
8. Günlük yeni kart/hızlı oturum sınırlarını küçük değerlere getir; Tekrar
   ekranının sınırı aşmadığını doğrula.
9. “Yedeği hazırla → JSON yedeğini paylaş” ile Dosyalar'a kaydet; JSON'u açıp
   kartları kontrol et ve içinde görüntü/base64 bulunmadığını doğrula.
10. “Orijinal sayfayı sakla” kapalıyken yeni bir sayfa işle; kartın kaynak
    alıntısı kalmalı, Sayfa ayrıntısında tam görüntü artık görünmemeli.

Bu listenin tamamı geçmeden “gerçek cihaz testi tamam” denmemelidir.
