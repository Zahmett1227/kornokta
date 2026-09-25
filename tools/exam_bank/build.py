"""Builds the past-exam question bank (docs/PLAN-cikmis-soru-bankasi.md §5).

    python -m tools.exam_bank.build --dry-run
    EXAM_SOURCE_DIR=/path/to/pdfs python -m tools.exam_bank.build --dry-run
    EXAM_SOURCE_DIR=/path/to/pdfs python -m tools.exam_bank.build

The dry run validates `sources.json` and, when the source folder is given,
checks that every registered PDF is there and unchanged (sha256) and that no
PDF in the folder is silently ignored. A real run does the same checks first
and then runs the deterministic stages, writing each one's output under
`tools/exam_bank/out/` (gitignored — it holds booklet text).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
from collections import Counter
from pathlib import Path
from typing import List, Optional

import json

from . import registry as reg

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_NOT_IMPLEMENTED = 2
EXIT_GATE = 3  # a stage ran, and its gate failed

OUT_DIR = Path(__file__).with_name("out")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_source_dir(registry: reg.Registry, root: Path) -> List[str]:
    """Every registered file present and byte-identical; every PDF under
    `root` either registered or explicitly excluded with a reason.

    The second half is the point: a PDF that is neither would be skipped
    without a trace, and a skipped booklet reads exactly like a booklet that
    does not exist (the "no silent caps" rule)."""
    problems: List[str] = []
    registered = {reg.nfc(s.file) for s in registry.sources}
    for source in registry.sources:
        path = root / source.file
        if not path.is_file():
            problems.append(f"eksik: {source.file}")
        elif sha256_of(path) != source.sha256:
            problems.append(f"değişmiş (sha256 uyuşmuyor): {source.file}")
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() != ".pdf":
            continue
        relative = reg.nfc(path.relative_to(root).as_posix())
        if relative in registered or registry.is_excluded(relative):
            continue
        problems.append(f"kayıtsız PDF (sources.json'a ekle ya da excluded'a gerekçesiyle yaz): {relative}")
    return problems


def summary_lines(registry: reg.Registry) -> List[str]:
    lines = []
    families = Counter(s.family for s in registry.sources)
    lines.append(f"{len(registry.sources)} kaynak dosya · {len(registry.papers)} dosya-kağıt · "
                 f"{len(registry.paper_ids())} benzersiz kağıt")
    lines.append("Aileler: " + ", ".join(f"{f} {families[f]}" for f in reg.FAMILIES))
    keyed = Counter(p.key_source for _, p in registry.papers)
    lines.append("Anahtar kaynağı (dosya-kağıt): " + ", ".join(f"{k} {keyed[k]}" for k in reg.KEY_SOURCES))
    gaps = reg.missing_tests(registry)
    lines.append("Eksik test: " + (", ".join(gaps) if gaps else "yok"))
    return lines


def paper_table(registry: reg.Registry) -> List[str]:
    rows = ["kağıt           aile  soru  anahtar         tarih       dosya"]
    for source, paper in sorted(registry.papers, key=lambda sp: (sp[1].id, sp[0].family)):
        rows.append(f"{paper.id:<15} {source.family:<5} {paper.expected:>4}  "
                    f"{paper.key_source:<14}  {paper.date or '—':<10}  {source.file}")
    return rows


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m tools.exam_bank.build")
    parser.add_argument("--dry-run", action="store_true",
                        help="kaydı doğrula, kaynak klasörü denetle; hiçbir şey üretme")
    parser.add_argument("--source-dir", type=Path, default=None,
                        help="PDF klasörü (varsayılan: EXAM_SOURCE_DIR)")
    parser.add_argument("--registry", type=Path, default=reg.REGISTRY_PATH)
    parser.add_argument("--list", action="store_true", help="kağıtları tek tek listele")
    parser.add_argument("--out", type=Path, default=OUT_DIR, help="çıktı klasörü (varsayılan: tools/exam_bank/out)")
    args = parser.parse_args(argv)

    registry = reg.load(args.registry)
    if registry.errors:
        print("sources.json geçersiz:", file=sys.stderr)
        for e in registry.errors:
            print(f"  - {e}", file=sys.stderr)
        return EXIT_INVALID

    for line in summary_lines(registry):
        print(line)
    if args.list:
        print()
        for row in paper_table(registry):
            print(row)

    source_dir = args.source_dir or (Path(os.environ["EXAM_SOURCE_DIR"]) if os.environ.get("EXAM_SOURCE_DIR") else None)
    if source_dir is None:
        print("Kaynak klasör verilmedi (EXAM_SOURCE_DIR ya da --source-dir): yalnız kayıt doğrulandı.")
    else:
        problems = check_source_dir(registry, source_dir)
        if problems:
            print(f"Kaynak klasör ({source_dir}) sorunlu:", file=sys.stderr)
            for p in problems:
                print(f"  - {p}", file=sys.stderr)
            return EXIT_INVALID
        print(f"Kaynak klasör tamam: {len(registry.sources)} dosyanın hepsi yerinde ve değişmemiş.")

    if args.dry_run:
        return EXIT_OK
    if source_dir is None:
        print("Üretim için kaynak klasör gerekli (EXAM_SOURCE_DIR ya da --source-dir).", file=sys.stderr)
        return EXIT_INVALID
    return run_stages(registry, source_dir, args.out)


def _write(out: Path, name: str, result: dict) -> None:
    (out / name).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")


def run_stages(registry: reg.Registry, source_dir: Path, out: Path) -> int:
    from . import a1, a2  # need pdfplumber; the dry run does not

    out.mkdir(parents=True, exist_ok=True)
    cache = out / "cache"
    first = a1.run(registry, source_dir, cache_dir=cache)
    _write(out, "a1.json", first)
    for line in a1.report(first):
        print(line)
    if any(p["missing"] for p in first["papers"]):
        print("V1 düştü: numarası bulunamayan soru var; sonraki aşamalara geçilmiyor.", file=sys.stderr)
        return EXIT_GATE

    second = a2.run(registry, first, source_dir, cache_dir=cache)
    _write(out, "a2.json", second)
    for line in a2.report(second, first):
        print(line)
    if second["problems"]:
        print("V3/V4 düştü: anahtar eksik ya da ÖSYM ile uyuşmuyor; sonraki aşamalara geçilmiyor.", file=sys.stderr)
        return EXIT_GATE

    from . import figures, merge
    from .a1 import read_pages

    third = merge.run(registry, first, second)
    by_file = {s.file: s for s in registry.sources}
    third["figures"] = figures.annotate(third["questions"],
                                        lambda f: read_pages(by_file[f], source_dir, cache))
    _write(out, "a3.json", third)
    for line in merge.report(third):
        print(line)
    counts = third["figures"]
    print(f"A4: görsel gerekli {counts.get('required', 0)}, görsele atıf {counts.get('reference', 0)}, "
          f"görselsiz {counts.get('none', 0)}")
    if third["problems"]:
        print("V5 düştü: ÖSYM'nin görünür sorusu kopyada bulunamadı; sonraki aşamalara geçilmiyor.", file=sys.stderr)
        return EXIT_GATE
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
