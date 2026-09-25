"""A3 — one record per question (docs/PLAN-cikmis-soru-bankasi.md §5.5).

Most papers come from one file. 2024/2–2026/2 come from two: ÖSYM's own
booklet, which shows ~10% of the questions, and a full third-party copy (the
Tusdata compilation, the 2026/2 reconstruction). Where both have a question,
ÖSYM's text, page and answer win and the copy's page is kept as
`altProvenance`. V5 checks the premise this rests on: the two carry the same
question under the same number.

Near-identical questions in different exams are linked (`similarTo`) so a
session never serves both.
"""
from __future__ import annotations

import re
import unicodedata
from collections import defaultdict
from typing import Dict, Iterable, List, Optional, Set, Tuple

from . import registry as reg

KIND_RANK = {"osym": 0, "osymPartial": 0, "tusdata": 1, "reconstruction": 2}
V5_THRESHOLD = 0.5       # §5.5/2 — measured on the 80 overlaps: see tests/test_merge.py
SIMILAR_THRESHOLD = 0.8  # §5.5/4


def fold(text: str) -> str:
    """Comparison form (docs/ADR-001's folding, loosened for matching): NFC,
    lower case, and every i/ı/İ/I as one letter — a retyped copy writes
    "İL-1" where ÖSYM printed "IL-1" (2026/2 Klinik 61), and for "is this
    the same question" the dot carries no information. Punctuation to spaces."""
    text = unicodedata.normalize("NFC", text)
    text = text.replace("İ", "i").replace("I", "i").replace("ı", "i").lower()
    return re.sub(r"[^\w]+", " ", text).strip()


def words(text: str) -> List[str]:
    return fold(text).split()


def shingles(tokens: List[str], n: int = 6) -> Set[Tuple[str, ...]]:
    if len(tokens) < n:
        return {tuple(tokens)} if tokens else set()
    return {tuple(tokens[i:i + n]) for i in range(len(tokens) - n + 1)}


def overlap(a: str, b: str) -> float:
    """§5.5/2's measure: 6-word shingles shared, over the smaller set (a
    retyped copy may drop a line, not add one)."""
    sa, sb = shingles(words(a)), shingles(words(b))
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / min(len(sa), len(sb))


def full_text(q: dict) -> str:
    return q["stem"] + " " + " ".join(q.get("options") or [])


def run(registry: reg.Registry, a1: dict, a2: dict) -> dict:
    answers = {(p["file"], p["paperId"]): p["answers"] for p in a2["papers"]}
    registry_papers: Dict[str, List[Tuple[reg.Source, reg.Paper]]] = defaultdict(list)
    for source, paper in registry.papers:
        registry_papers[paper.id].append((source, paper))

    # paper id → [(source, paper, {number: (question, answer)})]
    copies: Dict[str, List[Tuple[reg.Source, reg.Paper, Dict[int, Tuple[dict, dict]]]]] = defaultdict(list)
    for p in a1["papers"]:
        source, paper = next((s, x) for s, x in registry_papers[p["paperId"]] if s.file == p["file"])
        pairs = {q["number"]: (q, a) for q, a in zip(p["questions"], answers[(p["file"], p["paperId"])])
                 if not q["empty"]}
        copies[paper.id].append((source, paper, pairs))

    questions: List[dict] = []
    v5_compared, v5_failed = 0, []
    papers_out = []
    dropped: List[str] = []
    notes: List[str] = []
    for pid in sorted(registry_papers):
        entries = registry_papers[pid]
        paper = entries[0][1]
        have = sorted(copies.get(pid, []), key=lambda c: KIND_RANK[c[0].source_kind])
        papers_out.append(_paper(paper, entries))
        official = [c for c in have if c[0].source_kind in ("osym", "osymPartial")]
        if official and len(have) > 1:
            for i, (source, cpaper, cq) in enumerate(have):
                if source.source_kind in ("osym", "osymPartial"):
                    continue
                aligned, failed, lost, note = renumber(official[0][2], cq, paper.expected)
                v5_compared += len(official[0][2])
                v5_failed.extend((f"{pid}-{n:03d}", source.file, score) for n, score in failed)
                have[i] = (source, cpaper, aligned)
                dropped.extend(f"{pid}: {source.file} içindeki no. {n + cpaper.number_offset}" for n in lost)
                if note:
                    notes.append(f"{pid}: {note}")
        for n in range(1, paper.expected + 1):
            present = [(s, x, c[n]) for s, x, c in have if n in c]
            if not present:
                continue
            primary, *others = present
            questions.append(_record(pid, n, primary, others))

    _link_similar(questions)
    problems = [f"V5 {qid}: {file} içinde ÖSYM'nin bu sorusu bulunamadı (en iyi örtüşme {score} < {V5_THRESHOLD})"
                for qid, file, score in v5_failed]
    return {"stage": "A3", "papers": papers_out, "questions": questions, "problems": problems,
            "notes": notes, "dropped": dropped,
            "v5": {"compared": v5_compared, "failed": len(v5_failed)}}


def renumber(official: Dict[int, Tuple[dict, dict]], copy: Dict[int, Tuple[dict, dict]], expected: int):
    """A full copy's numbers, checked against ÖSYM's own (V5) and corrected
    where ÖSYM's visible questions prove them wrong.

    Every official question is found in the copy by its text (the anchor).
    Between two anchors whose copy-to-official offset agrees, every copy
    question is certain: it is its number plus that offset. Between two
    anchors that disagree, the copy gained or lost a question somewhere in
    between, and no evidence says where — those questions get no number and
    are left out rather than given one that might belong to another
    question (an ID, once issued, never changes — §6).

    Measured: the compilation's 2024/1 Klinik lacks one of ÖSYM's 60–63 and
    carries one extra between 70 and 88; everything else lines up.

    Returns (copy re-keyed by official number, [(official number, best score)]
    for anchors not found, [copy numbers left out], a note or "")."""
    anchors: List[Tuple[int, int]] = [(0, 0), (expected + 1, expected + 1)]   # (copy, official)
    failed = []
    for n, (oq, _) in official.items():
        best, score = None, 0.0
        for m, (cq, _) in copy.items():
            s = overlap(full_text(oq), full_text(cq))
            if s > score:
                best, score = m, s
        if best is not None and score >= V5_THRESHOLD:
            anchors.append((best, n))
        else:
            failed.append((n, round(score, 2)))
    anchors.sort()
    aligned: Dict[int, Tuple[dict, dict]] = {}
    lost = []
    for m, pair in copy.items():
        lower = max((a for a in anchors if a[0] <= m), key=lambda a: a[0])
        upper = min((a for a in anchors if a[0] >= m), key=lambda a: a[0])
        if lower[1] - lower[0] == upper[1] - upper[0]:
            aligned[m + lower[1] - lower[0]] = pair
        else:
            lost.append(m)
    shifted = sorted(o for c, o in anchors if c != o)
    note = ""
    if shifted or lost:
        note = (f"kopyanın numarası ÖSYM'den kayıyor (resmî {', '.join(map(str, shifted))} kopyada başka "
                f"numarada); iki çapa arası tutarsız {len(lost)} soru numarasız kaldı ve bankaya girmiyor")
    return aligned, failed, sorted(lost), note


def _paper(paper: reg.Paper, entries: List[Tuple[reg.Source, reg.Paper]]) -> dict:
    """What the phone shows about a paper. A paper with a full copy is
    described by that copy (it supplies most questions); ÖSYM's partial
    booklet is listed as a source all the same."""
    full = [s for s, _ in entries if s.source_kind != "osymPartial"]
    main = full[0] if full else entries[0][0]
    main_paper = next(p for s, p in entries if s is main)
    return {
        "id": paper.id, "year": paper.year, "session": paper.session, "test": paper.test,
        "date": paper.date, "questionCount": paper.expected,
        "timeLimitMinutes": paper.time_limit_minutes,
        "sessionTimeLimitMinutes": main.session_time_limit_minutes,
        "penalty": paper.penalty,
        "sourceKind": main.source_kind,
        "keySource": main_paper.key_source,
        "sources": [{"file": s.file, "family": s.family, "sourceKind": s.source_kind, "keySource": p.key_source}
                    for s, p in entries],
    }


def _record(pid: str, n: int, primary, others) -> dict:
    source, paper, (q, a) = primary
    answer, answer_source = a["answer"], a["answerSource"]
    if answer is None:
        for _, _, (_, oa) in others:
            if oa["answer"] is not None and not oa["cancelled"]:
                answer, answer_source = oa["answer"], oa["answerSource"]
                break
    cancelled = a["cancelled"] or any(oa["cancelled"] for _, _, (_, oa) in others)
    revised = q["revised"]  # only a copy is ever revised; ÖSYM's own text never is
    expected_print = n + paper.number_offset
    if cancelled:
        status = "cancelled"
    elif revised:
        status = "modified"
    elif q["problems"]:
        status = "needsRepair"   # A5 settles it: ok or needsHuman
    elif answer is None:
        status = "keyless"
    else:
        status = "ok"
    return {
        "id": f"{pid}-{n:03d}",
        "paperId": pid,
        "number": n,
        "stem": q["stem"],
        "options": q["options"],
        "answer": None if cancelled else answer,
        "answerSource": None if cancelled or answer is None else answer_source,
        "status": status,
        "textSource": {"osymPartial": "osym"}.get(source.source_kind, source.source_kind),
        "textQuality": "native",
        "provenance": [dict(file=source.file, **r) for r in q["regions"]],
        "altProvenance": [dict(file=s.file, **r) for s, _, (oq, _) in others for r in oq["regions"]],
        "problems": q["problems"],
        "printedAs": q["printed"] if q["printed"] != expected_print else None,
        "similarTo": [],
    }


def _link_similar(questions: List[dict]) -> None:
    """Pairs across different papers whose word sets overlap > 0.8 (Jaccard).
    Candidates come from shared rare words, so the whole bank is not
    compared pairwise."""
    sets = {q["id"]: set(t for t in words(full_text(q)) if len(t) > 2) for q in questions
            if q["status"] != "cancelled" and q["stem"]}
    df: Dict[str, List[str]] = defaultdict(list)
    for qid, ws in sets.items():
        for w in ws:
            df[w].append(qid)
    shared: Dict[Tuple[str, str], int] = defaultdict(int)
    for w, ids in df.items():
        if len(ids) > 40:
            continue  # common words link everything to everything
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                shared[(a, b) if a < b else (b, a)] += 1
    by_id = {q["id"]: q for q in questions}
    for (a, b), count in shared.items():
        if count < 3 or a.rsplit("-", 1)[0] == b.rsplit("-", 1)[0]:
            continue
        sa, sb = sets[a], sets[b]
        if len(sa & sb) / len(sa | sb) > SIMILAR_THRESHOLD:
            by_id[a]["similarTo"].append(b)
            by_id[b]["similarTo"].append(a)
    for q in questions:
        q["similarTo"].sort()


def report(result: dict) -> List[str]:
    qs = result["questions"]
    by_status: Dict[str, int] = defaultdict(int)
    for q in qs:
        by_status[q["status"]] += 1
    linked = sum(1 for q in qs if q["similarTo"])
    alt = sum(1 for q in qs if q["altProvenance"])
    lines = [f"A3: {len(qs)} soru ({', '.join(f'{k} {v}' for k, v in sorted(by_status.items()))})",
             f"  resmî metin öncelikli birleşen: {alt}; V5 (numara uyuşması): "
             f"{result['v5']['compared'] - result['v5']['failed']}/{result['v5']['compared']}",
             f"  yıllar arası neredeyse aynı: {linked} soru bir başkasına bağlı (similarTo)"]
    lines.extend(f"  not: {n}" for n in result.get("notes", []))
    if result.get("dropped"):
        lines.append(f"  numarası belirsiz, dışarıda: {len(result['dropped'])} soru")
    lines.extend(f"  {p}" for p in result["problems"])
    return lines
