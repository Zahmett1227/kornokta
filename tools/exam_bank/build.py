"""Builds the past-exam question bank (docs/PLAN-cikmis-soru-bankasi.md §5).

    python -m tools.exam_bank.build --dry-run
    EXAM_SOURCE_DIR=/path/to/pdfs python -m tools.exam_bank.build --dry-run

Faz 0 ships only the dry run: it validates `sources.json` and, when the source
folder is given, checks that every registered PDF is there and unchanged
(sha256) and that no PDF in the folder is silently ignored. The extraction
stages (A1–A9) are Faz A1's work; running without `--dry-run` says so and
exits non-zero rather than pretending to build.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
from collections import Counter
from pathlib import Path
from typing import List, Optional

from . import registry as reg

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_NOT_IMPLEMENTED = 2


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

    if not args.dry_run:
        print("Çıkarım aşamaları (A1–A9) henüz yazılmadı — Faz A1 (docs/PLAN-cikmis-soru-bankasi.md §9.2).",
              file=sys.stderr)
        return EXIT_NOT_IMPLEMENTED
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
