import Foundation
import SwiftData
import CizgiCore

/// One-time content classification for the pre-topic-rollout deck.
///
/// `SubjectBackfillMigration` gave every existing card "Patoloji" and left
/// `topic` nil, because a subject can be inferred generically ("the whole
/// deck is Patoloji") but a topic cannot — it depends on what the page was
/// actually about. This migration closes that gap for one specific, known
/// batch: the six page captures from 2026-08-07, before the model started
/// assigning topics itself (schema v2.2, 2026-08-08). Their card content —
/// chronic bronchitis/bronchiectasis, IPF/UIP/COP, pneumoconiosis/silicosis/
/// asbestosis, asthma/emphysema, lung and pleural tumors, mesothelioma — was
/// read once by hand from the Supabase job history and is entirely
/// respiratory-system pathology, so it all maps to the single canonical
/// topic "Solunum Sistemi Hastalıkları".
///
/// Matches by exact `front` text rather than "every nil-topic Patoloji card":
/// a future capture the model genuinely couldn't classify also lands on nil
/// topic, and must not be swept into this one batch's topic just because it
/// is unlabeled too. Only whole units (every card on them known) are moved —
/// a unit with even one unrecognized sibling is left alone rather than split,
/// though nothing in the known batch is expected to trigger that.
@MainActor
enum TopicBackfillMigration {
    static let flagKey = "cizgi.migration.topicBackfill.respiratoryLegacy.v1"
    private static let targetSubject = "Patoloji"
    private static let targetTopic = "Solunum Sistemi Hastalıkları"

    static func runIfNeeded(container: ModelContainer, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        // No schema, or the topic isn't canonical under it, means writing
        // nothing is safer than writing against a broken resource. Not
        // flagged done, so a later launch with the resource fixed retries.
        guard let schema = try? SubjectTopicSchema.bundled(),
              schema.isValidTopic(targetTopic, subject: targetSubject) else { return }

        let context = ModelContext(container)
        do {
            let units = try context.fetch(FetchDescriptor<KnowledgeUnit>())
            for unit in units {
                guard unit.subject == targetSubject,
                      unit.topic == nil,
                      !unit.cards.isEmpty,
                      unit.cards.allSatisfy({ knownFronts.contains($0.front) })
                else { continue }
                unit.topic = targetTopic
                unit.updatedAt = .now
            }
            try context.save()
            defaults.set(true, forKey: flagKey)
        } catch {
            // Retried next launch; half-written state must not survive.
            context.rollback()
        }
    }

    private static let knownFronts: Set<String> = [
        "Adenokarsinom prekürsör spektrumunda boyuta ve invazyona göre AAH, AIS ve minimal invaziv adenokarsinom nasıl ayrılır?",
        "Akciğer adenokarsinomunda sigara öyküsüne göre beklenen sürücü değişiklik farkı nedir?",
        "Akciğer adenokarsinomunu destekleyen patern ve immünohistokimyasal belirteçler nelerdir?",
        "Akciğer hamartomunun tipik radyolojik ve histolojik ipuçları nelerdir?",
        "Akciğer tümörlerinden hangileri TTF-1 pozitifliği gösterebilir?",
        "Alfa-1 antitripsin akciğer dokusunu amfizemden nasıl korur?",
        "Alfa-1 antitripsin eksikliğinde görülen tipik amfizem tipi ve dağılımı nedir?",
        "Amfibol ve serpentin asbest lifleri mezotelyoma riski ve lif yapısı bakımından nasıl ayrılır?",
        "Amfizemin işaretlenen morfolojik tanımı nedir?",
        "Asbest liflerinin demir içeren proteinoz materyalle kaplanmasıyla oluşan yapı nedir?",
        "Asbest liflerinin demir içeren proteinöz materyalle kaplanmasıyla oluşan yapı nedir?",
        "Asbest maruziyetinin en sık oluşturduğu lezyon nedir?",
        "Asbest maruziyetinin en sık yaptığı plevral lezyon hangisidir?",
        "Asbestoz akciğerde öncelikle hangi bölgeleri tutar ve bu yönüyle diğer birçok pnömokonyozdan nasıl ayrılır?",
        "Asbestozun akciğerdeki baskın yerleşimi, diğer birçok pnömokonyozdan nasıl ayrılır?",
        "Aspirin, duyarlı kişilerde hangi mekanizmayla bronkospazma yol açar?",
        "Astımda Charcot-Leyden kristalleri hangi hücresel proteinden oluşur?",
        "Astımda görülen Curschmann spiralleri nedir?",
        "Atopik astımda IL-4, IL-5 ve IL-13’ün temel etkileri nelerdir?",
        "Atopik astımla ilişkili IL-4, IL-5 ve IL-13 sitokin genlerinin kümelendiği kromozom hangisidir?",
        "Berilyoziste işaretlenen üç önemli özellik nedir?",
        "Bronşektazide bronşların kalıcı ve irreversibl dilatasyonu nasıl gelişir?",
        "Bronşektazinin işaretlenen tipik morfolojik dağılımı ve klinik balgam özelliği nedir?",
        "Çocukta akciğerde kalsifikasyon içeren kitle görüldüğünde, özellikle hangi ALK ilişkili tümör düşünülmelidir?",
        "DIP ile respiratuvar bronşiyolitle ilişkili interstisyel akciğer hastalığında sigara pigmentli makrofajların dağılımı nasıl farklıdır?",
        "Epitelyal mezotelyoma ile pulmoner adenokarsinom ayrımında kalretinin ve Claudin-4 nasıl kullanılır?",
        "Genç bir bireyde spontan pnömotoraksla özellikle ilişkilendirilen amfizem tipi hangisidir?",
        "Goodpasture sendromu ile idiyopatik pulmoner hemosiderozun işaretlenen ayırıcı özellikleri nelerdir?",
        "Goodpasture sendromunda akciğer ve böbrek tutulmasının ortak immünolojik hedefi nedir?",
        "Hava yolu obstrüksiyonunun geri dönüşebilirliği açısından bronşiyal astım ile amfizem nasıl ayrılır?",
        "Hipersensitivite pnömonisinin işaretlenen histopatolojik ve fonksiyonel özellikleri nelerdir?",
        "Hipersensitivite pnömonisinin işaretlenen temel patolojik ve fizyolojik özellikleri nelerdir?",
        "İdiyopatik pulmoner fibroziste tekrarlayan alveol epitel hasarı hangi temel profibrotik mediyatörü aktive eder?",
        "İPF/usual interstisyel pnömoni ile kriptojenik organize pnömoni temporal heterojenite ve fibrozisin yeri açısından nasıl ayrılır?",
        "İşaretlenen sekonder ve primer pulmoner hipertansiyon ipuçları nelerdir?",
        "Kömür işçisi pnömokonyozu hakkında karsinom ve tüberküloz sıklığı açısından sınav tuzağı nedir?",
        "Kronik bronşiti astımdan ayıran işaretli inflamatuvar hücre ipucu nedir?",
        "Kronik bronşitte Reid indeksi hangi yapısal oranı gösterir ve neden artar?",
        "Küçük hücreli akciğer karsinomunda Azzopardi etkisi nasıl oluşur?",
        "Küçük hücreli akciğer karsinomunun nöroendokrin kökenini destekleyen belirteçler nelerdir?",
        "Lambert-Eaton miyastenik sendromunda hedeflenen yapı nedir ve sendrom en klasik olarak hangi tümörle ilişkilidir?",
        "Lenfanjiyoleyomatozis en tipik olarak hangi hasta grubunu etkiler ve tümör hücrelerinde hangi hormon reseptörü bulunabilir?",
        "Malign mezotelyomanın işaretlenen iki çevresel etkeni nelerdir?",
        "Nazofarenks karsinomunda işaretlenen iki tipik klinik bulgu nedir?",
        "Nazofarenks karsinomunun özellikle undiferansiye tipi en güçlü olarak hangi viral etkenle ilişkilidir?",
        "Non-atopik astımda viral enfeksiyonlar hangi sinirsel yol üzerinden bronkokonstriksiyonu tetikleyebilir?",
        "Nöroendokrin kökenli olmayan büyük hücreli akciğer karsinomu nasıl tanınır?",
        "Otoimmün pulmoner alveoler proteinoziste alveollerde sürfaktan neden birikir?",
        "Otoimmün pulmoner alveoler proteinoziste sürfaktan neden alveollerde birikir ve nasıl boyanır?",
        "Plevranın en sık görülen tümörü nedir?",
        "Pnömokonyoz açısından en tehlikeli, distal hava yollarına ulaşabilen toz partikülü büyüklüğü nedir?",
        "Primer pulmoner arteriyel hipertansiyon için işaretlenen tipik demografik özellik ve genetik ilişki nedir?",
        "Pulmoner Langerhans hücreli histiyositozda hangi immünohistokimyasal belirteçler pozitiftir?",
        "Santral ve periferik akciğer tümörlerinin tipik histolojik dağılımı nasıldır?",
        "Sarkoidoz granülomlarında görülebilen Schaumann ve asteroid cisimleri hastalığa özgü müdür?",
        "Sarkoidoz granülomlarındaki Schaumann ve asteroid cisimleri hastalığa özgü müdür?",
        "Sarkoidozda periferik kandaki CD4+ T hücreleri azalırken bronkoalveoler lavajda CD4/CD8 oranı neden artar?",
        "Sarkoidozla ilişkili Löfgren ve Heerfordt sendromları hangi bulgularla tanınır?",
        "Sarkoidozla ilişkili Löfgren ve Heerfordt sendromlarının ayırt edici bileşenleri nelerdir?",
        "Sentriasiner amfizem en çok hangi akciğer bölgelerini etkiler ve hangi maruziyetlerle ilişkilidir?",
        "Sigara malign mezotelyoma için nedensel bir risk faktörü müdür?",
        "Silika maruziyetinde fibrozise katkı sağlayan, el yazısıyla not edilmiş inflamatuvar sitokinler hangileridir?",
        "Silikozisin işaretlenen tipik akciğer dağılımı, nodül yapısı ve lenf nodu bulgusu nedir?",
        "Skuamöz hücreli akciğer karsinomunun karakteristik morfolojik ve immünohistokimyasal bulguları nelerdir?",
        "Skuamöz papillom ve papillomatozis malignleşebilir mi?",
        "Soliter fibröz plevral tümörün asbestozis ile ilişkisi var mıdır?",
        "Soliter fibröz tümörde karakteristik moleküler değişiklik nedir?",
        "Soliter fibröz tümörün mezotelyomadan ayrımında CD34 ve keratin boyanma profili nasıldır?",
        "Tipik ve atipik bronşiyal karsinoid mitoz ve nekroz açısından nasıl ayrılır?",
        "Usual interstisyel pnömoni paterni yapabilen işaretli hastalıklar hangileridir?",
        "Yüksek doz berilyum maruziyetinde hangi iki önemli patoloji gelişebilir?",
    ]
}
