"""Stage A1 over the whole registry: every readable source → questions.

Output (`out/a1.json`) keeps what later stages need and nothing they would
have to re-derive: text as extracted, where it is printed, and every flag
the extractor raised. Nothing is corrected here (§5.3/5).
"""
from __future__ import annotations

import pickle
from pathlib import Path
from typing import List, Optional

from . import registry as reg
from .extract import families, paper, pdfwords

# Bump when anything in pdfwords changes what a page yields, so a stale
# page cache is not reused.
READER_VERSION = 1


def read_pages(source: reg.Source, source_dir: Path, cache_dir: Optional[Path]):
    """Pages of one PDF, cached by content hash. The cache lives under the
    gitignored `out/` — it holds booklet text, as the bank itself does."""
    if cache_dir is not None:
        path = cache_dir / f"{source.sha256}.v{READER_VERSION}.pkl"
        if path.exists():
            return pickle.loads(path.read_bytes())
    pages = list(pdfwords.read_pages(source_dir / source.file))
    if cache_dir is not None:
        cache_dir.mkdir(parents=True, exist_ok=True)
        path.write_bytes(pickle.dumps(pages))
    return pages


def run(registry: reg.Registry, source_dir: Path, cache_dir: Optional[Path] = None) -> dict:
    papers: List[dict] = []
    unreadable: List[str] = []
    for source in registry.sources:
        if source.file in families.UNREADABLE_TEXT:
            unreadable.append(source.file)
            continue
        pages = read_pages(source, source_dir, cache_dir)
        for result in paper.extract_source(source, families.family_for(source.family), pages):
            papers.append({
                "paperId": result.paper.id,
                "file": source.file,
                "family": source.family,
                "missing": result.missing,
                "questions": [_question(q) for q in result.questions],
            })
    return {"stage": "A1", "papers": papers, "unreadable": unreadable}


def _question(q: paper.Extracted) -> dict:
    return {
        "number": q.number,
        "printed": q.printed,
        "stem": q.stem,
        "options": q.options,
        "regions": [{"page": r.page, "bbox": r.as_list()} for r in q.regions],
        "problems": q.problems,
        "answerMarks": q.answer_marks,
        "empty": q.empty,
        "cancelled": q.cancelled,
        "revised": q.revised,
    }


def report(result: dict) -> List[str]:
    """V1 and V2 as the stage sees them (the gates proper run in A8)."""
    lines = []
    total = sum(len(p["questions"]) for p in result["papers"])
    visible = sum(1 for p in result["papers"] for q in p["questions"] if not q["empty"])
    v1 = [p for p in result["papers"] if p["missing"]]
    v2 = [(p["paperId"], q["number"], q["problems"][0]) for p in result["papers"] for q in p["questions"]
          if q["problems"]]
    lines.append(f"A1: {len(result['papers'])} dosya-kağıt, {total} yuva, {visible} görünür soru")
    lines.append(f"  V1 (numara bütünlüğü): {'tamam' if not v1 else f'{len(v1)} kağıtta eksik'}")
    for p in v1:
        lines.append(f"    {p['paperId']} ({p['file']}): eksik {p['missing']}")
    lines.append(f"  V2 (şık bütünlüğü): {len(v2)} soru onarım kuyruğuna (A5)")
    for pid, n, problem in v2:
        lines.append(f"    {pid}-{n:03d}: {problem}")
    for f in result["unreadable"]:
        lines.append(f"  metin katmanı okunamıyor, A6'ya: {f}")
    return lines
