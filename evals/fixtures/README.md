# Fixtures — yalnız yerel

Bu dizin altın test setinin **gerçek sayfa görsellerini** tutar ve `.gitignore` ile korunur: telifli kitap sayfaları repoya **asla commit edilmez** (ANA-PLAN §26, §30).

Düzen:

```text
fixtures/
├── samples/     # Sentetik/üretilmiş örnek görüntüler (araç testleri için)
├── highlight/   # printed_highlight kategorisi
├── underline/   # printed_ink_underline, pencil_underline
├── margin/      # printed_with_margin_note
├── handwriting/ # handwriting_heavy
├── layout/      # complex_layout
└── poor/        # poor_capture
```

Görselleri ekledikten sonra `evals/gold-manifest.json` içine girdi ekleyin ve doğrulayın:

```bash
python -m evals.ocr_eval.validate_manifest evals/gold-manifest.json --check-files
```

Çekim ve etiketleme kuralları: [docs/GOLD-SET-GUIDE.md](../../docs/GOLD-SET-GUIDE.md)
