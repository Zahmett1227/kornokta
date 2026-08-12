# Maliyet ölçümü ve teşhis

Bu belge, "para nereye gidiyor?" sorusunun **nasıl** cevaplandığını anlatır.
Cevabın kendisini değil — o her ay değişir; burada anlatılan, cevabı üretebilen
düzenek.

## Neden gerekti

Ağustos 2026'da uygulama az kullanılmasına rağmen OpenAI panelinde ~$11
görünüyordu, ama Ayarlar → Kullanım'daki toplam bunun altındaydı ve aradaki
farkın nedeni **hiçbir yerden görülemiyordu**. Üç ayrı boşluk vardı ve üçü de
aynı yöne, eksik göstermeye çalışıyordu:

1. **Önbellekli girdi, önbelleksiz fiyattan sayılıyordu.** Sağlayıcı daha önce
   gördüğü ön eki onda bir fiyata faturalıyor ve payını `usage` içinde
   bildiriyor. Toplam girdiyi tam fiyattan çarpmak, önbellekli bir çağrıyı kat
   kat yanlış gösterir.
2. **Reasoning tokenları görünmezdi.** Modelin kendi düşünmesi çıktı fiyatından
   — sistemdeki en pahalı fiyattan — faturalanıyor ve tek bir `outputTokens`
   sayısının içinde eriyordu. "Para karta mı düşünmeye mi gidiyor?" sorusunun
   cevabı yoktu.
3. **Başarısız çağrılar hiç kaydedilmiyordu.** Çıktı bütçesini tamamen yakıp
   sonra düşen bir üretim, başarılı olanla birebir aynı parayı harcar. Yalnız
   başarılar yazıldığı için defter **bilinmeyen bir miktarda** düşük okumak
   zorundaydı.

Üçüncüsü en önemlisiydi, çünkü sadece bir sayıyı bozmuyordu: farkın nedenini
de gizliyordu.

## Defterin sözleşmesi

Her sağlayıcı çağrısı için bir satır (`CallAccounting`, `providers/tokenUsage.ts`).
Kritik alan `billing` — ve **üç değerli, boolean değil**:

| değer | ne demek | toplama girer mi |
|---|---|---|
| `measured` | Sağlayıcı kullanımı bildirdi; sayılar gerçek. | Evet |
| `unmeasured` | İstek modele ulaştı, `usage` bloğu hiç gelmedi (kendi zaman aşımımız kesti ya da işçi öldürüldü). Üretim yapıldı ve **faturalandı**; ne kadar olduğunu bilemiyoruz. | Hayır — **sayılır**, fiyatlanmaz |
| `none` | Üretime hiç geçilmeden reddedildi (kota, hız sınırı, bozuk anahtar). Gerçekten bedava. | Hayır |

`unmeasured` ile `none` arasındaki fark bu defterin bütün meselesi. Sıfır token
ikisinde de var; biri para yakmış, diğeri yakmamış. Boolean bir bayrakla bu ikisi
ayırt edilemiyordu ve **aranan sızıntı tam olarak birincisiydi.**

Kural: **para yalnız `measured` çağrılardan toplanır.** `unmeasured` olanlar
ortalamaya karıştırılmaz — makul görünen uydurma bir sayı, dürüst bir
"bilmiyoruz"dan kötüdür (§0.6). Ekran bu yüzden toplamın bir **alt sınır**
olduğunu söyler.

### Defter nerede durur

- **Sunucu:** `jobs.usage` (jsonb dizi), denemeler boyunca **birikir**.
  `requeue` onu bilerek temizlemez: bu alan başlayacak denemeyi değil, olup
  bitmiş denemeleri ve hesaptan çıkmış parayı anlatır.
- **Telefon:** `ModelRun`, `(jobId, purpose, attempt)` üçlüsüyle tekilleştirilir.
  Sunucu tüm defteri her yoklamada bildirir ve bir sayfa çok kez yoklanır.

İkisi de gerekli: sayfa iki kez düşüp üçüncüde başarılı olduysa üç üretim
ödendi ve telefon ilk ikisinde büyük ihtimalle uykudaydı. Yalnız telefonun
gördüğüne dayanan her sayı, bilinmeyen bir miktarda düşük okur.

Defterde **hiç içerik yok** — yalnız sayı, fiyat ve süre (§7.3).

## Teşhis nasıl yapılır

1. **Ayarlar → Kullanım** toplamını OpenAI panelindeki tutarla karşılaştır.
2. Fark varsa nedeni artık aynı ekranda:
   - **"Boşa giden"** — başarısız ama faturalanmış çağrılar. Bu para
     üretilmeyen kartlara gitti.
   - **"Ölçülemedi"** — faturalanmış ama miktarı bildirilmemiş çağrılar. Toplam
     bu kadar eksik okuyor olabilir.
3. **"Çağrı dökümü"** ekranı her çağrıyı tek tek verir. Okunacak şey
   `failureReason` dağılımı:
   - çok sayıda `incomplete_max_output_tokens` → çıktı tavanı yetmiyor ya da
     sayfa başına kart sayısı fazla;
   - çok sayıda `timeout` / `worker_killed` → sayfalar zaman bütçesine sığmıyor;
   - çok sayıda `insufficient_quota` → bakiye;
   - temiz başarılar → para işin kendisi.

### Kuyruktaki kırmızı yazı

Toplu çekimde çıkan hata satırı artık genel bir sınıflandırma değil, sunucunun
kendi cümlesi. Ayırt edilmesi gereken iki durum:

- **"Kart üretimi sunucuda sürüyor; sonuç bir sonraki denemede alınacak
  (yeniden ücretlendirilmez)."** → Bu bir hata değil. İstemcinin bekleme sınırı
  (`jobDeadline`, 420 sn) doldu; iş sunucuda çalışmaya devam ediyor. İş kimliği
  sayfa kimliği olduğu için sonraki deneme sonucu **toplar**, yeniden üretmez.
  Ücretsiz.
- **"Model üretimi tamamlamadı: max_output_tokens"** ya da zaman aşımı → Bu
  faturalandı ve sonucu alınamadı. Tekrar denemek ikinci bir üretim demektir.

Bu ikisi eskiden ekranda aynı altı kelimeyi yazıyordu ("Sağlayıcıya
ulaşılamadı. Yeniden denenecek."), ve maliyet sorusunun telefondan
cevaplanamamasının doğrudan sebebi buydu.

## Fiyat ayarları

`OPENAI_USD_PER_MILLION_CACHED_INPUT_TOKENS` girilmezse **girdi fiyatına eşit**
sayılır, 0'a değil. Buradaki tek istisna bu: 0 varsayımı önbellekli tokenları
defterde bedava gösterir ve toplam gerçek faturanın altında kalır — bu
muhasebenin kapatmak için var olduğu hatanın ta kendisi. Fazla göstermek, eksik
göstermekten güvenli yön; değişkeni girmek de tam sayı verir.

## Model değiştirmeyi ölçmek

`npm run compare` (kullanım: `docs/RUNBOOK.md`). İki yarısı var:

- **Para** — kesin ölçülür, sağlayıcının kendi bildirdiği token sayılarından.
- **Kalite** — hiçbir yayınlanmış benchmark bu işi kapsamıyor (tier skorları
  agentic ve uzun-bağlam işler üzerinden veriliyor; bu uygulama tek fotoğrafta
  soluk fosforlu ve kenar el yazısı okuyor). İnsan puanlar, **kör** puanlar.

Körlük tören değil: bu karşılaştırmadaki her kart tanım gereği sınıra yakındır
— kimse bariz bir kalite çöküşü için model değiştirmez, "yeterince yakın" için
değiştirir — ve modeli bilmek tam da o sınır kararını bozan şeydir.

Bakılacak asıl sayı sayfa başına maliyet değil, **kabul edilen kart başına
maliyet**: yarı fiyata üçte bir kullanılabilir kart üreten bir model ucuz
değildir, ama sayfa başına maliyet onu ucuz gösterir.
