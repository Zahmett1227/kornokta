# Çıkmış soru bankası üretim hattı

Sahibinin çıkmış soru PDF'lerini, telefona tek seferde içe aktarılan bir soru
bankasına çevirir. Tasarım: [`docs/PLAN-cikmis-soru-bankasi.md`](../../docs/PLAN-cikmis-soru-bankasi.md)
§5; karar: [`docs/ADR-012`](../../docs/ADR-012-cikmis-soru-bankasi.md).

**Durum (Faz 0):** yalnız kaynak kaydı ve kuru çalıştırma. Çıkarım aşamaları
(A1–A9) Faz A1'in işi; `--dry-run` olmadan çalıştırmak bunu söyler ve sıfırdan
farklı bir kodla çıkar.

## Telif — bağlayıcı

- PDF'ler **repoya girmez.** Klasör yalnız ortam değişkeninden okunur:
  `EXAM_SOURCE_DIR`.
- Çıktı (`tools/exam_bank/out/`) gitignore'lu.
- Testler sentetik fikstür kullanır; hiçbir kitap sayfası fikstür olmaz
  (`evals/fixtures` kuralının aynısı).

## Çalıştırma

Standart kütüphaneyle çalışır; repo kökünden, yerel `.venv` (Python 3.9) ya da
3.11:

```bash
python -m tools.exam_bank.build --dry-run                     # yalnız sources.json'u doğrular
EXAM_SOURCE_DIR="…/01 - TUS Çıkmış Sorular" python -m tools.exam_bank.build --dry-run --list
python -m pytest tools -q
```

Kaynak klasör verilince kuru çalıştırma üç şeyi denetler:

1. Kayıttaki her dosya yerinde mi.
2. İçeriği değişmemiş mi (sha256). Değişmiş bir kitapçık soru numaralarını
   kaydırabilir; o numaralardan türeyen soru kimlikleri sessizce kaymasın diye
   kaynak sabitlenir.
3. Klasörde **kayıtsız PDF kalmamış mı.** Her PDF ya kayıtlı ya da `excluded`
   altında gerekçesiyle dışarıda. Sessizce atlanan bir kitapçık, hiç var
   olmayan bir kitapçıktan ayırt edilemez.

## `sources.json`

Her kaynak dosya bir ya da birden çok **kağıt** taşır. Kağıt kimliği
`TUS-<yıl>-<dönem 1|2>-<T|K|T2>`; soru kimliği buna `-<NNN>` eklenerek türer ve
bir kez verildikten sonra değişmez.

| Aile | Kapsam | Numaralandırma | Anahtar |
|---|---|---|---|
| F1 | 2006–2008 | Test başına 1–100 | yok |
| F2 | 2009–2011, Temel+Klinik tek PDF | **Her test 1'den** (test başlığı ayırır) | son iki sayfa |
| F3 | 2012–2021 | Test başına 1–120 | son sayfa |
| F4 | 2022–2026 ÖSYM (~%10 görünür) | Test başına | görünen soruda |
| F5 | Tusdata derlemesi, 2024/1–2025/2 | **Sınav boyunca kesintisiz** (Temel 1–100, Klinik 101–200 → `numberOffset: 100`) | 2024/1 hariç |
| F6 | 2026/2 yeniden dizimi | 1–100 | tablo |

Tarih, süre (`timeLimitMinutes`, F2'de iki testin ortak `sessionTimeLimitMinutes`'ı)
ve "yanlışların dörtte biri düşülür" kuralı (`penalty`) yalnız kitapçıkta
okunduğu yerde dolu; okunamayan yer `null`/`unknown`. Tahmin yazılmaz.

Doğrulayıcı (`registry.py`) her hatayı toplar, ilkinde durmaz. Başlıca
kuralları: aile ile anahtar kaynağının tutarlılığı (F1 anahtarsız, F6
yeniden dizim, …), aynı kağıdın farklı kaynaklarda aynı tanımı taşıması,
kesintisiz numaralanan dosyada aralıkların çakışmaması, aynı içeriğin iki adla
kaydedilmemesi, dışlama kuralının gerekçeli olması ve kayıtlı bir dosyayı
gizlememesi.

**Unicode:** macOS dosya adlarını NFD döndürür (`ş` = `s` + birleşik çengel);
`sources.json`'da yazılan ad NFC'dir. Karşılaştırmalar NFC'de yapılır
(`registry.nfc`) — docs/ADR-001'in sorunu, dosya yollarında.
