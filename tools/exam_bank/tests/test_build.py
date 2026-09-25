"""`python -m tools.exam_bank.build --dry-run` against a scratch folder.

Fake PDFs (a few bytes each) stand in for the booklets: what is under test is
the bookkeeping — present, unchanged, nothing silently skipped — not PDF
parsing, and no copyrighted page ever enters the repo (§5.13).
"""
import hashlib
import json
import unicodedata

import pytest

from tools.exam_bank import build


def write_pdf(root, relative, content):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return hashlib.sha256(content).hexdigest()


@pytest.fixture
def folder(tmp_path):
    root = tmp_path / "pdfs"
    sha = write_pdf(root, "2013-2021/TUS_2019_Ilkbahar_Temel.pdf", b"%PDF-1.4 temel")
    registry = {
        "schemaVersion": 1,
        "sources": [{
            "file": "2013-2021/TUS_2019_Ilkbahar_Temel.pdf",
            "sha256": sha,
            "family": "F3",
            "sourceKind": "osym",
            "papers": [{
                "id": "TUS-2019-1-T", "date": "2019-02-24", "expected": 120, "numberOffset": 0,
                "timeLimitMinutes": None, "penalty": "unknown", "keySource": "osym",
            }],
        }],
        "excluded": [{"pattern": "2022-2026/yenikeşif/*", "reason": "kopya"}],
    }
    path = tmp_path / "sources.json"
    path.write_text(json.dumps(registry, ensure_ascii=False), encoding="utf-8")
    return root, path


def run(root, registry_path, *extra):
    return build.main(["--dry-run", "--registry", str(registry_path), "--source-dir", str(root), *extra])


def test_clean_folder_passes(folder, capsys):
    root, registry_path = folder
    assert run(root, registry_path) == build.EXIT_OK
    assert "hepsi yerinde" in capsys.readouterr().out


def test_missing_file_fails(folder, capsys):
    root, registry_path = folder
    (root / "2013-2021/TUS_2019_Ilkbahar_Temel.pdf").unlink()
    assert run(root, registry_path) == build.EXIT_INVALID
    assert "eksik" in capsys.readouterr().err


def test_changed_file_fails(folder, capsys):
    # A re-downloaded or edited booklet could renumber questions; the IDs
    # minted from it must not drift silently.
    root, registry_path = folder
    (root / "2013-2021/TUS_2019_Ilkbahar_Temel.pdf").write_bytes(b"%PDF-1.4 changed")
    assert run(root, registry_path) == build.EXIT_INVALID
    assert "değişmiş" in capsys.readouterr().err


def test_unregistered_pdf_fails(folder, capsys):
    root, registry_path = folder
    write_pdf(root, "2022-2026/TUS_2027_Ilkbahar_Temel.pdf", b"%PDF-1.4 new")
    assert run(root, registry_path) == build.EXIT_INVALID
    assert "kayıtsız PDF" in capsys.readouterr().err


def test_excluded_pdf_with_a_decomposed_name_is_ignored(folder):
    root, registry_path = folder
    nfd = unicodedata.normalize("NFD", "2022-2026/yenikeşif/kopya.pdf")
    write_pdf(root, nfd, b"%PDF-1.4 copy")
    assert run(root, registry_path) == build.EXIT_OK


def test_non_pdf_files_are_not_sources(folder):
    root, registry_path = folder
    (root / "notlar.md").write_text("rapor", encoding="utf-8")
    assert run(root, registry_path) == build.EXIT_OK


def test_invalid_registry_fails_before_reading_the_folder(tmp_path, capsys):
    bad = tmp_path / "sources.json"
    bad.write_text(json.dumps({"schemaVersion": 2, "sources": [], "excluded": []}), encoding="utf-8")
    assert build.main(["--dry-run", "--registry", str(bad)]) == build.EXIT_INVALID
    assert "schemaVersion" in capsys.readouterr().err


def test_building_is_not_pretended(folder, capsys):
    # Faz 0 has no extraction stages; a real run must say so, not exit 0.
    root, registry_path = folder
    assert build.main(["--registry", str(registry_path), "--source-dir", str(root)]) == build.EXIT_NOT_IMPLEMENTED
    assert "Faz A1" in capsys.readouterr().err
