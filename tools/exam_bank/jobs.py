"""Job files for the model stages (§5.8), read by `backend/scripts/examBank.ts`.

    out/jobs/repair.json   A5 — each question V2 sent for repair, with its crop
    out/jobs/vision.json   A6 — each question page of 2011/1, as an image
    out/jobs/label.json    A7 — runs of ≤ 25 consecutive questions per paper
    out/jobs/check.json    V6 — 15 keyed questions per keyed paper

Images are written next to them (`out/crops/`, `out/pages/`) and referenced
relative to the job file. Nothing here calls a model or spends money.

Every item carries a `fingerprint` of what the model will be shown. Item ids
are stable across rebuilds and inputs are not, so a result is reused — by the
runner, which skips it, and by `apply.load_results`, which folds it in — only
while its item's fingerprint is unchanged (Codex, PR #51).
"""
from __future__ import annotations

import hashlib
import json
import random
import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

from . import registry as reg
from . import render

VISION_FILE = "2006-2012/TUS_2011_Ilkbahar_TemelKlinik.pdf"
# Measured on the booklet: 1 cover, 2 instructions, 3–18 Temel Testi-1,
# 18–33 Temel Testi-2, 34 rules, 35–36 keys.
VISION_PAGES = range(3, 34)

LABEL_BATCH = 25
CHECK_SAMPLE = 15
TEXT_LIMIT = 900  # characters of a question sent for labelling or checking
CROP_DPI = 150
PAGE_DPI = 200


PROMPTS = Path(__file__).resolve().parents[2] / "backend" / "prompts" / "examBank.ts"


def prompt_version(prompts: Path = PROMPTS) -> str:
    """The model stages' prompt version, read from the prompts themselves so
    there is one source. A result made under another version is stale even
    when its item is unchanged (Codex, PR #51); the version covers every
    stage, so bumping it re-sends all of them — cents, against folding in
    outputs of a prompt that is gone."""
    found = re.search(r'EXAM_BANK_PROMPT_VERSION\s*=\s*"([^"]+)"', prompts.read_text(encoding="utf-8"))
    if not found:
        raise RuntimeError(f"EXAM_BANK_PROMPT_VERSION bulunamadı: {prompts}")
    return found.group(1)


def fingerprint(basis: dict) -> str:
    """The inputs a model result was made from. Images are described by where
    they are rendered from (the PDFs are pinned by sha256 in sources.json),
    not by their bytes, so a re-render does not invalidate anything."""
    raw = json.dumps(basis, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def question_text(q: dict, limit: int = TEXT_LIMIT) -> str:
    options = q.get("options") or []
    body = q["stem"] + "\n" + "\n".join(f"{'ABCDE'[i]}) {o}" for i, o in enumerate(options))
    return body if len(body) <= limit else body[:limit] + " …"


def pdf_hashes(provenance: Sequence[dict], hashes: Dict[str, str]) -> List[Optional[str]]:
    """The pinned sha256 of each PDF a crop is cut from: a PDF replaced
    under the same name renders another image at the same coordinates."""
    return [hashes.get(r["file"]) for r in provenance]


def repair_items(questions: Iterable[dict], source_dir: Path, out: Path, hashes: Dict[str, str]) -> List[dict]:
    items = []
    for q in questions:
        if q["status"] != "needsRepair":
            continue
        crop = out / "crops" / f"{q['id']}.png"
        render.save_question_crop(source_dir, q["provenance"], crop, dpi=CROP_DPI)
        text = question_text(q, 4000)
        items.append({"id": q["id"], "text": text, "image": f"../crops/{crop.name}",
                      "fingerprint": fingerprint({"text": text, "provenance": q["provenance"], "dpi": CROP_DPI,
                                                  "pdfs": pdf_hashes(q["provenance"], hashes)})})
    return items


def vision_items(source_dir: Path, out: Path, hashes: Dict[str, str],
                 pages: Iterable[int] = VISION_PAGES) -> List[dict]:
    items = []
    for n in pages:
        dest = out / "pages" / f"TUS_2011_Ilkbahar-p{n:02d}.png"
        dest.parent.mkdir(parents=True, exist_ok=True)
        render.page_image(source_dir / VISION_FILE, n, dpi=PAGE_DPI).save(dest)
        items.append({"id": f"{VISION_FILE}|{n}", "image": f"../pages/{dest.name}",
                      "fingerprint": fingerprint({"file": VISION_FILE, "pdf": hashes.get(VISION_FILE), "page": n,
                                                  "dpi": PAGE_DPI})})
    return items


def label_items(papers: Sequence[dict], questions: Sequence[dict]) -> List[dict]:
    """Consecutive runs per paper, in booklet order: the model sees each
    question beside its neighbours, which is most of what tells a Farmakoloji
    question from a Biyokimya one near a block boundary."""
    test_of = {p["id"]: p["test"] for p in papers}
    by_paper: Dict[str, List[dict]] = {}
    for q in questions:
        if q["status"] in ("cancelled", "needsHuman") or not q["stem"]:
            continue
        by_paper.setdefault(q["paperId"], []).append(q)
    items = []
    for pid, qs in sorted(by_paper.items()):
        qs.sort(key=lambda q: q["number"])
        for start in range(0, len(qs), LABEL_BATCH):
            run = qs[start:start + LABEL_BATCH]
            items.append(_with_fingerprint({"id": f"{pid}|{start // LABEL_BATCH + 1}", "test": test_of[pid],
                                            "questions": [{"k": i + 1, "id": q["id"], "text": question_text(q)}
                                                          for i, q in enumerate(run)]}))
    return items


def check_items(papers: Sequence[dict], questions: Sequence[dict]) -> List[dict]:
    """V6's sample: per paper with its own key, 15 keyed questions the model
    can answer from text alone (no figure), drawn with the paper id as seed
    so a re-run asks the same ones."""
    by_paper: Dict[str, List[dict]] = {}
    for q in questions:
        if q["status"] == "ok" and q["answer"] is not None and q.get("figure", "none") == "none":
            by_paper.setdefault(q["paperId"], []).append(q)
    test_of = {p["id"]: p["test"] for p in papers}
    items = []
    for pid, qs in sorted(by_paper.items()):
        if len(qs) < CHECK_SAMPLE:
            continue  # ÖSYM's partial booklets: every answer is ÖSYM's own printed mark
        sample = sorted(random.Random(pid).sample(sorted(qs, key=lambda q: q["number"]), CHECK_SAMPLE),
                        key=lambda q: q["number"])
        items.append(_with_fingerprint({"id": pid, "test": test_of[pid],
                                        "questions": [{"k": i + 1, "id": q["id"], "text": question_text(q)}
                                                      for i, q in enumerate(sample)]}))
    return items


def _with_fingerprint(item: dict) -> dict:
    """Text-only items: what the model sees is the item itself."""
    return dict(item, fingerprint=fingerprint({"test": item["test"], "questions": item["questions"]}))


def write(out: Path, stage: str, items: List[dict]) -> Path:
    path = out / "jobs" / f"{stage}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"stage": stage, "items": items}, ensure_ascii=False, indent=1), encoding="utf-8")
    return path
