"""A2 — answer keys and cancellations (docs/PLAN-cikmis-soru-bankasi.md §5.4).

Keys are read from whole-page rows, not columns: a key grid is set across the
page, and the column gutter falls between a number and its letter
("1. B | 48. D"). A key row is nothing but pairs — "N. X", or "N X" in the
2026/2 reconstruction's table — where X is A–E or İPTAL.

| Family | Where                                          | Paper              |
|--------|------------------------------------------------|--------------------|
| F2     | last two pages, "A KİTAPÇIĞI"                  | header TEMEL/KLİNİK |
| F3     | last page                                      | the file's paper   |
| F4     | "DOĞRU CEVAP: X" under each visible question   | (read by A1)       |
| F5     | a key page after each exam but 2024/1; 1–200   | ≤100 Temel, >100 Klinik |
| F6     | last page, table                               | the file's paper   |
| F1     | none                                           | —                  |
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

from . import registry as reg
from .extract.columns import Page, Word, join_words, rows

LETTERS = "ABCDE"
NUMBER = re.compile(r"^(\d{1,3})\.?$")
ANSWER = re.compile(r"^([A-E]|İPTAL|İptal)$")
GLUED = re.compile(r"^(\d{1,3}\.)([A-E])$")
KEY_HEADER = re.compile(r"CEVAP ANAHTARI|Cevap Anahtarı")
MIN_PAIRS = 20  # a key page carries 100–200 pairs; a question page, a handful at most


@dataclass(frozen=True)
class Pair:
    number: int
    answer: Optional[int]  # 0…4, None when cancelled
    cancelled: bool
    page: int


@dataclass
class Key:
    """One paper's key as printed."""
    paper_id: str
    source: str                      # osym | tusdata | reconstruction
    file: str
    entries: Dict[int, Pair] = field(default_factory=dict)
    duplicates: List[int] = field(default_factory=list)


def pairs_in(words: Sequence[Word], page: int) -> List[Pair]:
    """Every "N. X" (or "N X") pair on the page, row by row, left to right."""
    out: List[Pair] = []
    for row in rows(words):
        tokens: List[str] = []
        for w in sorted(row, key=lambda w: w.x0):
            m = GLUED.match(w.text)
            tokens.extend([m.group(1), m.group(2)] if m else [w.text])
        i = 0
        while i < len(tokens) - 1:
            n, a = NUMBER.match(tokens[i]), ANSWER.match(tokens[i + 1])
            if n and a:
                letter = a.group(1)
                cancelled = letter.upper() == "İPTAL"  # "İptal" (F3) and "İPTAL" (F2)
                out.append(Pair(int(n.group(1)), None if cancelled else LETTERS.index(letter), cancelled, page))
                i += 2
            else:
                i += 1
    return out


def key_region(page: Page) -> List[Word]:
    """On a page with a "CEVAP ANAHTARI" heading, only what is below it —
    and, when the heading sits in the right column, only that column: the
    compilation sets 2025/1's key beside that exam's last questions (page
    62). A heading centred over the page (43, 87) heads a full-width grid."""
    heads = [w for w in page.words if w.text in ("ANAHTARI", "Anahtarı")]
    if not heads:
        return page.words
    top = min(w.top for w in heads)
    head_x0 = min(r[0].x0 for r in (sorted(r, key=lambda w: w.x0) for r in rows(page.words))
                  if KEY_HEADER.search(join_words(r)))
    left = page.width / 2 - 20 if head_x0 > page.width / 2 - 10 else 0.0
    return [w for w in page.words if w.top > top and w.x0 >= left]


def key_pages(pages: Sequence[Page]) -> List[Tuple[Page, List[Pair]]]:
    out = []
    for page in pages:
        pairs = pairs_in(key_region(page), page.number)
        if len(pairs) >= MIN_PAIRS:
            out.append((page, pairs))
    return out


def _f2_test(page: Page) -> str:
    """Which test a 2009–2011 key page is for, from its heading: "KLİNİK TIP
    BİLİMLERİ TESTİ", or "TEMEL TIP BİLİMLERİ TESTİ-1" / "-2" — 2011/1 is
    Temel-1 and Temel-2, not Temel and Klinik (its own cover says so)."""
    head = " ".join(join_words(r) for r in rows(page.words)[:6])
    if "KLİNİK" in head:
        return "K"
    if re.search(r"TESTİ\s*-?\s*2\b", head):
        return "T2"
    return "T"


def read_keys(source: reg.Source, pages: Sequence[Page],
              exam_pages: Optional[Dict[str, Tuple[int, int]]] = None) -> Dict[str, Key]:
    """Keys for the papers of one source file whose keySource is not "none"
    and not ÖSYM's per-question mark (F4, read by A1).

    `exam_pages` maps paper id → (first, last) page its questions occupy;
    the compilation needs it to tell which exam a key page belongs to."""
    keyed = [p for p in source.papers if p.key_source != "none"]
    if source.family in ("F1", "F4") or not keyed:
        return {}
    found = key_pages(pages)
    keys = {p.id: Key(p.id, p.key_source, source.file) for p in keyed}

    def put(pid: str, pair: Pair, number: int) -> None:
        key = keys[pid]
        if number in key.entries:
            key.duplicates.append(number)
        key.entries[number] = Pair(number, pair.answer, pair.cancelled, pair.page)

    if source.family == "F2":
        by_test = {p.test: p.id for p in keyed}
        for page, pairs in found:
            test = _f2_test(page)
            if test in by_test:
                for pair in pairs:
                    put(by_test[test], pair, pair.number)
    elif source.family in ("F3", "F6"):
        [paper] = keyed
        for page, pairs in found[-1:]:  # the key is the last such page
            for pair in pairs:
                put(paper.id, pair, pair.number)
    elif source.family == "F5":
        exams: Dict[Tuple[int, int], List[reg.Paper]] = {}
        for p in keyed:
            exams.setdefault(p.exam, []).append(p)
        for exam, papers in exams.items():
            spans = [exam_pages[p.id] for p in papers if exam_pages and p.id in exam_pages]
            if not spans:
                continue
            last_page = max(s[1] for s in spans)
            later_starts = [first for pid, (first, _) in (exam_pages or {}).items()
                            if first > last_page]
            limit = min(later_starts) if later_starts else 10 ** 6
            page_pairs = next((pp for page, pp in found if last_page <= page.number < limit), None)
            if page_pairs is None:
                continue
            for pair in page_pairs:
                for p in papers:
                    if p.number_offset < pair.number <= p.number_offset + p.expected:
                        put(p.id, pair, pair.number - p.number_offset)
    return {pid: k for pid, k in keys.items() if k.entries}


def completeness(key: Key, expected: int) -> List[str]:
    """V3 for one printed key: every number 1…N exactly once."""
    problems = []
    missing = [n for n in range(1, expected + 1) if n not in key.entries]
    extra = sorted(n for n in key.entries if not 1 <= n <= expected)
    if missing:
        problems.append(f"{key.paper_id}: anahtarda eksik numara {missing}")
    if extra:
        problems.append(f"{key.paper_id}: anahtarda kağıtta olmayan numara {extra}")
    if key.duplicates:
        problems.append(f"{key.paper_id}: anahtarda iki kez geçen numara {sorted(set(key.duplicates))}")
    return problems
