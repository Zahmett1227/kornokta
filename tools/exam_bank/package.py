"""A9 — the folder the phone imports (docs/PLAN-cikmis-soru-bankasi.md §5.12).

    CizgiSoruBankasi/
      manifest.json   version, sources, files with sha256, gates, human check
      bank.json       §6 (exam_bank.schema.json)
      pdf/<sha256>.pdf

Booklets are copied as they are, except ÖSYM's partial booklets (F4): only
the pages that carry a visible question travel (`qpdf --pages`), and every
region pointing into them is renumbered to the subset's pages. A PDF's name
is the hash of its bytes, so the same booklet is never stored twice.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import registry as reg

SCHEMA_PATH = Path(__file__).with_name("exam_bank.schema.json")
QUESTION_FIELDS = ("id", "paperId", "number", "stem", "options", "answer", "answerSource", "status",
                   "osymSubject", "subject", "topic", "figure", "provenance", "altProvenance",
                   "textQuality", "textSource", "printedAs", "similarTo")
PAPER_FIELDS = ("id", "year", "session", "test", "date", "questionCount", "timeLimitMinutes",
                "sessionTimeLimitMinutes", "penalty", "sourceKind", "keySource")


def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def used_pages(questions: List[dict]) -> Dict[str, List[int]]:
    pages: Dict[str, set] = defaultdict(set)
    for q in questions:
        for r in q["provenance"] + q["altProvenance"]:
            pages[r["file"]].add(r["page"])
    return {f: sorted(p) for f, p in pages.items()}


def place_pdfs(registry: reg.Registry, questions: List[dict], source_dir: Path, pdf_dir: Path
               ) -> Tuple[Dict[str, str], Dict[Tuple[str, int], int]]:
    """Copies or subsets every booklet a question points into.
    Returns (file → "pdf/<sha>.pdf", (file, page) → page in the packaged PDF)."""
    pdf_dir.mkdir(parents=True, exist_ok=True)
    family = {s.file: s.family for s in registry.sources}
    paths: Dict[str, str] = {}
    page_map: Dict[Tuple[str, int], int] = {}
    for file, pages in sorted(used_pages(questions).items()):
        src = source_dir / file
        tmp = pdf_dir / "_tmp.pdf"
        if family[file] == "F4":
            subprocess.run(["qpdf", "--empty", "--pages", str(src), ",".join(map(str, pages)), "--", str(tmp)],
                           check=True)
            for i, p in enumerate(pages, start=1):
                page_map[(file, p)] = i
        else:
            shutil.copyfile(src, tmp)
            for p in pages:
                page_map[(file, p)] = p
        name = f"{_sha(tmp)}.pdf"
        tmp.replace(pdf_dir / name)
        paths[file] = f"pdf/{name}"
    return paths, page_map


def bank_document(a7: dict, paths: Dict[str, str], page_map: Dict[Tuple[str, int], int],
                  bank_version: str, built_at: str, subject_schema_version: int) -> dict:
    def region(r: dict) -> dict:
        return {"pdf": paths[r["file"]], "page": page_map[(r["file"], r["page"])], "bbox": r["bbox"]}

    questions = []
    for q in a7["questions"]:
        out = {k: q.get(k) for k in QUESTION_FIELDS}
        out["provenance"] = [region(r) for r in q["provenance"]]
        out["altProvenance"] = [region(r) for r in q["altProvenance"]]
        out["similarTo"] = q.get("similarTo") or []
        questions.append(out)
    present = {q["paperId"] for q in questions}
    papers = []
    for p in a7["papers"]:
        if p["id"] not in present:
            continue
        out = {k: p.get(k) for k in PAPER_FIELDS}
        out["sources"] = [{"pdf": paths[s["file"]], "family": s["family"], "sourceKind": s["sourceKind"],
                           "keySource": s["keySource"]} for s in p["sources"] if s["file"] in paths]
        papers.append(out)
    return {"schemaVersion": 1, "bankVersion": bank_version, "subjectSchemaVersion": subject_schema_version,
            "builtAt": built_at, "papers": papers, "questions": questions}


def validate(document: dict) -> List[str]:
    try:
        import jsonschema
    except ImportError:  # the repo's .venv has it; say so rather than skip silently
        return ["jsonschema kurulu değil: bank.json şemaya karşı denetlenemedi"]
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'/'.join(map(str, e.absolute_path))}: {e.message}" for e in validator.iter_errors(document)][:50]


def write_package(dest: Path, document: dict, registry: reg.Registry, gates: dict,
                  human_check: Optional[dict]) -> dict:
    (dest / "bank.json").write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")),
                                    encoding="utf-8")
    files = []
    for path in sorted(dest.rglob("*")):
        if path.is_file() and path.name != "manifest.json":
            files.append({"path": path.relative_to(dest).as_posix(), "sha256": _sha(path),
                          "bytes": path.stat().st_size})
    manifest = {
        "bankVersion": document["bankVersion"], "schemaVersion": document["schemaVersion"],
        "builtAt": document["builtAt"],
        "sources": [{"file": s.file, "sha256": s.sha256, "family": s.family} for s in registry.sources],
        "files": files,
        "counts": {"papers": len(document["papers"]), "questions": len(document["questions"])},
        "gates": gates,
        "humanCheck": human_check,
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    return manifest


def bank_version(out: Path, today: Optional[str] = None) -> str:
    """Date plus a counter (§5.12): 2026-09-25.1, .2, … for rebuilds that day."""
    today = today or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    counter = out / "bank_version.json"
    state = json.loads(counter.read_text()) if counter.exists() else {}
    n = state.get(today, 0) + 1
    state[today] = n
    counter.write_text(json.dumps(state))
    return f"{today}.{n}"
