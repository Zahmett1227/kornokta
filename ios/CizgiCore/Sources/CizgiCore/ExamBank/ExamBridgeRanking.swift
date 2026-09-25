import Foundation

/// A card as the bridge reads it.
public struct ExamBridgeCard: Equatable, Sendable {
    public let id: UUID
    public let subject: String?
    public let topic: String?
    public let text: String

    public init(id: UUID, subject: String?, topic: String?, front: String, back: String, explanation: String?) {
        self.id = id
        self.subject = subject
        self.topic = topic
        self.text = [front, back, explanation ?? ""].joined(separator: "\n")
    }
}

/// The missed question, as the bridge reads it.
public struct ExamBridgeQuery: Equatable, Sendable {
    public let stem: String
    /// The key's option text — the fact the question was actually after.
    public let correctOption: String?
    /// The app's canonical subject (`ExamQuestion.subject`): cards carry the
    /// app's subjects, not ÖSYM's.
    public let subject: String?
    public let topic: String?
    /// Cards the owner linked to this question before; they lead the list.
    public let linkedCardIds: Set<UUID>

    public init(stem: String, correctOption: String?, subject: String?, topic: String?, linkedCardIds: Set<UUID> = []) {
        self.stem = stem
        self.correctOption = correctOption
        self.subject = subject
        self.topic = topic
        self.linkedCardIds = linkedCardIds
    }
}

public struct ExamBridgeCandidate: Equatable, Sendable {
    public let cardId: UUID
    public let score: Double
    public let isLinked: Bool
    public let sharesTopic: Bool
}

/// "Bu soruyu karşılayan bir kartın var mı?" — which of the owner's cards to
/// offer after a miss (plan §7.5). Deterministic, on the phone, no API: the
/// owner makes the call, this only puts the likely cards first.
///
/// The score is the IDF-weighted overlap of the question's words with the
/// card's. IDF is taken over the pool itself (the subject's active cards), so
/// a word every Farmakoloji card uses says nothing and a word two cards use
/// says a lot. The key's option counts double: it is the fact the question
/// tested, where the stem is mostly the case around it.
///
/// Words are compared by their first seven folded letters. Turkish is
/// agglutinative — "feokromositomada", "feokromositomanın" — and the deck's
/// terms are long; a fixed prefix is the standard cheap stemmer for it and
/// needs no dictionary. It does conflate a few pairs (hiperkalemi and
/// hiperkalsemi share "hiperka"), which costs one wrong candidate in a list
/// the owner reads, never a wrong link.
public enum ExamBridgeRanking {
    public static let maxCandidates = 8
    /// Below this, the overlap is common words only.
    public static let minimumScore = 2.0
    /// How much a card in the question's own topic is preferred.
    public static let sameTopicBoost = 1.5
    static let correctOptionWeight = 2.0
    static let minimumWordLength = 4
    static let stemLength = 7

    /// Exam boilerplate, folded (`CardSearch.fold`), matched as a word
    /// *prefix* so every suffixed form goes with it ("hastanın", "hastada").
    /// Only words that frame a question, never a medical term: the IDF weight
    /// already quiets common medical words, but it cannot quiet a word the
    /// cards never use and every question does.
    static let stopPrefixes: [String] = [
        "asagida", "yukarida", "hangi", "olasi", "yasind", "hasta", "degil", "dogru", "yanlis",
        "bulun", "gorul", "sonuc", "nedeniy", "olarak", "seklind", "basvur", "sikayet", "muayene",
        "bulgu", "erkek", "kadin", "cocuk", "gelen", "olgu", "sonra", "once", "daha", "fazla",
        "genell", "ozellik", "durum", "iliski", "ilgili", "sekil", "tablo", "grafik", "veril",
        "bunlar", "birlik", "arasi", "icind", "sahip", "gibi", "kadar", "olmay", "olmak", "oldug",
        "olan", "icin", "veya", "ancak", "asagi", "yapil", "saptan", "tespit", "izlen", "gozlen",
        "beklen", "kullan", "uygun", "ayrica", "yaklas", "sonucu",
    ]

    public static func rank(_ query: ExamBridgeQuery, cards: [ExamBridgeCard]) -> [ExamBridgeCandidate] {
        // The pool is the question's subject; linked cards join it whatever
        // their subject — the owner already said they answer this question.
        let pool = cards.filter { card in
            query.linkedCardIds.contains(card.id) || query.subject == nil || card.subject == query.subject
        }
        guard !pool.isEmpty else { return [] }

        let cardTerms = pool.map { Set(terms($0.text)) }
        var documentFrequency: [String: Int] = [:]
        for set in cardTerms {
            for term in set { documentFrequency[term, default: 0] += 1 }
        }
        let count = Double(pool.count)
        func idf(_ term: String) -> Double {
            log(1 + count / Double(documentFrequency[term] ?? 1))
        }

        var weights: [String: Double] = [:]
        for term in terms(query.stem) { weights[term] = 1 }
        for term in terms(query.correctOption ?? "") { weights[term] = correctOptionWeight }

        var candidates: [ExamBridgeCandidate] = []
        for (card, termsOfCard) in zip(pool, cardTerms) {
            var score = 0.0
            for (term, weight) in weights where termsOfCard.contains(term) {
                score += weight * idf(term)
            }
            let sharesTopic = query.topic != nil && card.topic == query.topic
            if sharesTopic { score *= sameTopicBoost }
            let isLinked = query.linkedCardIds.contains(card.id)
            guard isLinked || score >= minimumScore else { continue }
            candidates.append(ExamBridgeCandidate(cardId: card.id, score: score, isLinked: isLinked, sharesTopic: sharesTopic))
        }

        return Array(
            candidates.sorted { left, right in
                if left.isLinked != right.isLinked { return left.isLinked }
                if left.score != right.score { return left.score > right.score }
                return left.cardId.uuidString < right.cardId.uuidString
            }
            .prefix(maxCandidates)
        )
    }

    /// Folded, split into words, boilerplate and short words dropped, each
    /// cut to its stem.
    static func terms(_ text: String) -> [String] {
        let folded = CardSearch.fold(text)
        var words: [String] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= minimumWordLength,
                  !stopPrefixes.contains(where: current.hasPrefix) else { return }
            words.append(String(current.prefix(stemLength)))
        }
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}
