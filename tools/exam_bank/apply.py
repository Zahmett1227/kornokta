"""Folding the model stages' results back into the bank (§5.7–5.10, V6, V7).

Each function takes what `backend/scripts/examBank.ts` wrote and returns the
bank's questions changed only where the result is accepted — and says so
when it is not. A model result is a proposal: A5's is kept only when it
reads the same question the extractor saw, A6's only when the numbers run
1…N, A7's only as a vote for the monotone segmentation.
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from . import figures
from . import registry as reg
from . import subjects as sj
from .extract import segment
from .extract.columns import Page
from .extract.options import same_option
from .merge import fold

LETTERS = "ABCDE"
REPAIR_MIN_SHARED = 0.7   # §5.7: share of the extractor's words the repair must contain
PICTURE = "[görsel]"


def load_results(path: Path) -> Dict[str, dict]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {item["id"]: item for item in data["items"] if item.get("ok")}


def tidy(text: str) -> str:
    """A model copies the booklet's line breaks. Inside a paragraph they mean
    nothing; between paragraphs, a premise list or a table they do. Same
    shape `clean.assemble` gives extracted text. Column padding (the model
    aligns a two-column option table with ideographic spaces) becomes the
    " – " the booklets' own pair-options use."""
    text = re.sub(r"[ \t]*[\u3000\u2003]+[ \t]*", " – ", text.replace("\r", "")).strip()
    paragraphs = [p for p in re.split(r"\n\s*\n", text) if p.strip()]
    out = []
    for p in paragraphs:
        lines = [l.strip() for l in p.split("\n") if l.strip()]
        merged: List[str] = []
        for line in lines:
            keep = merged and (line.startswith("|") or merged[-1].startswith("|")
                               or re.match(r"^(I|II|III|IV|V|VI)\.", line))
            if merged and not keep:
                merged[-1] = merged[-1] + " " + line
            else:
                merged.append(line)
        out.append("\n".join(merged))
    return "\n".join(out)


def _options(output: dict) -> List[str]:
    """An option drawn rather than written (a structural formula, a curve)
    comes back as ASCII art over several lines; it is a picture, and the
    crop shows it (A4 marks the question `required`)."""
    return [PICTURE if output[k].count("\n") >= 3 else tidy(output[k]) for k in "abcde"]


def _stem(output: dict) -> str:
    return re.sub(r"^\s*\d{1,3}\.\s+", "", tidy(output["stem"]))  # the model sometimes copies the number


def _words(text: str) -> List[str]:
    return [w for w in fold(text).split() if len(w) > 1]


def shared_share(extracted: str, repaired: str) -> float:
    base = _words(extracted)
    if not base:
        return 1.0  # nothing to compare: the extractor read nothing (stem and options were pictures)
    have = set(_words(repaired))
    return sum(1 for w in base if w in have) / len(base)


# --- A5 ----------------------------------------------------------------------

def apply_repair(questions: List[dict], results: Dict[str, dict]) -> List[str]:
    notes = []
    for q in questions:
        if q["status"] != "needsRepair":
            continue
        r = results.get(q["id"])
        if r is None:
            notes.append(f"A5 {q['id']}: sonuç yok — needsHuman")
            q["status"] = "needsHuman"
            continue
        out = r["output"]
        stem, options = _stem(out), _options(out)
        # Compare only what both sides read as text: where the repair says an
        # option is a picture, what the extractor made of it (axis labels,
        # "(cid:129)") is not evidence either way.
        kept = [o for o, r in zip(q["options"] or [], options) if o and r != PICTURE]
        extracted = q["stem"] + " " + " ".join(kept)
        share = shared_share(extracted, stem + " " + " ".join(o for o in options if o != PICTURE))
        if share < REPAIR_MIN_SHARED or not stem or any(not o for o in options):
            notes.append(f"A5 {q['id']}: onarım çıkarımla örtüşmüyor ({share:.0%}) — needsHuman")
            q["status"] = "needsHuman"
            continue
        q["stem"], q["options"], q["textQuality"] = stem, options, "repaired"
        q["problems"] = []
        if any(o == PICTURE for o in options):
            q["figure"] = "required"
        keys = [same_option(o) for o in options if o != PICTURE]
        if len(set(keys)) != len(keys):
            # The repair read the same thing twice: the source itself prints
            # two identical options (2026/2 Klinik 23, the reconstruction).
            # Not scoreable as printed; kept out of the default filters.
            q["status"] = "needsHuman"
            notes.append(f"A5 {q['id']}: kaynakta iki şık aynı — needsHuman")
            continue
        q["status"] = "keyless" if q["answer"] is None else "ok"
    return notes


# --- A6 ----------------------------------------------------------------------

def _column_blocks(stream: segment.Stream, page: Page, column: int, decor: set, gap: float = 40.0
                   ) -> List[Tuple[float, float]]:
    """Vertical extents of the column's content (text lines and figure
    parts), split wherever the column goes empty for more than `gap` points —
    the space between two questions. A figure fills its own gap, so a
    question with a picture between stem and options stays one block."""
    # The body band only: 2011/1's running head and "Diğer sayfaya geçiniz."
    # are encoded differently on every page, so the running-head test cannot
    # recognise them; their position still does.
    top_band, bottom_band = 0.13 * page.height, 0.88 * page.height
    spans = [(sl.line.top, sl.line.bottom) for sl in stream.lines
             if sl.line.page == page.number and sl.line.column == column and sl.kind == segment.TEXT
             and sl.line.top > top_band and sl.line.bottom < bottom_band]
    x0, x1 = _column_x(stream, page, column)
    for g in page.graphics:
        if figures._is_figure_part(g, page, (x0, 0, x1, page.height), decor):
            spans.append((g.top, g.bottom))
    spans.sort()
    blocks: List[List[float]] = []
    for top, bottom in spans:
        if blocks and top - blocks[-1][1] <= gap:
            blocks[-1][1] = max(blocks[-1][1], bottom)
        else:
            blocks.append([top, bottom])
    return [(t, b) for t, b in blocks]


def _column_x(stream: segment.Stream, page: Page, column: int) -> Tuple[float, float]:
    gutter = stream.gutters.get(page.number) or page.width / 2
    return (20.0, gutter - 2) if column == 0 else (gutter + 2, page.width - 20.0)


def vision_questions(results: Dict[str, dict], file: str, pages: Sequence[Page],
                     keys: Dict[str, dict], papers: Sequence[reg.Paper]) -> Tuple[List[dict], List[str]]:
    """2011/1's questions from page reads: numbered 1…100 twice (Temel
    Testi-1, then Testi-2), answered from the booklet's own key, placed on
    the page by matching the model's per-column order to the column's
    content blocks."""
    notes: List[str] = []
    stream = segment.build_stream(pages)
    by_number = {p.number: p for p in pages}
    decor = figures.furniture(pages)
    reads = sorted(((int(k.split("|")[1]), v["output"]) for k, v in results.items() if k.startswith(file + "|")),
                   key=lambda r: r[0])
    order = [p.id for p in papers]
    paper_index, last = 0, 0
    out: List[dict] = []
    seen: Dict[str, set] = defaultdict(set)
    for page_no, read in reads:
        page = by_number[page_no]
        per_column: Dict[int, List[dict]] = defaultdict(list)
        for item in read["questions"]:
            per_column[0 if item["column"] == "left" else 1].append(item)
        placed: Dict[int, dict] = {}
        for column, items in per_column.items():
            blocks = _column_blocks(stream, page, column, decor)
            x0, x1 = _column_x(stream, page, column)
            if len(blocks) == len(items) + 1:
                # A test's first page carries its title above the questions
                # ("TEMEL TIP BİLİMLERİ TESTİ 2"), one extra block on top.
                blocks = blocks[1:]
            if len(blocks) == len(items):
                for item, (top, bottom) in zip(items, blocks):
                    placed[id(item)] = {"page": page_no, "bbox": [round(x0, 1), round(top - 3, 1),
                                                                  round(x1, 1), round(bottom + 3, 1)]}
            else:
                notes.append(f"A6 s.{page_no} {'sağ' if column else 'sol'} sütun: {len(items)} soru, "
                             f"{len(blocks)} blok — sütun bütünüyle kutu")
                body = [b for b in blocks] or [(60.0, page.height - 60)]
                for item in items:
                    placed[id(item)] = {"page": page_no, "bbox": [round(x0, 1), round(body[0][0] - 3, 1),
                                                                  round(x1, 1), round(body[-1][1] + 3, 1)]}
        for item in read["questions"]:
            n = int(item["number"])
            if n <= last and n == 1:
                paper_index += 1  # the numbers start again: Temel Testi-2
            last = n
            if paper_index >= len(order):
                notes.append(f"A6 s.{page_no}: {n}. soru kayıtlı kağıtların dışında")
                continue
            pid = order[paper_index]
            if n in seen[pid]:
                notes.append(f"A6 {pid}-{n:03d}: iki kez okundu")
                continue
            seen[pid].add(n)
            key = keys.get(pid, {}).get(str(n))
            cancelled = bool(key and key["cancelled"])
            answer = None if cancelled or key is None else key["answer"]
            options = _options(item)
            stem = _stem(item)
            complete = bool(stem) and all(options)
            status = ("cancelled" if cancelled else "needsHuman" if not complete
                      else "keyless" if answer is None else "ok")
            region = placed[id(item)]
            out.append({
                "id": f"{pid}-{n:03d}", "paperId": pid, "number": n, "stem": stem, "options": options,
                "answer": answer, "answerSource": "osym" if answer is not None else None, "status": status,
                "textSource": "osym", "textQuality": "vision",
                "provenance": [dict(file=file, **region)], "altProvenance": [], "problems": [],
                "printedAs": None, "similarTo": [],
            })
    for paper in papers:
        missing = sorted(set(range(1, paper.expected + 1)) - seen[paper.id])
        if missing:
            notes.append(f"V1 {paper.id}: görüntüden okunamayan numara {missing}")
    return out, notes


# --- A7 ----------------------------------------------------------------------

def apply_labels(papers: Sequence[reg.Paper], questions: List[dict], job_items: Sequence[dict],
                 results: Dict[str, dict], topics: Dict[str, Sequence[str]]) -> Dict[str, dict]:
    """Votes → monotone subjects per paper → the app's subject and a topic.

    Every question gets the settled subject, including those that got no vote
    (cancelled, unreadable): the segmentation places them in their block. A
    topic is kept only when the model's own vote for that question agrees
    with the settled subject and the topic is on that subject's list —
    otherwise null, the same rule `sanitizeTopics` applies to cards."""
    k_to_id = {(item["id"], q["k"]): q["id"] for item in job_items for q in item["questions"]}
    vote: Dict[str, Tuple[str, Optional[str]]] = {}
    for item_id, r in results.items():
        for v in r["output"].get("items", []):
            qid = k_to_id.get((item_id, v.get("k")))
            if qid:
                vote[qid] = (v.get("subject"), v.get("topic"))
    by_paper: Dict[str, List[dict]] = defaultdict(list)
    for q in questions:
        by_paper[q["paperId"]].append(q)
    report: Dict[str, dict] = {}
    for paper in papers:
        qs = sorted(by_paper.get(paper.id, []), key=lambda q: q["number"])
        if not qs:
            continue
        votes = [vote.get(q["id"], (None, None))[0] for q in qs]
        settled = sj.settle(votes, paper.test, paper.year)
        for q, osym in zip(qs, settled["labels"]):
            q["osymSubject"] = osym or None
            q["subject"] = sj.TO_APP.get(osym) if osym else None
            mine = vote.get(q["id"])
            topic = mine[1] if mine and mine[0] == osym else None
            q["topic"] = topic if topic in topics.get(q["subject"] or "", ()) else None
        report[paper.id] = {k: v for k, v in settled.items() if k != "labels"}
        report[paper.id]["votes"] = sum(1 for v in votes if v)
    return report


def v7_reference(path: Path) -> Dict[str, str]:
    """The 2026 currency analysis's 932 subject labels for 2022–2026, keyed
    by our question id, at ÖSYM subject level. A cross-check, not a source."""
    if not path.exists():
        return {}
    names = {"Histoloji ve Embriyoloji": "Histoloji-Embriyoloji"}
    out = {}
    for r in json.loads(path.read_text(encoding="utf-8")):
        exam = r["exam"].replace("/", "-")
        test = "T" if r["test"].startswith("Temel") else "K"
        out[f"TUS-{exam}-{test}-{int(r['q']):03d}"] = names.get(r["subject"], r["subject"])
    return out


def v7_agreement(questions: Iterable[dict], reference: Dict[str, str]) -> Tuple[int, int, List[str]]:
    compared = agree = 0
    misses = []
    for q in questions:
        ref = reference.get(q["id"])
        if ref is None or not q.get("osymSubject"):
            continue
        compared += 1
        if q["osymSubject"] == ref:
            agree += 1
        else:
            misses.append(f"{q['id']}: {q['osymSubject']} ≠ referans {ref}")
    return compared, agree, misses


# --- V6 ----------------------------------------------------------------------

V6_MIN = 0.6  # §5.11: chance is 20 %; a key for the other booklet would sit near it


def apply_check(job_items: Sequence[dict], results: Dict[str, dict], answers: Dict[str, Optional[int]]
                ) -> Dict[str, dict]:
    """Per paper: how many of its 15 sampled questions the model answers the
    way the key does. A key that belongs to the B booklet scores near chance."""
    report = {}
    for item in job_items:
        r = results.get(item["id"])
        if r is None:
            report[item["id"]] = {"asked": len(item["questions"]), "agree": None, "pass": False}
            continue
        by_k = {v["k"]: v["answer"] for v in r["output"].get("items", [])}
        agree = sum(1 for q in item["questions"]
                    if by_k.get(q["k"]) is not None and answers.get(q["id"]) == LETTERS.index(by_k[q["k"]]))
        asked = len(item["questions"])
        report[item["id"]] = {"asked": asked, "agree": agree, "pass": agree / asked >= V6_MIN}
    return report
