# Mac'te gold pasaj kart kalite ölçümü — Faz 3 çıkış kapısı

Bu belge Faz 3'ün kalan tek kalemi için **senin** uygulayacağın adımları
içerir (`docs/FAZ3-PLAN.md`, F3-10). Kod tarafı zaten hazır: kart üretimi
gerçek bir anahtarla uçtan uca doğrulandı (`docs/FAZ3-PLAN.md`'de "F3-9"),
ve rubrik puanlarını toplayıp bir kabul/inceleme/ret dağılımına çeviren araç
da artık yazılı ve test edilmiş (`evals/card_quality/`). Eksik olan tek şey
senin kendi kitabından gerçek pasajlar seçip üretilen kartları elle
puanlaman.

> **Faz 2'nin altın-set belgesinden (`docs/MAC-ADIMLARI.md`) fark:** orada
> OCR/işaret tespiti doğruluğu ölçülüyordu, 100+ gerçek fotoğraf gerekiyordu.
> Burada ölçülen **kart üretiminin kalitesi** — zaten temiz bir metinden
> (senin elle yazdığın ya da OCR'dan çıkmış, uzlaştırılmış bir pasajdan)
> kart üretiliyor, fotoğraf/işaret tespiti devre dışı. ANA-PLAN §25 kaç
> pasaj gerektiğini sayıca belirtmiyor — aşağıdaki "10-20 pasaj" bir öneri,
> bir zorunluluk değil (§0.6: uydurma sayı yok).

---

## Adım 0 — Depoyu güncelle, testleri doğrula (2 dk)

```bash
cd ~/Desktop/kornokta
git pull origin claude/proje-analizi-planlama-r7lxw4
python -m pytest evals -q
cd backend && npm test && cd ..
```

Beklenen: hepsi geçer (452 Python, 419 backend). Geçmezse buradan devam
etme, bana yaz.

`.env`'inde `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_MAX_OUTPUT_TOKENS=4096`
zaten kurulu olmalı (`docs/OPENAI-GEMINI-KURULUM.md`) — F3-9'da bir kez
gerçek bir kart üretmiştin, aynı kurulum burada da kullanılacak.

---

## Adım 1 — Gold pasajları seç (kendi kitabından, 30–45 dk)

Önerilen başlangıç: **10–20 pasaj**, birkaç farklı ders/konudan, hepsi
gerçekten okuyup öğrenmek istediğin cümleler. Seçerken:

- Doz, birim, yön, olumsuzluk veya ilaç/mikroorganizma adı içeren en az
  yarısı olsun — kartın kaynağa sadık kalıp kalmadığını asıl bunlar sınar.
- En az birkaçı "zor" olsun: iki yakın kavramı ayıran, istisna içeren,
  mekanizma anlatan cümleler (§13.1'in dört kart tipini hepsini bir kez
  görmek için).
- Pasajın kendisini (metnini) hiçbir yere commit etme — telifli kitap
  metni bu da geçerli (ANA-PLAN §26, §30 ile aynı ihtiyat). Elinde bir yerde
  (Notlar, düz metin dosyası, ne istersen) tut, repoya girmesin.

---

## Adım 2 — Her pasaj için gerçek kart üret (pasaj başına ~15 sn)

`scripts/cards.ts` bunun için zaten `--text`/`--output` bayraklarını
destekliyor (kaynağı düzenlemene gerek yok):

```bash
cd backend
npm run cards -- --text "BURAYA KENDİ PASAJIN" --output ../evals/reports/cards-01.json
npm run cards -- --text "İKİNCİ PASAJ"           --output ../evals/reports/cards-02.json
# ...10-20 pasaj için tekrarla, her seferinde --output'u değiştir
cd ..
```

Her çalıştırma **tek bir gerçek OpenAI çağrısı** yapar (gerçek maliyet
oluşur — terminaldeki `estimatedCostUSD` hâlâ güvenilir değil, çünkü
`OPENAI_USD_PER_MILLION_*` alanları hâlâ 0; gerçek harcamayı OpenAI'ın kendi
kullanım sayfasından takip et). `evals/reports/` zaten tamamen gitignore'lu,
ayrı bir kural eklemene gerek yok. Her dosyadaki `cards[].id` bir sonraki
adımda `cardId` olarak kullanılacak.

---

## Adım 3 — Her kartı ANA-PLAN §23.3 rubriğiyle puanla (kartın kendisi, 60-90 dk)

Yedi kriter, her biri 0-2 puan (`evals/card_quality/rubric.py`'deki
`CRITERIA` listesiyle birebir):

| Kriter | Ne soruyor |
|---|---|
| `source_faithfulness` (kaynağa sadakat) | Cevap yalnızca pasajdan mı çıkıyor, dışarıdan bilgi eklenmiş mi? |
| `single_clear_answer` (tek ve net cevap) | Soru tek bir doğru cevaba mı işaret ediyor? |
| `medical_accuracy` (tıbbi doğruluk) | Cevap tıbben doğru mu (senin kendi bilgine göre)? |
| `question_clarity` (soru açıklığı) | Soru belirsiz/çift anlamlı mı? |
| `learning_value` (öğrenme değeri) | Gerçekten hatırlamaya değer bir şey mi, yoksa önemsiz bir detay mı? |
| `non_redundancy` (tekrarsızlık) | Aynı pasajdan üretilen başka bir kartla neredeyse aynı şeyi mi soruyor? |
| `appropriate_difficulty` (uygun zorluk) | Ne çok kolay ne çok zor mu? |

Şu formatta bir dosya oluştur (`evals/fixtures/` altına — o dizin zaten
tamamen gitignore'lu, bu dosya için ayrı bir kural eklemene gerek yok):

```json
{
  "schemaVersion": "1.0",
  "entries": [
    {
      "cardId": "card_1",
      "goldPassageLabel": "Farmakoloji, anafilaksi (kendi notun, içerik değil)",
      "scores": {
        "source_faithfulness": 2,
        "single_clear_answer": 2,
        "medical_accuracy": 2,
        "question_clarity": 1,
        "learning_value": 2,
        "non_redundancy": 2,
        "appropriate_difficulty": 1
      },
      "notes": "opsiyonel serbest metin"
    }
  ]
}
```

Şema: `evals/card_quality/scores.schema.json`. `cardId`, Adım 2'deki JSON
çıktısındaki `cards[].id` ile eşleşmeli.

---

## Adım 4 — Dağılımı hesapla

```bash
python -m evals.card_quality.aggregate evals/fixtures/card-quality-scores.json
```

Her kartın toplamını/kararını (`accept`/`revise`/`reject`) ve toplam
dağılımı basar. **Bu araç sana tek bir "geçti/kaldı" cevabı vermez** —
ANA-PLAN §25 bir kabul yüzdesi belirtmiyor, yalnızca "kalite rubriği kabul
sınırını geçmelidir" diyor; dağılımı görüp bu cümlenin karşılandığına sen
karar veriyorsun (§0.6: uydurma bir eşik koymaktansa).

Hata alırsan (`ERROR ...` satırları) — çoğunlukla bir `cardId` eksik/yanlış
ya da bir puan 0-2 aralığı dışında; mesaj hangisi olduğunu söylüyor.

---

## Sonucu bana bildir

Dağılım ne çıkarsa çıksın (yüksek kabul oranı ya da çok sayıda ret), bana
yapıştır. Ret oranı yüksekse bu bir hata değil — tam olarak bu ölçümün
bulması gereken şey; hangi rubrik kriterinde sistematik olarak düştüğünü
görürsek (örn. hep `medical_accuracy` düşükse) prompt'ta düzeltilecek somut
bir yer buluruz.
