"""A1 — deterministic text extraction (docs/PLAN-cikmis-soru-bankasi.md §5.3).

Everything here works on plain word boxes (`columns.Word`), never on a PDF
object: `pdfwords` is the only module that opens a PDF, so every rule can be
tested with synthetic boxes and no copyrighted page ever becomes a fixture.
"""
