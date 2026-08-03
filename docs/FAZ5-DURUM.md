# Faz 5 — Sertleştirme ve iPhone hazırlığı

**Durum (2026-08-03):** Kod tarafı tamamlandı; fazın son kabulü gerçek iPhone
üzerindeki aşağıdaki kontrol listesine bağlıdır. Linux ortamında Xcode, kamera,
Keychain ve bildirim izni doğrulanamaz. **Aynı gün kullanıcı bu testi kendi
iPhone'unda fiilen başlattı** — aşağıdaki "Gerçek cihaz oturumu" bölümüne bak.

## Gerçek cihaz oturumu (2026-08-03)

Kullanıcı `xcodegen` + Xcode ile projeyi kendi iPhone'unda derleyip çalıştırdı.
Süreçte üç ayrı gerçek sorun bulundu ve düzeltildi — hiçbiri ortam/kurulum
sorunu değildi, üçü de koddaki gerçek hatalardı:

1. **`xcodegen` eksikti / "developer disk image" hatası** — Mac tarafı kurulum
   sorunları, kod değişikliği gerekmedi (`brew install xcodegen`, Xcode
   güncelleme).
2. **`ProcessingQueue.swift` — iki P1 bulgusu (PR #3).** `context.save()`
   başarısız olursa orijinal sayfa görüntüsü, `.ready` durumu veya kartlar
   diske hiç yazılmadan görüntü zaten silinmiş oluyordu (kurtarılamaz veri
   kaybı). Düzeltme: görüntü yalnız save başarılı olduktan sonra siliniyor;
   silinmemiş bir görüntü için kalıcı `pendingOriginalImageDeletion` bayrağı
   eklendi, `processPending()` başlangıçta bunu tarayıp yeniden deniyor —
   bayrağın kontrolü kendi taze `ModelContext`'i üzerinden yapılıyor ki
   başarısız bir save'in bellekte bıraktığı geçici durumu kalıcı sanmasın.
3. **`AppEnvironment.swift` — gerçek bir derleme hatası (PR #4).** `init`'te
   `queue` özelliği atanırken `self.settings` okunuyordu; Swift bunu tüm
   stored property'ler atanmadan yasaklıyor. Bu hata şimdiye kadar hiç
   yakalanmamıştı çünkü `swift test` yalnız `CizgiCore` paketini derliyor,
   `ios/App` hedefini (bu dosyayı) hiç dokunmuyor — bu, o hedefin Xcode'da
   **gerçekten derlendiği ilk andı**.
4. **Kart kalitesi kötü çıktı → kök neden bulundu (PR #5).** Kullanıcı gerçek
   bir sayfa çekti; backend henüz bağlanmadığı için kartlar Faz 1'in kasıtlı
   olarak aptal `MockCardProvider`'ından geldi (beklenen davranış — Ayarlar'da
   "Ayarlanmadı" yazıyordu). Ama arkadaki ham metin de karışıktı: sayfa iki
   sütunluydu (Nekroz/Apoptoz karşılaştırması), hem Apple Vision hem Google
   Document AI satırları yalnız "yukarıdan aşağı + soldan sağa" sıralıyordu,
   sütun sütun değil satır satır okuyordu — iki sütun aynı satırdaysa iki
   konuyu tek cümlede karıştırıyordu. Sütun tespiti eklendi
   (`ios/CizgiCore/Sources/CizgiCore/OCR/ReadingOrder.swift` ve
   `backend/providers/documentAI.ts`), Codex'in ardışık 8 turluk incelemesi
   sonunda 7 gerçek uç durum daha bulup düzelttirdi (dar sütun, taşan
   başlık/dipnot, hizasız satır, eşit olmayan uzunluk, vb.) — 8.'si (çok dar
   ama gerçek boşluğu kesen bir ayraç) kullanıcı kararıyla düşük öncelikli
   olarak ertelendi. Ayrıntı: `docs/ADR-002-birincil-ocr-secimi.md`.

~~Bu oturumda telefon backend'e **hâlâ bağlanmadı**~~ **Güncelleme
(2026-08-03, sonraki oturum):** kullanıcı Vercel cihaz tokenını girip
telefonu backend'e bağladı ve 153/153 Swift testini bir Mac'te doğruladı.
İlk gerçek bağlantılı çekimde ("Tip 4 hipersensitivite" sayfası) yeni bir
bulgu çıktı:

5. **Onay ekranı Apple Vision gürültüsüyle doluyordu (ADR-003).** Bağlantılı
   ilk sayfada dört "kritik değer uyuşmazlığı" uyarısı göründü — hepsi
   Apple Vision'ın bilinen Türkçe/sembol arızalarının yansımasıydı
   (`hipersenstvite` = harf düşürme, `[12]`/`[K⁻]` = Apple'ın okuyamadığı
   karakterler, `[1]` = Apple'ın uydurduğu sayı), gerçek bir tıbbi belirsizlik
   değil. İki gerçek kod hatası bulundu: `reconcile.ts`'te "kaynak"/"okuma"
   etiketleri ters yöndeydi (Apple'ın okuması "kaynak" olarak gösteriliyordu)
   ve ADR-002'ye rağmen Apple'ın uyuşmazlığı hâlâ onay ekranını tetikliyordu.
   Ek olarak `hypo_hyper` karşılaştırması polarite öneki yerine tüm kelimeyi
   kıyaslıyordu. Üçü de düzeltildi — karar kaydı:
   `docs/ADR-003-ocr-uzlastirma-kapisi-daraltildi.md`. Aynı oturumda kart
   üretim promptu v1.1'e güncellendi (soru çerçevesi pasajın kazanımına göre,
   `explanation`'da etiketli kaynak-dışı bağlam izni — ANA-PLAN §15.2'nin
   güncellenmiş metni).

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

**Durum (2026-08-03):** 1–3 ve 5 fiilen denendi (yukarıdaki "Gerçek cihaz
oturumu" bölümü) — üçü de o sırada bulunan koddaki gerçek hataları düzeltmeyi
gerektirdi, şimdi hepsi `main`'de. 4 henüz tamamlanmadı (backend'e
bağlanılmadı). 6–10 hiç denenmedi.

1. ~~Mac'te `cd ios && xcodegen generate && open Cizgi.xcodeproj` çalıştır.~~
   Denendi — `xcodegen` kurulu değildi, kullanıcı Mac'inde kurdu.
2. Xcode'da **Signing & Capabilities → Team** altında Apple ID takımını seç;
   bundle kimliği çakışırsa `local.cizgi.app` değerini benzersiz yap.
3. ~~iPhone'u bağla, geliştirici modunu aç ve `Cizgi` şemasını telefonda
   çalıştır.~~ Denendi — önce "developer disk image" hatası (Mac tarafı),
   sonra gerçek bir derleme hatası (`AppEnvironment.swift`, düzeltildi)
   çıktı. Artık derleniyor (kullanıcı `swift test`i doğruladı, ama yalnız
   sütun tespitinin ilk sürümüyle — bkz. `CLAUDE.md` "Test durumu").
4. Ayarlar'da Vercel adresini ve `npm run token` ile üretilen cihaz anahtarını
   gir. “Bağlı / Google Document AI / Gerçek (backend) / FSRS-6” görünmeli.
   **Henüz yapılmadı** — Ayarlar hâlâ "Ayarlanmadı" gösteriyordu.
5. Gerçek bir sayfa çek; uygulamayı işleme sırasında arka plana atıp geri dön.
   İş devam etmeli ve yalnız bir kart grubu oluşmalı. **Kısmen denendi:** bir
   sayfa çekildi (backend bağlanmadan, yani Mock kart üreticiyle) — kart
   kalitesi kötü çıktı, kök nedeni (sütun okuma hatası) bulunup düzeltildi.
   Arka plana atma senaryosu ayrıca denenmedi.
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
