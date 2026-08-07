# Runbook

Güncel durum (2026-08-07): Faz 0–6 tamam ve cihazda doğrulandı; galeriden
fotoğraf ekleme ve beş şıklı (TUS tipi) kart `main`'de. Kalan iş beş şıklı
kartın kalite döngüsü (`CLAUDE.md` → "Sıradaki iş"). Üç ayrı test paketi var —
Python (eval araçları), Swift (iOS mantığı), TypeScript (backend).

## Python — eval araçları

```bash
pip install -r evals/requirements.txt

python -m pytest evals -q                                        # 517 test
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json --check-files
python -m evals.spikes.marker_detection.run --demo                # sentetik demo, ağ gerekmez
```

Gerçek gold-set ölçümü (20+ görüntü gerekli, `docs/MAC-ADIMLARI.md`):

```bash
python -m evals.ocr_eval.gold_marker_report --vision evals/reports/vision.json
python -m evals.ocr_eval.vision_report evals/reports/google.json --verbose
```

## Swift — iOS mantığı (Xcode gerekmez)

```bash
cd ios/CizgiCore
swift test                                                        # yalnız bir Mac'te
```

Paket **Linux'ta derlenmez** (CoreGraphics, SwiftData). Foundation'a bağlı yeni
mantık, bir Swift araç zinciri kurup yalnız o dosyaları içeren izole bir pakette
gerçekten koşturulabilir — PR #27'nin 63 testi böyle doğrulandı. SwiftUI
dosyaları için elde yalnız `swiftc -parse` var; o **sözdizimi** kontrolüdür,
tip/aşırı-yükleme hatasını yakalamaz.

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
npm test                                                          # 508 test
```

Yerel sunucu (yalnız 127.0.0.1, dışarıya açılmaz):

```bash
npm run serve
curl http://127.0.0.1:8787/health                                # {"ok":true}
```

Gerçek Google Document AI çağrısı (kimlik bilgisi gerekli, `.env`):

```bash
npm run ocr -- --input ../evals/fixtures --output ../evals/reports/google.json
```

## Anahtar yönetimi (§0.7, §7.3)

- Google servis hesabı kimlik bilgisi **yalnız iki biçimde** yaşar:
  - Yerelde: `.env`'deki `GOOGLE_APPLICATION_CREDENTIALS`, indirilen JSON
    dosyasının **yolu**. Dosyanın kendisi repo dışında durur.
  - Vercel'de: `GOOGLE_CREDENTIALS_JSON`, dosyanın **içeriği** tek satır
    JSON olarak (dosya yolu orada işe yaramaz — sunucuda dosya yok).
- `DEVICE_TOKEN` iki yerde: backend ortam değişkeni + telefonun Keychain'i.
  Üçüncü kopya yok. Üretmek için: `npm run token` (yalnız ekrana basar, hiçbir
  yere yazmaz).
- `.env` dosyaları gitignore'ludur; asla commit edilmez.
- iOS uygulamasına hiçbir anahtar gömülmez — telefon backend'e cihaz
  tokenıyla konuşur, Google anahtarını hiç görmez.

## Vercel'e dağıtım

Tam adımlar ve dağıtımda çıkan beş gerçek tuzak, "Vercel'e dağıtım" başlığı
altında: [`backend/README.md`](../backend/README.md).

Kısaca:
1. Root Directory = `backend`
2. Environment Variables: `.env.example`'daki listeyle aynı, artı
   `GOOGLE_CREDENTIALS_JSON`. **İş kuyruğu için şart:** `SUPABASE_URL` ve
   `SUPABASE_SERVICE_ROLE_KEY` (ADR-006). İkincisi RLS'i tamamen atlar — repoya
   girmez, yalnız yerel `.env` ve Vercel proje ayarları.
   **Migration sırası (kural):** `jobs` tablosuna sütun ekleyen bir değişiklik
   **dağıtımdan önce** canlıya uygulanmalı — yeni kod sütunu yazar, sütun yoksa
   PostgREST `insert`'i reddeder ve her çekim patlar. `backend/supabase/migrations/`
   sırayla çalıştırılır; hiçbiri geçmişteki bir dosyayı düzenleyerek eklenmez.
3. Production Branch ayarının doğru dala işaret ettiğinden emin ol —
   yanlışsa dağıtım "Ready" görünür ama alan adı eski sürümü servis eder.
4. Doğrula:
   ```bash
   curl https://<proje>.vercel.app/health          # {"ok":true}
   curl https://<proje>.vercel.app/api/ocr         # 405, "Yalnızca POST."
   curl -X POST https://<proje>.vercel.app/api/ocr # 401, "Yetkisiz."
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
