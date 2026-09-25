# Çıkmış soru bankası üretim hattı

Sahibinin çıkmış soru PDF'lerini, telefona tek seferde içe aktarılan bir soru
bankasına çevirir. Tasarım: [`docs/PLAN-cikmis-soru-bankasi.md`](../../docs/PLAN-cikmis-soru-bankasi.md)
§5; karar: [`docs/ADR-012`](../../docs/ADR-012-cikmis-soru-bankasi.md).

## Telif — bağlayıcı

- PDF'ler **repoya girmez.** Klasör yalnız ortam değişkeninden okunur:
  `EXAM_SOURCE_DIR`.
- Bütün çıktı (`tools/exam_bank/out/`: aşama JSON'ları, sayfa önbelleği,
  kırpıntılar, V9 sayfası, paket) gitignore'lu; V10 bunu her koşuda denetler.
- Testler sentetik fikstür kullanır; hiçbir kitap sayfası fikstür olmaz
  (`evals/fixtures` kuralının aynısı).
- V9 örneklem sayfası (`out/V9-orneklem.html`) kitapçık içeriği taşır:
  yalnız yerelde açılır, hiçbir yere yüklenmez.

## Çalıştırma

Repo kökünden, yerel `.venv` (Python 3.9; `pip install -r tools/exam_bank/requirements.txt`),
backend için Node 22:

```bash
export EXAM_SOURCE_DIR="…/01 - TUS Çıkmış Sorular"

# 1. Deterministik aşamalar A1–A4 (ilk koşu ~7 dk, sonra önbellekten saniyeler)
python -m tools.exam_bank.build

# 2. Model aşamaları — finish her seferinde eksik olanı ve komutunu söyler
python -m tools.exam_bank.finish
cd backend && OPENAI_EXAM_USD_PER_MILLION_INPUT_TOKENS=0.2 \
  OPENAI_EXAM_USD_PER_MILLION_CACHED_INPUT_TOKENS=0.02 \
  OPENAI_EXAM_USD_PER_MILLION_OUTPUT_TOKENS=1.2 \
  npm run exam-bank -- ../tools/exam_bank/out/jobs/<repair|vision|label|check>.json

# 3. Kapılar ve paket — V9 için örneklem sayfasını gözden geçirip onayla
python -m tools.exam_bank.finish --human-check "Ad"
```

`python -m tools.exam_bank.build --dry-run` yalnız kaydı ve klasörü denetler
(sha256, kayıtsız PDF yok). Model koşucusu kaldığı yerden sürer, her çağrıyı
`out/ledger.jsonl`'a yazar ve toplam harcama `EXAM_BANK_MAX_USD`'yi ($5)
aşacaksa durur; fiyat girilmeden çalışmaz.

## Aşamalar

| Aşama | Modül | Ne yapar | Çıktı |
|---|---|---|---|
| A1 | `extract/` | Kelime kutularından sütun, satır, soru, beş şık | `out/a1.json` |
| A2 | `keys.py`, `a2.py` | Anahtar sayfaları (tam sayfa satırları), iptaller; V3, V4 | `out/a2.json` |
| A3 | `merge.py` | Soru başına tek kayıt; resmî metin öncelikli; V5 çapaları | `out/a3.json` |
| A4 | `figures.py` | Görsel gerekli / atıf / yok | `out/a3.json` |
| A5 | model (`repair`) | V2'den düşen soruyu kırpıntısından okur | `out/a6.json` |
| A6 | model (`vision`) | 2011/1'i sayfa görüntüsünden okur | `out/a6.json` |
| A7 | model (`label`) + `subjects.py` | Ders oyu → monoton bölütleme → ders/konu | `out/a7.json` |
| V6 | model (`check`) | Kağıt başına 15 soruyu anahtarsız çözer; anahtar bu kitapçığın mı | `out/a7.json` |
| A8 | `gates.py` | V1–V10 | ekran |
| A9 | `package.py` | `out/CizgiSoruBankasi/` (manifest, bank.json, pdf/) | paket |

Banka biçimi: [`exam_bank.schema.json`](exam_bank.schema.json) (Faz A2'de Swift
`ExamBankDocument` bununla kilitlenecek).

## Kitapçıkların öğrettikleri (her biri kodda gerekçesiyle)

- **Sütun ayırıcı:** numara–metin boşluğu da gutter kadar temiz; gerçeği sayfa
  ortasına en yakını, belge medyanıyla dengeli. Tam genişlik satırlar (başlık,
  açıklama, kurallar) önce ayrılır.
- **Filigran:** 2013–2017 "ÖSYM" 250 pt harf, 2026/1 45° döndürülmüş cümle,
  2012 harf harf görüntü — boyut, döndürme, `/Artifact` ve 3+ sayfada tekrar ile
  ayıklanır.
- **Kelime aralığı:** 2013/2 boşluk glifi koymuyor (1,5 pt eşik); derlemede
  harf önceki boşluğa biniyor (aynı boy/taban çizgisindeki iki kutu hep boşluk).
- **Numaralar:** yinelenen basım (2013/2 K "9." ×2), ilk hanesi kayıp ("08." =
  108), asılı olmayan (2025/1 K 104) — üçü de komşu numaralarca doğrulanırsa
  alınır ve raporlanır.
- **Derleme:** 14 soruda "modifiye/revizyon" notu (→ `modified`); 2024/1
  Klinik'in numarası ÖSYM'den kayıyor — resmî görünür sorular çapa, iki yanı
  tutarsız 22 soru bankaya girmez.
- **2011/1:** Temel Testi-1 ve -2 (Klinik değil; o sınavın Klinik'i klasörde
  yok). Metin katmanı sayfa sayfa değişen şifreyle bozuk, komşu sayfanın metni
  kutu dışında; anahtarı okunuyor.
- **Ders sırası:** Temel 7 ders; Klinik 6 blok (Küçük Stajlar iki kez: dahilî
  sonra, cerrahî sonra); Temel-2'nin sırası yıla göre değişir, oylardan okunur.

## `sources.json`

Her kaynak dosya bir ya da birden çok **kağıt** taşır. Kağıt kimliği
`TUS-<yıl>-<dönem 1|2>-<T|K|T2>`; soru kimliği buna `-<NNN>` eklenerek türer ve
bir kez verildikten sonra değişmez.

| Aile | Kapsam | Numaralandırma | Anahtar |
|---|---|---|---|
| F1 | 2006–2008 | Test başına 1–100 | yok |
| F2 | 2009–2011, iki test tek PDF (2011/1: Temel-1 + Temel-2) | **Her test 1'den** | son iki sayfa |
| F3 | 2012–2021 | Test başına 1–120 | son sayfa |
| F4 | 2022–2026 ÖSYM (~%10 görünür) | Test başına | görünen soruda |
| F5 | Tusdata derlemesi, 2024/1–2025/2 | **Sınav boyunca kesintisiz** (Klinik 101–200 → `numberOffset: 100`) | 2024/1 hariç |
| F6 | 2026/2 yeniden dizimi | 1–100 | tablo |

Tarih, süre ve "yanlışların dörtte biri düşülür" kuralı yalnız kitapçıkta
okunduğu yerde dolu; okunamayan yer `null`/`unknown`. Tahmin yazılmaz.

**Unicode:** macOS dosya adlarını NFD döndürür; karşılaştırmalar NFC'de
(`registry.nfc`) — docs/ADR-001'in sorunu, dosya yollarında.
