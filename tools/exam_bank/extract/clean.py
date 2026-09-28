"""Line classification and text assembly.

The rule for text is §5.3/5: join what the typesetter split (line-end
hyphenation, lines of one paragraph), normalise to NFC — and change nothing
else. Spelling, punctuation and a missing space in the booklet stay as they
are ("hangisikatılmaz" is what 2012/1 printed).
"""
from __future__ import annotations

import re
import unicodedata
from typing import List, Optional, Sequence

from .columns import Line

# Running heads, footers and publisher notes. Matched against a whole line.
NOISE = [re.compile(p) for p in (
    r"^(\d{1,3}\s+)?Diğer sayfaya geçiniz\.?(\s+\d{1,3})?$",   # the page number may share its row
    r"^\d{4}\s*-\s*TUS.*$",                             # 2019-TUS 1. Dönem/TTBT …
    r"^.*\bTIP BİLİMLERİ TESTİ(\s*-?\s*\d)?$",           # TEMEL TIP BİLİMLERİ TESTİ-1
    r"^Bu testte (sırasıyla .*|\d+ soru vardır\.?)$",
    r"^soruları bulunmaktadır\.?$",
    r"^[AB]$",                                           # booklet letter at the top
    r"^\d{4}-[AB]-[A-Z]+-?\d?$",                         # 2006-B-TTBT-1
    r"^\(DUS[’']da sorulmaya uygun\)$",                  # Tusdata annotation
    r"^Tusdata[’']nın yorumları için .*$",
    r"^TUS (İLKBAHAR|SONBAHAR) \d{4}$",
    r"^(TEMEL|KLİNİK) BİLİMLER TESTİ$",
    r"^(Temel|Klinik) Bilimler Sınavı.*$",
    r"^Soru 1 [–-] 100$",
)]

# Lines after which nothing belongs to the question in progress: end of a
# test, an answer key, the rules page on the back cover.
STOP = [re.compile(p) for p in (
    r"TEST\S* BİTTİ",                                   # TEMEL TIP BİLİMLERİ TESTİ-1 BİTTİ.
    r"TEST\w* GEÇİNİZ",                                 # TESTE / TESTİNE GEÇİNİZ
    r"^\d{2}-\d{2}-\d{4}$",                             # the exam date heading an answer-key page (F3)
    r"CEVAP ANAHTARI",
    r"^Cevap Anahtarı",
    r"KİTAPÇIĞI$",
    r"^SINAVDA UYULACAK KURALLAR",
    r"^AÇIKLAMA$",
    r"^GENEL AÇIKLAMA",
)]

# The Tusdata compilation says in print when it changed a question: one line
# after the options ("Bu sorunun orijinal hali hatalı olması nedeniyle
# modifiye edilmiştir…") or three ("Orijinalinde, kafa karışıklığı …
# minör revizyon ile onarılmış, … sağlanmıştır."). 14 such notes, the same 14
# the 2026 currency analysis had counted. The question is then not ÖSYM's text.
REVISION_NOTE = [re.compile(p) for p in (
    r"^Bu sorunun orijinal hali .*modifi\s?ye edilmiştir",
    r"^Orijinalinde, kafa karışıklığı oluşturacak",
    r"^hazırlanmış bu soru minör revizyon ile onarılmış",
    r"^berrak şekilde aktarılması sağlanmıştır\.?$",
)]

KEY_PAIR = re.compile(r"(\d{1,3})\.\s*([A-E]|İPTAL)\b")
# A key grid row, as a column sees it: pairs, and at the gutter possibly a
# number whose letter fell in the other column ("1. B 48.") or a letter whose
# number did ("E 180. E 200.").
KEY_TOKEN = re.compile(r"^(\d{1,3}\.|[A-E]|İPTAL)$")
TABLE_KEY_LINE = re.compile(r"^(\d{1,3}\s+[A-E]\s*)+$")          # F6: "1 E 26 D 51 B 76 D"
OSYM_ANSWER = re.compile(r"DOĞRU\s*CEVAP\s*:?\s*([A-E])")
CANCELLED = re.compile(r"Bu soru iptal edilmiştir", re.IGNORECASE)

ROMAN_PREMISE = re.compile(r"^(I|II|III|IV|V|VI|VII|VIII)\.")
LOWER_START = re.compile(r"^[a-zçğıöşüâîû]")


# Glyphs set in the Symbol font reach the text layer as private-use code
# points, U+F000 + the Symbol encoding ("Ca\uf02b2" is Ca+2, "\uf061-keto"
# is α-keto, "39 \uf0b0C" is 39 °C). These are the ones the booklets use;
# anything else in the private-use area is left in place and reported
# (`unreadable`), never guessed.
SYMBOL_FONT = {
    0x20: " ", 0x2B: "+", 0x2D: "−", 0x3D: "=", 0x3C: "<", 0x3E: ">",
    0x61: "α", 0x62: "β", 0x63: "χ", 0x64: "δ", 0x65: "ε", 0x66: "φ", 0x67: "γ", 0x68: "η",
    0x69: "ι", 0x6B: "κ", 0x6C: "λ", 0x6D: "μ", 0x6E: "ν", 0x70: "π", 0x71: "θ", 0x72: "ρ",
    0x73: "σ", 0x74: "τ", 0x77: "ω", 0x44: "Δ",
    0xA3: "≤", 0xA5: "∞", 0xAC: "←", 0xAD: "↑", 0xAE: "→", 0xAF: "↓",
    0xB0: "°", 0xB1: "±", 0xB3: "≥", 0xB4: "×", 0xB7: "•", 0xB8: "÷", 0xB9: "≠", 0xBB: "≈",
    0xD6: "√", 0xD7: "·",
    # Wingdings-style arrow the 2012 booklet uses in "3’→5’ ekzonükleaz".
    0xE0: "→",
}
PRIVATE_USE = re.compile("[\ue000-\uf8ff]")
CID = re.compile(r"\(cid:\d+\)")


def symbols(text: str) -> str:
    return PRIVATE_USE.sub(lambda m: SYMBOL_FONT.get(ord(m.group(0)) - 0xF000, m.group(0)), text)


def unreadable(text: str) -> bool:
    """Glyphs the text layer does not name: an unmapped private-use code point
    or pdfminer's "(cid:129)" for a glyph with no Unicode at all."""
    return bool(PRIVATE_USE.search(text) or CID.search(text))


def nfc(text: str) -> str:
    return unicodedata.normalize("NFC", symbols(text))


def is_noise(text: str) -> bool:
    t = text.strip()
    return any(p.match(t) for p in NOISE)


def is_stop(text: str) -> bool:
    t = text.strip()
    return any(p.search(t) for p in STOP)


def is_revision_note(text: str) -> bool:
    t = text.strip()
    return any(p.match(t) for p in REVISION_NOTE)


def is_key_line(text: str) -> bool:
    t = text.strip()
    if TABLE_KEY_LINE.match(t):
        return True
    tokens = re.sub(r"(\d{1,3}\.)(?=[A-E]\b)", r"\1 ", t).split()
    return (len(tokens) >= 2 and all(KEY_TOKEN.match(x) for x in tokens)
            and any(x.endswith(".") for x in tokens) and any(not x.endswith(".") for x in tokens))


# "40.-41. SORULARI AŞAĞIDAKİ BİLGİLERE GÖRE CEVAPLAYINIZ." — a case shared
# by the questions it names (three in the whole folder: 2006/1 Klinik 40–41,
# 2009/1 and 2009/2 Klinik 73–74). What follows it belongs to each of them.
GROUP_HEAD = re.compile(r"^(\d{1,3})\.\s*(?:-|ve)\s*(\d{1,3})\.\s*SORULARI\b")
GROUP_HEAD_TAIL = re.compile(r"^(AŞAĞIDAKİ\s+)?(BİLGİLERE\s+)?GÖRE\s+CEVAPLAYINIZ\.?$")


def is_page_number(line: Line, page_height: float) -> bool:
    return bool(re.fullmatch(r"\d{1,3}", line.text.strip())) and (
        line.top > 0.85 * page_height or line.bottom < 0.12 * page_height)


# Tusdata's own tag, set in the stem's last line: not part of the question.
INLINE_NOTE = re.compile(r"\s*\(DUS[’']da sorulmaya uygun\)")


def strip_inline_notes(text: str) -> str:
    return INLINE_NOTE.sub("", text)


def assemble(lines: Sequence[Line], pitch: Optional[float] = None) -> str:
    """Lines of one stem or option → text.

    Paragraphs are kept apart by "\\n" where the booklet leaves them apart —
    a clearly larger gap within a column, or a premise line ("I. …",
    "II. …") — because a case, its premises and its question
    sentence read as three blocks. Everything else is joined with a space,
    and a word hyphenated at the end of a line is rejoined when the next line
    carries on in lower case ("bir-" + "leştiren")."""
    if not lines:
        return ""
    if pitch is None:
        pitch = typical_pitch(lines)
    out = ""
    prev: Optional[Line] = None
    for line in lines:
        text = line.text.strip()
        if not text:
            continue
        if prev is None:
            out = text
        else:
            # A question that runs on into the next column or page is still
            # one paragraph; the gap across a column break means nothing.
            gap_break = line.segment == prev.segment and bool(pitch) and line.top - prev.top > 1.6 * pitch
            new_para = gap_break or ROMAN_PREMISE.match(text) or ROMAN_PREMISE.match(prev.text.strip())
            if out.endswith("-") and len(out) > 1 and out[-2].isalpha() and LOWER_START.match(text):
                out = out[:-1] + text          # "bir-" + "leştiren"
            elif out.endswith("-") and len(out) > 1 and out[-2].isalnum():
                out += text                    # "HMG-" + "KoA": a real hyphen, still no space
            elif new_para:
                out += "\n" + text
            else:
                out += " " + text
        prev = line
    return nfc(re.sub(r"[ \t]+", " ", strip_inline_notes(out))).strip()


def typical_pitch(lines: Sequence[Line]) -> Optional[float]:
    gaps = sorted(b.top - a.top for a, b in zip(lines, lines[1:])
                  if a.segment == b.segment and 4 < b.top - a.top < 40)
    return gaps[len(gaps) // 2] if gaps else None
