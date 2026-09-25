"""A8 — the gates (docs/PLAN-cikmis-soru-bankasi.md §5.11). Any one failing
stops packaging.

Each gate returns {"pass": bool, "detail": str}. The numbers behind them are
computed by the stages; this module only reads their outputs and the bank
itself, so a gate cannot pass on a number nobody measured.
"""
from __future__ import annotations

import html
import base64
import io
import json
import random
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

from . import render
from .extract.options import same_option

V7_MIN = 0.90
V8_MIN_INK = 0.02
V9_SAMPLE = 30


def _gate(ok: bool, detail: str) -> dict:
    return {"pass": bool(ok), "detail": detail}


def v1(a1: dict, a7: dict) -> dict:
    missing = [f"{p['paperId']} {p['missing']}" for p in a1["papers"] if p["missing"]]
    vision = [n for n in a7.get("modelNotes", []) if n.startswith("V1 ")]
    return _gate(not missing and not vision,
                 "tamam" if not missing and not vision else "; ".join(missing + vision))


def v2(questions: List[dict]) -> dict:
    """Five options, a stem, no unreadable glyph, no two options alike —
    except a question whose options are pictures ("[görsel]") and, reported,
    one whose source prints the same option twice (repair confirmed it)."""
    bad = []
    for q in questions:
        if q["status"] in ("cancelled", "needsHuman"):
            continue
        opts = q["options"] or []
        if q["status"] == "needsRepair" or not q["stem"] or len(opts) != 5 or any(not o for o in opts):
            bad.append(q["id"])
            continue
        keys = [same_option(o) for o in opts if o != "[görsel]"]
        if len(set(keys)) != len(keys) and q.get("textQuality") != "repaired":
            bad.append(q["id"])
    return _gate(not bad, "tamam" if not bad else f"{len(bad)} soru: {', '.join(bad[:10])}")


def v3_v4_v5(a2: dict, a3: dict) -> Dict[str, dict]:
    v3 = [p for p in a2["problems"] if not p.startswith("V4")]
    v4 = a2["v4"]
    v5 = a3["v5"]
    return {
        "V3": _gate(not v3, "tamam" if not v3 else "; ".join(v3[:5])),
        "V4": _gate(v4["disagree"] == 0 and v4["compared"] > 0, f"{v4['agree']}/{v4['compared']} uyuşuyor"),
        "V5": _gate(v5["failed"] == 0, f"{v5['compared'] - v5['failed']}/{v5['compared']}"),
    }


def v6(a7: dict) -> dict:
    failed = {pid: r for pid, r in a7["v6"].items() if not r["pass"]}
    return _gate(not failed, f"{len(a7['v6']) - len(failed)}/{len(a7['v6'])} kağıt ≥ %60"
                 + ("" if not failed else f"; düşen: {', '.join(failed)}"))


def v7(a7: dict) -> dict:
    v = a7["v7"]
    share = v["agree"] / v["compared"] if v["compared"] else 0.0
    loose = [pid for pid, r in a7["subjects"].items() if not r["monotone"]]
    ok = share >= V7_MIN and not loose
    return _gate(ok, f"referansla {v['agree']}/{v['compared']} = {share:.1%}; monoton olmayan kağıt "
                     f"{len(loose)}" + (f" ({', '.join(loose)})" if loose else ""))


def v8(questions: List[dict], source_dir: Path) -> dict:
    """Every figure question has a box whose crop is not blank, on a page
    whose geometry the phone can map (no offset crop box, no rotation)."""
    problems = []
    pages_by_file: Dict[str, set] = {}
    for q in questions:
        for r in q["provenance"]:
            pages_by_file.setdefault(r["file"], set()).add(r["page"])
    for file, pages in pages_by_file.items():
        problems.extend(render.check_geometry(source_dir / file, sorted(pages)))
    checked = 0
    for q in questions:
        if q.get("figure") != "required":
            continue
        if not q["provenance"]:
            problems.append(f"{q['id']}: kutu yok")
            continue
        r = q["provenance"][0]
        ink = render.ink_share(render.crop(source_dir / r["file"], r["page"], r["bbox"], dpi=50))
        checked += 1
        if ink < V8_MIN_INK:
            problems.append(f"{q['id']}: kırpıntı boş (%{ink * 100:.1f})")
    return _gate(not problems, f"{checked} görselli soru" + ("" if not problems else "; " + "; ".join(problems[:5])))


def v9_sample(questions: List[dict], seed: str) -> List[dict]:
    pool = [q for q in questions if q["status"] in ("ok", "keyless", "modified")]
    return sorted(random.Random(seed).sample(pool, min(V9_SAMPLE, len(pool))), key=lambda q: q["id"])


def v9_page(sample: List[dict], source_dir: Path, dest: Path) -> None:
    """The owner's sheet: each sampled question as the bank has it, beside its
    crop from the booklet. Local only (out/, gitignored) — never published:
    it is booklet content."""
    parts = []
    for q in sample:
        crops = []
        for r in q["provenance"]:
            image = render.crop(source_dir / r["file"], r["page"], r["bbox"], dpi=110)
            buf = io.BytesIO()
            image.save(buf, format="PNG")
            crops.append(f'<img src="data:image/png;base64,{base64.b64encode(buf.getvalue()).decode()}">')
        answer = "—" if q["answer"] is None else "ABCDE"[q["answer"]]
        options = "".join(f"<li{' class=ans' if i == q['answer'] else ''}>{'ABCDE'[i]}) {html.escape(o)}</li>"
                          for i, o in enumerate(q["options"] or []))
        where = ", ".join(f"{r['file'].split('/')[-1]} s.{r['page']}" for r in q["provenance"])
        parts.append(f"""<section><h2>{q['id']} <small>{html.escape(where)} · cevap {answer} ·
{q.get('osymSubject') or '—'} / {q.get('topic') or '—'} · {q['textQuality']}</small></h2>
<div class=row><div class=text><p>{html.escape(q['stem']).replace(chr(10), '<br>')}</p><ol>{options}</ol></div>
<div class=crop>{''.join(crops)}</div></div></section>""")
    dest.write_text(f"""<!doctype html><meta charset=utf-8><title>V9 örneklemi</title>
<style>body{{font:15px -apple-system,sans-serif;margin:24px;max-width:1300px}}
section{{border-top:1px solid #ccc;padding:12px 0}}h2{{font-size:16px}}small{{color:#666;font-weight:normal}}
.row{{display:flex;gap:24px}}.text{{flex:1}}.crop{{flex:1}}.crop img{{max-width:100%;border:1px solid #ddd}}
ol{{list-style:none;padding:0}}li.ans{{font-weight:bold;color:#0a6}}</style>
<h1>V9 — insan örneklemi ({len(sample)} soru)</h1>
<p>Her sorunun metnini, şıklarını ve cevabını yanındaki kitapçık kırpıntısıyla karşılaştır. Hepsi doğruysa
<code>python -m tools.exam_bank.finish --human-check "Ad"</code> ile onayla.</p>
{''.join(parts)}""", encoding="utf-8")


def v9(sample: List[dict], human_check: Optional[dict]) -> dict:
    ids = [q["id"] for q in sample]
    if not human_check:
        return _gate(False, "sahibinin onayı bekleniyor (out/V9-orneklem.html)")
    if human_check.get("sample") != ids:
        return _gate(False, "onay başka bir örnekleme ait; yeni örneklem gözden geçirilmeli")
    return _gate(True, f"{human_check['by']} · {human_check['at']} · {len(ids)} soru")


def v10(out: Path, repo: Path) -> dict:
    ignored = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", str(out / "bank.json")]).returncode == 0
    status = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "--", str(out)],
                            capture_output=True, text=True).stdout.strip()
    ok = ignored and not status
    return _gate(ok, "çıktı gitignore'lu, git temiz" if ok else f"gitignore={ignored}, git status: {status[:200]}")
