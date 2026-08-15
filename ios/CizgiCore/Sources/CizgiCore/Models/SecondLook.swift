import Foundation

/// "Gözden geçir" — the model's own doubt about a card it wrote (§13.3 rule 6).
///
/// Faz 6 dropped the approval gate on the promise that a suspicious card would
/// be *flagged* rather than held back (docs/FAZ7-PLAN-coktan-secmeli.md §9).
/// The half that was missing is the way out: `lowConfidence` was written once,
/// at generation, and no code path in the app ever wrote it again — not the
/// editor, not "İkinci görüş". So the owner could check a flagged card, find it
/// sound, and still have nowhere to record that. The only exits were suspending
/// the card or deleting it, and both take it out of review — the opposite of
/// what "I checked it and it is correct" means.
///
/// The flag is read on four more screens than the list it names (Egzersiz's
/// quick start, `ExerciseFilter.needsReview`, Tekrar's badge, and
/// `ExerciseSelection`'s always-eligible rule), which is why clearing it is a
/// single field rather than a per-screen dismissal.
public enum SecondLook {

    /// Whether a card still belongs in "Gözden geçir".
    ///
    /// Shared rather than repeated: Bilgilerim and Egzersiz each carried their
    /// own copy of this test, and Egzersiz's comment already asserted they were
    /// "the same cards" — a claim nothing enforced. That is the exact shape of
    /// drift this project has been bitten by twice (CLAUDE.md, anti-drift).
    ///
    /// A suspended card is excluded because it is out of the deck entirely;
    /// listing it under a heading that asks for a decision would be asking
    /// about a card the owner has already set aside.
    public static func isPending(lowConfidence: Bool, status: CardStatus) -> Bool {
        lowConfidence && status != .suspended
    }
}
