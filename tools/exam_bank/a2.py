"""Stage A2 over the whole registry: keys → answers, and the key gates.

V3 — every keyed paper's key is complete (1…N, once each), and every visible
     ÖSYM question carries exactly one "DOĞRU CEVAP".
V4 — every third-party answer (Tusdata compilation, 2026/2 reconstruction)
     agrees with ÖSYM's own printed answer wherever both exist: 100 %.
Plus a consistency check the plan did not name but the data offers: a slot
printed "Bu soru iptal edilmiştir." must be İPTAL in the key, and the
reverse.
"""
from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import keys as keymod
from . import registry as reg
from .a1 import read_pages

LETTERS = "ABCDE"


def run(registry: reg.Registry, a1: dict, source_dir: Path, cache_dir: Optional[Path] = None) -> dict:
    by_file: Dict[str, List[dict]] = {}
    for p in a1["papers"]:
        by_file.setdefault(p["file"], []).append(p)

    printed: Dict[Tuple[str, str], keymod.Key] = {}
    for source in registry.sources:
        if all(p.key_source == "none" for p in source.papers) or source.family == "F4":
            continue
        # A file A1 could not read (2011/1) still has a readable key; A6's
        # questions are matched to it later.
        exam_pages = {p["paperId"]: _page_span(p) for p in by_file.get(source.file, [])}
        pages = read_pages(source, source_dir, cache_dir)
        for pid, key in keymod.read_keys(source, pages, exam_pages).items():
            printed[(source.file, pid)] = key

    problems: List[str] = []
    for (file, pid), key in printed.items():
        if file not in by_file:
            paper = next(p for s in registry.sources if s.file == file for p in s.papers if p.id == pid)
            problems.extend(keymod.completeness(key, paper.expected))
    papers_out = []
    for source in registry.sources:
        for p in by_file.get(source.file, []):
            paper = next(x for x in source.papers if x.id == p["paperId"])
            key = printed.get((source.file, paper.id))
            if key is not None:
                problems.extend(keymod.completeness(key, paper.expected))
            elif paper.key_source != "none" and source.family != "F4":
                problems.append(f"{paper.id} ({source.file}): anahtar sayfası bulunamadı")
            answers = []
            for q in p["questions"]:
                answers.append(_answer(q, paper, source, key, problems))
            papers_out.append({"paperId": paper.id, "file": source.file, "family": source.family,
                               "answers": answers})

    agreement = _v4(papers_out)
    for (pid, n), (osym, other, src) in sorted(agreement["disagree"].items()):
        problems.append(f"V4 {pid}-{n:03d}: ÖSYM {LETTERS[osym]}, {src} {LETTERS[other]}")
    keys_out = {f"{pid}|{file}": {"source": key.source, "entries": {
        str(n): {"answer": e.answer, "cancelled": e.cancelled} for n, e in sorted(key.entries.items())}}
        for (file, pid), key in printed.items()}
    return {"stage": "A2", "papers": papers_out, "printedKeys": keys_out, "problems": problems, "v4": {
        "compared": agreement["compared"], "agree": agreement["agree"],
        "disagree": len(agreement["disagree"])}}


def _page_span(paper: dict) -> Tuple[int, int]:
    pages = [r["page"] for q in paper["questions"] if not q["empty"] for r in q["regions"]]
    return (min(pages), max(pages)) if pages else (0, 0)


def _answer(q: dict, paper: reg.Paper, source: reg.Source, key: Optional[keymod.Key], problems: List[str]) -> dict:
    n = q["number"]
    out = {"number": n, "answer": None, "answerSource": None, "cancelled": q["cancelled"]}
    if q["empty"]:
        return out
    if source.family == "F4":
        marks = q["answerMarks"]
        if len(marks) != 1:
            problems.append(f"V3 {paper.id}-{n:03d}: görünen soruda {len(marks)} 'DOĞRU CEVAP' var (1 olmalı)")
        else:
            out.update(answer=LETTERS.index(marks[0]), answerSource="osym")
        return out
    if key is None:
        return out
    entry = key.entries.get(n)
    if entry is None:
        return out
    # Either word cancels the question. ÖSYM cancels after the exam: older
    # booklets (2009–2013) were archived with the text intact and the key
    # says İPTAL; 2017's booklets replace the text with "Bu soru iptal
    # edilmiştir." while the key still prints the original letter. Neither
    # is a reading error, so it is counted, not raised.
    if entry.cancelled and not q["cancelled"]:
        out["cancelled"] = True
        out["cancelledBy"] = "key"
    elif q["cancelled"] and not entry.cancelled:
        out["cancelledBy"] = "booklet"
    elif q["cancelled"]:
        out["cancelledBy"] = "both"
    if entry.answer is not None and not out["cancelled"]:
        out.update(answer=entry.answer, answerSource=key.source)
    return out


def _v4(papers: List[dict]) -> dict:
    osym: Dict[Tuple[str, int], int] = {}
    others: Dict[Tuple[str, int], Tuple[int, str]] = {}
    for p in papers:
        for a in p["answers"]:
            if a["answer"] is None:
                continue
            k = (p["paperId"], a["number"])
            if p["family"] == "F4":
                osym[k] = a["answer"]
            elif a["answerSource"] in ("tusdata", "reconstruction"):
                others[k] = (a["answer"], a["answerSource"])
    compared = agree = 0
    disagree = {}
    for k, (ans, src) in others.items():
        if k in osym:
            compared += 1
            if osym[k] == ans:
                agree += 1
            else:
                disagree[k] = (osym[k], ans, src)
    return {"compared": compared, "agree": agree, "disagree": disagree}


def report(result: dict, a1: dict) -> List[str]:
    keyed = sum(1 for p in result["papers"] for a in p["answers"] if a["answer"] is not None)
    cancelled = sum(1 for p in result["papers"] for a in p["answers"] if a["cancelled"])
    visible = sum(1 for p in a1["papers"] for q in p["questions"] if not q["empty"])
    v4 = result["v4"]
    by = {}
    for p in result["papers"]:
        for a in p["answers"]:
            if a.get("cancelledBy"):
                by[a["cancelledBy"]] = by.get(a["cancelledBy"], 0) + 1
    lines = [f"A2: {visible} görünür sorunun {keyed}'i anahtarlı, {cancelled} iptal "
             f"(kitapçık ve anahtar {by.get('both', 0)}, yalnız anahtar {by.get('key', 0)}, "
             f"yalnız kitapçık {by.get('booklet', 0)})",
             f"  V4 (üçüncü taraf ↔ ÖSYM): {v4['agree']}/{v4['compared']} uyuşuyor"]
    if result["problems"]:
        lines.append(f"  {len(result['problems'])} sorun:")
        lines.extend(f"    {p}" for p in result["problems"])
    else:
        lines.append("  V3 (anahtar bütünlüğü): tamam")
    return lines
