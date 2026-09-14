import Foundation

/// The short line under a grade button: when that grade would bring the card
/// back.
///
/// It lives here rather than in the view because it is the one part of showing
/// the interval that can be quietly wrong. The scheduler already returns
/// `scheduledDays`; turning a `Double` of days into "12 dk" / "4 gün" / "3 ay"
/// is arithmetic with four boundaries in it, and a boundary that rounds the
/// wrong way prints a number the card does not honour. `swift test` can hold
/// that still; a `%.0f` in a `Text` cannot.
public enum ReviewIntervalLabel {

    /// Shown for "Unuttum" while the card still has requeue budget in this
    /// sitting (`ReviewSession.wouldRequeueOnAgain`).
    ///
    /// The scheduler's interval *is* written to the card, so printing it would
    /// not be a lie about the store — but it would be a lie about the next
    /// minute, which is what the user is deciding with. The card goes to the
    /// end of the queue and comes back before they leave the screen.
    public static let sameSession = "oturumda"

    /// Days → a two-token label that fits under a quarter-width button.
    ///
    /// Deliberately coarse. The screen is not reporting the schedule, it is
    /// separating four choices from each other, and "4 gün" does that as well
    /// as "4,3 gün" while staying readable at `caption2`.
    public static func short(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "şimdi" }

        if days < 1 {
            let minutes = (days * 1440).rounded()
            if minutes < 60 { return "\(max(1, Int(minutes))) dk" }
            // Capped at 23 so a card 0.99 days out reads "23 sa" and not
            // "24 sa", which is a unit the next branch already owns.
            return "\(min(23, max(1, Int((days * 24).rounded())))) sa"
        }
        if days < 30 { return "\(max(1, Int(days.rounded()))) gün" }
        if days < 365 { return "\(max(1, Int((days / 30).rounded()))) ay" }
        return "\(max(1, Int((days / 365).rounded()))) yıl"
    }

    /// How long a sitting is expected to take, from a count of minutes.
    ///
    /// A separate ladder from `short` because it measures effort, not delay,
    /// and it starts from whole minutes. The start screen used to print this
    /// in minutes at every scale: a 3.000-card queue came out as "≈ 603 dk",
    /// a number nobody reads as ten hours.
    ///
    /// Minutes are dropped past four hours on purpose — at that scale they are
    /// noise around an estimate that is itself built from an average.
    public static func sessionEstimate(minutes: Int) -> String {
        let total = max(1, minutes)
        if total < 60 { return "\(total) dk" }
        let hours = total / 60
        let rest = total % 60
        if hours >= 24 { return "\(hours / 24) gün" }
        if hours >= 4 || rest == 0 { return "\(hours) sa" }
        return "\(hours) sa \(rest) dk"
    }

    /// The same thing said in full, for VoiceOver — "4 g" is read out as a
    /// letter.
    public static func spoken(days: Double) -> String {
        guard days.isFinite, days > 0 else { return "şimdi" }

        if days < 1 {
            let minutes = (days * 1440).rounded()
            if minutes < 60 { return "\(max(1, Int(minutes))) dakika sonra" }
            return "\(min(23, max(1, Int((days * 24).rounded())))) saat sonra"
        }
        if days < 30 { return "\(max(1, Int(days.rounded()))) gün sonra" }
        if days < 365 { return "\(max(1, Int((days / 30).rounded()))) ay sonra" }
        return "\(max(1, Int((days / 365).rounded()))) yıl sonra"
    }
}
