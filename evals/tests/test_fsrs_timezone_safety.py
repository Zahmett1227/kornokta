"""§18.1: "Zaman dilimi değişimi kart kaybına veya çift tekrara yol açmamalıdır."

The scheduler satisfies this by construction: both the Python reference and
the Swift port compute elapsed time as an absolute duration
(`now - last_reviewed_at`, in seconds/86400) and never consult a calendar or
the device's current time zone. A calendar-date boundary is exactly what
would shift when the time zone changes — that is the failure mode this
design avoids by not having one.

This reads `FSRSScheduler.swift` as text, the same way
`test_swift_contract_sync.py` checks the risk-flag enums, so the invariant
is enforced by the existing Python CI with no Swift toolchain and no
simulator. It cannot prove the algorithm is *correct* — `FSRSSchedulerTests.swift`
does that against the shared case file — only that nobody quietly
reintroduced a time-zone dependency into how elapsed time is computed.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCHEDULER_PATH = (
    REPO_ROOT / "ios" / "CizgiCore" / "Sources" / "CizgiCore"
    / "Scheduling" / "FSRSScheduler.swift"
)


def test_the_scheduler_never_references_calendar_or_timezone():
    source = SCHEDULER_PATH.read_text(encoding="utf-8")
    for forbidden in ("Calendar", "TimeZone", "startOfDay", "DateComponents"):
        assert forbidden not in source, (
            f"FSRSScheduler.swift artık {forbidden!r} kullanıyor — bu, elapsed time "
            "hesabını cihazın saat dilimine bağımlı hale getirebilir (§18.1)."
        )


def test_elapsed_time_is_computed_as_a_plain_duration():
    source = SCHEDULER_PATH.read_text(encoding="utf-8")
    assert "timeIntervalSince(state.lastReviewedAt" in source
