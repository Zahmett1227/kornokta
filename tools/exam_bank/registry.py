"""The source registry: which PDF becomes which exam paper.

`sources.json` is the single place that says "this file is the 2019 spring
basic-sciences booklet, 120 questions, ÖSYM's own key". Everything the build
later does — segmenting questions, reading keys, minting question IDs — hangs
off it, so it is validated before anything is read (docs/PLAN-cikmis-soru-
bankasi.md §5.2).

Standard library only: this runs on the repo's local `.venv` (Python 3.9) and
on CI (3.11) with nothing to install.
"""
from __future__ import annotations

import fnmatch
import json
import re
import unicodedata
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Dict, List, Optional, Tuple

REGISTRY_PATH = Path(__file__).with_name("sources.json")
SCHEMA_VERSION = 1

FAMILIES = ("F1", "F2", "F3", "F4", "F5", "F6")
SOURCE_KINDS = ("osym", "osymPartial", "tusdata", "reconstruction")
KEY_SOURCES = ("osym", "tusdata", "reconstruction", "none")
PENALTIES = ("quarter", "unknown")
TESTS = ("T", "K", "T2")

# Families whose multi-paper files number one exam straight through (Temel
# 1–100, Klinik 101–200) rather than restarting at 1 for each test.
CONTINUOUS_NUMBERING = ("F5",)

# TUS-<year>-<session 1|2>-<T|K|T2>. The question ID appends -<NNN>, so this
# prefix must never change once a bank has been imported (§6).
PAPER_ID = re.compile(r"^TUS-(20\d\d)-([12])-(T|K|T2)$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
ISO_DATE = re.compile(r"^(20\d\d)-(\d\d)-(\d\d)$")

# What each family is allowed to claim. A family is a layout *and* a
# provenance; a registry entry that contradicts its own family is a typo that
# would otherwise surface much later as a paper scored against no key, or an
# unofficial key labelled as ÖSYM's.
FAMILY_RULES: Dict[str, Tuple[Tuple[str, ...], Tuple[str, ...]]] = {
    # family: (allowed sourceKind, allowed keySource)
    "F1": (("osym",), ("none",)),
    "F2": (("osym",), ("osym",)),
    "F3": (("osym",), ("osym",)),
    "F4": (("osymPartial",), ("osym",)),
    "F5": (("tusdata",), ("tusdata", "none")),
    "F6": (("reconstruction",), ("reconstruction",)),
}


def nfc(text: str) -> str:
    """macOS hands back file names decomposed (NFD: "s" + combining cedilla),
    while a name typed into `sources.json` is composed (NFC: "ş"). Compared
    raw, `yenikeşif/` never matches itself — docs/ADR-001's normalization
    problem, in file paths this time."""
    return unicodedata.normalize("NFC", text)


@dataclass(frozen=True)
class Paper:
    id: str
    date: Optional[str]
    expected: int
    number_offset: int
    time_limit_minutes: Optional[int]
    penalty: str
    key_source: str

    @property
    def year(self) -> int:
        return int(self.id.split("-")[1])

    @property
    def session(self) -> int:
        return int(self.id.split("-")[2])

    @property
    def test(self) -> str:
        return self.id.split("-")[3]

    @property
    def exam(self) -> Tuple[int, int]:
        return (self.year, self.session)


@dataclass(frozen=True)
class Source:
    file: str
    sha256: str
    family: str
    source_kind: str
    papers: Tuple[Paper, ...]
    session_time_limit_minutes: Optional[int] = None


@dataclass(frozen=True)
class Exclusion:
    pattern: str
    reason: str

    def matches(self, relative: str) -> bool:
        return fnmatch.fnmatchcase(nfc(relative), nfc(self.pattern))


@dataclass
class Registry:
    sources: List[Source]
    excluded: List[Exclusion]
    errors: List[str] = field(default_factory=list)

    @property
    def papers(self) -> List[Tuple[Source, Paper]]:
        return [(s, p) for s in self.sources for p in s.papers]

    def paper_ids(self) -> List[str]:
        return sorted({p.id for _, p in self.papers})

    def is_excluded(self, relative: str) -> Optional[Exclusion]:
        for rule in self.excluded:
            if rule.matches(relative):
                return rule
        return None


def _paper(raw: dict, where: str, errors: List[str]) -> Optional[Paper]:
    pid = raw.get("id")
    if not isinstance(pid, str) or not PAPER_ID.match(pid):
        errors.append(f"{where}: geçersiz kağıt kimliği {pid!r} (beklenen TUS-<yıl>-<1|2>-<T|K|T2>)")
        return None
    date = raw.get("date")
    if date is not None:
        m = ISO_DATE.match(date) if isinstance(date, str) else None
        if not m:
            errors.append(f"{where} {pid}: tarih YYYY-AA-GG olmalı, {date!r} geldi")
        elif m.group(1) != pid.split("-")[1]:
            errors.append(f"{where} {pid}: tarihin yılı ({m.group(1)}) kimlikteki yılla uyuşmuyor")
    expected = raw.get("expected")
    if expected not in (100, 120):
        errors.append(f"{where} {pid}: expected 100 ya da 120 olmalı, {expected!r} geldi")
    offset = raw.get("numberOffset", 0)
    if offset not in (0, 100):
        errors.append(f"{where} {pid}: numberOffset 0 ya da 100 olmalı, {offset!r} geldi")
    limit = raw.get("timeLimitMinutes")
    if limit is not None and (not isinstance(limit, int) or limit <= 0):
        errors.append(f"{where} {pid}: timeLimitMinutes pozitif tamsayı ya da null olmalı")
    penalty = raw.get("penalty")
    if penalty not in PENALTIES:
        errors.append(f"{where} {pid}: penalty {PENALTIES} içinden olmalı, {penalty!r} geldi")
    key = raw.get("keySource")
    if key not in KEY_SOURCES:
        errors.append(f"{where} {pid}: keySource {KEY_SOURCES} içinden olmalı, {key!r} geldi")
    return Paper(
        id=pid,
        date=date,
        expected=expected if isinstance(expected, int) else 0,
        number_offset=offset if isinstance(offset, int) else 0,
        time_limit_minutes=limit,
        penalty=penalty,
        key_source=key,
    )


def _safe_relative(path: str) -> bool:
    p = PurePosixPath(path)
    return bool(path) and not p.is_absolute() and ".." not in p.parts and path.lower().endswith(".pdf")


def parse(doc: dict) -> Registry:
    """Builds a registry and collects *every* problem, not just the first —
    a registry is edited in bulk, and fixing one error per run is slow."""
    errors: List[str] = []
    if doc.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"schemaVersion {SCHEMA_VERSION} olmalı, {doc.get('schemaVersion')!r} geldi")

    sources: List[Source] = []
    for i, raw in enumerate(doc.get("sources", [])):
        where = f"sources[{i}]"
        file = raw.get("file", "")
        if not _safe_relative(file):
            errors.append(f"{where}: dosya yolu göreli, '..' içermeyen bir .pdf olmalı: {file!r}")
        sha = raw.get("sha256", "")
        if not SHA256.match(sha or ""):
            errors.append(f"{where} {file}: sha256 64 küçük onaltılık karakter olmalı")
        family = raw.get("family")
        if family not in FAMILIES:
            errors.append(f"{where} {file}: family {FAMILIES} içinden olmalı, {family!r} geldi")
        kind = raw.get("sourceKind")
        if kind not in SOURCE_KINDS:
            errors.append(f"{where} {file}: sourceKind {SOURCE_KINDS} içinden olmalı, {kind!r} geldi")
        session_limit = raw.get("sessionTimeLimitMinutes")
        if session_limit is not None and (not isinstance(session_limit, int) or session_limit <= 0):
            errors.append(f"{where} {file}: sessionTimeLimitMinutes pozitif tamsayı olmalı")
        papers_raw = raw.get("papers") or []
        if not papers_raw:
            errors.append(f"{where} {file}: en az bir kağıt tanımlanmalı")
        papers = tuple(p for p in (_paper(r, f"{where} {file}", errors) for r in papers_raw) if p)

        if family in FAMILY_RULES:
            kinds, keys = FAMILY_RULES[family]
            if kind not in kinds:
                errors.append(f"{where} {file}: {family} ailesi sourceKind={kinds} olmalı, {kind!r} geldi")
            for p in papers:
                if p.key_source not in keys:
                    errors.append(f"{where} {p.id}: {family} ailesi keySource={keys} olmalı, {p.key_source!r} geldi")

        # One PDF may carry several papers, in two different ways. F2 prints
        # Temel and Klinik as separate tests, each numbered from 1 under its
        # own test heading — the heading, not the number, tells them apart.
        # F5 numbers an exam straight through (Temel 1–100, Klinik 101–200),
        # so there the offsets are what separate the papers and must not
        # overlap, or two papers would claim the same printed question.
        seen_ids = set()
        for p in papers:
            if p.id in seen_ids:
                errors.append(f"{where} {file}: {p.id} aynı dosyada iki kez tanımlı")
            seen_ids.add(p.id)
        if family in CONTINUOUS_NUMBERING:
            by_exam: Dict[Tuple[int, int], list] = {}
            for p in papers:
                by_exam.setdefault(p.exam, []).append((p.number_offset + 1, p.number_offset + p.expected, p.id))
            for exam_spans in by_exam.values():
                exam_spans.sort()
                for (lo1, hi1, a), (lo2, hi2, b) in zip(exam_spans, exam_spans[1:]):
                    if lo2 <= hi1:
                        errors.append(f"{where} {file}: {a} ve {b} soru numarası aralıkları çakışıyor")
        else:
            for p in papers:
                if p.number_offset != 0:
                    errors.append(f"{where} {p.id}: {family} ailesinde her test 1'den numaralanır; numberOffset 0 olmalı")
            per_exam = Counter((p.exam, p.test) for p in papers)
            for (exam, test), n in per_exam.items():
                if n > 1:
                    errors.append(f"{where} {file}: {exam[0]}/{exam[1]} sınavının {test} testi aynı dosyada iki kez")

        sources.append(Source(
            file=file,
            sha256=sha,
            family=family,
            source_kind=kind,
            papers=papers,
            session_time_limit_minutes=session_limit,
        ))

    files = [s.file for s in sources]
    for f in sorted({f for f in files if files.count(f) > 1}):
        errors.append(f"{f}: aynı dosya kayıtta birden çok kez var")
    hashes: Dict[str, str] = {}
    for s in sources:
        if s.sha256 in hashes and hashes[s.sha256] != s.file:
            errors.append(f"{s.file}: {hashes[s.sha256]} ile aynı içerik (sha256) — kopya kaydedilmiş")
        hashes.setdefault(s.sha256, s.file)

    # The same paper may come from more than one source (an official PDF
    # with 10% visible, and a compilation with all of it). They must agree
    # on what the paper *is*; they may differ on where its key comes from.
    by_id: Dict[str, List[Paper]] = {}
    for s in sources:
        for p in s.papers:
            by_id.setdefault(p.id, []).append(p)
    for pid, copies in sorted(by_id.items()):
        for attr in ("date", "expected", "penalty", "time_limit_minutes"):
            values = {getattr(c, attr) for c in copies}
            if len(values) > 1:
                errors.append(f"{pid}: kaynaklar {attr} konusunda uyuşmuyor: {sorted(map(str, values))}")

    excluded = []
    for i, raw in enumerate(doc.get("excluded", [])):
        pattern, reason = raw.get("pattern"), raw.get("reason")
        if not pattern or not reason:
            errors.append(f"excluded[{i}]: pattern ve reason zorunlu (neden dışarıda bırakıldığı yazılmalı)")
            continue
        excluded.append(Exclusion(pattern=pattern, reason=reason))
    for s in sources:
        for rule in excluded:
            if rule.matches(s.file):
                errors.append(f"{s.file}: hem kayıtlı hem dışarıda bırakılmış ({rule.pattern})")

    return Registry(sources=sources, excluded=excluded, errors=errors)


def load(path: Path = REGISTRY_PATH) -> Registry:
    return parse(json.loads(path.read_text(encoding="utf-8")))


def missing_tests(registry: Registry) -> List[str]:
    """Exams for which a Temel or Klinik paper is registered nowhere. Not an
    error — a missing source is a gap to report, never to hide (§10)."""
    have = {(p.year, p.session, p.test) for _, p in registry.papers}
    exams = sorted({(p.year, p.session) for _, p in registry.papers})
    gaps = []
    for year, session in exams:
        for test in ("T", "K"):
            if (year, session, test) not in have:
                gaps.append(f"TUS-{year}-{session}-{test}")
    return gaps
