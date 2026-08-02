# Google Cloud kurulumu — basit adımlar

Bu, Google'ın OCR servisini (Document AI) kullanabilmemiz için gereken kurulum.
Yaklaşık 15 dakika sürer. Kredi kartı istenecek ama yeni hesaplara genelde
$300'luk ücretsiz deneme kredisi veriliyor — bu, binlerce sayfa OCR'a yeter.

**Kuralımız:** Hiçbir şifre veya anahtar bana yapıştırılmayacak, koda
girmeyecek, git'e eklenmeyecek (ANA-PLAN §0.7). Sadece "adları" bana söyleyeceksin.

---

## 1. Proje oluştur

1. https://console.cloud.google.com adresine git, Google hesabınla gir.
2. Sayfanın üstünde bir proje seçici var (genelde "Select a project" yazar).
   Ona tıkla → **Yeni Proje / New Project**.
3. İsim ver: `cizgi-app` (istediğin başka bir isim de olur).
4. **Oluştur / Create**'e bas, birkaç saniye bekle.

## 2. Faturalandırmayı bağla

1. Sol menüden **Faturalandırma / Billing**'i aç.
2. Kredi kartı bilgini gir. (Deneme kredisi biterse otomatik ücretlendirme
   başlamaz, önce onay ister — endişelenme.)

## 3. Document AI'ı aç

1. Üstteki arama kutusuna **Document AI API** yaz.
2. Çıkan sonuca tıkla, sonra **Etkinleştir / Enable** butonuna bas.

## 4. Bir "işlemci" (processor) oluştur

Bu, hangi tür belge okuyacağını Google'a söylediğimiz yer.

1. Yine arama kutusuna **Document AI** yaz, Document AI konsoluna gir.
2. **İşlemci Oluştur / Create Processor**'a tıkla.
3. Listeden **Document OCR** seç (genel amaçlı metin okuma — başlangıç için doğru olan bu).
4. Bir bölge seç: **us** (Amerika) veya **eu** (Avrupa). İkisi de olur, **eu**
   Avrupa'da olduğun için biraz daha hızlı olabilir.
5. İsim ver (örn. `cizgi-ocr`), **Oluştur**'a bas.
6. Oluşunca işlemcinin detay sayfasına düşersin. Orada bir **Processor ID**
   göreceksin (harf-rakam karışık bir kod). **Bunu bana söyleyeceksin — gizli
   değil.**

## 5. Kısıtlı yetkili bir servis hesabı oluştur

Uygulamanın *tüm* Google hesabına değil, sadece Document AI'a erişmesini
istiyoruz — en dar yetki kuralı.

1. Sol menüden **IAM ve Yönetim / IAM & Admin** → **Servis Hesapları / Service Accounts**.
2. **Servis Hesabı Oluştur / Create Service Account**.
3. İsim ver: `cizgi-backend`.
4. Rol olarak **Document AI API User** (`roles/documentai.apiUser`) seç.
   Başka rol ekleme — sadece bu.
5. **Bitti / Done**.

## 6. Anahtar indir

1. Az önce oluşturduğun servis hesabına tıkla.
2. **Anahtarlar / Keys** sekmesine geç.
3. **Anahtar Ekle / Add Key** → **Yeni anahtar oluştur / Create new key** → **JSON** seç.
4. Bilgisayarına bir `.json` dosyası inecek.

> **Bu dosyayı:**
> - git'e ekleme (`.gitignore` zaten `*credentials*.json` ve
>   `*service-account*.json` desenlerini engelliyor, ama yine de dikkatli ol)
> - bana yapıştırma / göndermeme
> - Masaüstünde veya `Belgeler` gibi bir yerde, repo'nun **dışında** tut
>
> Backend'i kodladığımda bu anahtarı senden isteyeceğim ama sohbete değil —
> hosting platformunun (örn. Vercel) "Environment Variables / Secrets" ayarına
> **sen** ekleyeceksin. Ben sadece kodun onu nasıl okuyacağını yazarım.

## 7. Bana söylemen gerekenler

Bunlar gizli değil, rahatça yazabilirsin:

- **Project ID** (proje seçicide görünen, örn. `cizgi-app-123456`)
- **Processor ID** (4. adımda not ettiğin kod)
- **Bölge** (`us` veya `eu`, 4. adımda seçtiğin)

Bunlarla backend kodunu senin adına yazabilirim. Anahtarın kendisi (`.json`
dosyası) hiçbir zaman bana gelmeyecek.

---

## Maliyet

ANA-PLAN'daki referans: 1.000 sayfa ≈ 1,50 USD (Ağustos 2026 fiyatı). Senin
kullanımın muhtemelen ayda birkaç yüz sayfa, yani birkaç dolar civarı — ücretsiz
deneme kredisi bunu uzun süre karşılar.
