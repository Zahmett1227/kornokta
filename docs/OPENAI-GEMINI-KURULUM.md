# OpenAI ve Gemini anahtar kurulumu — basit adımlar

Faz 3'ün (AI kart üretimi) çalışması için iki yeni anahtar gerekiyor: OpenAI
(kart üretimi, §11.2) ve Gemini (el yazısı ikinci görüşü, §10.4 — yalnız
belirsiz durumlarda çağrılıyor, çoğu zaman hiç kullanılmayacak).

**Kuralımız aynı (ANA-PLAN §0.7):** Hiçbir anahtar bana yapıştırılmayacak,
koda girmeyecek, git'e eklenmeyecek. Anahtarları doğrudan `.env` dosyana
(yerelde) veya Vercel'in ortam değişkenleri ayarına (dağıtımda) sen
gireceksin.

---

## 1. OpenAI anahtarı

1. https://platform.openai.com adresine git, hesabınla gir (yoksa oluştur).
2. Sağ üstteki proje seçiciden yeni bir proje oluşturabilirsin (isteğe bağlı,
   isim: `cizgi`) — harcamaları ayrı görmek için işe yarar.
3. Sol menüden **API keys**'e gir → **Create new secret key**.
4. İsim ver (örn. `cizgi-backend`), oluştur.
5. Ekranda **bir kere** gösterilecek anahtarı (`sk-...` ile başlar) kopyala.

   > Bu anahtarı: git'e ekleme, bana yapıştırma/gönderme, repo içinde
   > bir yere yazma. Yalnız `.env`'e (yerelde) veya Vercel ortam
   > değişkenine (dağıtımda) gireceksin.

6. **Harcama sınırı koy.** Sol menüden **Settings → Limits** (veya **Billing
   → Limits**), aylık bir üst sınır belirle. ANA-PLAN §20.3 "aylık 10 USD
   uyarı, 15 USD sert limit" öneriyor — kişisel kullanım için makul bir
   başlangıç. Bu, backend'deki `MAX_USD_PER_CARD_GENERATION` ile **aynı şey
   değil**: o tek bir çağrının üst sınırı, bu OpenAI'ın kendi hesap düzeyinde
   uyguladığı aylık sınır. İkisi birlikte kullanılmalı.

## 2. Gemini anahtarı

1. https://aistudio.google.com adresine git, Google hesabınla gir.
2. Sol menüden **Get API key** → **Create API key**.
3. Yeni bir proje seçebilir veya var olan bir Google Cloud projesini
   (Document AI için kullandığın `kornokta` projesi de olabilir)
   seçebilirsin.
4. Üretilen anahtarı kopyala.

   > Aynı kural: git'e ekleme, bana yapıştırma, koda gömme.

Gemini yalnız el yazısı ikinci görüşü için ve yalnız gerçek uyuşmazlık
olduğunda çağrılıyor (§10.4); OpenAI'a göre çok daha nadir kullanılacak,
harcama sınırı koymak isteğe bağlı ama yine de önerilir (aistudio.google.com
üzerinden faturalandırma bağlıysa Google Cloud Console → Billing → Budgets &
alerts).

## 3. Anahtarları yerleştir

### Yerelde (`backend/.env`)

```
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
```

`.env` gitignore'lu; bu iki satır repoya asla gitmez.

### Vercel'de

Proje ayarları → **Environment Variables**:

- `OPENAI_API_KEY`
- `GEMINI_API_KEY`

Diğer OpenAI/Gemini değerleri (model adı, `maxOutputTokens`, fiyat alanları)
gizli değil; `.env.example`'daki karşılıklarıyla aynı şekilde eklenebilir —
ayrıntı `backend/README.md`.

## 4. İlk doğrulama — gold set ölçümüne geçmeden önce

Faz 2'de Google Document AI için yapılan aynı disiplin geçerli: önce **tek**
küçük bir çağrıyla istek/yanıt şeklinin doğru olduğunu doğrula, sonra gold
pasajlarla ölçüme geç. Bu backend'de henüz bir `npm run cards -- --limit 1`
betiği yok (`docs/FAZ3-PLAN.md`'de not edildi) — ilk canlı denemede eklenmesi
gereken en ucuz araç bu.

## 5. Bana söylemen gerekenler

Hiçbir şey — anahtarların kendisi hiçbir zaman bana gelmeyecek. Kurulum
bittiğinde "anahtarları girdim" demen yeterli; kod zaten `OPENAI_API_KEY` ve
`GEMINI_API_KEY` ortam değişkenlerini okuyacak şekilde yazıldı
(`backend/api/index.ts`).

## Maliyet

ANA-PLAN §20.2'deki 6 aylık tahmin (GPT-5.6 Sol için 2.800–3.600 TL) bu
belgenin yazıldığı tarihte doğrulanmış bir fiyata dayanmıyor — o model adı
henüz yayınlanmamıştı. Gerçek fiyatı `OPENAI_USD_PER_MILLION_INPUT_TOKENS` /
`OPENAI_USD_PER_MILLION_OUTPUT_TOKENS` alanlarına (backend `.env`) kendi
hesabındaki fiyatlandırma sayfasından gireceksin; girmezsen maliyet tahmini
dürüstçe sıfır görünür, uydurma bir rakam gösterilmez (§0.6).
