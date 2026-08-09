# Runbook

Güncel durum (2026-08-09): Faz 0–6 tamam ve cihazda doğrulandı; galeriden
fotoğraf ekleme, beş şıklı (TUS tipi) kart, ders/konu sınıflandırması,
Egzersiz + Bilgi Haritası ve Egzersiz→FSRS köprüsü (ADR-007) `main`/dalda.
Deterministik OCR hattı 2026-08-09 tıraşında silindi (ADR-005 notu). Kalan iş
`CLAUDE.md` → "Sıradaki iş". Üç ayrı test paketi var — Python (eval araçları),
Swift (iOS mantığı), TypeScript (backend).

> Test sayıları bilerek burada tutulmuyor — güncel sayının tek kaynağı CI
> (`.github/workflows/`). Üç paket de yeşilse durum sağlıklıdır.

## Python — eval araçları

```bash
pip install -r evals/requirements.txt

python -m pytest evals -q
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json --check-files
python -m evals.spikes.marker_detection.run --demo                # sentetik demo, ağ gerekmez
```

## Swift — iOS mantığı (Xcode gerekmez)

```bash
cd ios/CizgiCore
swift test                                                        # yalnız bir Mac'te
```

Paket **Linux'ta derlenmez** (CoreGraphics, SwiftData). Foundation'a bağlı yeni
mantık, bir Swift araç zinciri kurup yalnız o dosyaları içeren izole bir pakette
gerçekten koşturulabilir — PR #27'nin 63 testi ve ADR-007'nin 12 testi böyle
doğrulandı. SwiftUI dosyaları için elde yalnız `swiftc -parse` var; o
**sözdizimi** kontrolüdür, tip/aşırı-yükleme hatasını yakalamaz. App hedefi ve
tam paket için tek gerçek kapı CI'daki macOS işi ya da bir Mac derlemesi.

Kamera ve SwiftUI ekranları bunun dışında — onlar gerçek cihazda denenir
(`ios/README.md`). `ios/App` altına dosya eklendiyse önce:

```bash
cd ios && xcodegen generate                                       # yoksa Xcode dosyayı hedefe almaz
```

## Backend — TypeScript

```bash
cd backend
npm install
npm run typecheck
npm test
```

Yerel sunucu (yalnız 127.0.0.1, dışarıya açılmaz):

```bash
npm run serve
curl http://127.0.0.1:8787/health                                # {"ok":true}
```

## Anahtar yönetimi (§0.7, §7.3)

- `OPENAI_API_KEY` ve `SUPABASE_SERVICE_ROLE_KEY` yalnız yerel `.env` ve
  Vercel proje ayarlarında yaşar; koda, repoya, loglara girmez.
- `DEVICE_TOKEN` iki yerde: backend ortam değişkeni + telefonun Keychain'i.
  Üçüncü kopya yok. Üretmek için: `npm run token` (yalnız ekrana basar, hiçbir
  yere yazmaz).
- `.env` dosyaları gitignore'ludur; asla commit edilmez.
- iOS uygulamasına hiçbir anahtar gömülmez — telefon backend'e cihaz
  tokenıyla konuşur, sağlayıcı anahtarlarını hiç görmez.

## Vercel'e dağıtım

Tam adımlar ve dağıtımda çıkan gerçek tuzaklar, "Vercel'e dağıtım" başlığı
altında: [`backend/README.md`](../backend/README.md).

Kısaca:
1. Root Directory = `backend`
2. Environment Variables: `.env.example`'daki liste. **İş kuyruğu için şart:**
   `SUPABASE_URL` ve `SUPABASE_SERVICE_ROLE_KEY` (ADR-006). İkincisi RLS'i
   tamamen atlar — repoya girmez, yalnız yerel `.env` ve Vercel proje ayarları.
   **Migration sırası (kural):** `jobs` tablosuna sütun ekleyen bir değişiklik
   **dağıtımdan önce** canlıya uygulanmalı — yeni kod sütunu yazar, sütun yoksa
   PostgREST `insert`'i reddeder ve her çekim patlar. `backend/supabase/migrations/`
   sırayla çalıştırılır; hiçbiri geçmişteki bir dosyayı düzenleyerek eklenmez.
3. Production Branch ayarının doğru dala işaret ettiğinden emin ol —
   yanlışsa dağıtım "Ready" görünür ama alan adı eski sürümü servis eder.
4. Doğrula:
   ```bash
   curl https://<proje>.vercel.app/health          # {"ok":true}
   curl https://<proje>.vercel.app/api/jobs        # 401 (yoklama da token ister)
   ```

## Sorun giderme

- `pytest` içe aktarma hatası verirse repo kökünden çalıştırıldığından emin
  olun (`python -m pytest evals`).
- OpenCV kurulumu sorunluysa `opencv-python-headless` kullanın.
- `swift test` ilk kez bir Mac'te çalışıyorsa hata çıkması olası —
  `docs/FAZ2-PLAN.md`'de altı gerçek derleme/çalışma-zamanı hatası ve
  düzeltmeleri kayıtlı, aynı sınıftan bir hataya rastlarsan oraya bak.
- Vercel'de `FUNCTION_INVOCATION_FAILED` ya da sessiz zaman aşımı: dışa
  aktarım biçimini kontrol et — `export default handler` **çalışmaz**,
  Vercel bunu eski `(req, res)` imzası sanıp dönen `Response`'u yok sayar.
  Doğrusu `export default { fetch: handler }` (`backend/api/index.ts`,
  `backend/tests/router.test.ts`).
