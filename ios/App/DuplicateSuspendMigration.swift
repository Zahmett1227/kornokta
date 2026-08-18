import Foundation
import SwiftData
import CizgiCore

/// One-time suspension of the duplicate cards found in the 2026-08-18 deck
/// audit (996 active cards read one by one against the whole deck, mechanical
/// near-match scan + semantic pass; the cluster-by-cluster report lives with
/// the owner). Every id below is an exact/near duplicate of another card, or
/// a card whose entire testable content is contained in a kept card's answer.
/// 117 cards; the main source was pages photographed more than once — the
/// dHash step asks rather than refuses, by design.
///
/// Suspends, never deletes: `.suspended` keeps the card's `ReviewLog` history
/// and FES record, removes it from Tekrar scheduling, Egzersiz selection and
/// the FES lists, and stays reversible card by card from Bilgilerim
/// ("Askıdan çıkar"). Only an `.active` card is touched — a status the user
/// set by hand is never overridden.
///
/// Runs once at startup, guarded by a UserDefaults flag written only after a
/// successful save — `SubjectBackfillMigration`'s pattern: a failed run rolls
/// back and simply retries next launch. Deliberately NOT
/// `TopicBackfillMigration`'s per-card seen-set: that design keeps rescanning
/// the whole deck forever once a single listed card has been deleted (the
/// known open issue in CLAUDE.md). The gap the seen-set existed for — cards
/// arriving later via an additive restore, after a fresh install's empty-store
/// run has already spent the one-shot flag — is closed the way
/// `ApprovalGateMigration` closes the very same gap (Codex, PR #44 and #46):
/// `SettingsView.restore` re-runs the idempotent `suspend(in:)` step on the
/// restore's own context, so an audited duplicate restored as `.active` is
/// suspended in the same breath that inserted it. A listed card the user
/// un-suspends by hand afterwards stays un-suspended: the startup run has
/// spent its flag, and the restore hook is limited to the records that
/// restore actually inserted — a pre-existing card's status is the user's
/// live choice, and no later additive restore may override it (Codex,
/// PR #46, second pass).
@MainActor
enum DuplicateSuspendMigration {
    static let flagKey = "cizgi.migration.duplicateSuspend.deck2026_08_18.v1"

    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }

        let context = ModelContext(container)
        do {
            try suspend(in: context)
            try context.save()
            defaults.set(true, forKey: flagKey)
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }

    /// The core step, callable from the restore flow as well: suspends every
    /// listed card that is currently `.active` and returns how many changed.
    /// Idempotent — a second run finds nothing left to do — and it never
    /// saves; the caller owns the transaction.
    ///
    /// `limitedTo` narrows the sweep to specific card ids. The startup run
    /// passes nil — on the ordinary path nothing has had a chance to be
    /// un-suspended before the one-shot flag is spent. The restore hook
    /// passes the ids it just inserted, and must: a whole-store sweep there
    /// would re-suspend a card the user deliberately reactivated, on any
    /// later restore that happens to insert one new card (Codex, PR #46,
    /// second pass). One accepted wrinkle: a *failed* restore hook clears
    /// the startup flag, and the retry is a nil sweep that can re-suspend a
    /// reactivated card once. That trade is deliberate — the alternative,
    /// not retrying at all, leaves restored duplicates active silently and
    /// forever, while this failure mode is visible in Bilgilerim and one tap
    /// undoes it.
    @discardableResult
    static func suspend(in context: ModelContext, limitedTo restoredIds: Set<UUID>? = nil) throws -> Int {
        let cards = try context.fetch(FetchDescriptor<Card>())
        var changed = 0
        for card in cards where suspendIds.contains(card.id.uuidString.uppercased()) {
            if let restoredIds, !restoredIds.contains(card.id) { continue }
            guard card.status == .active else { continue }
            card.status = .suspended
            changed += 1
        }
        return changed
    }

    /// The audit's suspension list, grouped by the cards' topics as they
    /// stood in the 2026-08-18 backup. Kept as data, not derived: the
    /// duplicate judgement was made by reading, and nothing on the device
    /// could recompute it.
    private static let suspendIds: Set<String> = [
        // Solunum Sistem Hastalıkları (49)
        "07574536-0756-44CB-85B7-E31B6962299E", "103F8319-4B7C-4679-9DF7-2DB8552DF0D1", "1E75C83A-D8B4-48EF-95FD-7A1B21215655",
        "1EEF2370-9AC6-4DDE-B456-41B5CC5A532D", "20177026-6B56-46AC-B4E0-546C5F8071A9", "28D509DF-0A1C-42F7-BE90-C3BFC1659635",
        "33132AE3-4E36-48FA-97F6-FEDDA6EEBAF2", "340F874B-411A-43E4-9576-65F98DF4A94A", "39C4D8CD-15BA-41D9-BA1F-995529A73B34",
        "3BE435EF-7C2B-48F6-944C-9D624653F142", "3EA21BA7-9F57-496C-AE78-A62E0F8393FA", "3F3568ED-6EB0-4628-9CC9-029C9846C433",
        "45E36C7A-9121-4554-A004-62086C6C4DA2", "4967DEE2-2773-474C-AABC-78E13E144721", "4F38360D-2E48-4D74-8720-ABB1BAF3BE3F",
        "53F4B6EA-F9D6-459E-926A-E84856F80FD4", "5543FCAC-3B60-4F17-BA05-42AA162C5195", "56A0EA92-687E-496A-9F92-5A2156201F55",
        "5B25CBC4-5177-40EE-92BF-1D6283524908", "619DDEA9-0C27-45F0-9EC7-B00A12F09C7E", "62DBDBBD-D96D-4E45-863C-2F30BF6E925E",
        "668C1A77-F222-4113-9A15-4DFFDFD8BAEB", "68FA855F-31F3-47F6-A31D-98261DA09AD2", "6C898016-4864-4F79-8AB3-6AD6E411147A",
        "7E6EF8B7-1DB5-4751-AABD-2E0A95D0D5FC", "7ED5D9E7-96BD-47C3-A8C7-5E848374ADD6", "89D7F528-C822-4B9C-B8BE-326A4B5D53A1",
        "8E359E41-D526-43F2-8C5D-FA4E323E9213", "9B79CF4F-135C-4B7F-A8A5-58A79CB10ED6", "9C7AFA97-3124-45FE-9841-ECBA114E08D2",
        "9C9E2247-C250-4455-8E91-DBC1F1D11C5C", "9EDB4344-8575-403C-A892-81AF7524F0FB", "ACD0CB8C-25FE-41AA-A72D-5FCECC24E801",
        "AD4A5CFE-8B1A-4E47-A4E4-8E5012B19927", "AD7F835C-5884-41FF-BACB-09A75C57C707", "AE635C81-E9F0-4AFF-B6A4-6045604B2176",
        "BAEC1811-74FD-4366-A7F6-02DC4226C4DB", "C455E693-504D-43ED-9AA3-7F3418AEB849", "C5351186-B741-48D3-BEA3-5C2667B93435",
        "C61F0CDF-E877-4B74-926D-5E588D26FFB7", "DA6B3E12-E173-4DB5-888C-1C353F752A44", "E611F9C3-5380-43F5-983A-271A04E56426",
        "EF2602D1-AD8A-406F-AB96-A2E6CEB12512", "F1E305AE-F7AE-497C-98B2-D8347D449596", "F8FBA287-FF27-4F9B-8847-C73DA06EF24E",
        "FBDD665B-A9AD-445B-9591-28FDF287FC6E", "FD728AA3-49F2-4BB6-BCE8-990DD05D1AFB", "FE162B44-E788-4620-94CD-13C224C2E65F",
        "FFF233E1-E6B2-400E-8E0A-85D6F0D20551",
        // Vasküler Hastalıklar (12)
        "1BD4675D-8FDC-4755-BF02-9569C34F498A", "1D00FFDF-BD8D-4F76-AA1E-83906F10D85D", "1FA1BEB4-FA9A-4A91-B06A-0AF62BF4E2DC",
        "5A6B468D-244D-4B7E-9CE7-5587469FA78D", "66B198B7-A6BE-4C1A-940E-B349D8FF6E74", "6EEB287A-91F7-42A5-A383-90C68D062CE0",
        "7DEF623F-7920-4C9F-80E2-87ED21D661FB", "CB559CCC-BE75-4A49-B45E-F491009E4C60", "EA35CFC0-8121-4EB4-B9BC-9496C131E558",
        "EE41591A-C4C1-4701-B88D-571599010EB7", "F83A99F5-CECE-4141-A363-6B803CC0C180", "FF350786-8307-4428-9690-2CAFC06A38CC",
        // Üriner Sistem Hastalıkları (11)
        "1D00D4F5-DAFC-4920-9365-CCAD532EB028", "22690465-0096-4183-856E-7F0ED57AD06B", "24D25737-B92B-4A6A-9FFE-09028D5B7395",
        "32CF57E4-1E63-4910-B98A-F4F39E089027", "385A5E83-3CA0-42B4-BE95-16F7DADCB76F", "4A6D0F76-5261-4988-81B4-2E54B212A6EC",
        "55707B08-76EC-47E7-9EC5-0CE08AE8CA9F", "77D15D50-549A-48E1-B4DE-9FDECF2F18BF", "9E7007D2-C733-4490-BE75-081DC15AF1D0",
        "D7C1F4C2-50D3-4C3F-8D09-8ACB81CF2B3F", "EFD45F61-DFDD-4551-BDBA-3B6B57C61E8D",
        // Hücre Zedelenmesi (8)
        "1C4E38CE-7874-4E3E-9844-95C896D6AB10", "452E585A-361C-42BB-849B-B8BEBEBD1157", "4DC25D06-BA64-43CF-93D7-B5F00235AE43",
        "50376B0F-1E77-413E-82A0-5A6C6F2ABEA8", "A5CC7F0F-6E63-412D-B32E-FB109C0F479F", "DBC6A987-394A-4157-87A6-AAFC8ECE0B6B",
        "F039C8FB-09BE-44BD-8658-B604D5092620", "F32FDE1D-D2CB-459C-8C8D-ECDE99F54394",
        // İmmünoloji (8)
        "2013E151-6C1C-4B1A-BC1F-EAFD93FADAE9", "78FA2FAA-8C7C-4808-A73B-D52C342C9D64", "9013127C-D4BB-40E9-B3BD-99FD9FF374DA",
        "91ACD9BA-6BEF-413F-A803-06ABDABCBCA6", "96985653-F9B3-4C96-A5D3-08ABE36349D5", "B601B30C-1368-4BB4-9522-1C76B06138CB",
        "EA381E7B-5BE7-4AF5-90DA-4C6CA87D89C4", "F1D37B71-1BAF-413B-A451-DA3FE2AE8188",
        // İnflamasyon (5)
        "0716CD82-F674-4E2C-B3BE-38E80ABE030C", "1D034C42-1FDD-4791-81DC-7E374F402D74", "8A71FF59-C450-495E-AB9F-72BFF535F5E6",
        "AEC3D6FB-7A7D-4003-AD59-3DC83450DC6B", "B6398035-23A0-4FF4-A0E8-7C41EB31BB42",
        // Neoplazi (5)
        "8502A613-CF02-4FAD-AD8C-DB09D7E9DEE3", "AB623D43-8D4A-4FCB-BD80-E520218A09B7", "D48C16FA-271E-440D-915E-757EB6547378",
        "D79C4325-C2F7-45F6-AB66-D93BCB6C9622", "ECBA4ECE-9812-4419-8BF8-F91757069237",
        // Hematopoetik Sistem Hastalıkları (3)
        "370DFD14-5CC9-489D-9523-A5C047D6D61D", "8B6B47EC-BD31-4C9E-A87B-17109567442E", "B01487D2-FBC4-4629-810E-54D77B4F1791",
        // Sinir Sistem Hastalıkları (3)
        "76E955F0-36C0-49FF-9C31-4AAB36C5F659", "A7D63E54-FAEB-484A-A3C6-F4125965F721", "F070612F-C236-410D-B367-F0DF5820AC53",
        // Çevresel ve Enfeksiyoz Hastalıklar (2)
        "44183A25-24AC-4A05-B53A-BD3950D8300C", "9EEFDFB1-E17B-4D7C-8CC1-3B5E6F5957E7",
        // Kalp ve İskelet Sistemi Hastalıkları (2)
        "446AE1F0-E264-41A0-B519-0A6969B8FE89", "B7AFAC2B-931F-4A96-B47C-6811DA2F8AA3",
        // Karaciğer Hastalıkları (2)
        "642DB7F3-A7B0-4535-A111-B84300604071", "8C821E8F-ED77-4391-B563-F19067611B32",
        // Kalp Hastalıkları (2)
        "B37D96BE-BEDC-48BF-9C29-7CC279BC02E7", "D6D323A7-B2D5-4C80-9233-53F40F8515BE",
        // Meme Hastalıkları (1)
        "52FF30CC-4834-48A2-9F99-C978DB285937",
        // Gastrointestinal Sistem Hastalıkları (1)
        "8077111D-93EF-45DC-9A43-066CAF037CF9",
        // Deri Hastalıkları (1)
        "8911DCE5-9811-4EF0-ACAF-87F2B5F25512",
        // Kadın Genital Sistem Hastalıkları (1)
        "8D92A1C8-7C83-414D-8382-BF36AAF27EEF",
        // Erkek Genital Sistem Hastalıkları (1)
        "ED21751E-6535-439B-A98E-0981D4E5AB5F",
    ]
}
