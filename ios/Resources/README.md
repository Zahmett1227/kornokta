# Gömülü kaynaklar

Bu klasör uygulama hedefine **resources** derleme aşaması olarak bağlıdır
(`project.yml`). Buraya konan dosya doğrudan uygulama paketine girer.

## LibreCaslonText-Regular.ttf

Tasarım dilinin (Kemik & Oxblood) tek gömülü yazı ailesi. Üç yerde kullanılır:
kart sorusu, boş durum başlığı, büyük sayılar — başka hiçbir yerde serif yok.

Kaynak: [Libre Caslon Text](https://fonts.google.com/specimen/Libre+Caslon+Text),
SIL Open Font License 1.1 — lisans metni yanındaki `OFL.txt`'te ve bilerek
uygulama paketine giriyor (OFL fontun lisansıyla birlikte dağıtılmasını şart
koşar). `UIAppFonts` anahtarı `project.yml`'de kayıtlı.

**Not:** Google Fonts bu aileyi artık depoda yalnız *değişken* font olarak
tutuyor (`LibreCaslonText[wght].ttf`); buradaki dosya CSS API'nin verdiği
**statik Regular** kesiti (`fonts.gstatic.com/s/librecaslontext/v5/...ttf`,
63 KB). PostScript adı `LibreCaslonText-Regular` — `Cizgi.serifFamily` tam
bunu arar. Türkçe kapsaması denetlendi: ı İ ğ Ğ ş Ş ç Ç ö Ö ü Ü ve § var.

Font **yoksa uygulama kırılmaz**: `Cizgi.serif(_:)` çalışma anında bakar
(`Cizgi.isSerifBundled`) ve Georgia'ya düşer — iOS'ta her zaman bulunan,
gerçekten serif bir aile. Dynamic Type ölçeklemesi iki durumda da korunur.
