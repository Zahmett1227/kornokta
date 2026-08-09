import Foundation
import SwiftData
import CizgiCore

/// One-time content classification for the pre-topic-rollout deck.
///
/// `SubjectBackfillMigration` gave every existing card "Patoloji" and left
/// `topic` nil, because a subject can be inferred generically ("the whole
/// deck is Patoloji") but a topic cannot — it depends on what the page was
/// actually about. This migration closes that gap for the 204-card deck as
/// it stood in the 2026-08-08 backup export: every card's front/back/tags
/// was read once by hand and matched to a canonical Patoloji topic. Matches
/// by card `id` (the backup's UUID is the live `Card.id`), not by front
/// text — several pages were photographed more than once and produced
/// near-duplicate cards with slightly different wording, which a text match
/// would miss or double-count.
///
/// Only 203 of 204 cards are listed: one (the alpha-1-antitrypsin/emphysema
/// card) already carried a user-assigned topic in the backup and is
/// deliberately excluded — this migration must never overwrite a choice the
/// user made themselves. A card whose id isn't in `knownTopics` (anything
/// captured after this backup) is left untouched.
///
/// Reclassifies per card via find-or-create-and-rebind (mirrors
/// `CardEditorView.applyClassification`) rather than mutating a shared unit
/// in place: at least one source page mixed topics (ten respiratory cards
/// and two cardiology cards sharing one pre-topic-schema unit), so a
/// whole-unit move would either drag unrelated cards along or refuse to
/// move anything.
@MainActor
enum TopicBackfillMigration {
    static let flagKey = "cizgi.migration.topicBackfill.deck2026_08_08.v1"
    private static let targetSubject = "Patoloji"

    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        // No schema means no canonical topic names to validate against;
        // writing nothing is safer than writing against a broken resource.
        // Not flagged done, so a later launch with the resource fixed retries.
        guard let schema = try? SubjectTopicSchema.bundled() else { return }

        let context = ModelContext(container)
        do {
            let cards = try context.fetch(FetchDescriptor<Card>())
            var encounteredTargetDeck = false
            for card in cards {
                guard let topic = knownTopics[card.id.uuidString.uppercased()] else { continue }
                // The known-id match alone means this is the target deck,
                // regardless of whether the card below turns out already
                // classified or otherwise ineligible.
                encounteredTargetDeck = true
                guard schema.isValidTopic(topic, subject: targetSubject),
                      let unit = card.knowledgeUnit,
                      unit.subject == targetSubject,
                      unit.topic == nil
                else { continue }
                reclassify(card: card, to: topic, in: context)
            }
            try context.save()
            // A fresh install sees an empty store before the user restores
            // their backup; marking done here would skip the backfill on
            // that restore forever. Only mark done once the target deck's
            // cards have actually been seen.
            if encounteredTargetDeck {
                defaults.set(true, forKey: flagKey)
            }
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }

    /// Mirrors `CardEditorView.applyClassification`: find-or-create-and-rebind
    /// so a shared unit's other cards move only if they independently match,
    /// and a mixed-topic unit splits instead of dragging siblings along.
    private static func reclassify(card: Card, to topic: String, in context: ModelContext) {
        guard let current = card.knowledgeUnit else { return }

        if current.cards.count <= 1 {
            current.topic = topic
            current.updatedAt = .now
            card.updatedAt = .now
            return
        }

        let sibling = current.region?.knowledgeUnits.first {
            $0.id != current.id && $0.subject == targetSubject && $0.topic == topic
        }
        let target = sibling ?? {
            let unit = KnowledgeUnit(
                canonicalClaim: current.canonicalClaim,
                subject: targetSubject,
                topic: topic,
                tags: current.tags,
                sourceConcern: current.sourceConcern
            )
            unit.region = current.region
            context.insert(unit)
            return unit
        }()
        card.knowledgeUnit = target
        card.updatedAt = .now
    }

    private static let knownTopics: [String: String] = {
        var map: [String: String] = [:]
        // İnflamasyon (21)
        for id in ["0716CD82-F674-4E2C-B3BE-38E80ABE030C", "1839F518-5E2D-4EB9-A604-00F1079AB1A1", "1B6522B0-289F-4DD3-B25C-638494AC9715", "1D034C42-1FDD-4791-81DC-7E374F402D74", "28C49BC0-710A-41C6-9B27-680F91F7A145", "2F9C14A7-D8F3-4B84-A2FC-C3D8A0C5C432", "3AEF1DAC-B289-429C-B4AD-7DD1EA2E085F", "44322893-BF65-4F65-8BE3-CA84927E382C", "694BBF4C-3F8A-4512-903B-DBBB818432EF", "8A71FF59-C450-495E-AB9F-72BFF535F5E6", "A0171FA3-CD0E-4302-A3C8-59EC75A51DA5", "A65C1DDE-8F6D-45F0-857F-EF8563F103A0", "AB40328D-7EAE-4AFF-9D48-CF159010D9D5", "AEC3D6FB-7A7D-4003-AD59-3DC83450DC6B", "B6398035-23A0-4FF4-A0E8-7C41EB31BB42", "B642BEF9-97AE-4AD5-AF90-05932455697A", "BEF225CA-2B17-49D1-A0F5-CFC809B910BF", "C6B47CF1-8FDF-4D3A-9317-852F074A9689", "E086E6F9-6896-4E47-84EA-6B65A7BA1AE6", "E7BDAD60-75D6-49F1-8699-58A5B37F0DB2", "F234A9DE-17AF-409F-84B2-0E86367CCE30"] { map[id] = "İnflamasyon" }
        // İmmünoloji (19)
        for id in ["0DEEAB84-355B-4873-97A5-1DA97BA4411A", "2013E151-6C1C-4B1A-BC1F-EAFD93FADAE9", "61FCA2BF-B9BC-4CEE-A74F-190A27952BE8", "6E58AB8E-7AB7-4D5B-A343-FD7CCCAA2C74", "6FCCFECA-6CC1-4083-BCFD-54CA6CE5563F", "78FA2FAA-8C7C-4808-A73B-D52C342C9D64", "7B648300-5CB0-460E-9208-4F181BAFC9DA", "7BDF05CC-1ACB-43BF-B541-4848CB2968A6", "9013127C-D4BB-40E9-B3BD-99FD9FF374DA", "91ACD9BA-6BEF-413F-A803-06ABDABCBCA6", "96985653-F9B3-4C96-A5D3-08ABE36349D5", "B601B30C-1368-4BB4-9522-1C76B06138CB", "CEE754CC-1B78-40FB-816F-1668D7BD5F8A", "E82768E7-E768-4D9B-AD38-5340049B0198", "EA381E7B-5BE7-4AF5-90DA-4C6CA87D89C4", "EDD88EF8-BB8A-4DCD-872E-85F60C5B45B5", "F1CF0852-D49D-48D3-A77C-9CF3978CA67E", "F1D37B71-1BAF-413B-A451-DA3FE2AE8188", "F260A688-636A-477C-A75B-96E67E4535F5"] { map[id] = "İmmünoloji" }
        // Hücre Zedelenmesi (20)
        for id in ["0D7EA05B-F354-498E-B684-86F5BC89B626", "108E75C0-CD3C-4A87-BD64-5E4756762CE0", "1C4E38CE-7874-4E3E-9844-95C896D6AB10", "31E43016-7DC2-4787-8FBE-8F7A73DA26D2", "452E585A-361C-42BB-849B-B8BEBEBD1157", "4B7B7B45-E61F-4484-95C8-A0FBECAB2E57", "50376B0F-1E77-413E-82A0-5A6C6F2ABEA8", "5E5C47D7-75C0-4451-978E-B679BFE57C1B", "5EA0E3C5-74BC-4DEC-A442-A12E9D95EFC1", "7A17B7BA-84EB-4748-BEFE-E8B670B6B741", "7B046085-75E8-49CD-B285-98E3D0A4073D", "8687A428-33B9-4C65-AC07-A06F442D4134", "A5CC7F0F-6E63-412D-B32E-FB109C0F479F", "AF65DE38-5294-4024-B321-B50281F5F310", "D991F1F6-51BF-4172-BC63-EA4699330AEE", "DBC6A987-394A-4157-87A6-AAFC8ECE0B6B", "E27E1E6F-4F14-4B47-A664-24FD6B507CB1", "E5222AF9-3D72-4ADC-B4F0-A7A26BC5A5D7", "F32FDE1D-D2CB-459C-8C8D-ECDE99F54394", "F7F3B108-2E5F-45B7-981D-47D98675C169"] { map[id] = "Hücre Zedelenmesi" }
        // Solunum Sistem Hastalıkları (141)
        for id in ["07574536-0756-44CB-85B7-E31B6962299E", "0A7BD567-27C9-4516-8F86-E63785A73375", "0E0386C9-7DF1-448F-8C38-35E3D6E49C80", "103F8319-4B7C-4679-9DF7-2DB8552DF0D1", "10C49515-FAF0-4E5D-AF28-DE6FDE7912C6", "11B3856C-8BBA-4578-B177-57AE496AE879", "14FBCA8C-2694-4C45-AA84-F48CCBE814FF", "16067622-91B0-4B99-9FAE-821DE871E7FB", "19441E12-FF3F-4B24-92B7-4EA3CE984C38", "1B3E359E-C1DD-47D4-B23F-D3E81D7D8480", "1B8CD5A6-3295-4587-BFD3-1C5484F72BCD", "1E75C83A-D8B4-48EF-95FD-7A1B21215655", "1EEF2370-9AC6-4DDE-B456-41B5CC5A532D", "1FFB7EB9-992A-48BA-A9D3-87C2169E3F4D", "20177026-6B56-46AC-B4E0-546C5F8071A9", "2022DDAB-561D-4E00-9951-77004555480B", "24C1B946-B25E-4909-B286-4106D585ED78", "2558A670-D1FF-42A8-9CBF-2101DABE8BDA", "28BEC6AC-8581-4B1B-BF38-7442ADF2B343", "28D509DF-0A1C-42F7-BE90-C3BFC1659635", "32D82956-DA2C-47A2-A48A-B59CDB94CFA9", "33132AE3-4E36-48FA-97F6-FEDDA6EEBAF2", "33288C05-2913-474B-BF21-FD1509DA8B14", "336B903C-FE8E-4A3A-94E8-D9E01F9B3DCB", "340F874B-411A-43E4-9576-65F98DF4A94A", "34782F11-7496-4E65-A432-B42BD6363DF5", "379BADC8-F0CE-417D-BF56-381D75E0EFA1", "39C4D8CD-15BA-41D9-BA1F-995529A73B34", "3B70C826-6AED-4B8D-AD5F-6D1504A6F851", "3BE435EF-7C2B-48F6-944C-9D624653F142", "3EA21BA7-9F57-496C-AE78-A62E0F8393FA", "3F0926C4-8FFE-4209-9A9D-34396F4D80B4", "3F3568ED-6EB0-4628-9CC9-029C9846C433", "4198F263-14FD-4B17-AA04-2671871FB671", "421A4D60-CAFF-440E-A93F-67AFAA229098", "45AB275E-3F11-4102-94B6-9CA75D90CE45", "45E36C7A-9121-4554-A004-62086C6C4DA2", "47243DE6-5390-4805-87B1-4DA3A727CF11", "4967DEE2-2773-474C-AABC-78E13E144721", "4A42C52A-26DA-45A4-991C-8634923409DB", "4B5609FB-907A-4B49-B9A1-E52AF8F9A70C", "4D9CEB6E-B864-4FFF-B6C5-3B113251BC93", "4E0D4E36-7AAF-4D2C-8F9B-B0B65EE59B19", "4F38360D-2E48-4D74-8720-ABB1BAF3BE3F", "522B0654-5ECE-4834-8391-27153032E148", "52820468-1481-4BE4-83C4-942D37F8F493", "53F4B6EA-F9D6-459E-926A-E84856F80FD4", "5543FCAC-3B60-4F17-BA05-42AA162C5195", "56A0EA92-687E-496A-9F92-5A2156201F55", "59DD068B-B242-4375-A157-3781432FC472", "5AB49361-A896-4407-B2AC-32A562BAE392", "5B25CBC4-5177-40EE-92BF-1D6283524908", "5CBBB7A0-5CBA-4C07-9C55-B7F40C07E413", "5FB50FDA-147B-4DE2-A9CC-0735F0954167", "60455E1F-5D40-4324-A547-3D51532D3065", "619DDEA9-0C27-45F0-9EC7-B00A12F09C7E", "62DBDBBD-D96D-4E45-863C-2F30BF6E925E", "63465B91-CED2-41D7-89CD-8AFB4BEA9741", "64D75616-F114-4CCC-91C6-4B231FD0A2A4", "66182D36-075A-4698-989D-86DB13118717", "668C1A77-F222-4113-9A15-4DFFDFD8BAEB", "68FA855F-31F3-47F6-A31D-98261DA09AD2", "6C898016-4864-4F79-8AB3-6AD6E411147A", "6D9F0F18-7977-4940-A695-39F1C25C4E78", "6DF89C2A-9F9B-4375-894B-D55756C3DAE2", "71359251-5924-4949-AEF2-9EFA4E71E56B", "737CA912-3C8D-431D-8891-005E9AF94E2A", "75DCE005-7564-4DA8-A6FE-AB5B5D660C9F", "7A6C5010-F773-476B-A0A0-F84C3356D5CF", "7AF25800-10E4-482B-87D9-46E79DC11475", "7DA14C72-83FB-4BD6-9165-CD4CF93BEC91", "7E6EF8B7-1DB5-4751-AABD-2E0A95D0D5FC", "7ED5D9E7-96BD-47C3-A8C7-5E848374ADD6", "7F64EDE1-9956-437B-AED8-75B980D2B5C1", "8272A719-1F02-4E89-A96C-D56A24F656C7", "85346D30-4F83-4601-8C23-19DDD24CB956", "85373C9C-FAF2-4557-AE9A-99467AAE962D", "85638BDB-6C85-43C9-BA1A-92E21BC0A5EF", "86BAE42C-6D05-430E-AB5D-87149957D512", "8772A489-4BEE-4771-A318-EE9725578C04", "87AF1CF0-8869-4763-8D2A-4039AB7023D6", "89D7F528-C822-4B9C-B8BE-326A4B5D53A1", "8D88B084-D0C8-4908-8625-87E9776657B9", "8E359E41-D526-43F2-8C5D-FA4E323E9213", "925E956F-2EB1-47A0-AFAE-E2F23CDA996B", "9495AA9D-7E5D-4F76-87F0-A378E1D6124A", "9A29DACA-5A3D-4DF5-8D5F-60F449FB64C6", "9AFC485C-7CD8-475A-A602-9A512D67F49C", "9B79CF4F-135C-4B7F-A8A5-58A79CB10ED6", "9C7AFA97-3124-45FE-9841-ECBA114E08D2", "9C9E2247-C250-4455-8E91-DBC1F1D11C5C", "9E5BD350-D097-485E-BF7B-78B87E6B5CED", "9EDB4344-8575-403C-A892-81AF7524F0FB", "A4A99912-30A3-49B1-9ADB-CB5EEEE7A61F", "A73B41CB-3174-401B-A615-059122AF3959", "A872821F-3199-44EC-B6D6-42A075AD3E4C", "A87A9C73-0326-49E4-9C88-D862A618FF2F", "A9D0ACF3-C1B8-4DEA-9BD3-37D45D411268", "AAA7FF7D-815D-4C1B-9CDD-F90E51127234", "ACD0CB8C-25FE-41AA-A72D-5FCECC24E801", "AD4A5CFE-8B1A-4E47-A4E4-8E5012B19927", "AD7F835C-5884-41FF-BACB-09A75C57C707", "AE635C81-E9F0-4AFF-B6A4-6045604B2176", "AFA83F5A-56D1-4042-91B4-8CDEDCFD491D", "B33341AD-44AD-4B2C-AD20-B268FE3C9CF2", "B82C0E04-0A4B-4D62-9FFA-EFBAB7FEE04A", "BA02E589-7919-4B6F-9D03-E244328016C9", "BAEC1811-74FD-4366-A7F6-02DC4226C4DB", "BD57A59B-D8C5-4381-ABF8-C1044C3D79DA", "BE4D444D-86A8-40BA-A4CF-F1A44C3184EF", "BE98BF47-F8BD-48AF-94A2-3CA8EBBF1B95", "C0120295-E24E-48EA-B6CD-20F09D801AA6", "C455E693-504D-43ED-9AA3-7F3418AEB849", "C5351186-B741-48D3-BEA3-5C2667B93435", "C61F0CDF-E877-4B74-926D-5E588D26FFB7", "CA00C79D-FFDA-487C-B031-C25E7BF30DAF", "CFA2562D-C166-46BD-A3FB-D23F3D8E6BCF", "D05590C3-C948-4E48-9070-BEC0F06BE36B", "D57A0AC4-A92C-4959-9AA4-B56BD3B54E55", "D5F4447F-B190-4AFF-84F6-41E67543D80F", "D643C081-A252-4028-BBBC-B768F7A2B7C0", "D9DF0FA8-71F8-403B-9517-91C3B9011C46", "DA6B3E12-E173-4DB5-888C-1C353F752A44", "DBDECF8D-0D0F-4F53-B8AF-5099B1955E08", "DD578F77-C74A-46D6-8087-6680C6B2A2EA", "E1D469A1-8750-4505-BB95-57C30A2129B9", "E611F9C3-5380-43F5-983A-271A04E56426", "E8A1278D-DD73-47EF-9512-99E0F2AB14F1", "EC615B80-C8EA-4784-A6E3-472C8AE48CB9", "EE74A494-4509-435D-9A19-24E08C1C98FA", "EF2602D1-AD8A-406F-AB96-A2E6CEB12512", "F1E305AE-F7AE-497C-98B2-D8347D449596", "F5CCB10A-F9A8-4AA9-9C95-649BBCB87C26", "F83B77BF-42CA-4E0A-806D-84B5E4395A14", "F8FBA287-FF27-4F9B-8847-C73DA06EF24E", "FA956E4E-5D6E-401C-8829-61A577119CC9", "FBDD665B-A9AD-445B-9591-28FDF287FC6E", "FD61D710-50CF-4921-8E72-536AACC227D2", "FD728AA3-49F2-4BB6-BCE8-990DD05D1AFB", "FE162B44-E788-4620-94CD-13C224C2E65F", "FFF233E1-E6B2-400E-8E0A-85D6F0D20551"] { map[id] = "Solunum Sistem Hastalıkları" }
        // Kalp Hastalıkları (2)
        for id in ["8538CAD6-C931-48C6-9DFD-DF232EEF024C", "87DF00A1-645E-473D-B7BD-0CA340344BC3"] { map[id] = "Kalp Hastalıkları" }
        return map
    }()
}
