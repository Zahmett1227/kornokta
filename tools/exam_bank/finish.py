"""After the model stages: fold their results in, check the gates, package.

    python -m tools.exam_bank.finish

Idempotent and resumable. Each run applies whatever results exist and stops
at the first thing still missing, saying which command produces it:

1. A5 + A6 results (repair, 2011/1 vision) → `out/a6.json`, then the A7 and
   V6 job files.
2. A7 + V6 results (labels, key check) → `out/a7.json` with V6/V7 reports.
3. Gates V1–V10 and packaging (§5.11–5.12) — `package.py`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import List, Optional

from . import apply, figures, jobs
from . import registry as reg
from .a1 import read_pages

OUT = Path(__file__).with_name("out")
REFERENCE = "2022-2026/TUS_Guncellik_Raporu/SORU_KAYITLARI.json"
MODEL_ENV = ("OPENAI_EXAM_USD_PER_MILLION_INPUT_TOKENS=0.2 OPENAI_EXAM_USD_PER_MILLION_CACHED_INPUT_TOKENS=0.02 "
             "OPENAI_EXAM_USD_PER_MILLION_OUTPUT_TOKENS=1.2")


def _next(stage: str) -> str:
    return f"cd backend && {MODEL_ENV} npm run exam-bank -- ../tools/exam_bank/out/jobs/{stage}.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _write(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")


def _pending(out: Path, stage: str) -> List[str]:
    """Job items that have no successful result yet."""
    job = out / "jobs" / f"{stage}.json"
    if not job.exists():
        return []
    have = apply.load_results(out / "results" / f"{stage}.json")
    return [i["id"] for i in _load(job)["items"] if i["id"] not in have]


def stage_six(registry: reg.Registry, source_dir: Path, out: Path) -> Optional[dict]:
    a3 = _load(out / "a3.json")
    # The repair queue follows the deterministic stages: rebuilt every run, so
    # a question V2 newly sends to repair is queued without editing anything.
    jobs.write(out, "repair", jobs.repair_items(a3["questions"], source_dir, out))
    if not (out / "jobs" / "vision.json").exists():
        jobs.write(out, "vision", jobs.vision_items(source_dir, out))
    waiting = [(s, _pending(out, s)) for s in ("repair", "vision")]
    if any(p for _, p in waiting):
        for s, p in waiting:
            if p:
                print(f"Eksik: {len(p)} {s} sonucu. Çalıştır:\n  {_next(s)}")
        return None
    results = out / "results"
    a2 = _load(out / "a2.json")
    questions = a3["questions"]
    notes = apply.apply_repair(questions, apply.load_results(results / "repair.json"))

    source = next(s for s in registry.sources if s.file == jobs.VISION_FILE)
    pages = read_pages(source, source_dir, out / "cache")
    keys = {k.split("|")[0]: v["entries"] for k, v in a2["printedKeys"].items() if k.endswith("|" + source.file)}
    seen, vnotes = apply.vision_questions(apply.load_results(results / "vision.json"), source.file, pages, keys,
                                          list(source.papers))
    decor = figures.furniture(pages)
    by_number = {p.number: p for p in pages}
    for q in seen:
        images, vectors = figures.evidence(q["provenance"], by_number, decor)
        q["figure"] = figures.classify(q["stem"], [], images, vectors)
        if any(o == apply.PICTURE for o in q["options"]):
            q["figure"] = "required"
        q["figureEvidence"] = {"images": images, "vectors": vectors}
    notes.extend(vnotes)
    questions.extend(seen)
    questions.sort(key=lambda q: (q["paperId"], q["number"]))
    a6 = dict(a3, stage="A6", questions=questions, modelNotes=notes)
    _write(out / "a6.json", a6)
    by_status = {}
    for q in questions:
        by_status[q["status"]] = by_status.get(q["status"], 0) + 1
    print(f"A5+A6: {len(questions)} soru ({', '.join(f'{k} {v}' for k, v in sorted(by_status.items()))})")
    for n in notes:
        print(f"  {n}")
    return a6


def stage_seven(registry: reg.Registry, a6: dict, source_dir: Path, out: Path) -> Optional[dict]:
    results = out / "results"
    for stage, maker in (("label", jobs.label_items), ("check", jobs.check_items)):
        if not (out / "jobs" / f"{stage}.json").exists():
            items = maker(a6["papers"], a6["questions"])
            jobs.write(out, stage, items)
            print(f"{stage}: {len(items)} iş yazıldı.")
    missing = [s for s in ("label", "check") if not (results / f"{s}.json").exists()]
    if missing:
        for s in missing:
            print(f"Eksik: {s} sonuçları. Çalıştır:\n  {_next(s)}")
        return None

    papers = [p for s in registry.sources for p in s.papers]
    unique = list({p.id: p for p in papers}.values())
    topics = _topics()
    label_jobs = _load(out / "jobs" / "label.json")["items"]
    subjects = apply.apply_labels(unique, a6["questions"], label_jobs, apply.load_results(results / "label.json"),
                                  topics)
    reference = apply.v7_reference(source_dir / REFERENCE)
    compared, agree, misses = apply.v7_agreement(a6["questions"], reference)
    answers = {q["id"]: q["answer"] for q in a6["questions"]}
    check = apply.apply_check(_load(out / "jobs" / "check.json")["items"], apply.load_results(results / "check.json"),
                              answers)
    a7 = dict(a6, stage="A7", subjects=subjects, v6=check,
              v7={"compared": compared, "agree": agree, "misses": misses})
    _write(out / "a7.json", a7)

    not_monotone = [pid for pid, r in subjects.items() if not r["monotone"]]
    corrected = sum(r["corrected"] for r in subjects.values())
    with_topic = sum(1 for q in a6["questions"] if q.get("topic"))
    print(f"A7: {len(subjects)} kağıt; monoton bölütleme {len(subjects) - len(not_monotone)}/{len(subjects)}, "
          f"düzeltilen oy {corrected}; konulu soru {with_topic}/{len(a6['questions'])}")
    for pid in not_monotone:
        print(f"  sıra tutmadı: {pid} (uyuşma {subjects[pid]['agreement']:.0%})")
    share = agree / compared if compared else 0
    print(f"  V7 (referans 932 etiket): {agree}/{compared} = {share:.1%}")
    failed = {pid: r for pid, r in check.items() if not r["pass"]}
    print(f"V6 (kitapçık sağlaması): {len(check) - len(failed)}/{len(check)} kağıt ≥ %60")
    for pid, r in failed.items():
        print(f"  {pid}: {r['agree']}/{r['asked']}")
    return a7


def _topics():
    path = Path(__file__).parents[2] / "backend" / "schemas" / "subject_topics.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    return {s["name"]: s["topics"] for s in data["subjects"]}


def stage_eight(registry: reg.Registry, a7: dict, source_dir: Path, out: Path, human_by: Optional[str]) -> int:
    """Gates V1–V10; the package only when every one of them passes."""
    from datetime import datetime, timezone

    from . import gates, package

    a1, a2, a3 = (_load(out / f"a{i}.json") for i in (1, 2, 3))
    questions = a7["questions"]
    sample = gates.v9_sample(questions, seed="v9-" + str(len(questions)))
    gates.v9_page(sample, source_dir, out / "V9-orneklem.html")
    check_path = out / "human_check.json"
    if human_by:
        check_path.write_text(json.dumps({"by": human_by, "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                                          "sample": [q["id"] for q in sample]}, ensure_ascii=False, indent=1))
    human = _load(check_path) if check_path.exists() else None

    dest = out / "CizgiSoruBankasi"
    results = {"V1": gates.v1(a1, a7), "V2": gates.v2(questions)}
    results.update(gates.v3_v4_v5(a2, a3))
    results.update({"V6": gates.v6(a7), "V7": gates.v7(a7), "V8": gates.v8(questions, source_dir),
                    "V9": gates.v9(sample, human), "V10": gates.v10(dest, Path(__file__).parents[2])})
    print("A8 kapıları:")
    for name, r in results.items():
        print(f"  {name}: {'geçti' if r['pass'] else 'DÜŞTÜ'} — {r['detail']}")
    if not all(r["pass"] for r in results.values()):
        if not results["V9"]["pass"] and all(r["pass"] for k, r in results.items() if k != "V9"):
            print(f"Yalnız V9 kaldı: {out / 'V9-orneklem.html'} dosyasını aç, 30 soruyu kitapçıkla karşılaştır; "
                  "doğruysa:\n  python -m tools.exam_bank.finish --human-check \"Ad\"")
        return 3

    if dest.exists():
        import shutil
        shutil.rmtree(dest)
    paths, page_map = package.place_pdfs(registry, questions, source_dir, dest / "pdf")
    version = package.bank_version(out)
    built_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    document = package.bank_document(a7, paths, page_map, version, built_at, _subject_version())
    errors = package.validate(document)
    if errors:
        print("bank.json şemaya uymuyor:", *errors[:10], sep="\n  ")
        return 3
    manifest = package.write_package(dest, document, registry, results, human)
    package.commit_version(out, version)
    size = sum(f["bytes"] for f in manifest["files"]) / 1e6
    print(f"A9: {dest} — {manifest['counts']['questions']} soru, {manifest['counts']['papers']} kağıt, "
          f"{len(manifest['files'])} dosya, {size:.0f} MB, sürüm {version}")
    return 0


def _subject_version() -> int:
    path = Path(__file__).parents[2] / "backend" / "schemas" / "subject_topics.json"
    return json.loads(path.read_text(encoding="utf-8"))["version"]


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m tools.exam_bank.finish")
    parser.add_argument("--source-dir", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=OUT)
    parser.add_argument("--human-check", metavar="AD", default=None,
                        help="V9: 30 soruluk örneklemi kitapçıkla karşılaştırdım, doğru (onayı manifest'e yazar)")
    args = parser.parse_args(argv)
    source_dir = args.source_dir or (Path(os.environ["EXAM_SOURCE_DIR"]) if os.environ.get("EXAM_SOURCE_DIR") else None)
    if source_dir is None:
        print("Kaynak klasör gerekli (EXAM_SOURCE_DIR ya da --source-dir).", file=sys.stderr)
        return 1
    registry = reg.load()
    a6 = stage_six(registry, source_dir, args.out)
    if a6 is None:
        return 2
    a7 = stage_seven(registry, a6, source_dir, args.out)
    if a7 is None:
        return 2
    return stage_eight(registry, a7, source_dir, args.out, args.human_check)


if __name__ == "__main__":
    sys.exit(main())
