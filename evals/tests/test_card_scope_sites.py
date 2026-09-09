"""Every screen that lists cards must narrow them to one `CardCollection`.

Splitting the deck into "Çekimlerim" and "Kavramlar" (a `Card.collectionRaw`
discriminator plus a scope switcher, not a second SwiftData model) introduced
exactly one way to break a working app: forget the filter at a single call
site and an imported pack's 3.017 cards pour into Tekrar, Egzersiz, Bilgilerim
or the reminder counts.

Nothing detects that at runtime. Every one of those cards is `.active`, has a
due date and renders correctly, so the screen looks healthy while answering a
question about the wrong deck. The failure is silent in the same way the
`OPENAI_MODEL`-without-prices mistake is silent, and it gets the same
treatment CLAUDE.md prescribes for it: "elle senkron tutma, üret ve testle
kilitle."

`CizgiCoreTests/CardScopeTests` proves the *composition* is right — a scoped
deck fed to `ReviewSessionPlanner`, `ExerciseFilter`, `LibraryCardFilter`,
`CardSearch` and `KnowledgeMapBuilder` never crosses collections. It cannot
prove a view actually calls `CardScope`, because the views are SwiftUI and live
in the App target. This does, by reading the source.

Python rather than Swift for the reason `test_swiftdata_migration_safety.py`
gives: the App target only compiles on a Mac, so a Swift test would run in
CI's macOS job alone — the one place this class of mistake is caught latest.
"""

from __future__ import annotations

import re
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "ios" / "App"

# Every screen holding a `@Query private var ...: [Card]`. A file added to this
# set is a new place the deck can leak from; a file removed from it should be
# because the query is gone, not because the check became inconvenient.
SCOPED_SITES = {
    "RootView.swift": "reminder counts",
    "Features/Review/ReviewView.swift": "Tekrar",
    "Features/Review/ExerciseView.swift": "Egzersiz",
    "Features/Library/LibraryView.swift": "Bilgilerim",
    "Features/Settings/SettingsView.swift": "Ayarlar",
}

CARD_QUERY = re.compile(r"@Query[^\n]*var\s+\w+\s*:\s*\[Card\]")


def _sources() -> dict[Path, str]:
    return {p: p.read_text(encoding="utf-8") for p in APP.rglob("*.swift")}


def test_every_card_query_lives_in_a_file_that_scopes_it() -> None:
    """The set above is the whole surface — a new `[Card]` query must join it.

    This is the half that catches the dangerous edit: someone adds a screen
    that lists cards, and nothing anywhere says it forgot the filter.
    """
    found = {
        str(path.relative_to(APP)).replace("\\", "/")
        for path, text in _sources().items()
        if CARD_QUERY.search(text)
    }
    assert found == set(SCOPED_SITES), (
        "A screen queries [Card] without being listed in SCOPED_SITES "
        f"(or vice versa). Unexpected: {sorted(found - set(SCOPED_SITES))}; "
        f"missing: {sorted(set(SCOPED_SITES) - found)}. Every such screen must "
        "narrow its deck through CardScope before listing or counting."
    )


def test_each_scoped_site_reads_the_active_collection() -> None:
    for relative, screen in SCOPED_SITES.items():
        text = (APP / relative).read_text(encoding="utf-8")
        assert "CardScope" in text, f"{screen} ({relative}) never calls CardScope"
        assert "CardScope.storageKey" in text, (
            f"{screen} ({relative}) does not read the shared scope key; a "
            "hardcoded @AppStorage string would drift silently."
        )


def test_settings_keeps_backup_and_restore_unscoped() -> None:
    """Ayarlar is the one file that must NOT scope everything it touches.

    Backup and restore are whole-device operations. Exporting only the deck on
    screen would silently drop the other one, and deduplicating a restore
    against a scoped id set would try to re-insert cards that are already
    there under an `@Attribute(.unique)` id. Only the reminder count and the
    card tally read a single deck.
    """
    text = (APP / "Features/Settings/SettingsView.swift").read_text(encoding="utf-8")

    export = text[text.index("private func prepareExport"):]
    export = export[: export.index("\n    private ", 1)]
    assert "CardScope" not in export, (
        "prepareExport must export the whole store: a scoped export drops the "
        "other deck from every backup, and its FSRS history with it."
    )

    restore = text[text.index("private func restore("):]
    restore = restore[: restore.index("\n    private ", 1)]
    assert "existingIds: Set(cards.map(\\.id))" in restore, (
        "restore must deduplicate against every card in the store; a scoped id "
        "set would re-insert cards that are already here."
    )
    # The card's own deck has to travel, or a restore rebuilds imported cards
    # inside the photographed deck.
    assert "collection: card.collectionRaw" in text
    assert "collection: CardCollection(rawValue: record.collection)" in text


def test_the_duplicate_audit_stays_on_the_photographed_deck() -> None:
    """The 2026-08-18 audit read one deck and has no authority over the other.

    A concept pack repeats a drug across concepts on purpose, so a duplicate
    sweep aimed at photographed pages must not reach it.
    """
    text = (APP / "DuplicateSuspendMigration.swift").read_text(encoding="utf-8")
    assert "card.collection == .capture" in text
