import Foundation

/// What the daily reminder should say, and whether it should fire at all
/// (ANA-PLAN §5.4, §6.7).
///
/// The old reminder was a single repeating calendar trigger with fixed text. It
/// fired every day at the chosen hour whether or not a single card was due, and
/// said "bugün zamanı gelen kartlarını tamamla" on days when there were none. A
/// notification that is wrong often enough becomes one you swipe away without
/// reading, which costs the app the only nudge it has.
///
/// iOS cannot evaluate a predicate at fire time, so the counting is done in
/// advance: whenever the app is open it schedules one-shot reminders for the
/// next few days, each carrying the number of cards that will actually be due by
/// then, and skips the days where that number is zero. Re-scheduling on every
/// launch keeps the horizon rolling.
public enum ReviewReminderPlanner {

    /// How far ahead to schedule. Long enough to survive a week away from the
    /// app, short enough that the counts are still roughly true when they fire —
    /// they are computed from today's due dates and cannot know about cards
    /// graded in between.
    public static let horizonDays = 7

    public struct Reminder: Equatable, Sendable {
        public let fireDate: Date
        public let dueCount: Int

        public init(fireDate: Date, dueCount: Int) {
            self.fireDate = fireDate
            self.dueCount = dueCount
        }

        /// Turkish plural is invariant, so this reads correctly for any count.
        public var body: String {
            "\(dueCount) kart tekrar bekliyor."
        }
    }

    /// One reminder per upcoming day that will actually have something due.
    ///
    /// `dueDates` are the due dates of the cards eligible for review — the
    /// caller filters out suspended ones, because a reminder that counts cards
    /// the review screen will not show is the same lie in a different place.
    public static func reminders(
        dueDates: [Date],
        hour: Int,
        from now: Date,
        days: Int = horizonDays,
        calendar: Calendar = .current
    ) -> [Reminder] {
        let clampedHour = min(max(hour, 0), 23)
        guard days > 0 else { return [] }

        var reminders: [Reminder] = []
        let today = calendar.startOfDay(for: now)

        for offset in 0..<days {
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: today),
                let fireDate = calendar.date(bySettingHour: clampedHour, minute: 0, second: 0, of: day)
            else { continue }

            // Today's slot has usually already passed by the time the app is
            // opened; scheduling it would either fire immediately or be dropped.
            guard fireDate > now else { continue }

            let dueCount = dueDates.reduce(into: 0) { total, dueDate in
                if dueDate <= fireDate { total += 1 }
            }
            guard dueCount > 0 else { continue }

            reminders.append(Reminder(fireDate: fireDate, dueCount: dueCount))
        }
        return reminders
    }

    /// What the app icon should show right now: cards that are due at this
    /// moment, not at some point today.
    public static func badgeCount(dueDates: [Date], now: Date) -> Int {
        dueDates.reduce(into: 0) { total, dueDate in
            if dueDate <= now { total += 1 }
        }
    }
}
